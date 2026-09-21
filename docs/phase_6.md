# Phase 6 — optional logging

This phase adds **opt-in, level-gated logging** to the engine. By default nothing
is emitted; set a log threshold and each step of a run is written through `Logger`,
so it flows into whatever console, formatter, or backend the host application has
configured.

## What this phase delivers

- A `:log` option on `Verdict.Engine.new/1` (per engine) and
  `Verdict.Engine.run/3` (per run), plus a global application-config setting
  (`config :verdict, :log, level`).
- `Verdict.Log` — the level model: a cumulative threshold, the per-run
  resolution, and the lazy emitters the evaluator calls at each step.
- `test/json_rules/log_test.exs` — unit coverage of the gating/resolution and
  integration tests that capture real `Logger` output at each level.

## Enabling it

Logging is off unless a level is set, in any of three places:

```elixir
# per engine (applies to every run of that engine)
engine = Verdict.Engine.new(log: :debug)

# per run (overrides the engine's level for this run only)
Verdict.Engine.run(engine, %{}, log: :info)

# globally, in config/config.exs
config :verdict, :log, :warning
```

### Resolution

The effective level for a run is the first value set, most specific first:

1. the per-run `:log` (an explicit `log: nil` still wins, meaning "off");
2. else the per-engine `:log`;
3. else the application config;
4. else off.

### Levels

The levels are **cumulative** — a run at a given threshold emits every step at that
severity or higher:

| Level     | Emits                                                        |
| --------- | ------------------------------------------------------------ |
| `:debug`  | everything                                                   |
| `:info`   | `:info`, `:warning`, `:error`                                |
| `:warning`| `:warning`, `:error`                                         |
| `:error`  | `:error` only                                                |

`nil` and `:off` are silent. Any other value raises `ArgumentError` at the point it
is read.

## Which step emits at which level

| Step                                                       | Level    |
| ---------------------------------------------------------- | -------- |
| run started (rule count, schedule)                         | `debug`  |
| a named condition reference is resolved                    | `debug`  |
| a leaf condition is evaluated (`fact op value → actual`)   | `debug`  |
| an `all`/`any` combinator's outcome                        | `debug`  |
| a `not` node's outcome                                     | `debug`  |
| a callback fires (event type, rule)                        | `debug`  |
| a rule fired / did not fire                                | `info`   |
| run finished (succeeded / failed counts)                   | `info`   |
| short-circuit skipped `N` condition(s)                     | `warning`|
| the run was stopped (a fact or callback signalled stop)    | `warning`|

The engine has no `:error`-step today — evaluation errors propagate as exceptions
rather than being logged — but `:error` is a valid threshold so a host can cap the
output to the most severe messages.

## Zero cost when off

Each message is emitted with a zero-arity function, so when the level is below the
threshold the message is never built and no `Logger` call is made. A default run
(with no `:log`) is byte-for-byte the same work as before this phase.

The host application's own `:logger` configuration still applies on top: this module
decides *whether* the engine asks `Logger` to emit; `:logger` decides where it goes
and at what console level.

## Example

A run at `:debug` of a single matching rule:

```
[debug] run started: 1 rules, schedule: :serial
[debug] leaf "age" lessThan 45: actual=10 pass
[debug] all of 1: pass
[info]  rule "young" (priority 1): fired
[info]  run finished: 1 succeeded, 0 failed
```

The same run at `:info` omits the `debug` lines; at `:warning` it would emit only
the short-circuit / stop messages, and by default it emits nothing.

## Testing

`test/json_rules/log_test.exs` covers the pure logic (`emit?/2`, the predicates,
`valid?/1`/`validate!/1`, `normalize/3`, and that a lazy message is only built when
it will be emitted) and, with a temporary `:logger` handler that captures real
`Logger` output (`Verdict.LogCapture`), that a run:

- emits nothing with no `:log`;
- emits the full trace at `:debug`;
- emits `info` and above (but not `debug`) at `:info`;
- emits only the short-circuit warning (not `info`/`debug`) at `:warning`; and
- resolves the level with per-run > per-engine > application-config precedence.

## Where this fits

Phases 1–5 built the engine, the rule language, events and run control, scheduling
and stores, operator behaviors, and the round-trip/acceptance/performance work.
This phase adds an observability knob that is cheap to leave on in development and
free to leave off in production. The remaining work is publication: a CHANGELOG,
ExDoc, and a Hex release workflow (Phase 7).
