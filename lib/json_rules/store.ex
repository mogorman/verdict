defmodule JsonRules.Store do
  @moduledoc """
  The contract (behaviour) for a pluggable, in-memory rule/fact store.

  A store holds validated `JsonRules.Rule` structs (keyed by id) plus the
  registered facts, operators, operator decorators and named conditions.
  Evaluation is pure and lives in `JsonRules.Evaluator`; a store is only
  responsible for persistence.

  The `t:t/0` "state" is an opaque handle. Each backend defines it differently:

    * `JsonRules.Store.Pure` – a plain `JsonRules.Store.State` struct the caller
      holds (the default);
    * `JsonRules.Store.GenServer` – a GenServer pid / name holding a `State` in
      its process;
    * `JsonRules.Store.Ets` – a GenServer whose rules and facts also live in a
      public ETS table for fast, shareable reads.

  `JsonRules.Engine` keeps both the backend *module* and its *state* and dispatches
  through the module, so **adding a backend is just implementing this behaviour**.

  ## Implementing a custom store

  The callbacks return the (possibly new) handle as the first element of a tuple,
  so a stateful backend can return the same handle each time (a process) while a
  pure backend returns a new struct. For example, a minimal process-backed store:

      defmodule MyStore do
        use GenServer
        @behaviour JsonRules.Store

        def create(_opts) do
          {:ok, pid} = GenServer.start(__MODULE__, JsonRules.Store.State.new())
          pid
        end

        def add_rule(handle, rule) do
          handle
          |> GenServer.call({:add_rule, rule})
          |> then(&{handle, &1})
        end

        def rules(handle) do
          handle |> GenServer.call(:rules) |> then(&{handle, &1})
        end

        # ... the remaining callbacks the same way, delegating to
        # JsonRules.Store.State ...

        def init(initial_state), do: {:ok, initial_state}

        def handle_call({:add_rule, rule}, _from, state) do
          {state, added} = JsonRules.Store.State.add_rule(state, rule)
          {:reply, added, state}
        end

        def handle_call(:rules, _from, state),
          do: {:reply, elem(JsonRules.Store.State.rules(state), 1), state}
      end

  Then use it with `JsonRules.Engine.new(store: {MyStore, MyStore.create([])})` —
  or start it under your own supervision and pass the pid/name as the handle.

  ## Note on run configuration

  A store holds only the rule/fact/operator/decorator/condition registries. Run
  configuration (`schedule`, `strict`, `allow_undefined_facts`, …) lives on the
  `JsonRules.Engine`, so a pre-started store can be shared across engines and runs
  without its configuration being baked in.
  """
  alias JsonRules.Rule

  @type t :: term()

  @doc "Creates a new store, returning its (opaque) handle."
  @callback create(keyword()) :: t()

  @callback add_rule(t(), Rule.t()) :: {t(), Rule.t()}
  @callback remove_rule(t(), String.t() | atom()) :: {t(), boolean()}
  @callback get_rule(t(), String.t()) :: {t(), Rule.t() | nil}
  @callback rules(t()) :: {t(), [Rule.t()]}
  @callback add_fact(t(), JsonRules.Fact.t()) :: t()
  @callback remove_fact(t(), String.t()) :: t()
  @callback facts(t()) :: {t(), JsonRules.Fact.registry()}
  @callback add_operator(t(), String.t(), term()) :: t()
  @callback remove_operator(t(), String.t()) :: t()
  @callback operators(t()) :: {t(), map()}
  @callback add_decorator(t(), String.t(), term()) :: t()
  @callback remove_decorator(t(), String.t()) :: t()
  @callback decorators(t()) :: {t(), map()}
  @callback add_condition(t(), String.t(), term()) :: t()
  @callback remove_condition(t(), String.t()) :: {t(), boolean()}
  @callback conditions(t()) :: {t(), map()}
end
