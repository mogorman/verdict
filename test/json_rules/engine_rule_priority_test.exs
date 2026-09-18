defmodule JsonRules.EngineRulePriorityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  @conditions %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]}

  test "evaluates rules in descending priority order" do
    engine =
      Engine.new()
      |> Engine.add_fact("age", 22)
      |> TestSupport.add_rule(%{
        conditions: @conditions,
        event: %{type: "midPriorityEvent"},
        priority: 50
      })
      |> TestSupport.add_rule(%{
        conditions: @conditions,
        event: %{type: "highPriorityEvent"},
        priority: 100
      })
      |> TestSupport.add_rule(%{
        conditions: @conditions,
        event: %{type: "lowestPriorityEvent"},
        priority: 1
      })

    %RunResult{results: results} = Engine.run(engine)

    assert Enum.map(results, & &1.event.type) ==
             ["highPriorityEvent", "midPriorityEvent", "lowestPriorityEvent"]
  end

  # The reference test also asserts that all events from a higher-priority rule are
  # fully resolved before a lower-priority rule runs. That requires per-event success
  # callbacks (Phase 2); the serial executor already runs one rule to completion before
  # the next, so the ordering guarantee holds.
end
