defmodule JsonRules.EngineAllTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  @event %{type: "ageTrigger", params: %{demographic: "under50"}}

  describe "single \"all\" condition" do
    @conditions %{all: [%{fact: "age", operator: "lessThan", value: 50}]}

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
        |> Engine.add_fact("age", 65)
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: []} = Engine.run(engine)
    end
  end

  describe "\"all\" with multiple conditions" do
    @conditions %{
      all: [
        %{fact: "age", operator: "lessThan", value: 50},
        %{fact: "age", operator: "greaterThan", value: 21}
      ]
    }

    test "emits when every condition is met" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 30)
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: [%_struct{type: "ageTrigger"}]} = Engine.run(engine)
    end

    test "does not emit when the first condition fails" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 10)
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: []} = Engine.run(engine)
    end

    test "does not emit when the second condition fails" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", 65)
        |> TestSupport.add_rule(%{conditions: @conditions, event: @event})

      assert %RunResult{events: []} = Engine.run(engine)
    end
  end
end
