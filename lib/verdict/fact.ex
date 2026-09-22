defmodule Verdict.Fact do
  @moduledoc """
  A registered fact.

  A fact is either a **constant** (any term) or **dynamic** (a function of
  `(params, almanac)` — or `(params)` — that computes its value). `params` are
  supplied by the condition that references the fact (its `params` map); a
  dynamic fact can also read *other* facts through the `almanac`, which is how
  facts depend on one another:

      engine =
        Verdict.Engine.new()
        |> Verdict.Engine.add_fact("account-info", fn _p, _a -> %{company: "microsoft"} end)
        |> Verdict.Engine.add_fact("company", fn _p, almanac ->
          Verdict.Almanac.fact_value(almanac, "account-info").company
        end)

  Facts are computed lazily and **cached per run**, so a fact (and any facts it
  reads) is computed only once no matter how many conditions or facts reference
  it. Beyond the definition a fact carries two options:

    * `cache` (default `true`) – when `false`, a dynamic fact is recomputed on
      every reference instead of being cached for the run.
    * `priority` (default `1`) – when a rule's `all`/`any` leaves carry no
      explicit condition `priority`, they are evaluated in fact-priority order
      (highest first), so a high-priority fact that fails an `all` (or passes an
      `any`) can decide the rule before the lower-priority facts are touched.
  """

  @type calc :: (map(), Verdict.Almanac.t() -> term()) | (map() -> term())

  @type t :: %__MODULE__{
          id: String.t(),
          value: term(),
          calculation_method: nil | calc(),
          cache: boolean(),
          priority: integer()
        }

  @type registry :: %{String.t() => t()}

  defstruct [:id, :value, :calculation_method, cache: true, priority: 1]

  @doc """
  Builds a fact from a `definition` (a constant term or a `(params, almanac)` /
  `(params)` function) and `opts`.

  ## Options

  * `:cache` – default `true`.
  * `:priority` – default `1`.
  """
  @spec new(String.t(), term(), keyword()) :: t()
  def new(id, definition, opts \\ []) do
    base = %__MODULE__{
      id: id,
      cache: Keyword.get(opts, :cache, true),
      priority: parse_priority(Keyword.get(opts, :priority, 1))
    }

    if dynamic?(definition) do
      %{base | calculation_method: definition}
    else
      %{base | value: definition}
    end
  end

  @doc "True when the fact is dynamic (backed by a `(params, almanac)` / `(params)` function)."
  @spec is_dynamic?(t()) :: boolean()
  def is_dynamic?(%__MODULE__{calculation_method: method}), do: is_function(method)

  @doc "Computes the fact's value for the given `params` (its constant value, if constant)."
  @spec calculate(t(), map(), Verdict.Almanac.t()) :: term()
  def calculate(%__MODULE__{calculation_method: nil, value: value}, _params, _almanac), do: value

  def calculate(%__MODULE__{calculation_method: fun}, params, almanac) when is_function(fun, 2),
    do: fun.(params, almanac)

  def calculate(%__MODULE__{calculation_method: fun}, params, _almanac) when is_function(fun, 1),
    do: fun.(params)

  defp dynamic?(definition), do: is_function(definition, 1) or is_function(definition, 2)

  defp parse_priority(nil), do: 1
  defp parse_priority(p) when is_integer(p), do: p
  defp parse_priority(p) when is_binary(p), do: String.to_integer(p)
  defp parse_priority(_), do: 1
end
