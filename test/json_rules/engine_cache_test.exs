defmodule JsonRules.EngineCacheTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  @conditions %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]}

  defp engine_with_age_fact(counter, fact_opts \\ []) do
    Engine.new()
    |> Engine.add_fact(
      "age",
      fn _params, _almanac ->
        TestSupport.inc(counter)
        22
      end,
      fact_opts
    )
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

  test "allows caching to be turned off per fact (fact option)" do
    # With `cache: false`, three rules referencing the same fact recompute it
    # each time, so the definition runs three times.
    counter = TestSupport.start_counter()
    engine = engine_with_age_fact(counter, cache: false)

    %RunResult{events: events} = Engine.run(engine)
    assert length(events) == 3
    assert TestSupport.count(counter) == 3
  end
end
