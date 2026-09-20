# Phase 4 — `:parallel` scheduling and pluggable store backends

Phase 4 completes the two axes of pluggability the design promised:

- **Scheduling** — a `:parallel` engine that evaluates each priority bucket's rules
  concurrently, over a **shared** per-run almanac.
- **Storage** — a clean `JsonRules.Store` **behaviour** as the extension point, with
  three built-in backends (`:pure`, `:genserver`, `:ets`) and support for wrapping
  a pre-started store.

The pure evaluation core (`JsonRules.Evaluation`) is unchanged. What changed is the
**run loop** (`JsonRules.Evaluator`), the **Almanac** (now a thin API over a
backend), and the **store layer** (split into a behaviour, a shared `State`, and the
backends). See [architecture](./architecture.md) for the updated data types.

## What this phase delivers

- **`:parallel` scheduling** — `Engine.new(schedule: :parallel)`; each priority
  bucket's rules run concurrently (bounded by `:parallel_concurrency`).
- **Shared almanac** — `Almanac` is now a handle over a backend: `ProcessLocal`
  (`:serial`) or a per-run GenServer `Shared` (`:parallel`), so workers share the
  fact cache and run state.
- **`Store` behaviour as the extension point** — `create/1` + the registry
  callbacks; run config lives on the `Engine`, not the store.
- **`Store.State`** — the shared in-memory state + pure fns behind the built-ins.
- **`Store.GenServer`** — a process-backed store.
- **`Store.Ets`** — an ETS-backed store (rules/facts in public ETS tables).
- **Wrapping a pre-started store** — `Engine.new(store: {module, handle})`.

## `:parallel` scheduling

Set `schedule: :parallel` on the engine. Rules are still grouped into priority
buckets and the buckets run **one after another** (highest priority first); only the
rules *within* a bucket run concurrently:

```elixir
engine =
  JsonRules.Engine.new(schedule: :parallel)
  |> JsonRules.Engine.add_fact("age", 22)
  |> JsonRules.Engine.add_fact("score", 95)
  |> JsonRules.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
    event: %{type: "adult"},
    priority: 10
  })
  |> JsonRules.Engine.add_rule(%{
    conditions: %{any: [%{fact: "score", operator: "greaterThanInclusive", value: 90}]},
    event: %{type: "high-score"},
    priority: 10  # same bucket as "adult" -> evaluated concurrently
  })

%JsonRules.RunResult{events: events} = JsonRules.Engine.run(engine)
Enum.sort(Enum.map(events, & &1.type)) #=> ["adult", "high-score"]
```

The concurrency of a bucket is bounded by the `:parallel_concurrency` run option
(default `System.schedulers_online()`); pass it per run or set it on the engine:

```elixir
JsonRules.Engine.run(engine, %{}, parallel_concurrency: 4)
```

### The shared almanac

Under `:parallel` the `Evaluator` builds the almanac with the `:shared` backend — a
short-lived GenServer that owns the same `%{defs, cache, stopped}` state the
process-local backend uses. That lets two rules in the same bucket share a fact's
cached value, and lets a callback add a runtime fact or stop the run for the whole
run.

The important detail: a fact's **value is computed in the calling worker**, not in
the server — only the cache lookups and control updates round-trip through the
GenServer. This is what keeps a fact that depends on other facts from deadlocking
(the worker calls back into the server for its dependencies; the server never calls
back).

```elixir
engine =
  JsonRules.Engine.new(schedule: :parallel)
  |> JsonRules.Engine.add_fact("base", fn _p, _a -> %{age: 20} end)
  |> JsonRules.Engine.add_fact("age", fn _p, almanac ->
    Map.fetch!(JsonRules.Almanac.fact_value(almanac, "base"), :age)
  end)
  |> JsonRules.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "lessThanInclusive", value: 25}]},
    event: %{type: "young"}
  })
  |> JsonRules.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
    event: %{type: "adult"}
  })
```

### Semantics that differ from `:serial`

- **Stop granularity** — in `:serial`, `Almanac.stop/1` halts before the next
  *rule*; in `:parallel`, it halts before the next *bucket*. The rules already
  running in the current bucket still complete (they are in flight), matching the
  JS reference's per-bucket `Promise.all`.
- **A fact may compute more than once within a bucket** — the shared cache is a
  best-effort check-then-put across processes, so a fact hit by several rules in
  the *same* bucket can be computed more than once (the value is identical for pure
  facts). `:serial` still guarantees single computation.

## The store layer

`JsonRules.Store` is now a **behaviour** — the single contract a backend
implements. It covers `create/1` plus the rule / fact / operator / decorator /
condition registries. Run configuration (`schedule`, `strict`, …) is **not** part of
the contract; it lives on the `Engine`, which is what lets one pre-started store be
shared across engines and runs.

`JsonRules.Store.State` is the internal helper all built-ins share: a plain struct
holding the five registries with pure transformations. A custom backend does **not**
need it — it only needs to implement the behaviour.

### Choosing a backend

```elixir
JsonRules.Engine.new()                       # :pure (default) — a plain struct
JsonRules.Engine.new(store: :genserver)      # a GenServer holds the state
JsonRules.Engine.new(store: :ets)            # rules/facts in public ETS tables
```

### Sharing a pre-started store

Start a store yourself (e.g. under a supervisor) and wrap it — the engine reuses it
without re-creating it:

```elixir
{:ok, pid} = JsonRules.Store.GenServer.start_link([])
engine = JsonRules.Engine.new(store: {JsonRules.Store.GenServer, pid})

# or, with a named ETS store, so other processes can read the tables directly:
store = JsonRules.Store.Ets.create(table: :my_store)
engine = JsonRules.Engine.new(store: {JsonRules.Store.Ets, store})
:ets.lookup(:"my_store.rules", some_rule_id)
```

### Writing your own backend

Implement the behaviour. The minimal idea (full example in the `JsonRules.Store`
moduledoc):

```elixir
defmodule MyStore do
  use GenServer
  @behaviour JsonRules.Store

  def create(_opts) do
    {:ok, pid} = GenServer.start(__MODULE__, JsonRules.Store.State.new())
    pid
  end

  @impl true
  def add_rule(handle, rule), do: {handle, GenServer.call(handle, {:add_rule, rule})}
  @impl true
  def rules(handle), do: {handle, GenServer.call(handle, :rules)}

  # ... the remaining callbacks, delegating to JsonRules.Store.State ...

  def init(state), do: {:ok, state}
  def handle_call({:add_rule, rule}, _from, state) do
    {state, added} = JsonRules.Store.State.add_rule(state, rule)
    {:reply, added, state}
  end
  def handle_call(:rules, _from, state) do
    {:reply, elem(JsonRules.Store.State.rules(state), 1), state}
  end
end
```

## Engine options

| Option                | Default                   | Effect |
| --------------------- | ------------------------- | ------ |
| `:schedule`           | `:serial`                 | `:parallel` runs each priority bucket concurrently |
| `:parallel_concurrency` | `System.schedulers_online()` | cap on concurrent rules within a `:parallel` bucket |
| `:store`              | `:pure`                   | `:pure`, `:genserver`, `:ets`, or `{module, handle}` |
| `:store_options`      | `[]`                      | backend-specific options passed to `create/1` (e.g. a `:name` / `:table`) |

## Where this fits

Phase 4 layers scheduling and storage on the [Phase 1](./phase_1.md) /
[Phase 2](./phase_2.md) / [Phase 3](./phase_3.md) core — same pure evaluator,
operators, and changeset report. The only remaining work is full JSON round-tripping
of a rule.
