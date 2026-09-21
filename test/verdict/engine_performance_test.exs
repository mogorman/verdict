defmodule Verdict.EnginePerformanceTest do
  @moduledoc """
  A lightweight performance *sanity* check, not a precise benchmark (use `mix bench`
  and `docs/benchmarks.md` for that). It builds a sizeable engine and asserts a run
  both produces the right results and completes within a generous wall-clock budget,
  so a catastrophic regression — an accidental quadratic, a deadlock, a runaway —
  fails CI instead of shipping silently. The budget is deliberately loose so the
  test does not flake on slow machines.
  """
  use ExUnit.Case, async: true

  alias Verdict.Engine

  @rules 1000
  # Wall-clock budget (ms) for a run over `@rules` two-condition rules. Locally
  # this run takes single-digit milliseconds, so 2s is ~200x headroom: it will not
  # flake on a slow CI machine, yet it fails on a regression that makes the run
  # hundreds of times slower.
  @budget_ms 2_000

  test "performs 1000 'any' rules quickly" do
    engine = build_engine(%{any: base_conditions()})
    {elapsed_ms, result} = run!(engine)
    assert length(result.events) == @rules
    assert_under_budget(elapsed_ms)
  end

  test "performs 1000 'all' rules quickly" do
    engine = build_engine(%{all: base_conditions()})
    {elapsed_ms, result} = run!(engine)
    assert length(result.events) == @rules
    assert_under_budget(elapsed_ms)
  end

  defp base_conditions do
    [
      %{fact: "age", operator: "lessThan", value: 50},
      %{fact: "segment", operator: "equal", value: "european"}
    ]
  end

  defp build_engine(conditions) do
    engine =
      Enum.reduce(1..@rules, Engine.new(), fn i, engine ->
        {:ok, engine, _} =
          Engine.add_rule(engine, %{
            name: "rule-#{i}",
            event: %{type: "ageTrigger"},
            conditions: conditions
          })

        engine
      end)

    engine
    |> Engine.add_fact("segment", "european", cache: true)
    |> Engine.add_fact("age", 15, cache: true)
  end

  defp run!(engine) do
    start = System.monotonic_time(:millisecond)
    result = Engine.run(engine, %{})
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp assert_under_budget(elapsed_ms) do
    assert elapsed_ms < @budget_ms,
           "run took #{elapsed_ms}ms, over the #{@budget_ms}ms budget"
  end
end
