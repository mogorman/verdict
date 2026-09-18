defmodule JsonRules.EngineAnyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  describe "single \"any\" condition" do
    @event %{type: "ageTrigger", params: %{demographic: "under50"}}
    @conditions %{any: [%{fact: "age", operator: "lessThan", value: 50}]}

    test "emits when the condition is met" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 10)
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: [%_struct{type: "ageTrigger"}]} = Engine.run(engine)
    end

    test "does not emit when the condition fails" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 75)
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: []} = Engine.run(engine)
    end
  end

  describe "\"any\" with multiple conditions" do
    @event %{type: "ageTrigger", params: %{demographic: "under50"}}

    @conditions %{
      any: [
        %{fact: "age", operator: "lessThan", value: 50},
        %{fact: "segment", operator: "equal", value: "european"}
      ]
    }

    test "emits when the first condition is met and the second is not" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 25)
        |> Engine.add_fact("segment", "north-american")
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: [%_struct{type: "ageTrigger"}]} = Engine.run(engine)
    end

    test "emits when the second condition is met and the first is not" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 100)
        |> Engine.add_fact("segment", "european")
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: [%_struct{type: "ageTrigger"}]} = Engine.run(engine)
    end

    test "does not emit when all conditions fail" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 100)
        |> Engine.add_fact("segment", "north-american")
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: []} = Engine.run(engine)
    end
  end
end
