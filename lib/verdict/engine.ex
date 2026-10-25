defmodule Verdict.Engine do
  @moduledoc """
  The public rules engine.

  An engine bundles a **store** (where rules and facts live) with the pure
  `Verdict.Evaluator`. The store backend is selected at construction time so
  overhead scales with the workload; evaluation is independent of the store.

  ## Example

      engine =
        Verdict.Engine.new()
        |> Verdict.Engine.add_fact("gameDuration", 40)
        |> Verdict.Engine.add_fact("personalFoulCount", 6)

      {:ok, engine, _rule} =
        Verdict.Engine.add_rule(engine, %{
          name: "fouled-out",
          event: %{type: "fouledOut", params: %{message: "Player has fouled out!"}},
          conditions: %{
            all: [
              %{fact: "gameDuration", operator: "equal", value: 40},
              %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 5}
            ]
          }
        })

      %Verdict.RunResult{events: [event]} = Verdict.Engine.run(engine, %{})
      event.type
      #=> "fouledOut"

  ## Store backends

    * `:pure` (default) – a plain struct, no process.
    * `:genserver` – a stateful store in a GenServer's process state.
    * `:ets` – a GenServer with rules/facts in public ETS tables.

  ## Scheduling

    * `:serial` (default) – priority buckets run one at a time.
    * `:parallel` – items within a priority bucket run concurrently.

  ## Report modes

  The `:report` option (on `new/1` or per run via `run/3`) selects how much of
  the per-condition report is built. The rule outcome, `events` and
  `failure_events` are the same in every mode; only the detail carried on each
  `RuleResult.changeset` differs:

    * `:full` (default) – the complete report: the passing and failing
      conditions (with explanations), the computed facts, and any leaves
      short-circuited before they were reached.
    * `:result_only` – just each rule's boolean outcome. No conditions, facts
      or explanations are built (each `RuleResult.changeset` is `nil`), so this
      is the fastest mode. Use it when you only need to know which rules fired.
    * `:failures_only` – the failing conditions (with explanations) only; the
      passing conditions are dropped. Faster than `:full` in proportion to how
      many conditions pass.

  ## Event callbacks

  `on/3` registers a callback for the event `"success"`, `"failure"`, or a
  specific event `type`; `on_rule/4` registers one for a single rule, keyed by
  its `id`. A callback is `fn first, almanac, rule_result`: for `"success"` /
  `"failure"` `first` is the rule's full `event`; for a specific type (fired only
  when that rule succeeds) it is the event's `params`. Callbacks run between
  rules, after each rule is evaluated — a successful rule fires `"success"` and
  then its own event type; a failed rule fires only `"failure"`.

  ## Run control

  A callback receives the per-run `Verdict.Almanac` and can steer the run:

    * `Verdict.Almanac.add_runtime_fact/3` — register a constant fact that later
      rules (and facts) in the same run read, so one rule's outcome can seed the
      next;
    * `Verdict.Almanac.stop/1` — halt the run: no further rules are evaluated and
      no further events are emitted (before the next rule in `:serial`).

  An error raised inside a fact's definition is not swallowed — it propagates
  out of `run/3`.

  ## Sharing a pre-started store

  Start a backend yourself (e.g. under a supervisor) and wrap it with
  `new(store: {module, handle})`; the engine reuses it without re-creating it —
  see `Verdict.Store` for the backends and how to write your own.
  """
  alias Verdict.{Evaluator, Fact, Log, Rule, Store.Pure, Template, Types}
  alias Verdict.Store.Ets, as: EtsStore
  alias Verdict.Store.GenServer, as: GenServerStore

  @type t :: %__MODULE__{
          store_module: module(),
          store: term(),
          options: keyword(),
          events: %{String.t() => [term()]},
          rule_events: %{String.t() => %{String.t() => [term()]}}
        }

  @type store_backend :: :pure | :genserver | :ets | {module(), term()}
  @type schedule :: :serial | :parallel

  # Engine options. Elixir cannot precisely type an *optional* keyword list, so
  # this stays `keyword()`; the recognized keys and defaults are documented on
  # `new/1` and `run/3`.
  @type opts :: keyword()

  defstruct [:store_module, :store, :options, events: %{}, rule_events: %{}]

  @doc """
  Creates a new engine.

  ## Options

   * `:store` – a `t:store_backend/0`: `:pure` (default), `:genserver` or
     `:ets`; or a `{module, handle}` tuple wrapping an already-created
     `Verdict.Store` backend (see its moduledoc for how to implement one).
   * `:store_options` – a keyword list of backend-specific options passed to the
     store's `create/1` (e.g. a GenServer name). Ignored by `:pure`.
    * `:schedule` – a `t:schedule/0`: `:serial` (default) or `:parallel`.
    * `:parallel_concurrency` – default `System.schedulers_online()`. The cap on
      how many rules within a `:parallel` bucket run at once (ignored by
      `:serial`).
   * `:allow_undefined_facts` – default `false`. When `true`, an undefined
     fact evaluates to `nil` instead of raising.
    * `:strict` – default `false`. When `false` (the default) a rule's
      `all`/`any` conditions **short-circuit** (skipped leaves land in
      `data.empty_values`); when `true` every condition is evaluated.
    * `:report` – default `:full`. How much of the per-condition report to
      build: `:full` builds the complete report (passing and failing conditions
      with explanations, the computed facts, and short-circuited leaves);
      `:result_only` returns just each rule's boolean outcome, with no
      conditions, facts or explanations (the fastest); `:failures_only` keeps
      only the failing conditions (with explanations) and drops the passing
      ones, so it is faster than `:full` in proportion to how many conditions
      pass. Overridable per run via `run/3`.
    * `:allow_undefined_conditions` – default `false`. When `true`, a
      condition reference that was never registered evaluates to false instead
      of raising.
     * `:path_resolver` – a `(value, path) -> term()` used to resolve a
       condition's `path`. When omitted, the engine's default (JSONPath)
       resolver is used.
      * `:replace_facts_in_event_params` – default `false`. When `true`, a
        top-level event `params` value that is a fact reference (`%{fact: …}`,
        optionally with `params` / `path`) is resolved to its computed value
        before the event is emitted.
      * `:allow_unsafe_eex` – default `false` (falling back to the application
        config `config :verdict, :allow_unsafe_eex, value`). An event `params`
        value shaped `%{eex_string: "…"}` is rendered as an EEx template at run
        time (see `Verdict.Template`). When `true`, such a template may use EEx
        control flow (`<% if %>`, `<% for %>`, `<% … do %>`); when `false` only
        `<%= expr %>` interpolation is allowed and a control-flow template
        raises.
      * `:log` – a logging threshold: `nil` (default, off), `:debug`, `:info`,
      `:warning`, or `:error`. When set, each step of a run is emitted via
      `Logger`. Falls back to the application config
      (`config :verdict, :log, level`) when not set, and may be
      overridden per run via `run/3`.

      Each of these may be overridden per run via `run/3` (where applicable).
  """
  @spec new(opts()) :: t()
  def new(opts \\ []) do
    store_spec = Keyword.get(opts, :store, :pure)
    store_options = Keyword.get(opts, :store_options, [])

    options =
      [
        schedule: Keyword.get(opts, :schedule, :serial),
        allow_undefined_facts: Keyword.get(opts, :allow_undefined_facts, false),
        allow_undefined_conditions: Keyword.get(opts, :allow_undefined_conditions, false),
        path_resolver: Keyword.get(opts, :path_resolver),
        strict: Keyword.get(opts, :strict, false),
        report: validate_report!(Keyword.get(opts, :report, :full)),
        replace_facts_in_event_params: Keyword.get(opts, :replace_facts_in_event_params, false),
        allow_unsafe_eex:
          Keyword.get(
            opts,
            :allow_unsafe_eex,
            Application.get_env(:verdict, :allow_unsafe_eex, false)
          )
      ] ++ log_option(opts)

    {store_module, handle} = init_store(store_spec, store_options)
    %__MODULE__{store_module: store_module, store: handle, options: options}
  end

  # `:log` is stored on the engine only when explicitly given, so `run/3` can tell
  # "set on the engine" apart from "fall through to the application config".
  defp log_option(opts) do
    if Keyword.has_key?(opts, :log) do
      level = Keyword.fetch!(opts, :log)
      Log.validate!(level)
      [log: level]
    else
      []
    end
  end

  @valid_reports [:full, :result_only, :failures_only]

  # Raises `ArgumentError` when `report` is not a recognized report mode, else
  # returns it unchanged (validate-then-bind).
  defp validate_report!(report) do
    unless report in @valid_reports do
      raise ArgumentError,
            "invalid report #{inspect(report)}; expected :full, :result_only or :failures_only"
    end

    report
  end

  # A `{module, handle}` tuple wraps an already-created store. See the
  # `Verdict.Store` behaviour for how to implement a backend.
  defp init_store({module, handle}, _options) when is_atom(module), do: {module, handle}

  defp init_store(:pure, options) do
    {Pure, Pure.create(options)}
  end

  defp init_store(:genserver, options) do
    {GenServerStore, GenServerStore.create(options)}
  end

  defp init_store(:ets, options) do
    {EtsStore, EtsStore.create(options)}
  end

  defp init_store(other, _options) do
    raise ArgumentError, "unknown store backend: #{inspect(other)}"
  end

  @doc """
  Validates and adds a rule.

  `attrs` may use string or atom keys. Returns `{:ok, engine, rule}` on success
  or `{:error, changeset}` if validation fails.

  ## Examples

      iex> engine = Verdict.Engine.new()
      iex> {:ok, _engine, rule} = Verdict.Engine.add_rule(engine, %{
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

        case Template.validate(rule.event.params) do
          :ok ->
            {store, rule} = engine.store_module.add_rule(engine.store, rule)
            {:ok, %{engine | store: store}, rule}

          {:error, messages} ->
            invalid = Enum.reduce(messages, changeset, &add_template_error/2)
            {:error, invalid}
        end

      %Ecto.Changeset{} = changeset ->
        {:error, changeset}
    end
  end

  # Attaches one `eex_string` template-validation error to the changeset.
  @spec add_template_error(String.t(), Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp add_template_error(message, changeset),
    do: Ecto.Changeset.add_error(changeset, :event, message)

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
  Returns the engine's rules as JSON-compatible maps.

  Each rule is serialized with `Verdict.Rule.to_map/1`. Rules are returned in
  descending `priority` order (ties broken by `name`), matching the order the
  evaluator runs them.
  """
  @spec rules_as_map(t()) :: [map()]
  def rules_as_map(%__MODULE__{} = engine) do
    {_, rules} = engine.store_module.rules(engine.store)

    rules
    |> Enum.sort_by(fn rule -> {-rule.priority, rule.name || ""} end)
    |> Enum.map(&Rule.to_map/1)
  end

  @doc """
  Registers a fact.

  A fact is either a constant (any term) or a function of `(params, almanac)`
  (or `(params)`) that computes its value. Dynamic facts are cached per run by
  default; pass `cache: false` to recompute them on every reference.

  ## Options

  * `:cache` – default `true`. When `false`, a dynamic fact is never cached.
  * `:priority` – default `1`. Used to order a rule's conditions by fact
    priority during evaluation.
  """
  @spec add_fact(t(), String.t(), term(), keyword()) :: t()
  def add_fact(%__MODULE__{} = engine, id, definition, opts \\ []) when is_binary(id) do
    fact = Fact.new(id, definition, opts)
    %{engine | store: engine.store_module.add_fact(engine.store, fact)}
  end

  @doc "Unregisters a fact."
  @spec remove_fact(t(), String.t()) :: t()
  def remove_fact(%__MODULE__{} = engine, id) when is_binary(id) do
    %{engine | store: engine.store_module.remove_fact(engine.store, id)}
  end

  @doc """
  Registers a custom operator.

  `fun` is a 2- or 3-arity function — `(fact_value, json_value)` or
  `(fact_value, json_value, params)` — that returns a boolean, or a
  `{passed?, explanation}` tuple to supply a custom explanation. A custom
  operator takes precedence over a built-in of the same name while the engine is
  in use.

  Custom operators (and decorators) can be combined into a composite operator
  name using `:` — see `Verdict.Operators.resolve/4`.
  """
  @spec add_operator(t(), String.t(), term()) :: t()
  def add_operator(%__MODULE__{} = engine, name, fun) when is_binary(name) do
    %{engine | store: engine.store_module.add_operator(engine.store, name, fun)}
  end

  @doc "Unregisters an operator."
  @spec remove_operator(t(), String.t()) :: t()
  def remove_operator(%__MODULE__{} = engine, name) when is_binary(name) do
    %{engine | store: engine.store_module.remove_operator(engine.store, name)}
  end

  @doc """
  Registers a custom operator decorator.

  `fun` has the arity `(fact_value, json_value, next) -> boolean`, where `next`
  is the wrapped operator. Decorators are applied to an operator via a
  composite name, e.g. `\"myDecorator:contains\"`.
  """
  @spec add_operator_decorator(t(), String.t(), term()) :: t()
  def add_operator_decorator(%__MODULE__{} = engine, name, fun) when is_binary(name) do
    %{engine | store: engine.store_module.add_decorator(engine.store, name, fun)}
  end

  @doc "Unregisters an operator decorator."
  @spec remove_operator_decorator(t(), String.t()) :: t()
  def remove_operator_decorator(%__MODULE__{} = engine, name) when is_binary(name) do
    %{engine | store: engine.store_module.remove_decorator(engine.store, name)}
  end

  @doc """
  Registers a named, reusable condition.

  `condition` is a JSON-shaped condition map (string or atom keys) whose root
  must be `all`, `any`, `not`, a `condition` reference, or a leaf. Returns
  `{:ok, engine}` on success or `{:error, [message: _]}` if the structure is
  invalid.
  """
  @spec set_condition(t(), String.t(), map()) :: {:ok, t()} | {:error, keyword()}
  def set_condition(%__MODULE__{} = engine, name, condition) when is_binary(name) do
    case Types.Condition.from_map(condition) do
      {:ok, tree} ->
        store = engine.store_module.add_condition(engine.store, name, tree)
        {:ok, %{engine | store: store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Removes a named condition. Returns `{engine, removed?}`."
  @spec remove_condition(t(), String.t()) :: {t(), boolean()}
  def remove_condition(%__MODULE__{} = engine, name) when is_binary(name) do
    {store, removed} = engine.store_module.remove_condition(engine.store, name)
    {%{engine | store: store}, removed}
  end

  @doc """
  Registers an event callback.

  `event_type` is `"success"`, `"failure"`, or the specific `type` of a rule's
  event. The `callback` is a 3-arity function `fn first, almanac, rule_result`:

    * for `"success"` / `"failure"`, `first` is the rule's full `event`;
    * for a specific event type (fired only when that rule succeeds), `first`
      is the event's `params`.

  `rule_result` is a `Verdict.RuleResult`. Callbacks run between rules, so they
  may call `Verdict.Almanac.stop/1` to halt the run or
  `Verdict.Almanac.add_runtime_fact/3` to feed a value to later rules.

  Returns the engine (pipeable).
  """
  @spec on(
          t(),
          String.t() | atom(),
          (term(), Verdict.Almanac.t(), Verdict.RuleResult.t() -> term())
        ) :: t()
  def on(%__MODULE__{} = engine, event_type, callback) when is_function(callback, 3) do
    type = to_string(event_type)
    %{engine | events: Map.update(engine.events, type, [callback], &(&1 ++ [callback]))}
  end

  @doc """
  Registers a callback for a *specific* rule, keyed by its `id` (the value
  `Verdict.Engine.add_rule/2` returns). The `callback` has the same shape as
  `on/3`'s and fires only for that rule, in addition to any engine-level
  callbacks. Returns the engine (pipeable).
  """
  @spec on_rule(
          t(),
          String.t(),
          String.t() | atom(),
          (term(), Verdict.Almanac.t(), Verdict.RuleResult.t() -> term())
        ) :: t()
  def on_rule(%__MODULE__{} = engine, rule_id, event_type, callback)
      when is_binary(rule_id) and is_function(callback, 3) do
    type = to_string(event_type)

    rule_events =
      Map.update(engine.rule_events, rule_id, %{type => [callback]}, fn inner ->
        Map.update(inner, type, [callback], &(&1 ++ [callback]))
      end)

    %{engine | rule_events: rule_events}
  end

  @doc """
  Runs the engine.

  `runtime_facts` are facts available for this run only (they override
  registered facts of the same name for the duration of the run). `opts` may
  override any engine option for this run — e.g. `:schedule`, `:strict`,
  `:report`, `:allow_undefined_facts` or `:log` (a per-run value wins over the
  engine default).

  Returns a `Verdict.RunResult` whose `results` is a list of
  `Verdict.RuleResult` (in priority order) and whose `events` /
  `failure_events` are the events of the valid / invalid rules.
  """
  @spec run(t(), Verdict.Almanac.fact_map(), opts()) :: Verdict.RunResult.t()
  def run(%__MODULE__{} = engine, runtime_facts \\ %{}, opts \\ []) do
    {_, rules} = engine.store_module.rules(engine.store)
    {_, defs} = engine.store_module.facts(engine.store)
    {_, operators} = engine.store_module.operators(engine.store)
    {_, decorators} = engine.store_module.decorators(engine.store)
    {_, conditions} = engine.store_module.conditions(engine.store)

    merged =
      engine.options
      |> Keyword.merge(opts)
      |> Keyword.put(:log, resolve_log(engine.options, opts))
      |> Keyword.put(:operators, operators)
      |> Keyword.put(:decorators, decorators)
      |> Keyword.put(:conditions, conditions)
      |> Keyword.put(:callbacks, engine.events)
      |> Keyword.put(:rule_callbacks, engine.rule_events)

    validate_report!(Keyword.get(merged, :report, :full))
    Evaluator.run(rules, defs, runtime_facts, merged)
  end

  # The effective log level for a run: a per-run `:log`, else a per-engine `:log`,
  # else the application config (`config :verdict, :log, level`), else off.
  # An explicit `:log` at any tier (including `nil`) wins over the tiers below it.
  defp resolve_log(engine_options, run_opts) do
    level =
      case Keyword.fetch(run_opts, :log) do
        {:ok, level} -> level
        :error -> Keyword.get(engine_options, :log, Application.get_env(:verdict, :log))
      end

    Log.validate!(level)
    level
  end
end
