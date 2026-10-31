defmodule Verdict.Store.Ets do
  @moduledoc """
  The `:ets` store backend (opt-in, for high-scale or shared workloads).

  A GenServer whose **rules and facts live in public ETS tables** (one per store)
  for fast, low-overhead lookups, while operators, decorators and conditions stay
  in the process state. This is the highest-capacity built-in backend; pick it with
  `Verdict.Engine.new(store: :ets)`.

  ## Starting the store

  * `Verdict.Engine.new(store: :ets)` – a store is started for you, backed by
    uniquely-named ETS tables.
  * `Verdict.Engine.new(store: :ets, store_options: [table: :my_store])` – use a
    **named** table base, so other processes can read the tables directly via
    `:ets.lookup(:"my_store.rules", id)`.
  * `start_link/1` – start one under a supervisor and wrap it with
    `Verdict.Engine.new(store: {Verdict.Store.Ets, name_or_pid})`.

  The tables are owned by the store process and are removed when it exits.
  """
  use GenServer
  @behaviour Verdict.Store

  alias Verdict.Fact

  @type t :: pid() | atom()

  # --- behaviour: creation ---------------------------------------------------

  @impl true
  def create(options) do
    name_opts = Keyword.take(options, [:name])

    case GenServer.start(__MODULE__, Keyword.get(options, :table), name_opts) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "failed to start store: #{inspect(reason)}"
    end
  end

  @doc "Starts a store under the caller's supervision (returns `{:ok, pid}`)."
  def start_link(options),
    do:
      GenServer.start_link(
        __MODULE__,
        Keyword.get(options, :table),
        Keyword.take(options, [:name])
      )

  # --- behaviour: rules (ETS) ------------------------------------------------

  @impl true
  def add_rule(handle, rule), do: {handle, GenServer.call(handle, {:add_rule, rule})}

  @impl true
  def remove_rule(handle, key), do: {handle, GenServer.call(handle, {:remove_rule, key})}

  @impl true
  def get_rule(handle, id), do: {handle, GenServer.call(handle, {:get_rule, id})}

  @impl true
  def rules(handle), do: {handle, GenServer.call(handle, :rules)}

  # --- behaviour: facts (ETS) ------------------------------------------------

  @impl true
  def add_fact(handle, fact) do
    GenServer.call(handle, {:add_fact, fact})
    handle
  end

  @impl true
  def remove_fact(handle, id) do
    GenServer.call(handle, {:remove_fact, id})
    handle
  end

  @impl true
  def facts(handle), do: {handle, GenServer.call(handle, :facts)}

  # --- behaviour: operators / decorators / conditions (process state) --------

  @impl true
  def add_operator(handle, name, fun) do
    GenServer.call(handle, {:add_operator, name, fun})
    handle
  end

  @impl true
  def remove_operator(handle, name) do
    GenServer.call(handle, {:remove_operator, name})
    handle
  end

  @impl true
  def operators(handle), do: {handle, GenServer.call(handle, :operators)}

  @impl true
  def add_decorator(handle, name, fun) do
    GenServer.call(handle, {:add_decorator, name, fun})
    handle
  end

  @impl true
  def remove_decorator(handle, name) do
    GenServer.call(handle, {:remove_decorator, name})
    handle
  end

  @impl true
  def decorators(handle), do: {handle, GenServer.call(handle, :decorators)}

  @impl true
  def add_condition(handle, name, condition) do
    GenServer.call(handle, {:add_condition, name, condition})
    handle
  end

  @impl true
  def remove_condition(handle, name),
    do: {handle, GenServer.call(handle, {:remove_condition, name})}

  @impl true
  def conditions(handle), do: {handle, GenServer.call(handle, :conditions)}

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(table_name) do
    base = table_name || :"ets_store_#{:erlang.unique_integer([:positive])}"
    rules = :"#{base}.rules"
    facts = :"#{base}.facts"

    # `:ets.new/2` registers the named table; a name collision raises
    # `ArgumentError` out of `init/1`, which the GenServer turns into a failed
    # start (surfaced by `create/1`).
    _ = :ets.new(rules, [:set, :public, :named_table])
    _ = :ets.new(facts, [:set, :public, :named_table])

    {:ok, %{rules: rules, facts: facts, operators: %{}, decorators: %{}, conditions: %{}}}
  end

  @impl true
  def handle_call({:add_rule, rule}, _from, state) do
    :ets.insert(state.rules, {rule.id, rule})
    {:reply, rule, state}
  end

  @impl true
  def handle_call({:remove_rule, key}, _from, state) do
    if :ets.member(state.rules, key) do
      :ets.delete(state.rules, key)
      {:reply, true, state}
    else
      all = :ets.tab2list(state.rules)
      remaining = Enum.reject(all, fn {_id, rule} -> rule.name == key end)
      removed = length(remaining) < length(all)
      rewrite_rules(state, remaining)
      {:reply, removed, state}
    end
  end

  @impl true
  def handle_call({:get_rule, id}, _from, state) do
    reply =
      case :ets.lookup(state.rules, id) do
        [{^id, rule}] -> rule
        [] -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:rules, _from, state) do
    {:reply, :ets.tab2list(state.rules) |> Enum.map(&elem(&1, 1)), state}
  end

  @impl true
  def handle_call({:add_fact, %Fact{} = fact}, _from, state) do
    :ets.insert(state.facts, {fact.id, fact})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_fact, id}, _from, state) do
    :ets.delete(state.facts, to_string(id))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:facts, _from, state) do
    {:reply, :ets.tab2list(state.facts) |> Map.new(), state}
  end

  @impl true
  def handle_call({:add_operator, name, fun}, _from, state) do
    {:reply, :ok, %{state | operators: Map.put(state.operators, name, fun)}}
  end

  @impl true
  def handle_call({:remove_operator, name}, _from, state) do
    {:reply, :ok, %{state | operators: Map.delete(state.operators, name)}}
  end

  @impl true
  def handle_call(:operators, _from, state), do: {:reply, state.operators, state}

  @impl true
  def handle_call({:add_decorator, name, fun}, _from, state) do
    {:reply, :ok, %{state | decorators: Map.put(state.decorators, name, fun)}}
  end

  @impl true
  def handle_call({:remove_decorator, name}, _from, state) do
    {:reply, :ok, %{state | decorators: Map.delete(state.decorators, name)}}
  end

  @impl true
  def handle_call(:decorators, _from, state), do: {:reply, state.decorators, state}

  @impl true
  def handle_call({:add_condition, name, condition}, _from, state) do
    {:reply, :ok, %{state | conditions: Map.put(state.conditions, name, condition)}}
  end

  @impl true
  def handle_call({:remove_condition, name}, _from, state) do
    removed = Map.has_key?(state.conditions, name)
    {:reply, removed, %{state | conditions: Map.delete(state.conditions, name)}}
  end

  @impl true
  def handle_call(:conditions, _from, state), do: {:reply, state.conditions, state}

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.rules)
    :ets.delete(state.facts)
    :ok
  end

  defp rewrite_rules(state, remaining) do
    :ets.delete_all_objects(state.rules)

    for {id, rule} <- remaining do
      :ets.insert(state.rules, {id, rule})
    end

    :ok
  end
end
