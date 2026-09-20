# Phase 5 — round-tripping, acceptance, and performance

This phase completes the "rules as data" story in **both** directions (rules
serialize back to JSON, not just into the engine), adds an **acceptance test** that
ports the reference engine's integration scenario, and adds a lightweight
**performance** guard with a [performance guide](./performance.md).

Publication (a CHANGELOG, ExDoc, and a Hex release workflow) is deferred to Phase 7.

## What this phase delivers

- `JsonRules.Rule.to_map/1` and `JsonRules.Event.to_map/1` — serialize a rule (and
  its event) back to a JSON-compatible map.
- `JsonRules.Engine.rules_as_map/1` — serialize an engine's whole rule set.
- An acceptance test ported from the reference's `test/acceptance/acceptance.js`.
- A performance sanity test and `docs/performance.md`.

## JSON round-trip

Up to now a rule could be *loaded* from JSON (via `Rule.changeset/2`) but not
*serialized back out*. The condition tree already round-tripped
(`JsonRules.Types.Condition.from_map/1` / `to_map/1`); this phase adds the same for
the rule and event:

```elixir
alias JsonRules.{Engine, Rule}

payload = %{
  "name" => "first",
  "priority" => 10,
  "event" => %{"type" => "event-1", "params" => %{"eventParam" => 1}},
  "conditions" => %{"all" => [%{"fact" => "x", "operator" => "equal", "value" => 1}]}
}

{:ok, engine, rule} = Engine.add_rule(Engine.new(), payload)

Rule.to_map(rule)
#=> payload, unchanged

# ...or serialize every rule an engine holds, in descending priority order:
Engine.rules_as_map(engine)
#=> [payload]
```

For **well-formed** rules `to_map/1` is the exact inverse of the cast, so
`decode → add_rule → to_map` returns a payload's rules unchanged, and serializing
twice is stable (idempotent). The output uses string keys and omits the Ecto
internals (`id`, timestamps); a default `priority` of `1` and an empty `extra` are
omitted, mirroring the condition serializer.

Facts and operators hold **functions**, which are not JSON-serializable, so only
rules round-trip — not the whole engine state.

The same idea extends to the **result** of a run. `JsonRules.RunResult.to_map/1` and
`JsonRules.RuleResult.to_map/1` serialize the completed run — `events`,
`failure_events`, and the per-rule evaluation report (the leaves that passed,
failed, or were short-circuited, each with the operator, expected value, and the
fact's actual value) — back to a JSON-compatible map. Together with the rule
serializer, a JSON payload can flow in and a JSON result out. See
[From JSON back to JSON: the completed result](./result_json.md).

## The acceptance suite

`test/json_rules/engine_acceptance_test.exs` ports the reference engine's
acceptance test, whose purpose is to exercise features **in combination** — the
place where integration bugs hide. A single scenario wires together:

- **rule and fact priority ordering** (a priority-10 rule and priority-1 rule; a
  priority-2 fact and a priority-1 fact);
- **fact `params`** and **JSONPath `path`**;
- **facts reading other facts** through the almanac;
- a **rule-level success callback** that creates a runtime fact mid-run; and
- a condition whose **`value` is itself a `{fact, path}` reference** to that
  runtime fact.

It has a *succeeds* scenario and a *fails* scenario. The assertions are written
against this engine's `JsonRules.RuleResult` shape (`valid?`, `event`, `rule`, and
the evaluation `changeset`) rather than the reference's JSON
`results[].conditions` tree — parity on **behavior**, not on the wire format.

## Performance

`test/json_rules/engine_performance_test.exs` is a *sanity* check, not a precise
benchmark: it builds a 1000-rule engine and asserts a run both returns the right
results and stays within a generous wall-clock budget, so a catastrophic regression
fails CI instead of shipping. For reproducible per-scenario numbers and the
trade-offs (store choice, `:serial` vs `:parallel`, fact caching), see
[performance](./performance.md) and the `mix bench` suite
([benchmarks](./benchmarks.md)).

## Where this fits

Phases 1–4.5 built the engine, the rule language, events and run control,
scheduling and stores, and operator behaviors and coverage. This phase closes the
data-model loop (JSON in **and** out), pins the integration behavior with an
acceptance test, and documents the performance characteristics. The remaining work
is publication: a CHANGELOG, ExDoc, and a Hex release workflow (Phase 7).
