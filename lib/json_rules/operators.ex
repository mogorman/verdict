defmodule JsonRules.Operators do
  @moduledoc """
  The built-in operators used to compare a computed fact against a condition's
  value.

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

  Custom operators and operator decorators (Phase 2) extend this set at runtime.
  """

  @type value :: term()
  @type operator :: (value(), value() -> boolean())

  @names ~w(equal notEqual lessThan lessThanInclusive greaterThan greaterThanInclusive in notIn contains doesNotContain)

  @doc "Returns the list of built-in operator names."
  @spec known() :: [String.t()]
  def known, do: @names

  @doc """
  Returns the function implementing the named operator.

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

  defp equal(a, b), do: a == b
  defp not_equal(a, b), do: a != b
  defp less_than(a, b), do: a < b
  defp less_than_inclusive(a, b), do: a <= b
  defp greater_than(a, b), do: a > b
  defp greater_than_inclusive(a, b), do: a >= b
  defp in_op(a, b), do: is_list(b) and a in b
  defp not_in_op(a, b), do: is_list(b) and a not in b
  defp contains(a, b), do: is_list(a) and b in a
  defp does_not_contain(a, b), do: is_list(a) and b not in a
end
