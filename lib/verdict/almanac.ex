defmodule Verdict.Almanac do
  @moduledoc """
  Per-run evaluation context and mutable run state.

  The almanac owns the registered facts, a cache of computed fact values, and the
  run's control state (whether it has been stopped, plus any runtime facts added
  mid-run). A run obtains a value with `fact_value/3`, which computes and caches on
  a miss, and must release the almanac with `destroy/1` when the run is complete.

  ## Backends

  The almanac is a thin, public API over a pluggable **backend** that stores the
  mutable run state. Both backends expose the same functions (`create/2`,
  `fact_value/3`, `fact_priority/2`, `facts/1`, `add_runtime_fact/3`, `stop/1`,
  `stopped?/1`, `destroy/1`), taking the almanac itself (so a fact that depends on
  other facts can recurse through this API):

    * `Verdict.Almanac.ProcessLocal` (default) – the state lives in the calling
      process's dictionary. Used by the `:serial` engine. A fact referenced by
      several conditions (or facts) is computed once.
    * `Verdict.Almanac.Shared` – the state lives in a short-lived GenServer, so
      it is shared across the worker processes of a `:parallel` run.

  `new/3` selects the backend via the `:backend` option (`:process_local`, the
  default, or `:shared`). The `Verdict.Evaluator` passes `:shared` when the
  engine runs `:parallel`.
  """
  alias Verdict.{Almanac.ProcessLocal, Almanac.Shared, Fact}

  defstruct backend: nil, handle: nil, allow_undefined_facts: false

  # A map of fact names (string or atom) to plain values, e.g. the runtime facts
  # passed to `Verdict.Engine.run/3`.
  @type fact_map :: %{(String.t() | atom()) => term()}

  @type backend :: :process_local | :shared

  @type t :: %__MODULE__{
          backend: module(),
          handle: term(),
          allow_undefined_facts: boolean()
        }

  @doc """
  Builds a fresh almanac for a run.

  `defs` are the facts registered on the engine (a `Verdict.Fact.registry()`);
  `runtime_facts` (e.g. the map passed to `Verdict.Engine.run/3`) override them
  for this run only.

  ## Options

  * `:backend` – `:process_local` (default) or `:shared`.
  * `:allow_undefined_facts` – default `false`. When `true`, a missing fact
    reads as `nil` instead of raising.
  """
  @spec new(Fact.registry() | nil, fact_map() | nil, keyword()) :: t()
  def new(defs, runtime_facts \\ %{}, opts \\ []) do
    backend_name = Keyword.get(opts, :backend, :process_local)
    backend = backend_module(backend_name)
    merged_defs = Map.merge(normalize_registry(defs), normalize_runtime(runtime_facts))
    handle = backend.create(merged_defs, opts)

    %__MODULE__{
      backend: backend,
      handle: handle,
      allow_undefined_facts: Keyword.get(opts, :allow_undefined_facts, false)
    }
  end

  @doc "Releases the almanac's run state. Safe to call once per run."
  @spec destroy(t()) :: :ok
  def destroy(%__MODULE__{} = almanac), do: almanac.backend.destroy(almanac)

  @doc """
  Computes the value of `fact_id` for the given `params`, caching it for the run
  unless the fact was registered with `cache: false`.

  A cached value is reused for the same `{fact_id, params}`. An unregistered
  fact either raises `Verdict.UndefinedFactError` or (when
  `allow_undefined_facts` is set) evaluates to `nil`.
  """
  @spec fact_value(t(), String.t(), map() | nil) :: term()
  def fact_value(%__MODULE__{} = almanac, fact_id, params \\ %{}) do
    almanac.backend.fact_value(almanac, fact_id, params)
  end

  @doc """
  Returns the registered priority of `fact_id` (used to order a rule's leaf
  conditions), defaulting to `1` when the fact is not registered.
  """
  @spec fact_priority(t(), String.t() | atom()) :: integer()
  def fact_priority(%__MODULE__{} = almanac, fact_id),
    do: almanac.backend.fact_priority(almanac, fact_id)

  @doc "Returns the `{fact_id, value}` pairs computed so far during the run."
  @spec facts(t()) :: [{String.t(), term()}]
  def facts(%__MODULE__{} = almanac), do: almanac.backend.facts(almanac)

  @doc """
  Adds a constant fact to the almanac mid-run, visible to subsequent fact
  lookups. Used by event handlers to feed a value to later rules.
  """
  @spec add_runtime_fact(t(), String.t() | atom(), term()) :: t()
  def add_runtime_fact(%__MODULE__{} = almanac, fact_id, value) do
    almanac.backend.add_runtime_fact(almanac, fact_id, value)
    almanac
  end

  @doc "Stops the run: no further rules will be evaluated and no further events emitted."
  @spec stop(t()) :: t()
  def stop(%__MODULE__{} = almanac) do
    almanac.backend.stop(almanac)
    almanac
  end

  @doc "True once `stop/1` has been called for this run."
  @spec stopped?(t()) :: boolean()
  def stopped?(%__MODULE__{} = almanac), do: almanac.backend.stopped?(almanac)

  defp backend_module(:process_local), do: ProcessLocal
  defp backend_module(:shared), do: Shared

  defp backend_module(other) do
    raise ArgumentError, "unknown almanac backend: #{inspect(other)}"
  end

  # Registered facts are keyed by id; ids are normalised to strings so
  # `%{x: 1}` and `%{"x" => 1}` are equivalent.
  defp normalize_registry(nil), do: %{}

  defp normalize_registry(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # Runtime facts are plain values; wrap each as a constant fact.
  defp normalize_runtime(nil), do: %{}

  defp normalize_runtime(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      id = to_string(k)
      {id, Fact.new(id, v)}
    end)
  end
end
