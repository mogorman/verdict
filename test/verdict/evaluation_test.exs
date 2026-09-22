defmodule Verdict.EvaluationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}
  alias Verdict.TestSupport

  # Runs a single rule with the given conditions against the given facts and
  # returns the rule's evaluation changeset.
  defp run_cs(conditions, facts, run_opts \\ []) do
    engine = Engine.new() |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "e"}})
    %RunResult{results: [rr]} = Engine.run(engine, facts, run_opts)
    rr.changeset
  end

  defp field_in?(changes, field), do: Enum.any?(changes, fn {f, _} -> f == field end)

  # Runs a single rule and returns its boolean outcome (used for `:result_only`,
  # where no changeset report is built).
  defp run_bool(conditions, facts, run_opts \\ []) do
    engine = Engine.new() |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "e"}})
    %RunResult{results: [rr]} = Engine.run(engine, facts, run_opts)
    rr.valid?
  end

  defp changeset_of(engine, facts) do
    %RunResult{results: [rr]} = Engine.run(engine, facts)
    rr.changeset
  end

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

    test "all: strict: true evaluates every leaf past the first failure" do
      conditions = %{
        all: [
          %{fact: "age", operator: "lessThan", value: 50, priority: 10},
          %{fact: "member", operator: "equal", value: true, priority: 5},
          %{fact: "other", operator: "equal", value: 1, priority: 1}
        ]
      }

      facts = %{age: 30, member: false, other: 999}

      short = run_cs(conditions, facts)
      refute short.valid?
      assert short.changes == [{:age, %{actual: 30, operator: "lessThan", value: 50}}]
      assert field_in?(short.errors, :member)
      refute field_in?(short.errors, :other)
      assert short.data.facts == %{age: 30, member: false}
      assert Enum.map(short.empty_values, & &1.fact) == ["other"]

      strict = run_cs(conditions, facts, strict: true)
      refute strict.valid?
      assert strict.empty_values == []
      assert strict.data.facts == %{age: 30, member: false, other: 999}
      assert field_in?(strict.errors, :member)
      assert field_in?(strict.errors, :other)
      assert strict.changes == [{:age, %{actual: 30, operator: "lessThan", value: 50}}]
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

  describe "report: :result_only (boolean evaluation path)" do
    test "not / any / strict-all reduce to booleans" do
      # not: 60 < 50 is false, so not(false) is true
      assert run_bool(%{not: %{fact: "age", operator: "lessThan", value: 50}}, %{age: 60},
               report: :result_only
             )

      # not: 30 < 50 is true, so not(true) is false
      refute run_bool(%{not: %{fact: "age", operator: "lessThan", value: 50}}, %{age: 30},
               report: :result_only
             )

      # any: every child fails -> false (drives the :any recursion down to the empty base)
      refute run_bool(
               %{
                 any: [
                   %{fact: "age", operator: "equal", value: 1},
                   %{fact: "age", operator: "equal", value: 2}
                 ]
               },
               %{age: 30},
               report: :result_only
             )

      # any: the second child passes -> true (short-circuits once decided)
      assert run_bool(
               %{
                 any: [
                   %{fact: "age", operator: "equal", value: 1},
                   %{fact: "age", operator: "equal", value: 30}
                 ]
               },
               %{age: 30},
               report: :result_only
             )

      # all with strict: true evaluates every child (the strict combinator branch)
      refute run_bool(
               %{
                 all: [
                   %{fact: "age", operator: "lessThan", value: 100},
                   %{fact: "age", operator: "lessThan", value: 1}
                 ]
               },
               %{age: 30},
               report: :result_only,
               strict: true
             )
    end

    test "a valid condition reference resolves and evaluates" do
      {:ok, engine} =
        Engine.new(report: :result_only)
        |> Engine.set_condition("young", %{all: [%{fact: "age", operator: "lessThan", value: 18}]})

      engine =
        TestSupport.add_rule(engine, %{conditions: %{condition: "young"}, event: %{type: "e"}})

      %RunResult{results: [rr]} = Engine.run(engine, %{age: 10})
      assert rr.valid?
    end

    test "a circular condition reference raises" do
      {:ok, e1} = Engine.new(report: :result_only) |> Engine.set_condition("a", %{condition: "b"})
      {:ok, e2} = Engine.set_condition(e1, "b", %{condition: "a"})

      engine = TestSupport.add_rule(e2, %{conditions: %{condition: "a"}, event: %{type: "e"}})

      assert_raise ArgumentError, ~r/circular condition reference/, fn ->
        Engine.run(engine, %{})
      end
    end

    test "an undefined condition raises when not allowed" do
      engine =
        Engine.new(report: :result_only)
        |> TestSupport.add_rule(%{conditions: %{condition: "missing"}, event: %{type: "e"}})

      assert_raise ArgumentError, ~r/No condition missing exists/, fn ->
        Engine.run(engine, %{})
      end
    end

    test "an undefined condition is false when allowed" do
      engine =
        Engine.new(report: :result_only, allow_undefined_conditions: true)
        |> TestSupport.add_rule(%{conditions: %{condition: "missing"}, event: %{type: "e"}})

      %RunResult{results: [rr]} = Engine.run(engine, %{})
      refute rr.valid?
    end
  end

  describe "short-circuited subtrees (leaves_of)" do
    test "a skipped not-node and a skipped reference are both collected" do
      {:ok, engine} =
        Engine.new()
        |> Engine.set_condition("named", %{all: [%{fact: "z", operator: "equal", value: 1}]})

      conditions = %{
        any: [
          %{fact: "member", operator: "equal", value: true, priority: 10},
          %{not: %{fact: "a", operator: "equal", value: 1}, priority: 1},
          %{condition: "named", priority: 1}
        ]
      }

      engine = TestSupport.add_rule(engine, %{conditions: conditions, event: %{type: "e"}})
      cs = changeset_of(engine, %{member: true, a: 5, z: 1})
      assert cs.valid?

      # member (highest priority) passes, so the not-node and the reference are
      # never evaluated; only the not-node's inner leaf is recorded as a descriptor.
      skipped_facts = cs.empty_values |> Enum.map(& &1.fact) |> Enum.uniq()
      assert "a" in skipped_facts
    end
  end

  describe "path resolution of invalid paths" do
    test "a leaf whose precompiled path is invalid resolves to nil" do
      engine =
        Engine.new()
        |> Engine.add_fact("obj", %{x: 1})
        |> TestSupport.add_rule(%{
          conditions: %{all: [%{fact: "obj", operator: "equal", value: 1, path: "$invalid["}]},
          event: %{type: "e"}
        })

      refute changeset_of(engine, %{}).valid?
    end

    test "a fact-reference value whose path is invalid resolves to nil" do
      engine =
        Engine.new()
        |> Engine.add_fact("a", 1)
        |> Engine.add_fact("b", %{x: 1})
        |> TestSupport.add_rule(%{
          conditions: %{
            all: [%{fact: "a", operator: "equal", value: %{fact: "b", path: "$invalid["}}]
          },
          event: %{type: "e"}
        })

      refute changeset_of(engine, %{}).valid?
    end
  end
end
