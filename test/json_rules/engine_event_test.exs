defmodule JsonRules.EngineEventTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Almanac, Engine, RunResult}
  alias JsonRules.TestSupport

  @event %{type: "setDrinkingFlag", params: %{canOrderDrinks: true}}

  defp drinking_engine(facts) do
    engine =
      Engine.new()
      |> TestSupport.add_rule(%{
        conditions: %{
          any: [
            %{name: "over 21", fact: "age", operator: "greaterThanInclusive", value: 21},
            %{fact: "qualified", operator: "equal", value: true}
          ]
        },
        event: @event,
        priority: 100
      })

    Enum.reduce(facts, engine, fn {name, value}, e ->
      Engine.add_fact(e, to_string(name), value)
    end)
  end

  test "success callback receives the full event, an almanac, and the rule result" do
    collected = TestSupport.start_collector()

    engine =
      drinking_engine(age: 21, qualified: false)
      |> Engine.on("success", fn event, almanac, rr ->
        TestSupport.collect(collected, {:success, event, almanac, rr})
      end)
      |> Engine.on("failure", fn event, _a, _rr ->
        TestSupport.collect(collected, {:failure, event})
      end)

    %RunResult{results: [rr], failure_events: []} = Engine.run(engine)

    assert rr.valid?
    assert [{:success, event, almanac, _rr}] = TestSupport.collected(collected)
    assert event.type == "setDrinkingFlag"
    assert event.params == %{canOrderDrinks: true}
    assert %Almanac{} = almanac
  end

  test "a specific event type callback receives the event params (success only)" do
    collected = TestSupport.start_collector()

    engine =
      drinking_engine(age: 21, qualified: false)
      |> Engine.on("setDrinkingFlag", fn params, _a, _rr ->
        TestSupport.collect(collected, params)
      end)

    Engine.run(engine)

    # the type callback gets params, not the full event
    assert [%{canOrderDrinks: true}] = TestSupport.collected(collected)
  end

  test "failure callback receives the full event for an invalid rule" do
    collected = TestSupport.start_collector()

    engine =
      drinking_engine(age: 10, qualified: false)
      |> Engine.on("failure", fn event, _a, rr ->
        TestSupport.collect(collected, {event.type, rr.valid?})
      end)
      |> Engine.on("success", fn _e, _a, _rr -> TestSupport.collect(collected, :success) end)

    %RunResult{failure_events: [event], events: []} = Engine.run(engine)

    assert event.type == "setDrinkingFlag"
    assert [{"setDrinkingFlag", false}] = TestSupport.collected(collected)
  end

  test "an event handler can add a runtime fact that later rules read" do
    offered = TestSupport.start_collector()

    engine =
      Engine.new()
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
        event: %{type: "setDrinkingFlag", params: %{canOrderDrinks: true}},
        priority: 100
      })
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "canOrderDrinks", operator: "equal", value: true}]},
        event: %{type: "offerDrink", params: %{wine: "merlot", quantity: 2}},
        priority: 1
      })
      |> Engine.add_fact("age", 21)
      |> Engine.on("success", fn event, almanac, _rr ->
        case event.type do
          "setDrinkingFlag" ->
            Almanac.add_runtime_fact(almanac, "canOrderDrinks", event.params[:canOrderDrinks])

          "offerDrink" ->
            TestSupport.collect(offered, event.params)
        end
      end)

    %RunResult{events: events} = Engine.run(engine)

    # the second (lower-priority) rule saw the runtime fact added by the first
    assert Enum.map(events, & &1.type) == ["setDrinkingFlag", "offerDrink"]
    assert [%{wine: "merlot", quantity: 2}] = TestSupport.collected(offered)
  end

  describe "replace_facts_in_event_params" do
    @counted %{type: "countedEnough", params: %{count: %{fact: "count"}}}

    defp counted_engine(opts \\ []) do
      Engine.new(opts)
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "success", operator: "equal", value: true}]},
        event: @counted,
        priority: 100
      })
    end

    test "resolves fact refs in event params when enabled" do
      collected = TestSupport.start_collector()

      engine =
        counted_engine(replace_facts_in_event_params: true)
        |> Engine.on("success", fn event, _a, _rr -> TestSupport.collect(collected, event) end)

      %RunResult{results: [rr]} = Engine.run(engine, %{success: true, count: 5})

      assert rr.event.params == %{count: 5}
      assert [%{type: "countedEnough", params: %{count: 5}}] = TestSupport.collected(collected)
    end

    test "keeps fact refs unresolved when disabled" do
      engine = counted_engine()

      %RunResult{results: [rr]} = Engine.run(engine, %{success: true, count: 5})

      assert rr.event.params == %{count: %{fact: "count"}}
    end
  end

  describe "rule-level callbacks" do
    test "a rule-level callback fires only for its own rule" do
      target = TestSupport.start_collector()

      engine = Engine.new() |> Engine.add_fact("age", 21)

      {:ok, engine, rule1} =
        Engine.add_rule(engine, %{
          conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
          event: %{type: "r1"},
          priority: 100
        })

      {:ok, engine, _rule2} =
        Engine.add_rule(engine, %{
          conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
          event: %{type: "r2"},
          priority: 1
        })

      engine =
        Engine.on_rule(engine, rule1.id, "success", fn event, _a, _rr ->
          TestSupport.collect(target, event.type)
        end)

      Engine.run(engine)

      # both rules succeed, but the rule-level callback is registered only on
      # rule1, so it fires once — for rule1
      assert ["r1"] == TestSupport.collected(target)
    end
  end
end
