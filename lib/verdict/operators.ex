defmodule Verdict.Operators do
  @moduledoc """
  The built-in operators used to compare a computed fact against a condition's
  value.

  Each operator returns `{passed?, explanation}` where `explanation` is a
  human-readable description of the comparison (used to build the `errors` of
  the evaluation changeset).

  | Operator               | Meaning                                        |
  | ---------------------- | ---------------------------------------------- |
  | `equal`                | fact equals value                              |
  | `notEqual`             | fact does not equal value                      |
  | `lessThan`             | fact < value                                   |
  | `lessThanInclusive`    | fact <= value                                  |
  | `greaterThan`          | fact > value                                   |
  | `greaterThanInclusive` | fact >= value                                  |
  | `in`                   | fact is a member of value (a list)             |
  | `notIn`                | fact is not a member of value (a list)         |
  | `contains`             | fact (a list) includes value                   |
  | `doesNotContain`       | fact (a list) does not include value           |

  Custom operators (registered via `Verdict.Engine.add_operator/3`) extend this
  set at runtime. A custom operator is a **2- or 3-arity** function — the 3rd
  argument is the condition's `params` — that returns a boolean, or a
  `{passed?, explanation}` tuple to supply its own explanation. When a plain
  custom operator returns a tuple, that explanation is used verbatim; when it
  returns a boolean (or is used inside a `decorator:…` composite), a generic
  explanation is generated. Operator decorators
  (`Verdict.Engine.add_operator_decorator/3`) wrap an operator.
  """

  @type value :: term()
  @type result :: {boolean(), String.t()}
  @type operator :: (value(), value() -> result())

  # A custom operator as registered with `Verdict.Engine.add_operator/3`. It is
  # a 2- or 3-arity function (the 3rd argument is the condition's `params`) that
  # returns a boolean, or a `{passed?, explanation}` tuple to supply its own
  # explanation.
  @type custom_operator ::
          (value(), value() -> boolean() | result())
          | (value(), value(), map() -> boolean() | result())

  # A boolean operator (the shape the decorator chain composes over).
  @type boolean_operator :: (value(), value() -> boolean())

  # An operator decorator: receives `(fact_value, json_value, next)` where
  # `next` is the wrapped `t:boolean_operator/0`, and returns a boolean.
  @type decorator :: (value(), value(), boolean_operator() -> boolean())

  @names ~w(equal notEqual lessThan lessThanInclusive greaterThan greaterThanInclusive in notIn contains doesNotContain)

  @doc "Returns the list of built-in operator names."
  @spec known() :: [String.t()]
  def known, do: @names

  @doc """
  Returns the function implementing the named operator.

  The function has the arity `(actual, value) -> {passed?, explanation}`.

  ## Errors

  Raises `ArgumentError` if `name` is not a known operator.
  """
  @spec get(String.t()) :: operator()
  def get(name) when is_binary(name) do
    case name do
      "equal" -> &equal/2
      "notEqual" -> &not_equal/2
      "lessThan" -> &less_than/2
      "lessThanInclusive" -> &less_than_inclusive/2
      "greaterThan" -> &greater_than/2
      "greaterThanInclusive" -> &greater_than_inclusive/2
      "in" -> &in_op/2
      "notIn" -> &not_in_op/2
      "contains" -> &contains/2
      "doesNotContain" -> &does_not_contain/2
      _ -> raise ArgumentError, "unknown operator: #{inspect(name)}"
    end
  end

  @doc """
  Returns the built-in operator decorators as `%{name => decorator}`.

  A decorator receives `(fact_value, json_value, next)` and returns a boolean,
  where `next` is the wrapped operator. See `t:decorator/0`.
  """
  @spec decorators() :: %{String.t() => decorator()}
  def decorators do
    %{
      # fact is a list: at least one element satisfies `next`
      "someFact" => fn fv, jv, next -> is_list(fv) and Enum.any?(fv, &next.(&1, jv)) end,
      # value is a list: at least one element satisfies `next`
      "someValue" => fn fv, jv, next -> is_list(jv) and Enum.any?(jv, &next.(fv, &1)) end,
      # fact is a list: every element satisfies `next`
      "everyFact" => fn fv, jv, next -> is_list(fv) and Enum.all?(fv, &next.(&1, jv)) end,
      # value is a list: every element satisfies `next`
      "everyValue" => fn fv, jv, next -> is_list(jv) and Enum.all?(jv, &next.(fv, &1)) end,
      # swap the fact and value, then evaluate
      "swap" => fn fv, jv, next -> next.(jv, fv) end,
      # negate the result
      "not" => fn fv, jv, next -> not next.(fv, jv) end
    }
  end

  @doc """
  Resolves an operator name to a `t:operator/0` function.

  The name may be a plain operator or a **composite** of the form
  `"decorator:…:operator"` (e.g. `"swap:contains"`), where each decorator is
  applied over the base operator (the leftmost decorator is outermost).

  `custom_operators` and `custom_decorators` are the engine-registered ones
  (they take precedence over the built-ins). Raises `ArgumentError` if the base
  operator or a decorator is unknown.
  """
  @spec resolve(map(), map(), String.t(), map()) :: operator()
  def resolve(custom_operators, custom_decorators, name, params \\ %{}) do
    parts = String.split(name, ":")
    base = List.last(parts)
    decorator_names = Enum.drop(parts, -1)

    cond do
      # a plain, un-overridden built-in: keep its operator-specific explanation
      decorator_names == [] and base in known() and not Map.has_key?(custom_operators, base) ->
        get(base)

      # a plain custom operator: returns a boolean (a generic explanation is
      # built) or {passed?, explanation} (used verbatim)
      decorator_names == [] ->
        plain_custom(custom_operators, base, name, params)

      # a composite: decorators compose over a boolean; the explanation is generic
      true ->
        base_fn = base_boolean(custom_operators, base, params)

        composed =
          Enum.reduce(Enum.reverse(decorator_names), base_fn, fn dname, acc ->
            decorator = decorator_fn(custom_decorators, dname)
            fn fv, jv -> decorator.(fv, jv, acc) end
          end)

        wrap(composed, name)
    end
  end

  # A plain custom operator, invoked with the condition's `params` when it is a
  # 3-arity function. A `{passed?, explanation}` return is used verbatim; a bare
  # boolean gets a generated explanation. An unknown base falls through to `get/1`,
  # which raises the friendly "unknown operator" error.
  defp plain_custom(custom_operators, base, name, params) do
    fn actual, value ->
      case Map.fetch(custom_operators, base) do
        {:ok, fun} ->
          case apply_op(fun, actual, value, params) do
            {passed?, explanation} when is_binary(explanation) -> {passed?, explanation}
            passed? -> {passed?, generic(actual, name, value, passed?)}
          end

        :error ->
          get(base).(actual, value)
      end
    end
  end

  # Calls an operator function, passing the condition `params` when it is 3-arity.
  defp apply_op(fun, actual, value, params) do
    if is_function(fun, 3), do: fun.(actual, value, params), else: fun.(actual, value)
  end

  defp base_boolean(custom_operators, base, params) do
    case Map.fetch(custom_operators, base) do
      {:ok, fun} ->
        fn a, v -> as_bool(apply_op(fun, a, v, params)) end

      :error ->
        builtin = get(base)

        fn a, v ->
          {passed?, _} = builtin.(a, v)
          passed?
        end
    end
  end

  defp as_bool({passed?, _}), do: passed?
  defp as_bool(passed?), do: passed?

  defp decorator_fn(custom_decorators, name) do
    case Map.fetch(custom_decorators, name) do
      {:ok, fun} ->
        fun

      :error ->
        case Map.fetch(decorators(), name) do
          {:ok, fun} -> fun
          :error -> raise ArgumentError, "unknown operator decorator: #{inspect(name)}"
        end
    end
  end

  defp wrap(composed, name) do
    fn actual, value ->
      passed? = composed.(actual, value)
      {passed?, generic(actual, name, value, passed?)}
    end
  end

  defp generic(actual, name, value, passed?) do
    "#{f(actual)} #{name} #{f(value)} is #{if passed?, do: "true", else: "false"}"
  end

  # Each operator inspects both operands once and builds only the explanation for
  # the branch that was taken (rather than building both the pass and fail strings
  # and discarding one), keeping the per-leaf explanation cost down.
  defp equal(a, b) do
    {sa, sb} = {f(a), f(b)}
    if a == b, do: {true, "#{sa} equals #{sb}"}, else: {false, "#{sa} is not equal to #{sb}"}
  end

  defp not_equal(a, b) do
    {sa, sb} = {f(a), f(b)}
    if a != b, do: {true, "#{sa} is not equal to #{sb}"}, else: {false, "#{sa} equals #{sb}"}
  end

  defp less_than(a, b) do
    {sa, sb} = {f(a), f(b)}
    if a < b, do: {true, "#{sa} < #{sb}"}, else: {false, "#{sa} is not less than #{sb}"}
  end

  defp less_than_inclusive(a, b) do
    {sa, sb} = {f(a), f(b)}

    if a <= b,
      do: {true, "#{sa} <= #{sb}"},
      else: {false, "#{sa} is not less than or equal to #{sb}"}
  end

  defp greater_than(a, b) do
    {sa, sb} = {f(a), f(b)}
    if a > b, do: {true, "#{sa} > #{sb}"}, else: {false, "#{sa} is not greater than #{sb}"}
  end

  defp greater_than_inclusive(a, b) do
    {sa, sb} = {f(a), f(b)}

    if a >= b,
      do: {true, "#{sa} >= #{sb}"},
      else: {false, "#{sa} is not greater than or equal to #{sb}"}
  end

  defp in_op(a, b) do
    {sa, sb} = {f(a), f(b)}
    passed? = is_list(b) and a in b
    if passed?, do: {true, "#{sa} is in #{sb}"}, else: {false, "#{sa} is not in #{sb}"}
  end

  defp not_in_op(a, b) do
    {sa, sb} = {f(a), f(b)}
    passed? = is_list(b) and a not in b
    if passed?, do: {true, "#{sa} is not in #{sb}"}, else: {false, "#{sa} is in #{sb}"}
  end

  defp contains(a, b) do
    {sa, sb} = {f(a), f(b)}
    passed? = is_list(a) and b in a
    if passed?, do: {true, "#{sa} contains #{sb}"}, else: {false, "#{sa} does not contain #{sb}"}
  end

  defp does_not_contain(a, b) do
    {sa, sb} = {f(a), f(b)}
    passed? = is_list(a) and b not in a
    if passed?, do: {true, "#{sa} does not contain #{sb}"}, else: {false, "#{sa} contains #{sb}"}
  end

  defp f(value), do: inspect(value)
end
