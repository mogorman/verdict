defmodule Verdict.EngineParallelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Almanac, Engine, RunResult}
  alias Verdict.TestSupport

  test "parallel produces the same results as serial" do
    build = fn schedule ->
      engine =
        Engine.new(schedule: schedule)
        |> Engine.add_fact("age", 22)
        |> Engine.add_fact("score", 90)
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
          event: %{type: "adult"},
          priority: 10
        })
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "score", operator: "greaterThanInclusive", value: 90}]},
          event: %{type: "high-score"},
          priority: 5
        })
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
          event: %{type: "can-drink"},
          priority: 5
        })
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "score", operator: "greaterThanInclusive", value: 100}]},
          event: %{type: "nope"},
          priority: 1
        })

      Engine.run(engine)
    end

    %RunResult{} = serial = build.(:serial)
    %RunResult{} = parallel = build.(:parallel)

    assert Enum.sort(Enum.map(serial.events, & &1.type)) ==
             Enum.sort(Enum.map(parallel.events, & &1.type))

    assert Enum.sort(Enum.map(serial.failure_events, & &1.type)) ==
             Enum.sort(Enum.map(parallel.failure_events, & &1.type))

    key = fn rr -> {rr.valid?, rr.event && rr.event.type} end
    assert Enum.sort(Enum.map(serial.results, key)) == Enum.sort(Enum.map(parallel.results, key))
  end

  test "a runtime fact added in a higher bucket is visible to a lower bucket" do
    engine =
      Engine.new(schedule: :parallel)
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
        event: %{type: "setDrinkingFlag", params: %{canOrderDrinks: true}},
        priority: 100
      })
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "canOrderDrinks", operator: "equal", value: true}]},
        event: %{type: "offerDrink"},
        priority: 1
      })
      |> Engine.add_fact("age", 21)
      |> Engine.on("success", fn event, almanac, _rr ->
        if event.type == "setDrinkingFlag" do
          Almanac.add_runtime_fact(almanac, "canOrderDrinks", event.params[:canOrderDrinks])
        end
      end)

    %RunResult{events: events} = Engine.run(engine)

    assert Enum.sort(Enum.map(events, & &1.type)) == ["offerDrink", "setDrinkingFlag"]
  end

  test "stop() halts before the next priority bucket" do
    age_counter = TestSupport.start_counter()
    segment_counter = TestSupport.start_counter()

    engine =
      Engine.new(schedule: :parallel)
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
        event: %{type: "adult"},
        priority: 100
      })
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "segment", operator: "equal", value: "human"}]},
        event: %{type: "human"},
        priority: 1
      })
      |> Engine.add_fact("age", fn _p, _a ->
        TestSupport.inc(age_counter)
        20
      end)
      |> Engine.add_fact("segment", fn _p, _a ->
        TestSupport.inc(segment_counter)
        "human"
      end)
      |> Engine.on("success", fn _event, almanac, _rr ->
        Almanac.stop(almanac)
      end)

    %RunResult{events: events} = Engine.run(engine)

    # only the higher-priority bucket fired before the stop
    assert length(events) == 1
    assert TestSupport.count(age_counter) == 1
    assert TestSupport.count(segment_counter) == 0
  end

  test "rules within a bucket run concurrently" do
    {:ok, agent} = Agent.start(fn -> %{inflight: 0, max: 0} end)
    engine = overlapping_engine(agent)

    %RunResult{events: events} = Engine.run(engine, %{}, parallel_concurrency: 3)

    assert length(events) == 3
    assert Agent.get(agent, & &1.max) >= 2
  end

  test "parallel_concurrency caps how many rules run at once" do
    {:ok, agent} = Agent.start(fn -> %{inflight: 0, max: 0} end)
    engine = overlapping_engine(agent)

    %RunResult{events: events} = Engine.run(engine, %{}, parallel_concurrency: 1)

    assert length(events) == 3
    assert Agent.get(agent, & &1.max) == 1
  end

  test "a fact can read another fact's value (re-entrant compute through the shared almanac)" do
    engine =
      Engine.new(schedule: :parallel)
      |> Engine.add_fact("base", fn _p, _a -> %{age: 20} end)
      |> Engine.add_fact("age", fn _p, almanac ->
        Map.fetch!(Almanac.fact_value(almanac, "base"), :age)
      end)
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "age", operator: "lessThanInclusive", value: 25}]},
        event: %{type: "young"}
      })
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
        event: %{type: "adult"}
      })

    %RunResult{events: events} = Engine.run(engine)

    # both rules share a bucket and run concurrently; each reads "age", which
    # re-entrantly reads "base" through the shared almanac
    assert Enum.sort(Enum.map(events, & &1.type)) == ["adult", "young"]
  end

  # Three same-priority rules, each backed by a distinct fact that records how
  # many facts are being computed at once. Used by the concurrency tests.
  defp overlapping_engine(agent) do
    Enum.reduce(1..3, Engine.new(schedule: :parallel), fn i, engine ->
      engine
      |> Engine.add_fact("f#{i}", fn _p, _a ->
        Agent.update(agent, fn s ->
          %{s | inflight: s.inflight + 1, max: max(s.max, s.inflight + 1)}
        end)

        Process.sleep(150)

        Agent.update(agent, fn s -> %{s | inflight: s.inflight - 1} end)
        :done
      end)
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "f#{i}", operator: "equal", value: :done}]},
        event: %{type: "r#{i}"}
      })
    end)
  end
end
