defmodule JsonRules.EngineRecursiveRulesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  @event %{type: "middle-income-adult"}

  defp run(conditions, facts) do
    engine = Engine.new() |> TestSupport.add_rule(%{conditions: conditions, event: @event})
    Engine.run(engine, facts)
  end

  defp emitted(result), do: %RunResult{events: [%_struct{type: "middle-income-adult"}]} = result
  defp not_emitted(result), do: %RunResult{events: []} = result

  describe "\"all\" with nested \"any\"" do
    @conditions %{
      all: [
        %{fact: "age", operator: "lessThan", value: 65},
        %{fact: "age", operator: "greaterThan", value: 21},
        %{
          any: [
            %{fact: "income", operator: "lessThanInclusive", value: 100},
            %{fact: "family-size", operator: "lessThanInclusive", value: 3}
          ]
        }
      ]
    }

    test "true when facts pass the rules" do
      emitted(run(@conditions, %{age: 30, income: 30, "family-size": 2}))
    end

    test "false when facts do not pass the rules" do
      not_emitted(run(@conditions, %{age: 30, income: 200, "family-size": 8}))
    end
  end

  describe "\"any\" with nested \"all\"" do
    @conditions %{
      any: [
        %{fact: "age", operator: "lessThan", value: 65},
        %{fact: "age", operator: "equal", value: 70},
        %{
          all: [
            %{fact: "income", operator: "lessThanInclusive", value: 100},
            %{fact: "family-size", operator: "lessThanInclusive", value: 3}
          ]
        }
      ]
    }

    test "true when facts pass the rules" do
      emitted(run(@conditions, %{age: 90, income: 30, "family-size": 2}))
    end

    test "false when facts do not pass the rules" do
      not_emitted(run(@conditions, %{age: 90, income: 200, "family-size": 2}))
    end
  end

  describe "\"any\" with \"all\" within \"any\"" do
    @conditions %{
      any: [
        %{
          all: [
            %{any: [%{fact: "income", operator: "lessThanInclusive", value: 100}]},
            %{fact: "family-size", operator: "lessThanInclusive", value: 3}
          ]
        }
      ]
    }

    test "true when facts pass the rules" do
      emitted(run(@conditions, %{income: 30, "family-size": 1}))
    end

    test "false when facts do not pass the rules" do
      not_emitted(run(@conditions, %{income: 30, "family-size": 5}))
    end
  end

  describe "\"not\" nested directly within a \"not\"" do
    @conditions %{not: %{not: %{fact: "age", operator: "lessThan", value: 65}}}

    test "true when facts pass the rules" do
      emitted(run(@conditions, %{age: 30}))
    end

    test "false when facts do not pass the rules" do
      not_emitted(run(@conditions, %{age: 65}))
    end
  end

  describe "outer \"not\" with nested \"all\" and nested \"not\"" do
    @conditions %{
      not: %{
        all: [
          %{fact: "age", operator: "lessThan", value: 65},
          %{fact: "age", operator: "greaterThan", value: 21},
          %{not: %{fact: "income", operator: "lessThanInclusive", value: 100}}
        ]
      }
    }

    test "true when facts pass the rules" do
      emitted(run(@conditions, %{age: 30, income: 100}))
    end

    test "false when facts do not pass the rules" do
      not_emitted(run(@conditions, %{age: 30, income: 101}))
    end
  end
end
