defmodule Verdict.EngineOperatorMapTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult, RuleResult}
  alias Verdict.TestSupport

  # Ported from the reference `engine-operator-map.test.js`. Rather than poking
  # the internal operator map, each case exercises the feature end-to-end: a
  # custom operator / decorator / composite operator is registered and used by a
  # rule.

  defp starts_with_letter(fv, jv), do: to_string(fv) |> String.first() == jv

  defp rule(fact, operator, value) do
    %{event: %{type: "op"}, conditions: %{all: [%{fact: fact, operator: operator, value: value}]}}
  end

  defp fires?(engine, facts) do
    %RunResult{events: events} = Engine.run(engine, facts)
    length(events) > 0
  end

  # The single rule result of a one-rule engine, for asserting on its report.
  defp result_of(engine, facts) do
    %RunResult{results: [rule_result]} = Engine.run(engine, facts)
    rule_result
  end

  defp rule_with_params(fact, operator, value, params) do
    %{
      event: %{type: "op"},
      conditions: %{all: [%{fact: fact, operator: operator, value: value, params: params}]}
    }
  end

  # A parameterized operator: 3-arity, reads its bounds from the condition's
  # `params`, and supplies its own explanation.
  defp in_range(fv, _jv, params) do
    min = params[:min] || params["min"]
    max = params[:max] || params["max"]
    ok = is_number(fv) and (is_nil(min) or fv >= min) and (is_nil(max) or fv <= max)

    {ok,
     "#{inspect(fv)} #{if ok, do: "is within", else: "is outside"} [#{inspect(min)}..#{inspect(max)}]"}
  end

  describe "custom operator" do
    test "is used when a condition references it" do
      engine =
        Engine.new()
        |> Engine.add_operator("startsWithLetter", &starts_with_letter/2)
        |> TestSupport.add_rule(rule("x", "startsWithLetter", "t"))

      assert fires?(engine, %{x: "test"})
      refute fires?(engine, %{x: "nope"})
    end

    test "takes precedence over a built-in of the same name" do
      engine =
        Engine.new()
        |> Engine.add_operator("equal", fn _a, _b -> true end)
        |> TestSupport.add_rule(rule("x", "equal", 999))

      assert fires?(engine, %{x: 1})
    end

    test "after removal the operator is unknown at run time" do
      engine =
        Engine.new()
        |> Engine.add_operator("startsWithLetter", &starts_with_letter/2)
        |> Engine.remove_operator("startsWithLetter")
        |> TestSupport.add_rule(rule("x", "startsWithLetter", "t"))

      assert_raise ArgumentError, ~r/unknown operator/, fn -> Engine.run(engine, %{x: "test"}) end
    end
  end

  describe "custom decorator" do
    test "decorates an operator" do
      engine =
        Engine.new()
        |> Engine.add_operator("startsWithLetter", &starts_with_letter/2)
        |> Engine.add_operator_decorator("never", fn _fv, _jv, _next -> false end)
        |> TestSupport.add_rule(rule("x", "never:startsWithLetter", "t"))

      refute fires?(engine, %{x: "test"})
    end

    test "removing the decorator makes the composite unknown" do
      engine =
        Engine.new()
        |> Engine.add_operator("startsWithLetter", &starts_with_letter/2)
        |> Engine.add_operator_decorator("never", fn _fv, _jv, _next -> false end)
        |> Engine.remove_operator_decorator("never")
        |> TestSupport.add_rule(rule("x", "never:startsWithLetter", "t"))

      assert_raise ArgumentError, ~r/unknown operator/, fn -> Engine.run(engine, %{x: "test"}) end
    end
  end

  describe "built-in decorators (composites)" do
    test "swap:contains swaps the fact and value" do
      engine = Engine.new() |> TestSupport.add_rule(rule("x", "swap:contains", [1, 2, 3]))

      assert fires?(engine, %{x: 1})
      refute fires?(engine, %{x: 9})
    end

    test "everyFact:someValue:not:greaterThanInclusive" do
      engine =
        Engine.new()
        |> TestSupport.add_rule(
          rule("odds", "everyFact:someValue:not:greaterThanInclusive", [2, 4, 6, 8])
        )

      assert fires?(engine, %{odds: [1, 3, 5, 7]})
    end
  end

  describe "custom operator explanations" do
    test "a custom operator may return its own {passed?, explanation}" do
      engine =
        Engine.new()
        |> Engine.add_operator("startsWithLetter", fn fv, _jv ->
          {to_string(fv) |> String.first() == "t", "value must start with the letter t"}
        end)
        |> TestSupport.add_rule(rule("x", "startsWithLetter", "t"))

      %RuleResult{valid?: false, changeset: cs} = result_of(engine, %{x: "nope"})
      assert [{:x, {msg, _meta}}] = cs.errors
      assert msg == "value must start with the letter t"
    end

    test "a 2-arity custom operator returning a bare boolean gets a generic explanation" do
      engine =
        Engine.new()
        |> Engine.add_operator("startsWithLetter", &starts_with_letter/2)
        |> TestSupport.add_rule(rule("x", "startsWithLetter", "t"))

      %RuleResult{changeset: cs} = result_of(engine, %{x: "nope"})
      assert [{:x, {msg, _meta}}] = cs.errors
      assert msg =~ "startsWithLetter"
    end
  end

  describe "parameterized custom operators" do
    test "a 3-arity operator receives the condition's params" do
      engine =
        Engine.new()
        |> Engine.add_operator("inRange", &in_range/3)
        |> TestSupport.add_rule(rule_with_params("score", "inRange", nil, %{min: 5, max: 10}))

      assert fires?(engine, %{score: 7})
      refute fires?(engine, %{score: 12})
    end

    test "the operator's explanation names the bounds it used" do
      engine =
        Engine.new()
        |> Engine.add_operator("inRange", &in_range/3)
        |> TestSupport.add_rule(rule_with_params("score", "inRange", nil, %{min: 5, max: 10}))

      %RuleResult{changeset: cs} = result_of(engine, %{score: 12})
      assert [{:score, {msg, _meta}}] = cs.errors
      assert msg =~ "12"
      assert msg =~ "5"
      assert msg =~ "10"
      assert msg =~ "outside"
    end
  end
end
