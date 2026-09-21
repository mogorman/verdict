defmodule Verdict.EngineFailureTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}
  alias Verdict.TestSupport

  @event %{type: "generic"}
  @conditions %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]}

  test "emits a failure event when a rule fails" do
    engine =
      Engine.new()
      |> Engine.add_fact("age", 10)
      |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

    assert %RunResult{events: [], failure_events: [%_struct{type: "generic"}]} =
             Engine.run(engine)
  end

  test "does not emit a failure event when a rule passes" do
    engine =
      Engine.new()
      |> Engine.add_fact("age", 50)
      |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

    assert %RunResult{events: [%_struct{type: "generic"}], failure_events: []} =
             Engine.run(engine)
  end
end
