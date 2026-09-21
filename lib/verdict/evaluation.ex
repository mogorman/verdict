defmodule Verdict.Evaluation do
  @moduledoc """
  Evaluates a rule's condition tree into a **pure `Ecto.Changeset`** report.

  ## The report

  The returned changeset is the report of the evaluation:

    * `valid?` is true **exactly** when the rule fires;
    * `changes` – the conditions that passed, a list of `{fact, info}`;
    * `errors` – the conditions that failed, a list of `{fact, {explanation, meta}}`;
    * `empty_values` – the leaves never evaluated because evaluation
      short-circuited before them;
    * `data` – `%{facts: %{fact => value}}`, the computed fact values.

   `changes` and `errors` are **lists** (not maps) because a single fact can be
   tested by several conditions in one rule; a list keeps every decisive
   condition rather than letting later ones overwrite earlier ones.

  A condition that is false under a node that ends up true is *demoted*: it is
  neither a change nor an error (only the decisive conditions are kept). This
  is what lets `valid?` reflect the rule's real outcome for `all`/`any`/`not`.

  A `not` flips the decisive set and wraps it so it stays readable: when the
  child is false the not passes and the child's failing leaves become wrapped
  changes; when the child is true the not fails and the child's passing leaves
  become wrapped errors.

  ## Short-circuiting

  On by default: children are evaluated in priority order (declaration order
  within a priority) and evaluation stops as soon as the `all`/`any` outcome is
  decided — an `any` stops at its first passing child, an `all` at its first
  failing child. Children never reached are recorded in `empty_values`. Pass
  `strict: true` to evaluate every child regardless.
  """

  alias Verdict.{Almanac, Condition, EvaluationContext, Log, Operators}

  @doc "Evaluates a condition tree to a pure `Ecto.Changeset`."
  @spec eval(Condition.t(), EvaluationContext.t()) :: Ecto.Changeset.t()
  def eval(node, context), do: eval_node(node, context, MapSet.new())

  defp eval_node(%Condition{kind: :leaf} = node, context, _seen), do: leaf(node, context)

  defp eval_node(%Condition{kind: :not, child: child}, context, seen),
    do: not_node(child, context, seen)

  defp eval_node(%Condition{kind: :all, children: children}, context, seen),
    do: combinator(:all, children, context, seen)

  defp eval_node(%Condition{kind: :any, children: children}, context, seen),
    do: combinator(:any, children, context, seen)

  # A condition reference resolves against the engine's named conditions. A
  # reference that is still on the current resolution chain is a cycle; an
  # unregistered reference either raises or evaluates to false depending on
  # `allow_undefined_conditions`.
  defp eval_node(%Condition{kind: :ref, ref: ref}, context, seen) do
    Log.debug(context.log, fn -> "condition ref #{inspect(ref)}" end)

    case Map.fetch(context.conditions, ref) do
      {:ok, condition} ->
        if ref in seen do
          raise ArgumentError, "circular condition reference detected: #{inspect(ref)}"
        else
          eval_node(condition, context, MapSet.put(seen, ref))
        end

      :error ->
        if context.allow_undefined_conditions do
          build(%{facts: %{}}, [], [{:condition, {"undefined condition: #{ref}", [ref: ref]}}])
        else
          raise ArgumentError, "No condition #{ref} exists"
        end
    end
  end

  # --- leaf -----------------------------------------------------------------

  defp leaf(
         %Condition{
           fact: fact,
           operator: operator,
           value: value,
           params: params,
           path: path,
           path_ast: path_ast
         },
         context
       ) do
    field = String.to_atom(fact)
    fact_value = Almanac.fact_value(context.almanac, fact, params || %{})
    actual = if path, do: resolve_path!(fact_value, path, path_ast, context), else: fact_value
    resolved_value = resolve_value(value, context)
    {passed?, explanation} = operator_fn(context, operator, params).(actual, resolved_value)
    data = %{facts: %{field => fact_value}}

    Log.debug(context.log, fn ->
      "leaf #{inspect(fact)} #{operator} #{inspect(resolved_value)}: actual=#{inspect(actual)} " <>
        if passed?, do: "pass", else: "fail"
    end)

    if passed? do
      build(data, [{field, leaf_info(actual, operator, resolved_value)}], [])
    else
      build(data, [], [
        {field, {explanation, [operator: operator, value: resolved_value, actual: actual]}}
      ])
    end
  end

  # A value is either a plain value or a reference to a fact
  # (`%{fact: _, params: _, path: _}`), resolved through the almanac. Used to
  # compare two facts in a condition and to resolve fact references in event
  # params (`replace_facts_in_event_params`). The resolved value is what the
  # operator sees and what is recorded in the report.
  @doc "Resolves a fact reference (`%{fact: _, params: _, path: _}`) to its value; passes other values through."
  @spec resolve_value(term(), EvaluationContext.t()) :: term()
  def resolve_value(value, context) do
    if fact_ref?(value) do
      fact = value["fact"] || value[:fact]
      params = value["params"] || value[:params] || %{}
      path = value["path"] || value[:path]
      fact_value = Almanac.fact_value(context.almanac, fact, params)
      # A fact-reference value's path is data (not a precompiled leaf path), so it
      # is compiled on demand (`path_ast: nil` falls back to parsing here).
      if path, do: resolve_path!(fact_value, path, nil, context), else: fact_value
    else
      value
    end
  end

  defp fact_ref?(value),
    do: is_map(value) and (Map.has_key?(value, "fact") or Map.has_key?(value, :fact))

  # --- combinators ----------------------------------------------------------

  defp combinator(kind, children, context, seen) do
    ordered =
      children
      |> Enum.group_by(fn child -> effective_priority(child, context) end)
      |> by_priority_desc()
      |> Enum.map(&elem(&1, 1))
      |> List.flatten()

    {evaluated, skipped} = take_until_decided(kind, ordered, context, seen, [])

    outcome =
      if kind == :all do
        Enum.all?(evaluated, & &1.valid?)
      else
        Enum.any?(evaluated, & &1.valid?)
      end

    Log.debug(context.log, fn ->
      "#{kind} of #{length(children)}: #{if outcome, do: "pass", else: "fail"}"
    end)

    if length(skipped) > 0 do
      Log.warning(context.log, fn ->
        "short-circuit: #{length(skipped)} condition(s) not evaluated"
      end)
    end

    changes = Enum.map(evaluated, fn cs -> cs.changes end) |> List.flatten()

    errors =
      if outcome, do: [], else: Enum.map(evaluated, fn cs -> cs.errors end) |> List.flatten()

    facts = merge_maps(Enum.map(evaluated, fn cs -> cs.data[:facts] end))
    empty_values = Enum.map(evaluated, fn cs -> cs.empty_values end) |> List.flatten()

    build(%{facts: facts}, changes, errors, empty_values ++ skipped)
  end

  defp take_until_decided(_kind, [], _context, _seen, acc), do: {acc, []}

  defp take_until_decided(kind, [child | rest], context, seen, acc) do
    cs = eval_node(child, context, seen)
    acc = acc ++ [cs]

    if context.strict or not decided?(kind, [cs]) do
      take_until_decided(kind, rest, context, seen, acc)
    else
      {acc, collect_leaves(rest)}
    end
  end

  defp decided?(:all, results), do: Enum.any?(results, fn cs -> not cs.valid? end)
  defp decided?(:any, results), do: Enum.any?(results, & &1.valid?)

  # --- not ------------------------------------------------------------------

  defp not_node(child, context, seen) do
    cs = eval_node(child, context, seen)
    Log.debug(context.log, fn -> "not: #{if cs.valid?, do: "false", else: "true"}" end)

    if cs.valid? do
      # child true -> not is false: the child's passing leaves are why it failed
      errors = Enum.map(cs.changes, fn {field, info} -> change_to_not_error(field, info) end)

      build(cs.data, [], errors, cs.empty_values)
    else
      # child false -> not is true: the child's failing leaves are why it passed
      changes =
        Enum.map(cs.errors, fn {field, {_msg, meta}} -> error_to_not_change(field, meta) end)

      build(cs.data, changes, [], cs.empty_values)
    end
  end

  defp change_to_not_error(field, info) do
    meta = [
      negated: true,
      operator: Map.get(info, :operator),
      value: Map.get(info, :value),
      actual: Map.get(info, :actual)
    ]

    msg =
      "not(#{Map.get(info, :operator)}): #{inspect(Map.get(info, :actual))} is satisfied, so the not is false"

    {field, {msg, meta}}
  end

  defp error_to_not_change(field, meta) do
    {field,
     %{
       negated: true,
       operator: Keyword.get(meta, :operator),
       value: Keyword.get(meta, :value),
       actual: Keyword.get(meta, :actual)
     }}
  end

  # --- helpers --------------------------------------------------------------

  defp leaf_info(actual, operator, value), do: %{actual: actual, operator: operator, value: value}

  defp merge_maps(list), do: Enum.reduce(list, %{}, &Map.merge(&2, &1))

  defp by_priority_desc(grouped), do: Enum.sort_by(grouped, fn {priority, _} -> -priority end)

  # A node's effective evaluation priority. An explicit condition priority wins;
  # a leaf without one takes its fact's registered priority; anything else is 1.
  defp effective_priority(%Condition{kind: :leaf, fact: fact, priority: priority}, context) do
    priority || Almanac.fact_priority(context.almanac, fact)
  end

  defp effective_priority(%Condition{priority: priority}, _context), do: priority || 1

  # Resolves the operator named `operator` for this context: a plain built-in
  # keeps its explanation, while a custom operator or a `decorator:…:operator`
  # composite (built from the engine's registered operators/decorators) is
  # wrapped with a generated explanation. The leaf's `params` are handed to the
  # operator so a 3-arity custom operator can be parameterized by the condition.
  defp operator_fn(context, operator, params),
    do: Operators.resolve(context.operators, context.decorators, operator, params || %{})

  defp collect_leaves(children) do
    Enum.flat_map(children, &leaves_of/1)
  end

  defp leaves_of(%Condition{kind: :leaf} = leaf), do: [leaf_descriptor(leaf)]

  defp leaves_of(%Condition{children: children}) when is_list(children),
    do: Enum.flat_map(children, &leaves_of/1)

  defp leaves_of(%Condition{child: %Condition{} = child}), do: leaves_of(child)
  defp leaves_of(_), do: []

  defp leaf_descriptor(%Condition{fact: f, operator: o, value: v, path: p, params: pp}) do
    base = %{fact: f, operator: o, value: v}
    base = if p, do: Map.put(base, :path, p), else: base
    if pp, do: Map.put(base, :params, pp), else: base
  end

  defp build(data, changes, errors, empty_values \\ []) do
    %Ecto.Changeset{
      data: data,
      changes: changes,
      errors: errors,
      empty_values: empty_values,
      valid?: errors == [],
      types: nil,
      action: nil
    }
  end

  # Resolves a condition's `path` against the computed fact value, mirroring the
  # reference engine. The path is only applied when the fact value is an object
  # (map) or array (list); any other value is returned unchanged. A custom
  # `path_resolver` (when registered on the engine) takes full control;
  # otherwise the built-in JSONPath resolver is used.
  defp resolve_path!(fact_value, path, path_ast, context) do
    if is_map(fact_value) or is_list(fact_value) do
      case context.path_resolver do
        nil -> default_resolve_path(fact_value, path, path_ast)
        fun when is_function(fun, 2) -> fun.(fact_value, path)
      end
    else
      fact_value
    end
  end

  # `JSONPath.values/2` returns a list of matches: a `[*]` wildcard keeps that
  # list (so it can be used with `in`/`contains`), while a non-wildcard path
  # unwraps to the single matched value (or `nil` when nothing matches).
  #
  # `path_ast` is the leaf's precompiled path (see `Verdict.Types.Condition`) when
  # available; a `nil` (a fact-reference value's path) is compiled on demand.
  defp default_resolve_path(fact_value, path, path_ast) do
    case compiled_ast(path_ast, path) do
      :invalid ->
        nil

      ast ->
        case JSONPath.values(fact_value, ast) do
          {:ok, matches} -> normalize_path(matches, path)
          {:error, _} -> nil
        end
    end
  end

  # The leaf's precompiled path AST, or `:invalid` when the path is not a valid
  # JSONPath (in which case the value resolves to `nil`). A `nil` — a
  # fact-reference value's path, which is data rather than a precompiled leaf
  # path — is compiled here on demand.
  defp compiled_ast({:ok, ast}, _path), do: ast
  defp compiled_ast({:error, _}, _path), do: :invalid

  defp compiled_ast(nil, path) do
    case JSONPath.build(normalize_json_path(path)) do
      {:ok, ast} -> ast
      {:error, _} -> :invalid
    end
  end

  # The reference engine's JSONPath (jsonpath-plus) accepts the member-access
  # form `$.obj.['key']`; the RFC-9535 `json_path` lib expects `$.obj['key']`.
  # Normalize the dot-bracket form so keys with special characters (e.g. dots)
  # resolve. Index/wildcard segments are unaffected (the bracket is preceded by
  # a non-dot character).
  defp normalize_json_path(path), do: String.replace(path, ".[", "[")

  defp normalize_path(matches, path) do
    cond do
      String.contains?(path, "[*]") -> matches
      matches == [] -> nil
      true -> hd(matches)
    end
  end
end
