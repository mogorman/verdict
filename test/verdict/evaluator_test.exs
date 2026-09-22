defmodule Verdict.EvaluatorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Condition, Evaluator, Event, Fact, Rule, RunResult}

  # Drives `Evaluator.run/4` directly to exercise the parallel-scheduler's error
  # handling and the `replace_facts_in_event_params` event-param resolution, which
  # are not reachable through the happy path of `Engine.run/3`.

  defp rule_for(fact) do
    %Rule{
      id: "r",
      name: "r",
      priority: 1,
      event: %Event{type: "e"},
      conditions: %Condition{
        kind: :all,
        priority: 1,
        children: [%Condition{kind: :leaf, fact: fact, operator: "equal", value: 1}]
      }
    }
  end

  test "a rule that raises under :parallel re-raises the error" do
    defs = %{"boom" => Fact.new("boom", fn _p, _a -> raise "boom happened" end)}

    assert_raise RuntimeError, ~r/boom happened/, fn ->
      Evaluator.run([rule_for("boom")], defs, %{}, schedule: :parallel)
    end
  end

  test "a task that exits under :parallel raises an unexpected-result error" do
    # Trap exits so the linked worker's exit is routed through the task's monitor
    # (as an `{:exit, _}` result) rather than tearing down this process.
    prev = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, prev) end)

    defs = %{"boom" => Fact.new("boom", fn _p, _a -> exit(:boom_exited) end)}

    assert_raise RuntimeError, ~r/unexpected task result/, fn ->
      Evaluator.run([rule_for("boom")], defs, %{}, schedule: :parallel)
    end
  end

  test "replace_facts passes a nil-params event through unchanged" do
    rule = %Rule{
      id: "r",
      name: "r",
      priority: 1,
      event: %Event{type: "e", params: nil},
      conditions: %Condition{
        kind: :all,
        priority: 1,
        children: [%Condition{kind: :leaf, fact: "a", operator: "equal", value: 1}]
      }
    }

    defs = %{"a" => Fact.new("a", 1)}
    assert %RunResult{} = Evaluator.run([rule], defs, %{}, replace_facts_in_event_params: true)
  end
end
