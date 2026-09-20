defmodule JsonRules.EvaluationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.TestSupport

  # Runs a single rule with the given conditions against the given facts and
  # returns the rule's evaluation changeset.
  defp run_cs(conditions, facts, run_opts \\ []) do
    engine = Engine.new() |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "e"}})
    %RunResult{results: [rr]} = Engine.run(engine, facts, run_opts)
    rr.changeset
  end

  defp field_in?(changes, field), do: Enum.any?(changes, fn {f, _} -> f == field end)

  describe "leaf" do
    test "a passing leaf is a change" do
      cs = run_cs(%{all: [%{fact: "age", operator: "lessThan", value: 50}]}, %{age: 10})
      assert cs.valid?
      assert [{:age, %{actual: 10, operator: "lessThan", value: 50}}] = cs.changes
      assert cs.errors == []
      assert cs.data.facts == %{age: 10}
    end

    test "a failing leaf is an error carrying the operator's explanation" do
      cs = run_cs(%{all: [%{fact: "age", operator: "lessThan", value: 50}]}, %{age: 60})
      refute cs.valid?
      assert cs.changes == []
      assert [{:age, {msg, meta}}] = cs.errors
      assert msg =~ "60"
      assert meta[:operator] == "lessThan"
      assert meta[:value] == 50
      assert meta[:actual] == 60
    end
  end

  describe "all" do
    @conditions %{
      all: [
        %{fact: "age", operator: "lessThan", value: 65},
        %{fact: "income", operator: "lessThanInclusive", value: 100}
      ]
    }

    test "passes only when every leaf passes" do
      cs = run_cs(@conditions, %{age: 30, income: 50})
      assert cs.valid?
      assert length(cs.changes) == 2
      assert cs.errors == []
      assert cs.data.facts == %{age: 30, income: 50}
    end

    test "fails when any leaf fails, keeping the failing leaf as an error" do
      cs = run_cs(@conditions, %{age: 30, income: 200})
      refute cs.valid?
      assert field_in?(cs.changes, :age)
      assert [{:income, {_msg, meta}}] = cs.errors
      assert meta[:operator] == "lessThanInclusive"
    end

    test "keeps every condition on the same fact (no crushing)" do
      conditions = %{
        all: [
          %{fact: "age", operator: "greaterThanInclusive", value: 18},
          %{fact: "age", operator: "lessThanInclusive", value: 65}
        ]
      }

      cs = run_cs(conditions, %{age: 30})
      assert cs.valid?

      assert cs.changes == [
               {:age, %{actual: 30, operator: "greaterThanInclusive", value: 18}},
               {:age, %{actual: 30, operator: "lessThanInclusive", value: 65}}
             ]

      assert cs.errors == []
    end
  end

  describe "any" do
    @conditions %{
      any: [
        %{fact: "age", operator: "lessThan", value: 18},
        %{fact: "member", operator: "equal", value: true}
      ]
    }

    test "passes when at least one leaf passes; non-matching leaves are demoted" do
      cs = run_cs(@conditions, %{age: 30, member: true})
      assert cs.valid?
      assert field_in?(cs.changes, :member)
      refute field_in?(cs.changes, :age)
      assert cs.errors == []
    end

    test "fails only when every leaf fails" do
      cs = run_cs(@conditions, %{age: 30, member: false})
      refute cs.valid?
      assert cs.changes == []
      assert length(cs.errors) == 2
    end
  end

  describe "not" do
    @conditions %{not: %{fact: "age", operator: "lessThan", value: 50}}

    test "child true -> not is false, wrapping the passing leaf as an error" do
      cs = run_cs(@conditions, %{age: 30})
      refute cs.valid?
      assert cs.changes == []
      assert [{:age, {msg, meta}}] = cs.errors
      assert meta[:negated] == true
      assert msg =~ "not is false"
    end

    test "child false -> not is true, wrapping the failing leaf as a change" do
      cs = run_cs(@conditions, %{age: 60})
      assert cs.valid?
      assert [{:age, %{negated: true, operator: "lessThan", value: 50, actual: 60}}] = cs.changes
      assert cs.errors == []
    end

    test "double not" do
      cs = run_cs(%{not: %{not: %{fact: "age", operator: "lessThan", value: 65}}}, %{age: 30})
      assert cs.valid?
    end
  end

  describe "short-circuiting" do
    @conditions %{
      any: [
        %{fact: "age", operator: "lessThan", value: 18, priority: 1},
        %{fact: "member", operator: "equal", value: true, priority: 10},
        %{fact: "other", operator: "equal", value: 1, priority: 5}
      ]
    }
    @facts %{age: 30, member: true, other: 999}

    test "records skipped lower-priority leaves in data.empty_values" do
      cs = run_cs(@conditions, @facts)
      assert cs.valid?
      assert field_in?(cs.changes, :member)

      skipped = Enum.map(cs.empty_values, & &1.fact)
      assert "age" in skipped
      assert "other" in skipped
      refute "member" in skipped
    end

    test "strict: true evaluates every leaf (no empty_values)" do
      cs = run_cs(@conditions, @facts, strict: true)
      assert cs.valid?
      assert cs.empty_values == []
      assert cs.data.facts == %{age: 30, member: true, other: 999}
      assert cs.changes == [{:member, %{actual: true, operator: "equal", value: true}}]
    end

    test "an any of same-priority branches stops at the first that matches" do
      conditions = %{
        any: [
          %{
            all: [
              %{fact: "gameDuration", operator: "equal", value: 40},
              %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 5}
            ]
          },
          %{
            all: [
              %{fact: "gameDuration", operator: "equal", value: 48},
              %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 6}
            ]
          }
        ]
      }

      cs = run_cs(conditions, %{gameDuration: 40, personalFoulCount: 6})
      assert cs.valid?

      assert cs.changes == [
               {:gameDuration, %{actual: 40, operator: "equal", value: 40}},
               {:personalFoulCount, %{actual: 6, operator: "greaterThanInclusive", value: 5}}
             ]

      # the second branch was never evaluated
      skipped = Enum.map(cs.empty_values, & &1.fact)
      assert skipped == ["gameDuration", "personalFoulCount"]
      assert Enum.any?(cs.empty_values, &(&1.fact == "gameDuration" and &1.value == 48))
    end
  end

  describe "top-level shape" do
    test "valid rule -> its event; invalid rule -> its failure event" do
      conditions = %{all: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]}

      engine =
        Engine.new() |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "e"}})

      %RunResult{events: [%_struct{type: "e"}], failure_events: [], results: [rr]} =
        Engine.run(engine, %{age: 30})

      assert rr.valid?
      assert rr.rule.event.type == "e"

      %RunResult{events: [], failure_events: [%_struct{type: "e"}]} =
        Engine.run(engine, %{age: 10})
    end
  end
end
