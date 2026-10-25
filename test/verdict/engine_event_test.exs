defmodule Verdict.EngineEventTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Almanac, Engine, RunResult}
  alias Verdict.TestSupport

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

  describe "eex_string event params" do
    test "renders markers to the specific-type callback and RunResult.events" do
      collected = TestSupport.start_collector()

      engine =
        Engine.new()
        |> Engine.add_fact("name", "Mog")
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]},
          event: %{
            type: "greeted",
            params: %{
              message: %{eex_string: "Hello <%= name %>!"},
              nested: %{inner: %{eex_string: "<%= name %>"}}
            }
          }
        })
        |> Engine.on("greeted", fn params, _a, _rr ->
          TestSupport.collect(collected, params)
        end)

      %RunResult{events: [event]} = Engine.run(engine, %{ok: true})

      expected = %{message: "Hello Mog!", nested: %{inner: "Mog"}}
      assert event.params == expected
      assert [rendered] = TestSupport.collected(collected)
      assert rendered == expected
    end

    test "rejects an ill-formed eex_string template at add_rule" do
      engine = Engine.new()

      assert {:error, changeset} =
               Engine.add_rule(engine, %{
                 name: "bad",
                 conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]},
                 event: %{type: "greeted", params: %{message: %{eex_string: "<%= unclosed"}}}
               })

      assert changeset.errors != []
    end

    test "raises at run time for control flow when allow_unsafe_eex is off" do
      engine =
        Engine.new()
        |> Engine.add_fact("n", 1)
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]},
          event: %{type: "t", params: %{m: %{eex_string: "<%= if n do %>y<% end %>"}}}
        })

      assert_raise ArgumentError, ~r/control flow/, fn -> Engine.run(engine, %{ok: true}) end
    end

    test "renders control flow when allow_unsafe_eex is true" do
      engine =
        Engine.new()
        |> Engine.add_fact("n", 1)
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]},
          event: %{type: "t", params: %{m: %{eex_string: "<%= if n do %>y<% end %>"}}}
        })

      %RunResult{events: [event]} = Engine.run(engine, %{ok: true}, allow_unsafe_eex: true)
      assert event.params == %{m: "y"}
    end

    test "typed markers render to their Elixir types in the emitted event" do
      engine =
        Engine.new()
        |> Engine.add_fact("name", "Mog")
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]},
          event: %{
            type: "scored",
            params: %{
              label: %{eex_string: "<%= name %>"},
              score: %{eex_integer: "<%= points %>"},
              ratio: %{eex_float: "<%= points %>"},
              active: %{eex_boolean: "<%= active %>"},
              badges: %{eex_list: "[\"gold\"]"}
            }
          }
        })

      %RunResult{events: [event]} =
        Engine.run(engine, %{ok: true, points: 10, active: true})

      assert event.params == %{
               label: "Mog",
               score: 10,
               ratio: 10.0,
               active: true,
               badges: ["gold"]
             }
    end

    test "failure events are rendered like success events when the rule is false" do
      collected = TestSupport.start_collector()

      engine =
        Engine.new()
        |> Engine.add_fact("name", "Mog")
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]},
          event: %{type: "greeted", params: %{message: %{eex_string: "Hello <%= name %>!"}}}
        })
        |> Engine.on("failure", fn event, _a, _rr ->
          TestSupport.collect(collected, event)
        end)

      %RunResult{events: [], failure_events: [event]} = Engine.run(engine, %{ok: false})

      # the failure event is rendered exactly like a success event would be
      assert event.params == %{message: "Hello Mog!"}
      assert [rendered] = TestSupport.collected(collected)
      assert rendered.params == %{message: "Hello Mog!"}
    end
  end

  test "a rule's failure_event replaces its success event in failure results when it does not fire" do
    engine =
      Engine.new()
      |> TestSupport.add_rule(%{
        conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
        event: %{type: "success-type"},
        failure_event: %{type: "failure-type", params: %{why: "too young"}},
        priority: 1
      })

    %RunResult{events: [], failure_events: [fe], results: [rr]} = Engine.run(engine, %{age: 10})

    assert fe.type == "failure-type"
    assert fe.params == %{why: "too young"}
    assert Verdict.RuleResult.to_map(rr)["failure_event"] ==
             %{"type" => "failure-type", "params" => %{why: "too young"}}
  end
end
