defmodule Verdict.EngineConditionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}
  alias Verdict.TestSupport

  # Ported from the reference `engine-condition.test.js`.

  @over60 %{all: [%{fact: "age", operator: "greaterThanInclusive", value: 60}]}

  defp types(result) do
    Enum.map(result.events, & &1.type)
  end

  describe "set_condition/3" do
    test "rejects an invalid root condition" do
      assert {:error, [message: message]} =
               Engine.set_condition(Engine.new(), "test", %{foo: true})

      assert message =~ "all"
    end
  end

  describe "undefined condition" do
    @conditions %{
      all: [
        %{condition: "over60"},
        %{fact: "isRetired", operator: "equal", value: true}
      ]
    }

    test "evaluates to false when allow_undefined_conditions is set" do
      engine =
        Engine.new(allow_undefined_conditions: true)
        |> TestSupport.add_rule(%{conditions: @conditions, event: %{type: "checkSending"}})

      %RunResult{events: [], failure_events: []} = Engine.run(engine, %{isRetired: true})
    end

    test "raises when allow_undefined_conditions is not set" do
      engine =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: @conditions, event: %{type: "checkSending"}})

      assert_raise ArgumentError, ~r/No condition over60 exists/, fn ->
        Engine.run(engine, %{isRetired: true})
      end
    end
  end

  describe "condition shared across multiple rules" do
    @send %{
      all: [
        %{condition: "over60"},
        %{fact: "isRetired", operator: "equal", value: true}
      ]
    }

    @outreach %{
      all: [
        %{condition: "over60"},
        %{fact: "requestedOutreach", operator: "equal", value: true}
      ]
    }

    setup do
      {:ok, engine} =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: @send, event: %{type: "checkSending"}})
        |> TestSupport.add_rule(%{conditions: @outreach, event: %{type: "triggerOutreach"}})
        |> Engine.set_condition("over60", @over60)

      {:ok, engine: engine}
    end

    test "every rule using the condition fires", %{engine: engine} do
      result = Engine.run(engine, %{age: 65, isRetired: true, requestedOutreach: true})
      assert "checkSending" in types(result)
      assert "triggerOutreach" in types(result)
    end
  end

  describe "nested condition" do
    @early_retirement %{
      all: [
        %{not: %{condition: "over60"}},
        %{fact: "isRetired", operator: "equal", value: true}
      ]
    }

    @outreach %{
      all: [
        %{condition: "earlyRetirement"},
        %{fact: "requestedOutreach", operator: "equal", value: true}
      ]
    }

    test "resolves a condition that references another, nested in a not" do
      {:ok, e1} = Engine.set_condition(Engine.new(), "over60", @over60)
      {:ok, e2} = Engine.set_condition(e1, "earlyRetirement", @early_retirement)

      engine =
        TestSupport.add_rule(e2, %{conditions: @outreach, event: %{type: "triggerOutreach"}})

      result = Engine.run(engine, %{age: 55, isRetired: true, requestedOutreach: true})
      assert "triggerOutreach" in types(result)
    end
  end

  describe "top-level condition reference" do
    test "the rule's root may be a condition reference" do
      {:ok, engine} =
        Engine.new()
        |> TestSupport.add_rule(%{
          conditions: %{condition: "retired"},
          event: %{type: "checkSending"}
        })
        |> Engine.set_condition("retired", %{
          all: [%{fact: "isRetired", operator: "equal", value: true}]
        })

      result = Engine.run(engine, %{isRetired: true})
      assert "checkSending" in types(result)
    end
  end

  describe "cycle guard" do
    test "detects circular condition references" do
      {:ok, e1} = Engine.set_condition(Engine.new(), "a", %{all: [%{condition: "b"}]})
      {:ok, e2} = Engine.set_condition(e1, "b", %{all: [%{condition: "a"}]})

      engine =
        TestSupport.add_rule(e2, %{conditions: %{all: [%{condition: "a"}]}, event: %{type: "e"}})

      assert_raise ArgumentError, ~r/circular condition reference/, fn ->
        Engine.run(engine, %{})
      end
    end
  end
end
