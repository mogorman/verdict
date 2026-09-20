defmodule JsonRules.Almanac.Shared do
  @moduledoc """
  The shared almanac backend, used by the `:parallel` engine.

  The per-run state (`%{defs, cache, stopped}`) lives in a short-lived GenServer,
  so it is shared across the worker processes that evaluate a run's rules
  concurrently. Only the cache lookups and control-state updates round-trip
  through the server; a fact's value is **computed in the calling worker**, not in
  the server. That is what keeps a fact that depends on other facts from deadlocking
  (the worker calls back into the server for its dependencies, never the reverse).

  Because the cache is a best-effort check-then-put across processes, a fact
  referenced by several rules in the *same* priority bucket may be computed more
  than once; the value is consistent for pure facts. The `:serial` engine
  (`JsonRules.Almanac.ProcessLocal`) still guarantees single computation.
  """
  use GenServer

  alias JsonRules.{Almanac, Fact, UndefinedFactError}

  # --- backend API (dispatched to by JsonRules.Almanac) ----------------------

  @doc "Starts the per-run state GenServer and returns its pid (the handle)."
  def create(defs, _opts) do
    {:ok, pid} = GenServer.start(__MODULE__, %{defs: defs, cache: %{}, stopped: false})
    pid
  end

  @doc "Stops the per-run state GenServer."
  def destroy(%Almanac{handle: pid}), do: GenServer.stop(pid)

  @doc "Computes (and caches) the value of `fact_id` in the calling worker."
  def fact_value(%Almanac{handle: pid, allow_undefined_facts: allow?} = almanac, fact_id, params) do
    params = params || %{}

    case GenServer.call(pid, {:get_def, fact_id}) do
      nil ->
        if allow? do
          nil
        else
          raise UndefinedFactError, fact: fact_id
        end

      %Fact{cache: true} = fact ->
        key = {fact_id, params}

        case GenServer.call(pid, {:lookup, key}) do
          {:ok, value} ->
            value

          :error ->
            # Compute in the calling worker (which may recurse into fact_value for
            # dependent facts); only the store round-trips through the server.
            value = Fact.calculate(fact, params, almanac)
            GenServer.call(pid, {:cache_put, key, value})
            value
        end

      %Fact{cache: false} = fact ->
        Fact.calculate(fact, params, almanac)
    end
  end

  @doc "The registered priority of `fact_id` (default `1`)."
  def fact_priority(%Almanac{handle: pid}, fact_id),
    do: GenServer.call(pid, {:fact_priority, fact_id})

  @doc "The `{fact_id, value}` pairs computed so far."
  def facts(%Almanac{handle: pid}), do: GenServer.call(pid, {:facts})

  @doc "Adds a constant fact to the run state, visible to later lookups."
  def add_runtime_fact(%Almanac{handle: pid}, fact_id, value),
    do: GenServer.call(pid, {:add_runtime_fact, fact_id, value})

  @doc "Marks the run as stopped."
  def stop(%Almanac{handle: pid}), do: GenServer.call(pid, {:stop})

  @doc "True once `stop/1` has been called for this run."
  def stopped?(%Almanac{handle: pid}), do: GenServer.call(pid, {:stopped?})

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get_def, id}, _from, state), do: {:reply, Map.get(state.defs, id), state}

  @impl true
  def handle_call({:lookup, key}, _from, state), do: {:reply, Map.fetch(state.cache, key), state}

  @impl true
  def handle_call({:cache_put, key, value}, _from, state),
    do: {:reply, :ok, %{state | cache: Map.put(state.cache, key, value)}}

  @impl true
  def handle_call({:add_runtime_fact, id, value}, _from, state) do
    id = to_string(id)
    {:reply, :ok, %{state | defs: Map.put(state.defs, id, Fact.new(id, value))}}
  end

  @impl true
  def handle_call({:stop}, _from, state), do: {:reply, :ok, %{state | stopped: true}}

  @impl true
  def handle_call({:stopped?}, _from, state), do: {:reply, state.stopped, state}

  @impl true
  def handle_call({:facts}, _from, state) do
    facts = Enum.map(state.cache, fn {{id, _params}, value} -> {id, value} end)
    {:reply, facts, state}
  end

  @impl true
  def handle_call({:fact_priority, id}, _from, state) do
    reply =
      case Map.get(state.defs, to_string(id)) do
        %Fact{priority: priority} -> priority
        _ -> 1
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
