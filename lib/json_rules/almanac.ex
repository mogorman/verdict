defmodule JsonRules.Almanac do
  @moduledoc """
  Per-run evaluation context.

  The almanac owns the registered facts and a cache of computed fact values.
  The cache is an in-memory ETS table created for the duration of a single run
  and shared (read/write) so that:

    * a fact referenced by several conditions is computed only once;
    * a fact that calls other facts (fact dependencies) can read cached values;
    * (Phase 2) parallel evaluation of a priority bucket shares one cache.

  Callers obtain a value with `fact_value/3`, which computes and caches on a
  miss. The almanac must be released with `destroy/1` when the run is complete.
  """
  alias JsonRules.UndefinedFactError

  defstruct [:cache, :defs, allow_undefined_facts: false]

  @type t :: %__MODULE__{
          cache: :ets.tid(),
          defs: map(),
          allow_undefined_facts: boolean()
        }

  @doc """
  Builds a fresh almanac for a run.

  `defs` are the facts registered on the engine; `runtime_facts` (e.g. the map
  passed to `JsonRules.Engine.run/3`) override them for this run only.
  """
  @spec new(map() | nil, map() | nil, keyword()) :: t()
  def new(defs, runtime_facts \\ %{}, opts \\ []) do
    defs = normalize(defs)
    # runtime facts override registered facts of the same name for this run
    defs = Map.merge(defs, normalize(runtime_facts))
    name = String.to_atom("almanac_cache_#{:erlang.unique_integer([:positive])}")
    cache = :ets.new(name, [:set, :public])

    %__MODULE__{
      cache: cache,
      defs: defs,
      allow_undefined_facts: Keyword.get(opts, :allow_undefined_facts, false)
    }
  end

  @doc "Releases the almanac's cache. Safe to call once per run."
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{cache: cache}) do
    :ets.delete(cache)
    :ok
  end

  @doc """
  Computes (and caches) the value of `fact_id` for the given `params`.

  A fact is a constant (any term) or a function of `(params, almanac)` (or
  `(params)`). The result is cached under `{fact_id, params}`.
  """
  @spec fact_value(t(), term(), map() | nil) :: term()
  def fact_value(%__MODULE__{} = almanac, fact_id, params \\ %{}) do
    params = params || %{}
    key = {fact_id, params}

    case :ets.lookup(almanac.cache, key) do
      [{^key, value}] ->
        value

      [] ->
        value = compute(Map.get(almanac.defs, fact_id), fact_id, params, almanac)
        :ets.insert(almanac.cache, {key, value})
        value
    end
  end

  @doc "Returns the `{fact_id, value}` pairs computed so far during the run."
  @spec facts(t()) :: [{term(), term()}]
  def facts(%__MODULE__{cache: cache}) do
    cache
    |> :ets.tab2list()
    |> Enum.map(fn {{fact_id, _params}, value} -> {fact_id, value} end)
  end

  # Fact ids are normalised to strings so `%{x: 1}` and `%{"x" => 1}` are
  # equivalent; condition facts are always strings.
  defp normalize(nil), do: %{}
  defp normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp compute(nil, fact_id, _params, almanac) do
    if almanac.allow_undefined_facts do
      nil
    else
      raise UndefinedFactError, fact: fact_id
    end
  end

  defp compute(fun, _fact_id, params, almanac) when is_function(fun, 2),
    do: fun.(params, almanac)

  defp compute(fun, _fact_id, params, _almanac) when is_function(fun, 1),
    do: fun.(params)

  defp compute(value, _fact_id, _params, _almanac), do: value
end
