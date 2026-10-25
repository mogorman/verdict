# Architecture and data types

`Verdict` is built from a small number of orthogonal pieces: a typed data model
(`Rule`, `Event`, `Condition`), a pluggable **store** that holds it, a pure
**evaluator** that turns a condition tree into a `Ecto.Changeset` report, and a
thin **engine** that glues the two together. This reference describes each data
type and how a run flows through them.

## The pieces at a glance

| Type                         | Kind                | Role                                                    |
| ---------------------------- | ------------------- | ------------------------------------------------------- |
| `Verdict.Engine`           | struct              | the public API; bundles a store with the evaluator      |
| `Verdict.Rule`             | Ecto schema         | a condition tree + a single event, plus `priority`/`extra` |
| `Verdict.Event`            | Ecto embedded schema| the thing a rule emits (`type` + `params`)              |
| `Verdict.Condition`        | struct (tree)       | one node of the condition tree                          |
| `Verdict.Types.Condition`  | `Ecto.Type`         | casts/dumps a condition tree to/from a JSON-shaped map  |
| `Verdict.Fact`             | struct              | a registered fact (constant or function) + `cache`/`priority` |
| `Ecto.Changeset`             | struct              | the **evaluation report** for a single rule             |
| `Verdict.RuleResult`       | struct              | one rule's outcome: rule + report + event + `valid?`    |
| `Verdict.RunResult`        | struct              | the outcome of a run (events + per-rule reports)        |
| `Verdict.Almanac`          | struct              | the per-run fact store, cache, and run state            |
| `Verdict.Almanac.ProcessLocal` | almanac backend   | the process-local almanac (used by `:serial`)           |
| `Verdict.Almanac.Shared`   | almanac backend     | a per-run GenServer almanac, shared by `:parallel`      |
| `Verdict.EvaluationContext`| struct              | everything `Evaluation` needs for one run               |
| `Verdict.Store`            | behaviour           | the pluggable store contract                            |
| `Verdict.Store.State`      | struct (internal)   | the shared state + pure fns behind the built-in backends |
| `Verdict.Store.Pure`       | store               | the default backend (a plain `State` struct)            |
| `Verdict.Store.GenServer`  | store               | a process-backed store (the stateful default)           |
| `Verdict.Store.Ets`        | store               | an ETS-backed store (rules/facts in ETS tables)         |
| `Verdict.Operators`        | module              | built-in operators, decorators and composite resolution |
| `Verdict.Log`              | module              | optional, level-gated logging (the `:log` threshold)    |
| `Verdict.UndefinedFactError`| exception          | raised when a missing fact is not allowed               |

## The data types

### `Verdict.Rule`

An `Ecto.Schema` (no repo, no table) — the unit the engine stores and evaluates.
It is produced by `Rule.changeset/2` from JSON-shaped attributes and serialized back
out with `Rule.to_map/1`, the inverse of the cast for well-formed rules.
`Verdict.Engine.rules_as_map/1` serializes an engine's whole rule set (in
descending priority order).

| Field         | Type                              | Notes                                        |
| ------------- | --------------------------------- | -------------------------------------------- |
| `id`          | `String.t() \| nil`               | a UUID, generated client-side on add         |
| `name`        | `String.t() \| nil`               | optional identifier                          |
| `priority`    | `integer()` (default `1`)         | higher runs first; must be `> 0`             |
| `extra`       | `map()` (default `%{}`)           | arbitrary custom properties                  |
| `event`       | `Verdict.Event.t() \| nil`      | optional; emitted when the rule fires        |
| `failure_event` | `Verdict.Event.t() \| nil`    | optional; emitted when the rule does not fire |
| `conditions`  | `Verdict.Condition.t()`         | required; root is `all`/`any`/`not`/`ref`    |
| `inserted_at`/`updated_at` | `NaiveDateTime.t() \| nil` | present but always `nil` (no repo)          |

### `Verdict.Event`

An embedded `Ecto.Schema` — what a rule emits. It is a *success* when the rule's
conditions are truthy, a *failure* otherwise.

| Field    | Type                  | Notes            |
| -------- | --------------------- | ---------------- |
| `type`   | `String.t() \| nil`   | required         |
| `params` | `map()` (default `%{}`)| arbitrary data |

### `Verdict.Condition`

A recursive tree. A node is one of five kinds; most fields are `nil` unless
relevant to the node's kind.

