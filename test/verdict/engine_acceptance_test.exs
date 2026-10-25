defmodule Verdict.EngineAcceptanceTest do
  @moduledoc """
  Acceptance test ported from the reference engine's `test/acceptance/acceptance.js`.

  These scenarios exercise several features *in combination* — rule and fact
  priority ordering, fact `params` and JSONPath `path`, facts reading other
  facts, a rule-level success callback that creates a runtime fact, and a
  condition whose `value` is itself a `{fact, path}` reference — because that
  combination is where integration bugs hide.

  The assertions are adapted to this engine's `Verdict.RuleResult` shape
  (`valid?`, `event`, `rule`, and the evaluation `changeset`) rather than the
  reference's JSON `results[].conditions` tree.
  """
  use ExUnit.Case, async: true

  alias Verdict.{Almanac, Engine}
  alias Verdict.TestSupport

  defp setup_engine(%{high_priority_value: h, low_priority_value: l}) do
    fact_order = TestSupport.start_collector()

    engine =
      Engine.new()
      |> Engine.add_fact("sub-fact", fn _params, almanac ->
        Almanac.fact_value(almanac, "baseIndex")
      end)
      |> Engine.add_fact(
        "high-priority",
        fn params, almanac ->
          TestSupport.collect(fact_order, "high-priority")
          %{"values" => [Almanac.fact_value(almanac, "sub-fact") + params[:factParam]]}
        end,
        priority: 2
      )
      |> Engine.add_fact(
        "low-priority",
        fn _params, almanac ->
          TestSupport.collect(fact_order, "low-priority")
          Almanac.fact_value(almanac, "sub-fact") + 1
        end,
        priority: 1
      )
      |> Engine.add_operator(
        "containsDivisibleValuesOf",
        fn fact_value, json_value ->
          is_list(fact_value) and is_integer(json_value) and
            Enum.any?(fact_value, &(rem(&1, json_value) == 0))
        end
      )

    {:ok, engine, first} =
      Engine.add_rule(engine, %{
        name: "first",
        priority: 10,
        event: %{type: "event-1", params: %{eventParam: 1}},
        conditions: %{
          all: [
            %{
              fact: "high-priority",
              params: %{factParam: 1},
              operator: "contains",
              path: "$.values",
              value: h
            },
            %{fact: "low-priority", operator: "in", value: l}
          ]
        }
      })

    engine =
      Engine.on_rule(engine, first.id, "success", fn _event, almanac, _rule_result ->
        Almanac.add_runtime_fact(almanac, "rule-created-fact", %{"array" => h})
      end)

    {:ok, engine, _second} =
      Engine.add_rule(engine, %{
        name: "second",
        priority: 1,
        event: %{type: "event-2"},
        conditions: %{
          all: [
            %{
              fact: "high-priority",
              params: %{factParam: 1},
              operator: "containsDivisibleValuesOf",
              path: "$.values",
              value: %{fact: "rule-created-fact", path: "$.array"}
            }
          ]
        }
      })

    success = TestSupport.start_collector()
    failure = TestSupport.start_collector()

    engine =
      engine
      |> Engine.on("success", fn event, _a, _r -> TestSupport.collect(success, event.type) end)
      |> Engine.on("failure", fn event, _a, _r ->
        TestSupport.collect(failure, event && event.type)
      end)

    handles = %{fact_order: fact_order, success: success, failure: failure}
    {engine, handles}
  end

  test "succeeds when both rules' conditions are satisfied" do
    {engine, handles} = setup_engine(%{high_priority_value: 2, low_priority_value: [2]})

    result = Engine.run(engine, %{"baseIndex" => 1})

    # Results, in priority order (first=10, second=1).
    [first, second] = result.results
    assert first.valid?
    assert first.event.type == "event-1"
    assert first.rule.name == "first"
    assert first.rule.priority == 10
    assert second.valid?
    assert second.event.type == "event-2"
    assert second.rule.name == "second"
    assert second.rule.priority == 1

    # First rule: both leaves pass; the report carries the computed facts and
    # the path-resolved actuals.
    assert first.changeset.valid?
    assert first.changeset.data[:facts][:"high-priority"] == %{"values" => [2]}
    assert first.changeset.data[:facts][:"low-priority"] == 2
    assert change_for(first, :"high-priority") == %{actual: [2], operator: "contains", value: 2}
    assert change_for(first, :"low-priority") == %{actual: 2, operator: "in", value: [2]}

    # Second rule: its condition value is a reference to the runtime fact the
    # first rule's success callback created; it resolves to 2 and the custom
    # operator passes.
    assert second.changeset.data[:facts][:"high-priority"] == %{"values" => [2]}

    assert change_for(second, :"high-priority") == %{
             actual: [2],
             operator: "containsDivisibleValuesOf",
             value: 2
           }

    # Events and callbacks.
    assert Enum.map(result.events, & &1.type) == ["event-1", "event-2"]
    assert result.failure_events == []
    assert TestSupport.collected(handles.success) == ["event-1", "event-2"]
    assert TestSupport.collected(handles.failure) == []

    # The high-priority fact is computed before the low-priority one.
    assert_fact_order(handles.fact_order)
  end

  test "fails when a condition is unsatisfied" do
    {engine, handles} = setup_engine(%{high_priority_value: 2, low_priority_value: [3]})

    # The first rule fails, so its success callback never runs and the
    # `rule-created-fact` it would create is never added; seed an empty one so
    # the second rule's reference resolves instead of raising.
    result = Engine.run(engine, %{"baseIndex" => 1, "rule-created-fact" => ""})

    [first, second] = result.results
    refute first.valid?
    refute second.valid?

    assert result.events == []
    # neither rule declares a failure_event, so none are reported; the
    # "failure" callbacks still fire, with a nil payload
    assert result.failure_events == []
    assert TestSupport.collected(handles.success) == []
    assert TestSupport.collected(handles.failure) == [nil, nil]

    # The high-priority fact is still computed before the low-priority one.
    assert_fact_order(handles.fact_order)
  end

  defp change_for(rule_result, field) do
    {^field, info} = Enum.find(rule_result.changeset.changes, fn {f, _} -> f == field end)
    info
  end

  defp assert_fact_order(collector) do
    order = TestSupport.collected(collector)
    assert "high-priority" in order
    assert "low-priority" in order

    assert Enum.find_index(order, &(&1 == "high-priority")) <
             Enum.find_index(order, &(&1 == "low-priority"))
  end
end
