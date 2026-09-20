defmodule JsonRules.Almanac.ProcessLocal do
  @moduledoc """
  The default (process-local) almanac backend, used by the `:serial` engine.

  The per-run state (`%{defs, cache, stopped}`) lives in the calling process's
  dictionary under a unique token. Because everything runs in a single process,
  a fact referenced by several conditions — or facts — is computed once and
  cached for the run, and nested fact computation can read and update the cache
  directly.
  """
  alias JsonRules.{Almanac, Fact, UndefinedFactError}

  @doc "Creates the process-local state and returns its token (the handle)."
  def create(defs, _opts) do
    state = %{defs: defs, cache: %{}, stopped: false}
    token = make_ref()
    Process.put(token, state)
    token
  end

  @doc "Releases the process-local state."
  def destroy(%Almanac{handle: token}) do
    Process.delete(token)
    :ok
  end

  @doc "Computes (and caches) the value of `fact_id`."
  def fact_value(
        %Almanac{handle: token, allow_undefined_facts: allow?} = almanac,
        fact_id,
        params
      ) do
    params = params || %{}
    st = state(token)

    case Map.get(st.defs, fact_id) do
      nil ->
        if allow? do
          nil
        else
          raise UndefinedFactError, fact: fact_id
        end

      %Fact{cache: true} = fact ->
        key = {fact_id, params}

        case Map.fetch(st.cache, key) do
          {:ok, value} ->
            value

          :error ->
            value = Fact.calculate(fact, params, almanac)
            # Re-read before writing: compute may have cached dependent facts
            # via nested fact_value calls, which this write must not clobber.
            put_state(token, fn s -> %{s | cache: Map.put(s.cache, key, value)} end)
            value
        end

      %Fact{cache: false} = fact ->
        Fact.calculate(fact, params, almanac)
    end
  end

  @doc "The registered priority of `fact_id` (default `1`)."
  def fact_priority(%Almanac{handle: token}, fact_id) do
    case Map.get(state(token).defs, to_string(fact_id)) do
      %Fact{priority: priority} -> priority
      _ -> 1
    end
  end

  @doc "The `{fact_id, value}` pairs computed so far."
  def facts(%Almanac{handle: token}) do
    token
    |> state()
    |> Map.get(:cache)
    |> Enum.map(fn {{fact_id, _params}, value} -> {fact_id, value} end)
  end

  @doc "Adds a constant fact to the run state, visible to later lookups."
  def add_runtime_fact(%Almanac{handle: token}, fact_id, value) do
    id = to_string(fact_id)
    put_state(token, fn s -> %{s | defs: Map.put(s.defs, id, Fact.new(id, value))} end)
    :ok
  end

  @doc "Marks the run as stopped."
  def stop(%Almanac{handle: token}) do
    put_state(token, fn s -> %{s | stopped: true} end)
    :ok
  end

  @doc "True once `stop/1` has been called for this run."
  def stopped?(%Almanac{handle: token}), do: state(token).stopped

  defp state(token), do: Process.get(token)

  # Read-modify-write the run state. The transform is applied to the latest
  # state, so nested mutations (e.g. a dependent fact cached during compute) are
  # preserved.
  defp put_state(token, fun) do
    Process.put(token, fun.(Process.get(token)))
  end
end