| Field      | Type                              | Used by          |
| ---------- | --------------------------------- | ---------------- |
| `kind`     | `:leaf \| :all \| :any \| :not \| :ref` | all          |
| `children` | `[Condition.t()] \| nil`          | `:all`, `:any`   |
| `child`    | `Condition.t() \| nil`            | `:not`           |
| `ref`      | `String.t() \| nil`               | `:ref`           |
| `fact`     | `String.t() \| nil`               | `:leaf`          |
| `operator` | `String.t() \| nil`               | `:leaf`          |
| `value`    | `term()`                          | `:leaf` (a plain value **or** a `%{fact: …}` reference) |
| `path`     | `String.t() \| nil`               | `:leaf` (a JSONPath into the fact) |
| `params`   | `map() \| nil`                    | `:leaf`          |
| `priority` | `integer() \| nil`                | all (leaves default to their fact's priority; other nodes to `1`) |
| `extra`    | `map()` (default `%{}`)           | all              |

### `Verdict.Types.Condition`

The `Ecto.Type` that turns a JSON-shaped map into the `Condition` tree (and back).
`from_map/1` (used by `cast` and by `Engine.set_condition/3`) validates the
*structure*; `to_map/1` (used by `dump`) serializes it. The type reports as
`:map`, so the tree round-trips through Ecto's map machinery.

### The changeset report (`Ecto.Changeset`)

A rule's conditions are evaluated into a plain `Ecto.Changeset` — the engine's
**evaluation report**. Its shape:

| Member             | Meaning                                                                |
| ------------------ | ---------------------------------------------------------------------- |
| `valid?`           | whether the rule fired                                                 |
| `changes`          | list of `{fact_atom, %{actual:, operator:, value:}}` for conditions that **passed** |
| `errors`           | list of `{fact_atom, {explanation, [operator:, value:, actual: (, negated:)}}}` for conditions that **failed** |
| `data.facts`       | the computed fact values (`%{fact_atom => value}`)                     |
| `data.empty_values`| conditions short-circuited before they were reached                    |

`changes` and `errors` are **lists**, so one fact can appear under several
conditions without overwriting.

### `Verdict.RunResult`

The outcome of one `Engine.run/3`.

| Field            | Type                                  |
| ---------------- | ------------------------------------- |
| `events`         | `[Event.t()]` — events of fired rules that declare one |
| `failure_events` | `[Event.t()]` — failure events of not-fired rules that declare one |
| `results`        | `[RuleResult.t()]` — in priority order |

`RunResult.to_map/1` and `RuleResult.to_map/1` serialize the run (and each rule's
result, including its evaluation report) back to a JSON-compatible map — see
[From JSON back to JSON: the completed result](result_json.md).

### `Verdict.Almanac`

The per-run fact store, cache, and run state. Created at the start of every
`Engine.run/3`, destroyed at the end.

The struct is a lightweight **handle** carrying a `backend` (a module), a
`handle` (that backend's opaque state), and the public `allow_undefined_facts`
flag. The public API (`fact_value/3`, `stop/1`, …) dispatches to the backend.
Both backends hold the same `%{defs: Fact.registry(), cache: map(), stopped:
boolean()}` state, but store it differently:

- **`Almanac.ProcessLocal`** (default) — the state lives in the calling
  process's dictionary under a `make_ref/0` token. Used by `:serial`; a fact
  referenced by several conditions (or facts) is computed once.
- **`Almanac.Shared`** — the state lives in a short-lived per-run GenServer, so it
  is shared across the worker processes of a `:parallel` run. A fact's value is
  computed in the calling worker (only cache lookups round-trip through the
  server), which keeps a fact that depends on other facts from deadlocking.

| Field / function                     | Type / signature                          | Notes |
| ------------------------------------ | ----------------------------------------- | ----- |
| `backend`                            | `module()`                                | `Almanac.ProcessLocal` or `Almanac.Shared` |
| `handle`                             | `term()`                                  | the backend's state (a token, or a pid)    |
| `allow_undefined_facts`              | `boolean()`                               | `true` → a missing fact is `nil`          |
| `new(defs, runtime_facts, opts)`     | `(Fact.registry(), fact_map(), [allow_undefined_facts: boolean(), backend: :process_local \| :shared]) :: t()` | build the almanac (merges `defs` + `runtime_facts`, the latter winning) |
| `fact_value(almanac, fact_id, params)` | `(t(), String.t(), map() \\ %{}) :: term()` | value of `fact_id`, computed + cached on first call (unless `cache: false`) |
| `facts(almanac)`                      | `t() :: [{String.t(), term()}]`           | the `{fact_id, value}` pairs computed so far |
| `add_runtime_fact(almanac, id, value)` | `(t(), String.t() \| atom(), term()) :: t()` | register/overwrite a constant fact mid-run |
| `stop(almanac)`                       | `t() :: t()`                              | halt the run after the current rule       |
| `stopped?(almanac)`                   | `t() :: boolean()`                        | whether `stop/1` has been called          |
| `fact_priority(almanac, fact_id)`     | `(t(), String.t() \| atom()) :: integer()`| a registered fact's priority (default `1`) |
| `destroy(almanac)`                    | `t() :: :ok`                              | drop the run state                        |

`fact_map` is `%{(String.t() \| atom()) => term()}`.

### `Verdict.Fact`

A registered fact — either a **constant** (any term) or **dynamic** (a
`(params, almanac)` / `(params)` function that computes its value). Built from a
definition and options by `Fact.new/3`; the almanac and store hold these.

| Field                | Type                     | Notes |
| -------------------- | ------------------------ | ----- |
| `id`                 | `String.t()`             | the fact's name (normalised to a string) |
| `value`              | `term()`                 | the constant value (dynamic facts leave this `nil`) |
| `calculation_method` | `nil \| (params, almanac -> term()) \| (params -> term())` | set for dynamic facts |
| `cache`              | `boolean()` (default `true`) | `false` → a dynamic fact is recomputed on every reference |
| `priority`           | `integer()` (default `1`) | orders a rule's leaf conditions by fact priority |

A fact's `value` is resolved by `Fact.calculate/3`, which dispatches on arity
(2-arity gets the almanac so it can read other facts; 1-arity gets `params`
only). `is_dynamic?/1` reports whether a `calculation_method` is present.
`Fact.registry()` is `%{String.t() => Fact.t()}`.

### `Verdict.RuleResult`

The outcome of evaluating one rule during a run. It is the third argument every
event callback receives, and the element type of `RunResult.results`.

| Field        | Type                 | Notes |
| ------------ | -------------------- | ----- |
| `rule`       | `Rule.t()`           | the evaluated rule          |
| `changeset`  | `Ecto.Changeset.t()` | the rule's evaluation report |
| `event`      | `Event.t()`          | the event emitted (fact refs in `params` resolved when `replace_facts_in_event_params` is set) |
| `valid?`     | `boolean()`          | whether the rule fired      |

### `Verdict.EvaluationContext`

Bundles everything the pure `Verdict.Evaluation` needs for one run. Built by the
`Evaluator` from the almanac plus the engine's registries and options.

| Field                        | Type                                   |
| ---------------------------- | -------------------------------------- |
| `almanac`                    | `Almanac.t()`                          |
| `operators`                  | `%{String.t() => (a, b -> boolean())}` |
| `decorators`                 | `%{String.t() => (a, b, next -> boolean())}` |
| `conditions`                 | `%{String.t() => Condition.t()}`       |
| `path_resolver`              | `(value, path -> term()) \| nil`       |
| `allow_undefined_conditions` | `boolean()`                            |
| `strict`                     | `boolean()`                            |

### `Verdict.Engine`

The public API. It holds the store backend *module* and its *state* handle, plus
the event-callback registries:

| Field          | Type     | Notes                                          |
| -------------- | -------- | ---------------------------------------------- |
| `store_module` | `module()` | the store backend (e.g. `Store.Pure`)        |
| `store`        | `term()` | the backend's opaque state                     |
| `options`      | `keyword()` | run configuration (`schedule`, `strict`, `allow_undefined_*`, `log`, …) |
| `events`       | `%{String.t() => [callback]}` | engine-level event callbacks (keyed by type) |
| `rule_events`  | `%{rule_id => %{String.t() => [callback]}}` | per-rule event callbacks |

`Engine` is a façade: each `add_*`/`remove_*` validates and forwards to the store
module (rebinding the new state), and `run/3` reads a snapshot of the store and
hands it to the pure `Evaluator`.

Run configuration lives **on the engine**, not in the store. So a store holds only
its rule/fact/operator/decorator/condition registries, and a pre-started store can
be shared across engines and runs. `Engine.new/1` selects the store with `:store`
(`:pure` by default, `:genserver`, `:ets`, or a `{module, handle}` tuple wrapping
an already-created `Verdict.Store` backend) and passes `:store_options` to the
backend's `create/1`.

Event callbacks are registered with `on/3` (engine-level, keyed by event type —
`"success"`, `"failure"`, or a specific event `type`) and `on_rule/4`
(per-rule, keyed by the rule's `id`). Both take a 3-arity callback
`fn first, almanac, rule_result`: for `"success"`/`"failure"` `first` is the full
event; for a specific type (fired only when that rule succeeds) `first` is the
event's `params`. Callbacks run between rules, so they may call
`Almanac.stop/1` or `Almanac.add_runtime_fact/3`.

### `Verdict.Store` (behaviour) and its backends

`Store` is the **pluggable store contract**. A backend holds the rule / fact /
operator / decorator / condition registries. Stateful callbacks return
`{handle, result}`; the `Engine` rebinds the (possibly new) handle — a new struct
for a pure backend, the same pid for a process backend. The callbacks are
`create/1` (build a handle) plus `add_rule`/`remove_rule`/`get_rule`/`rules`,
`add_fact`/`remove_fact`/`facts`, `add_operator`/`remove_operator`/`operators`,
`add_decorator`/`remove_decorator`/`decorators`, and `add_condition`/
`remove_condition`/`conditions`. Run configuration is **not** part of the contract
(it lives on the `Engine`). **Adding a backend is just implementing this
behaviour** — see the `Store` moduledoc for a minimal worked example.

`Store.State` is an internal helper: a plain struct (rules, facts, operators,
decorators, conditions) with the pure transformations the built-in backends share.
Custom backends do not need it.

| Backend                 | State lives in                                   | Pick with |
| ----------------------- | ------------------------------------------------ | --------- |
| `Store.Pure` (default)   | a plain immutable `State` struct (no process)    | `store: :pure`      |
| `Store.GenServer`        | a GenServer's process state                      | `store: :genserver` |
| `Store.Ets`              | a GenServer, with rules/facts in public ETS tables | `store: :ets`    |

A pre-started store (from `Store.GenServer.start_link/1` or `Store.Ets.start_link/1`)
can be shared across engines/runs via `Engine.new(store: {module, name_or_pid})`.

### `Verdict.Operators`

Not a struct — a module of functions. Built-in operators have the shape
`(fact_value, json_value) -> {passed?, explanation}`. Decorators have the shape
`(fact_value, json_value, next) -> boolean` where `next` is the wrapped operator.

A **custom operator** (registered via `Engine.add_operator/3`) is a **2- or
3-arity** function — `(fact_value, json_value)` or `(fact_value, json_value,
params)` — that returns a `boolean()` or a `{passed?, explanation}` tuple. When it
returns a bare boolean, a generic explanation is generated; when it returns a
tuple, that explanation is used verbatim in the report. The 3-arity form receives
the condition's `params` map, which is how an operator can be parameterized by the
condition that uses it.

`resolve/4` turns a name (possibly a `decorator:…:operator` composite, where the
leftmost decorator is outermost) plus the condition's `params` into an operator
function, preferring the engine's custom operators/decorators over the built-ins.

### `Verdict.UndefinedFactError`

Raised by the almanac when a condition needs a fact that was never registered (and
not supplied to `run/3`), unless `allow_undefined_facts` is set.

## How a run flows

```
Engine.run(engine, runtime_facts, opts)
  │  read a snapshot from the store:
  │    rules, facts (defs), options, operators, decorators, conditions
   │  attach the engine's event callbacks (engine.events, engine.rule_events)
   │  resolve the log level (per-run > per-engine > app config; default off)
   ▼
   Evaluator.run(rules, defs, runtime_facts, merged_opts)
   │  1. Almanac.new(…, backend: :process_local | :shared)  (shared for :parallel)
   │  2. build %EvaluationContext{...}  (carries the resolved log level)
  │  3. group rules into priority buckets (highest first)
  │  4. for each bucket (until Almanac.stopped?):
  │        :serial  -> its rules, one at a time in order
  │        :parallel-> its rules concurrently (Task.async_stream,
  │                    bounded by parallel_concurrency)
   │       per rule: Evaluation.eval(rule.conditions, context) -> a pure Ecto.Changeset
   │                 render the outcome's event only (event if fired, failure_event
   │                 if not; fact-refs resolved if replace_facts_in_event_params)
   │                 build a RuleResult, fire engine + per-rule callbacks
   │                 ("success" then type, or "failure")
   │  5. collect: events (fired), failure_events (not-fired), results
  │  6. after: Almanac.destroy(almanac)
  ▼
%RunResult{events: …, failure_events: …, results: [RuleResult]}
```

`Evaluation.eval/2` walks the condition tree recursively:

- a **`leaf`** resolves the fact (and its `path`) through the almanac, resolves the
  `value` (which may itself be a fact reference), applies the operator, and emits a
  passing `change` or a failing `error`;
- **`all`** / **`any`** evaluate their children in priority order (a leaf's
  effective priority is its explicit condition `priority`, else its fact's
  registered `priority`, else `1`) and **short-circuit** as soon as the outcome is
  decided (unless `strict`), collecting the un-evaluated leaves into `empty_values`;
- **`not`** negates its child's report;
- **`ref`** resolves against the engine's named conditions (with a cycle guard).

## Where the purity boundary is

The store and the evaluator never touch each other directly. `Engine.run/3` copies
out an immutable snapshot of the store's contents and passes it to the pure
`Evaluator`, which produces a `RunResult` with no side effects beyond the
run-scoped almanac state (destroyed on the way out) and the invocation of
user-registered event callbacks between rules. That separation is what lets the
store backend be swapped (`:pure`, `:genserver`, `:ets`) and the scheduling be
swapped (`:serial`, `:parallel`) without touching the evaluation logic.
