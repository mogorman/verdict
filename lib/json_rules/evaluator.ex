defmodule JsonRules.Evaluator do
  @moduledoc """
  The pure evaluation core.

  `run/4` evaluates a set of rules against a set of facts and returns a
  `JsonRules.RunResult`. Evaluation is organised as a **priority-bucketed
  executor**: rules are grouped by priority and evaluated highest-priority
  first, and within each rule the children of every `all`/`any` node are
  likewise grouped by priority. This MVP is **serial** (and **strict**: every
  bucket is fully evaluated); `:parallel` scheduling and the short-circuit
  option are added in Phase 2 on top of the same executor.
  """
  alias JsonRules.{Almanac, Condition, Operators, Rule, RuleResult, RunResult, UnsupportedError}

  @type opts :: keyword()

  @doc """
  Evaluates `rules` (a list of `JsonRules.Rule`) using `defs` (registered facts)
  and `runtime_facts` (facts supplied for this run).

  `opts` may include `:allow_undefined_facts`.
  """
  @spec run([Rule.t()], map(), map(), opts()) :: RunResult.t()
  def run(rules, defs, runtime_facts, opts) do
    almanac = Almanac.new(defs, runtime_facts, opts)

    try do
      groups = rules |> Enum.group_by(& &1.priority) |> by_priority_desc()

      {events, failure_events, results, failure_results} =
        Enum.reduce(groups, {[], [], [], []}, fn {_priority, bucket}, acc ->
          Enum.reduce(bucket, acc, fn rule, acc -> evaluate_rule(rule, almanac, acc) end)
        end)

      %RunResult{
        events: Enum.reverse(events),
        failure_events: Enum.reverse(failure_events),
        results: Enum.reverse(results),
        failure_results: Enum.reverse(failure_results)
      }
    after
      Almanac.destroy(almanac)
    end
  end

  defp evaluate_rule(rule, almanac, {events, failure_events, results, failure_results}) do
    result = eval_tree(rule.conditions, almanac)

    rule_result = %RuleResult{
      id: rule.id,
      name: rule.name,
      priority: rule.priority,
      result: result,
      event: rule.event
    }

    if result do
      {[rule.event | events], failure_events, [rule_result | results], failure_results}
    else
      {events, [rule.event | failure_events], results, [rule_result | failure_results]}
    end
  end

  # --- condition-tree evaluation -------------------------------------------

  @spec eval_tree(Condition.t(), Almanac.t()) :: boolean()
  def eval_tree(%Condition{kind: :leaf} = node, almanac), do: eval_leaf(node, almanac)

  def eval_tree(%Condition{kind: :not, child: child}, almanac),
    do: not eval_tree(child, almanac)

  def eval_tree(%Condition{kind: :all, children: children}, almanac),
    do: eval_bool(:all, children, almanac)

  def eval_tree(%Condition{kind: :any, children: children}, almanac),
    do: eval_bool(:any, children, almanac)

  def eval_tree(%Condition{kind: :ref, ref: ref}, _almanac) do
    raise UnsupportedError, feature: "condition references (#{inspect(ref)})"
  end

  # Strict, serial: evaluate every child in priority order, then combine.
  defp eval_bool(:all, children, almanac) do
    children
    |> buckets()
    |> Enum.map(fn bucket -> Enum.map(bucket, &eval_tree(&1, almanac)) end)
    |> List.flatten()
    |> Enum.all?()
  end

  defp eval_bool(:any, children, almanac) do
    children
    |> buckets()
    |> Enum.map(fn bucket -> Enum.map(bucket, &eval_tree(&1, almanac)) end)
    |> List.flatten()
    |> Enum.any?()
  end

  defp eval_leaf(
         %Condition{
           fact: fact,
           operator: operator,
           value: value,
           params: params,
           path: path
         },
         almanac
       ) do
    fact_value = Almanac.fact_value(almanac, fact, params)
    actual = if path, do: resolve_path!(fact_value, path), else: fact_value
    Operators.get(operator).(actual, value)
  end

  defp resolve_path!(_fact_value, path) do
    raise UnsupportedError, feature: "condition paths (#{inspect(path)})"
  end

  # Group a list of priority-bearing items into buckets, highest priority first.
  defp by_priority_desc(grouped) do
    grouped
    |> Enum.sort_by(fn {priority, _} -> -priority end)
  end

  defp buckets(children) do
    children
    |> Enum.group_by(& &1.priority)
    |> by_priority_desc()
    |> Enum.map(fn {_priority, bucket} -> bucket end)
  end
end
