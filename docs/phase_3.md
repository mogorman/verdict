# Phase 3 — events, callbacks, and run control

Phase 3 makes the engine **interactive**: rules can emit events that handlers
observe, handlers can influence the run (add facts, stop it), and rules can be
ordered by the *fact* priority as well as by an explicit condition priority. It
also adds per-fact caching control, fact-reference resolution in event params,
and clearer error propagation.

The evaluation core (`Verdict.Evaluation`) stays pure and unchanged. What
changed is the **run loop** (`Verdict.Evaluator`): it is now a stateful,
priority-ordered fold over the rules, carrying a per-run `Almanac` that handlers
can read and mutate. The Almanac itself was moved off ETS onto a process-local
state record (see [architecture](./architecture.md)).

## What this phase delivers

- **Event callbacks** — `Engine.on/3` (engine-level, keyed by event type) and
  `Engine.on_rule/4` (per-rule, keyed by rule id).
- **`Almanac.stop/1`** — halt the run after the current rule.
- **Runtime facts** — `Almanac.add_runtime_fact/3`, so a handler can feed a value
  to later rules.
- **Fact priority** — order a rule's leaf conditions by each fact's registered
  `priority`.
- **`cache: false`** — opt a dynamic fact out of the per-run cache.
- **`replace_facts_in_event_params`** — resolve `%{fact: …}` references in an
  event's `params`.
- **`RuleResult`** — a first-class per-rule outcome (rule + report + event +
  `valid?`) handed to callbacks and collected into `RunResult.results`.
- **Error propagation** — an error raised inside a fact is surfaced out of
  `run/3`.

## Event callbacks

Register a callback with `Engine.on/3`. The `event_type` is `"success"`,
`"failure"`, or the specific `type` of a rule's event. The callback is a 3-arity
function `fn first, almanac, rule_result`:

- for `"success"` / `"failure"`, `first` is the rule's full `event`;
- for a specific event type (fired only when that rule succeeds), `first` is the
  event's `params`;
- `rule_result` is a `Verdict.RuleResult`.

Callbacks run **between rules**, after each rule is evaluated. A successful rule
fires `"success"` and then its own event type; a failed rule fires only
`"failure"`.

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("age", 21)
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
    event: %{type: "setDrinkingFlag", params: %{canOrderDrinks: true}},
    priority: 100
  })
  |> Verdict.Engine.on("success", fn event, _almanac, _rr ->
    IO.inspect(event.type)  # "setDrinkingFlag"
  end)
  |> Verdict.Engine.on("setDrinkingFlag", fn params, _almanac, _rr ->
    IO.inspect(params)  # %{canOrderDrinks: true}
  end)
```

### Rule-level callbacks

`Engine.on_rule/4` registers a callback for a *specific* rule, keyed by its `id`
(the value `Engine.add_rule/2` returns). It fires in addition to any
engine-level callbacks, but only for that rule:

```elixir
{:ok, engine, rule} =
  Verdict.Engine.add_rule(engine, %{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
    event: %{type: "r1"},
    priority: 100
  })

engine =
  Verdict.Engine.on_rule(engine, rule.id, "success", fn event, _a, _rr ->
    IO.inspect(event.type)  # fires only when rule fires
  end)
```

## Stopping the run

A callback can call `Almanac.stop/1` to halt the run: no further rules are
evaluated and no further events are emitted. In the default `:serial` engine the
stop takes effect before the *next* rule, so the current rule (and its event)
still complete:

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("age", 20)
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
    event: %{type: "adult"},
    priority: 100
  })
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "segment", operator: "equal", value: "human"}]},
    event: %{type: "human"}
  })
  |> Verdict.Engine.on("success", fn _event, almanac, _rr ->
    Verdict.Almanac.stop(almanac)
  end)

%Verdict.RunResult{events: [event]} = Verdict.Engine.run(engine)
event.type #=> "adult"  # the second rule was skipped
```

## Runtime facts

