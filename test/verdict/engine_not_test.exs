defmodule Verdict.EngineNotTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}
  alias Verdict.TestSupport

  @event %{type: "ageTrigger", params: %{demographic: "under50"}}
  @conditions %{not: %{fact: "age", operator: "greaterThanInclusive", value: 50}}

  test "emits when the inner condition is false" do
    engine =
      Engine.new()
      |> Engine.add_fact("age", 10)
      |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

    assert %RunResult{events: [%_struct{type: "ageTrigger"}]} = Engine.run(engine)
  end

  test "does not emit when the inner condition is true" do
    engine =
      Engine.new()
      |> Engine.add_fact("age", 75)
      |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

    assert %RunResult{events: []} = Engine.run(engine)
  end
end
