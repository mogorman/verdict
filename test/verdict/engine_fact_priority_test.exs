defmodule Verdict.EngineFactPriorityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}
  alias Verdict.TestSupport

  @event %{type: "adult-human-admins"}

  # The three leaf conditions are declared in the order c, a, b — deliberately
  # NOT in fact-priority order (a=100, b=50, c=1). This proves the evaluation
  # follows the fact's registered priority, not the declaration order.
  defp conditions(kind) do
    %{
      kind => [
        %{fact: "c", operator: "equal", value: true},
        %{fact: "a", operator: "equal", value: true},
        %{fact: "b", operator: "equal", value: true}
      ]
    }
  end

  defp run(kind, a, b, c) do
    ca = TestSupport.start_counter()
    cb = TestSupport.start_counter()
    cc = TestSupport.start_counter()

    engine =
      Engine.new()
      |> Engine.add_fact(
        "a",
        fn _p, _al ->
          TestSupport.inc(ca)
          a
        end,
        priority: 100
      )
      |> Engine.add_fact(
        "b",
        fn _p, _al ->
          TestSupport.inc(cb)
          b
        end,
        priority: 50
      )
      |> Engine.add_fact(
        "c",
        fn _p, _al ->
          TestSupport.inc(cc)
          c
        end,
        priority: 1
      )
      |> TestSupport.add_rule(%{conditions: conditions(kind), event: @event})

    result = Engine.run(engine)
    {result, TestSupport.count(ca), TestSupport.count(cb), TestSupport.count(cc)}
  end

  test "all: highest-priority fact is evaluated first; a failure short-circuits the rest" do
    # a (priority 100) fails and is declared 2nd. c (declared 1st, priority 1)
    # must never be evaluated because a's failure decides the all first.
    {result, a, b, c} = run(:all, false, true, true)
    assert %RunResult{events: []} = result
    assert {a, b, c} == {1, 0, 0}
  end

  test "all: when the highest-priority fact passes, the next priority is evaluated" do
    {result, a, b, c} = run(:all, true, false, true)
    assert %RunResult{events: []} = result
    assert {a, b, c} == {1, 1, 0}
  end

  test "any: highest-priority fact is evaluated first; a success short-circuits the rest" do
    {result, a, b, c} = run(:any, true, false, false)
    assert %RunResult{events: [event]} = result
    assert event.type == "adult-human-admins"
    assert {a, b, c} == {1, 0, 0}
  end

  test "any: when the highest-priority fact fails, the next priority is evaluated" do
    {result, a, b, c} = run(:any, false, true, false)
    assert %RunResult{events: [_]} = result
    assert {a, b, c} == {1, 1, 0}
  end
end
