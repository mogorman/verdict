defmodule JsonRules.EngineCacheTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  @conditions %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]}

  defp engine_with_age_fact(counter) do
    Engine.new()
    |> Engine.add_fact("age", fn _params, _almanac ->
      TestSupport.inc(counter)
      22
    end)
    |> TestSupport.add_rule(%{
      conditions: @conditions,
      event: %{type: "setDrinkingFlag"},
      priority: 100
    })
    |> TestSupport.add_rule(%{
      conditions: @conditions,
      event: %{type: "isCollegeSenior"},
      priority: 1
    })
    |> TestSupport.add_rule(%{
      conditions: @conditions,
      event: %{type: "isCollegeSenior"},
      priority: 50
    })
  end

  test "loads a shared fact once and caches the result for future use" do
    counter = TestSupport.start_counter()
    engine = engine_with_age_fact(counter)

    %RunResult{events: events} = Engine.run(engine)
    assert length(events) == 3
    assert TestSupport.count(counter) == 1
  end

  @tag :phase_2
  test "allows caching to be turned off per fact (fact option)" do
    # Requires the per-fact `cache: false` option (Phase 2). When three rules reference
    # the same uncached fact, the definition must run three times.
    counter = TestSupport.start_counter()
    engine = engine_with_age_fact(counter)

    %RunResult{events: events} = Engine.run(engine)
    assert length(events) == 3
    assert TestSupport.count(counter) == 3
  end
end