A callback can register a constant fact mid-run with
`Almanac.add_runtime_fact/3`; later rules (and facts) in the same run read it.
This is how one rule's outcome can seed the next:

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("age", 21)
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
    event: %{type: "setDrinkingFlag", params: %{canOrderDrinks: true}},
    priority: 100
  })
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "canOrderDrinks", operator: "equal", value: true}]},
    event: %{type: "offerDrink", params: %{wine: "merlot", quantity: 2}},
    priority: 1
  })
  |> Verdict.Engine.on("success", fn event, almanac, _rr ->
    if event.type == "setDrinkingFlag" do
      Verdict.Almanac.add_runtime_fact(almanac, "canOrderDrinks", event.params[:canOrderDrinks])
    end
  end)

%Verdict.RunResult{events: events} = Verdict.Engine.run(engine)
Enum.map(events, & &1.type) #=> ["setDrinkingFlag", "offerDrink"]
```

## Fact priority

Each registered fact may carry a `priority` (default `1`). When a rule's
`all`/`any` conditions are leaves without an explicit condition `priority`, they
are evaluated in **fact-priority order** (highest first), which can reorder the
conditions relative to their declaration order. Short-circuiting then happens in
that order, so a high-priority fact that fails an `all` (or passes an `any`)
decides the rule without touching the lower-priority facts:

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("a", fn _p, _a -> false end, priority: 100)
  |> Verdict.Engine.add_fact("b", fn _p, _a -> true end, priority: 50)
  |> Verdict.Engine.add_fact("c", fn _p, _a -> true end, priority: 1)
  |> Verdict.Engine.add_rule(%{
    # declared c, a, b — but a (priority 100) is evaluated first
    conditions: %{
      all: [
        %{fact: "c", operator: "equal", value: true},
        %{fact: "a", operator: "equal", value: true},
        %{fact: "b", operator: "equal", value: true}
      ]
    },
    event: %{type: "none"}
  })

Verdict.Engine.run(engine) #=> %RunResult{events: []}
# a is evaluated first and fails, so b and c are never evaluated
```

A leaf's effective priority is: its explicit condition `priority` if present,
else its fact's registered priority, else `1`. Boolean nodes (`all`/`any`/`not`)
and references default to `1`.

### `cache: false`

Dynamic facts are cached per run by default (computed once no matter how many
conditions or facts read them). Pass `cache: false` when registering a fact to
recompute it on every reference:

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("age", fn _p, _a -> 22 end, cache: false)

# every reference to "age" runs the definition again
```

## `replace_facts_in_event_params`

By default an event's `params` are emitted as written. When the engine is
configured with `replace_facts_in_event_params: true`, any top-level `params`
value that is a fact reference (`%{fact: …}`, optionally with `params`/`path`) is
resolved to its computed value before the event is emitted or stored in the
`RuleResult`:

```elixir
engine =
  Verdict.Engine.new(replace_facts_in_event_params: true)
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "success", operator: "equal", value: true}]},
    event: %{type: "countedEnough", params: %{count: %{fact: "count"}}},
    priority: 100
  })

%Verdict.RunResult{results: [rr]} = Verdict.Engine.run(engine, %{success: true, count: 5})
rr.event.params #=> %{count: 5}
```

## Errors

A fact is computed on first reference, inside `run/3`. If the definition raises,
the error is **not** swallowed — it propagates out of `Engine.run/3`:

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("age", fn _p, _a -> raise "problem occurred" end)
  |> Verdict.Engine.add_rule(%{
    conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
    event: %{type: "generic"}
  })

Verdict.Engine.run(engine)
# ** (RuntimeError) problem occurred
```

## Engine options

The Phase 3 option (set on `Engine.new/1`):

| Option                        | Default | Effect                                                  |
| ----------------------------- | ------- | ------------------------------------------------------- |
| `replace_facts_in_event_params` | `false` | resolve `%{fact: …}` refs in an event's `params`       |

## Where this fits

Phase 3 layers run control and events on the [Phase 1](./phase_1.md) /
[Phase 2](./phase_2.md) core — same pure evaluator, operators, and changeset
report. [Phase 4](./phase_4.md) adds `:parallel` scheduling and the pluggable
store backends. The remaining work is full JSON round-tripping.
