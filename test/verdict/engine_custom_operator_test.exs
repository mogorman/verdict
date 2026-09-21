defmodule Verdict.EngineCustomOperatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult, RuleResult}
  alias Verdict.TestSupport

  # The worked example from docs/phase_4_5.md: a 3-arity (parameterized) custom
  # operator that reads its bounds from the condition's `params` and returns a
  # custom `{passed?, explanation}` tuple.
  defp range_op(fv, _jv, params) do
    min = params[:min]
    max = params[:max]

    passed = is_number(fv) and is_number(min) and is_number(max) and fv >= min and fv <= max

    {passed, "#{fv} is #{if passed, do: "within", else: "outside"} the range [#{min}, #{max}]"}
  end

  defp run_rule(engine, facts) do
    %RunResult{results: [result]} = Engine.run(engine, facts)
    result
  end

  test "a custom operator's {passed?, explanation} is used verbatim in the report" do
    engine =
      Engine.new()
      |> Engine.add_operator("startsWithT", fn fv, _jv ->
        {to_string(fv) |> String.starts_with?("t"), "value must start with the letter t"}
      end)
      |> TestSupport.add_rule(%{
        event: %{type: "op"},
        conditions: %{all: [%{fact: "x", operator: "startsWithT", value: "t"}]}
      })

    %RuleResult{valid?: false, changeset: cs} = run_rule(engine, %{x: "nope"})
    assert [{:x, {"value must start with the letter t", meta}}] = cs.errors
    assert meta[:operator] == "startsWithT"
  end

  test "a boolean-returning custom operator gets a generated explanation" do
    engine =
      Engine.new()
      |> Engine.add_operator("isA", fn fv, jv -> fv == jv end)
      |> TestSupport.add_rule(%{
        event: %{type: "op"},
        conditions: %{all: [%{fact: "x", operator: "isA", value: 1}]}
      })

    %RuleResult{valid?: false, changeset: cs} = run_rule(engine, %{x: 2})
    assert [{:x, {msg, meta}}] = cs.errors
    assert msg =~ "2" and msg =~ "isA" and msg =~ "false"
    assert meta[:operator] == "isA"
  end

  test "a 3-arity custom operator receives the condition params" do
    engine =
      Engine.new()
      |> Engine.add_operator("scaled", fn fv, jv, params -> fv * params[:mult] == jv end)
      |> TestSupport.add_rule(%{
        event: %{type: "op"},
        conditions: %{all: [%{fact: "x", operator: "scaled", value: 9, params: %{mult: 3}}]}
      })

    assert %RuleResult{valid?: true} = run_rule(engine, %{x: 3})
    assert %RuleResult{valid?: false} = run_rule(engine, %{x: 4})
  end

  test "range: a parameterized operator with a custom explanation" do
    engine =
      Engine.new()
      |> Engine.add_operator("range", &range_op/3)
      |> TestSupport.add_rule(%{
        event: %{type: "in-range"},
        conditions: %{all: [%{fact: "age", operator: "range", params: %{min: 18, max: 65}}]}
      })

    assert %RuleResult{valid?: true} = run_rule(engine, %{age: 30})

    %RuleResult{valid?: false, changeset: cs} = run_rule(engine, %{age: 10})
    assert [{:age, {"10 is outside the range [18, 65]", meta}}] = cs.errors
    assert meta[:operator] == "range"
  end
end
