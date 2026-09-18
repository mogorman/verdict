defmodule JsonRules.Engine do
  @moduledoc """
  The public rules engine.

  An engine bundles a **store** (where rules and facts live) with the pure
  `JsonRules.Evaluator`. The store backend is selected at construction time so
  overhead scales with the workload; evaluation is independent of the store.

  ## Example

      engine =
        JsonRules.Engine.new()
        |> JsonRules.Engine.add_fact("gameDuration", 40)
        |> JsonRules.Engine.add_fact("personalFoulCount", 6)

      {:ok, engine, _rule} =
        JsonRules.Engine.add_rule(engine, %{
          name: "fouled-out",
          event: %{type: "fouledOut", params: %{message: "Player has fouled out!"}},
          conditions: %{
            all: [
              %{fact: "gameDuration", operator: "equal", value: 40},
              %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 5}
            ]
          }
        })

      %JsonRules.RunResult{events: [event]} = JsonRules.Engine.run(engine, %{})
      event.type
      #=> "fouledOut"

  ## Store backends

    * `:pure` (default, MVP) – a plain struct, no process.
    * `:genserver` / `:ets` (Phase 2) – a stateful GenServer, optionally ETS-backed.

  ## Scheduling

    * `:serial` (default, MVP) – priority buckets run one at a time.
    * `:parallel` (Phase 2) – items within a priority bucket run concurrently.
  """
  alias JsonRules.{Evaluator, Rule, Store.Pure}

  @type t :: %__MODULE__{store_module: module(), store: term()}

  defstruct [:store_module, :store]

  @doc """
  Creates a new engine.

  ## Options

    * `:store` – `:pure` (default), `:genserver` or `:ets` (Phase 2).
    * `:schedule` – `:serial` (default) or `:parallel` (Phase 2).
    * `:allow_undefined_facts` – default `false`. When `true`, an undefined
      fact evaluates to `nil` instead of raising.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    store = Keyword.get(opts, :store, :pure)

    options = [
      schedule: Keyword.get(opts, :schedule, :serial),
      allow_undefined_facts: Keyword.get(opts, :allow_undefined_facts, false)
    ]

    {store_module, handle} = init_store(store, options)
    %__MODULE__{store_module: store_module, store: handle}
  end

  defp init_store(:pure, options) do
    {Pure, Pure.init(options)}
  end

  defp init_store(:genserver, _options) do
    raise ArgumentError, "the :genserver store is not available yet (Phase 2)"
  end

  defp init_store(:ets, _options) do
    raise ArgumentError, "the :ets store is not available yet (Phase 2)"
  end

  defp init_store(other, _options) do
    raise ArgumentError, "unknown store backend: #{inspect(other)}"
  end

  @doc """
  Validates and adds a rule.

  `attrs` may use string or atom keys. Returns `{:ok, engine, rule}` on success
  or `{:error, changeset}` if validation fails.

  ## Examples

      iex> engine = JsonRules.Engine.new()
      iex> {:ok, _engine, rule} = JsonRules.Engine.add_rule(engine, %{
      ...>   event: %{type: "ok"},
      ...>   conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
      ...> })
      iex> rule.event.type
      "ok"
  """
  @spec add_rule(t(), map()) :: {:ok, t(), Rule.t()} | {:error, Ecto.Changeset.t()}
  def add_rule(%__MODULE__{} = engine, attrs) do
    case Rule.changeset(%Rule{}, attrs) do
      %Ecto.Changeset{valid?: true} = changeset ->
        rule = Ecto.Changeset.apply_changes(changeset)
        {store, rule} = engine.store_module.add_rule(engine.store, rule)
        {:ok, %{engine | store: store}, rule}

      %Ecto.Changeset{} = changeset ->
        {:error, changeset}
    end
  end

  @doc """
  Removes a rule by its id or by name (removes all rules with that name).

  Returns `{engine, removed?}`.
  """
  @spec remove_rule(t(), String.t() | atom()) :: {t(), boolean()}
  def remove_rule(%__MODULE__{} = engine, key) do
    {store, removed} = engine.store_module.remove_rule(engine.store, key)
    {%{engine | store: store}, removed}
  end

  @doc """
  Registers a fact.

  A fact is either a constant (any term) or a function of `(params, almanac)`
  (or `(params)`) that computes its value. Facts are cached per run.
  """
  @spec add_fact(t(), String.t(), term()) :: t()
  def add_fact(%__MODULE__{} = engine, id, definition) when is_binary(id) do
    %{engine | store: engine.store_module.add_fact(engine.store, id, definition)}
  end

  @doc "Unregisters a fact."
  @spec remove_fact(t(), String.t()) :: t()
  def remove_fact(%__MODULE__{} = engine, id) when is_binary(id) do
    %{engine | store: engine.store_module.remove_fact(engine.store, id)}
  end

  @doc """
  Runs the engine.

  `runtime_facts` are facts available for this run only (they override
  registered facts of the same name for the duration of the run). `opts` may
  include `:allow_undefined_facts`.

  Returns a `JsonRules.RunResult` with the successful and failed events and
  results.
  """
  @spec run(t(), map(), keyword()) :: JsonRules.RunResult.t()
  def run(%__MODULE__{} = engine, runtime_facts \\ %{}, opts \\ []) do
    {_, rules} = engine.store_module.rules(engine.store)
    {_, defs} = engine.store_module.facts(engine.store)
    {_, store_opts} = engine.store_module.options(engine.store)
    merged = Keyword.merge(store_opts, opts)
    Evaluator.run(rules, defs, runtime_facts, merged)
  end
end
