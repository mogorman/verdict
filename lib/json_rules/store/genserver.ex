defmodule JsonRules.Store.GenServer do
  @moduledoc """
  The `:genserver` store backend.

  The store's `JsonRules.Store.State` lives in a GenServer's process state, so the
  engine's rules and facts are owned by a process rather than held (as immutable
  structs) in the caller. This is the default "stateful" backend: pick it with
  `JsonRules.Engine.new(store: :genserver)`.

  ## Starting the store

  * `JsonRules.Engine.new(store: :genserver)` – a store process is started (linked
    to the calling process) for you.
  * `start_link/1` – start one yourself (e.g. under a supervisor) and wrap it with
    `JsonRules.Engine.new(store: {JsonRules.Store.GenServer, name_or_pid})`. This
    is the way to share a single store across engines/runs when its contents are
    stable.

  Store-specific options (currently just `:name`) are passed via
  `JsonRules.Engine.new(store: :genserver, store_options: [name: ...])` or directly
  to `create/1` / `start_link/1`.
  """
  use GenServer
  @behaviour JsonRules.Store

  alias JsonRules.Store.State

  @type t :: pid() | atom()

  # --- behaviour: creation ---------------------------------------------------

  @impl true
  def create(options) do
    case GenServer.start(__MODULE__, State.new(), Keyword.take(options, [:name])) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "failed to start store: #{inspect(reason)}"
    end
  end

  @doc "Starts a store under the caller's supervision (returns `{:ok, pid}`)."
  def start_link(options) do
    GenServer.start_link(__MODULE__, State.new(), Keyword.take(options, [:name]))
  end

  # --- behaviour: rule / fact / operator / decorator / condition ------------

  @impl true
  def add_rule(handle, rule), do: {handle, GenServer.call(handle, {:add_rule, rule})}

  @impl true
  def remove_rule(handle, key), do: {handle, GenServer.call(handle, {:remove_rule, key})}

  @impl true
  def get_rule(handle, id), do: {handle, GenServer.call(handle, {:get_rule, id})}

  @impl true
  def rules(handle), do: {handle, GenServer.call(handle, :rules)}

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
  def init(initial_state), do: {:ok, initial_state}

  @impl true
  def handle_call({:add_rule, rule}, _from, state) do
    {state, added} = State.add_rule(state, rule)
    {:reply, added, state}
  end

  @impl true
  def handle_call({:remove_rule, key}, _from, state) do
    {state, removed} = State.remove_rule(state, key)
    {:reply, removed, state}
  end

  @impl true
  def handle_call({:get_rule, id}, _from, state),
    do: {:reply, elem(State.get_rule(state, id), 1), state}

  @impl true
  def handle_call(:rules, _from, state), do: {:reply, elem(State.rules(state), 1), state}

  @impl true
  def handle_call({:add_fact, fact}, _from, state) do
    {:reply, :ok, State.add_fact(state, fact)}
  end

  @impl true
  def handle_call({:remove_fact, id}, _from, state) do
    {:reply, :ok, State.remove_fact(state, id)}
  end

  @impl true
  def handle_call(:facts, _from, state), do: {:reply, state.facts, state}

  @impl true
  def handle_call({:add_operator, name, fun}, _from, state) do
    {:reply, :ok, State.add_operator(state, name, fun)}
  end

  @impl true
  def handle_call({:remove_operator, name}, _from, state) do
    {:reply, :ok, State.remove_operator(state, name)}
  end

  @impl true
  def handle_call(:operators, _from, state), do: {:reply, state.operators, state}

  @impl true
  def handle_call({:add_decorator, name, fun}, _from, state) do
    {:reply, :ok, State.add_decorator(state, name, fun)}
  end

  @impl true
  def handle_call({:remove_decorator, name}, _from, state) do
    {:reply, :ok, State.remove_decorator(state, name)}
  end

  @impl true
  def handle_call(:decorators, _from, state), do: {:reply, state.decorators, state}

  @impl true
  def handle_call({:add_condition, name, condition}, _from, state) do
    {:reply, :ok, State.add_condition(state, name, condition)}
  end

  @impl true
  def handle_call({:remove_condition, name}, _from, state) do
    {state, removed} = State.remove_condition(state, name)
    {:reply, removed, state}
  end

  @impl true
  def handle_call(:conditions, _from, state), do: {:reply, state.conditions, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
