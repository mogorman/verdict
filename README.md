# JsonRules

An Elixir/Ecto reimplementation of
[json-rules-engine](https://github.com/CacheControl/json-rules-engine).

Rules are composed of simple, human-readable condition trees (expressed as maps,
JSON-compatible) plus a single **event**. When the engine runs, each rule's
conditions are evaluated against a set of **facts**; if the result is truthy the
rule's event is emitted as a *success*, otherwise as a *failure*.

## Why Ecto, without a database?

The rule data model is built from Ecto primitives:

- `JsonRules.Rule` — an `Ecto.Schema`
- `JsonRules.Event` — an `Ecto` embedded schema
- `JsonRules.Condition` — a recursive tree behind a custom `Ecto.Type`
- `Ecto.Changeset` — casts and validates the JSON-shaped input into typed structs

No `Ecto.Repo`, no database driver, no migrations. The validated structs are held
by a **pluggable, in-memory store**. Ecto gives you a rigorous, typed data model
and changeset validation for free; the storage backend is a separate concern you
get to choose.

For a field-by-field reference to every type and how a run flows through the
engine, see [Architecture & data types](docs/architecture.md).

## A layered store

The store is selected at engine construction so overhead scales with the workload:

| Backend     | What it is                                   | Status |
| ----------- | -------------------------------------------- | ------ |
| `:pure`     | the engine is a plain struct; no process     | available (default) |
| `:genserver`| a stateful store in a GenServer's state      | available |
| `:ets`      | a GenServer with rules/facts in ETS tables   | available |

The store is a pluggable `JsonRules.Store` behaviour; you can also wrap a
pre-started store with `Engine.new(store: {module, handle})`.

Evaluation is **independent of the store**: the evaluator is pure and operates on
an immutable snapshot of the store's contents.

## Serial or parallel evaluation

Scheduling is orthogonal to the store, selected via `:schedule`:

| Mode        | Behaviour                                                        | Status |
| ----------- | ---------------------------------------------------------------- | ------ |
| `:serial`   | priority buckets run one at a time                               | available (default) |
| `:parallel` | items within a priority bucket run concurrently, then the next   | available |

Both **rules** and **conditions** carry a `priority` (default `1`); higher
priority runs first. Evaluation **short-circuits** by default — an `all`/`any`
stops as soon as its outcome is decided and the skipped leaves are reported in the
changeset's `empty_values`. Pass `strict: true` to evaluate every condition
instead.

**Facts** are computed lazily and cached in a per-run `JsonRules.Almanac`
(a shared in-memory cache) so a fact referenced by several conditions — or by
other facts — is computed only once.

## Logging

By default the engine is silent. Set a log threshold to have each step of a run
emitted through `Logger`:

```elixir
# per engine
engine = JsonRules.Engine.new(log: :debug)

# per run (overrides the engine's level)
JsonRules.Engine.run(engine, %{}, log: :info)

# or globally, in config/config.exs
config :ecto_json_rules, :log, :warning
```

The effective level is resolved per run: a per-run `:log` beats a per-engine
`:log`, which beats the application config, which defaults to off. The levels are
cumulative — a run at `:debug` emits everything; a run at `:info` emits `:info`,
`:warning` and `:error` but not `:debug`; and so on. When the level is off, no
message is built and no `Logger` call is made, so the default run costs nothing
extra. The host application's own `:logger` configuration (console level,
formatters, backends) applies on top — this only decides *whether* the engine
emits. See [Phase 6](docs/phase_6.md) for the step-by-level reference.

## Installation

Add `ecto_json_rules` to your `mix.exs`:

```elixir
def deps do
  [{:ecto_json_rules, "~> 0.1"}]
end
```

## Usage

```elixir
engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_fact("gameDuration", 40)
  |> JsonRules.Engine.add_fact("personalFoulCount", 6)

# (has committed 5 fouls AND a 40-minute game) OR (6 fouls AND a 48-minute game)
{:ok, engine, _rule} =
  JsonRules.Engine.add_rule(engine, %{
    name: "fouled-out",
    priority: 5,
    event: %{type: "fouledOut", params: %{message: "Player has fouled out!"}},
    conditions: %{
      any: [
        %{
          all: [
            %{fact: "gameDuration", operator: "equal", value: 40},
            %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 5}
          ]
        },
        %{
          all: [
            %{fact: "gameDuration", operator: "equal", value: 48},
            %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 6}
          ]
        }
      ]
    }
  })

%JsonRules.RunResult{events: [event]} = JsonRules.Engine.run(engine, %{})
event.type    #=> "fouledOut"
event.params  #=> %{message: "Player has fouled out!"}
```

### Facts

A fact is a constant or a function of `(params, almanac)`:

```elixir
products = %{"widget" => %{price: 150}}

engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_fact("product-price", fn params, _almanac ->
    Map.fetch!(products, params["productId"]).price
  end)
  |> then(fn engine ->
    {:ok, engine, _} =
      JsonRules.Engine.add_rule(engine, %{
        event: %{type: "expensive"},
        conditions: %{
          all: [
            %{
              fact: "product-price",
              params: %{"productId" => "widget"},
              operator: "greaterThan",
              value: 100
            }
          ]
        }
      })

    engine
  end)
```

A fact can read other facts through the almanac (fact dependencies):

```elixir
engine
|> JsonRules.Engine.add_fact("account-info", fn _p, _a -> %{company: "microsoft"} end)
|> JsonRules.Engine.add_fact("company", fn _p, almanac ->
  JsonRules.Almanac.fact_value(almanac, "account-info").company
end)
```

### Operators

`equal`, `notEqual`, `lessThan`, `lessThanInclusive`, `greaterThan`,
`greaterThanInclusive`, `in`, `notIn`, `contains`, `doesNotContain`.

Custom operators (registered with `add_operator/3`) may return their own
`{passed?, explanation}` for the report and may be 3-arity —
`(fact_value, json_value, params)` — to be parameterized by the condition's `params`.
See [Phase 4.5](docs/phase_4_5.md#operator-behaviors) for examples.

## From a JSON payload

Rules (and, optionally, the facts they run against) usually arrive as JSON — from
a config file, a database row, or an API. OTP 28 ships a built-in JSON module, so
the whole flow is `:json.decode/1` followed by the public API. Decoded objects
have string keys, which the casts and the almanac accept as-is. This payload
registers two facts and one rule that fires when the player fouls out — either a
40-minute game with 5+ fouls, or a 48-minute game with 6+:

```elixir
payload = """
{
  "facts": {
    "gameDuration": 40,
    "personalFoulCount": 6
  },
  "rules": [
    {
      "name": "fouled-out",
      "priority": 5,
      "event": { "type": "fouledOut", "params": { "message": "Player has fouled out!" } },
      "conditions": {
        "any": [
          { "all": [
              { "fact": "gameDuration", "operator": "equal", "value": 40 },
              { "fact": "personalFoulCount", "operator": "greaterThanInclusive", "value": 5 }
            ]
          },
          { "all": [
              { "fact": "gameDuration", "operator": "equal", "value": 48 },
              { "fact": "personalFoulCount", "operator": "greaterThanInclusive", "value": 6 }
            ]
          }
        ]
      }
    }
  ]
}
"""

decoded = :json.decode(payload)

engine =
  Enum.reduce(decoded["rules"], JsonRules.Engine.new(), fn rule, engine ->
    {:ok, engine, _rule} = JsonRules.Engine.add_rule(engine, rule)
    engine
  end)

%JsonRules.RunResult{events: [event], results: [{_rule, changeset}]} =
  JsonRules.Engine.run(engine, decoded["facts"])

event.type   #=> "fouledOut"
event.params #=> %{"message" => "Player has fouled out!"}
```

`changeset` is that rule's **evaluation report** — a pure `Ecto.Changeset`
describing exactly how the rule fired:

```elixir
changeset.valid?       #=> true
changeset.errors       #=> []
changeset.data.facts   #=> %{gameDuration: 40, personalFoulCount: 6}
changeset.changes      #=> [
                         gameDuration: %{value: 40, operator: "equal", actual: 40},
                         personalFoulCount: %{value: 5, operator: "greaterThanInclusive", actual: 6}
                       ]
changeset.empty_values #=> [
                         %{fact: "gameDuration", operator: "equal", value: 48},
                         %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 6}
                       ]
```

`changes` are the conditions that passed, `errors` the conditions that failed
(each carrying the operator's explanation, the expected `value` and the `actual`
fact value), and `empty_values` the conditions short-circuited before they were
reached. Here the first `any` branch matched, so evaluation stopped and the second
branch's leaves landed in `empty_values` instead of being evaluated. `changes` and
`errors` are **lists**, so a rule may test the same fact with several conditions
without any of them overwriting the others. `data.facts` holds the computed fact
values. Facts passed to `run/3` are runtime facts (they override registered facts
for that run); you may also register facts up front with `add_fact/3`. See
`JsonRules.Evaluation` for the full report shape.

The round-trip runs in reverse, too. A stored rule serializes back to a
JSON-compatible map with `JsonRules.Rule.to_map/1`, and an engine's whole rule set
with `JsonRules.Engine.rules_as_map/1` (in descending priority order). For
well-formed rules `to_map/1` is the exact inverse of the cast, so
`decode → add_rule → to_map` returns a payload's rules unchanged. Facts and
operators hold functions and so are not serializable.

The **completed result** of a run serializes the same way —
`JsonRules.RunResult.to_map/1` (the whole run) and `JsonRules.RuleResult.to_map/1`
(one rule) — so a JSON payload can flow in and a JSON result can flow out. See
[From JSON back to JSON: the completed result](docs/result_json.md) for the full
flow and the report shape.

## Phases

Feature development is tracked in per-phase guides, each with features and
examples:

- [**Phase 1 — the core engine (MVP)**](docs/phase_1.md) — the Ecto data model,
  the `:pure` store, facts and the almanac, built-in operators, condition trees,
  the changeset evaluation report, short-circuiting and the JSON payload entry
  point.
- [**Phase 2 — the core rule language**](docs/phase_2.md) — fact paths (JSONPath),
  custom operators, operator decorators and composite operators, comparing facts,
  named condition references and custom properties.
- [**Phase 3 — events, callbacks, and run control**](docs/phase_3.md) — event
  callbacks (engine-level and per-rule), `Almanac.stop/1`, runtime facts, fact
  priority, `cache: false`, `replace_facts_in_event_params` and error propagation.
- [**Phase 4 — `:parallel` scheduling and pluggable stores**](docs/phase_4.md) —
  `:parallel` scheduling over a shared almanac, and the pluggable `Store`
  behaviour with the `:pure`, `:genserver` and `:ets` backends.
- [**Phase 4.5 — operator behaviors, benchmarks, and coverage**](docs/phase_4_5.md) —
  custom operators with their own explanations and per-condition parameters, a
  `mix bench` benchmark suite, and ExCoveralls coverage with a ratchet.
- [**Phase 5 — round-tripping, acceptance, and performance**](docs/phase_5.md) —
  serializing rules back to JSON (`Rule.to_map/1`, `Engine.rules_as_map/1`), an
  acceptance test ported from the reference engine, and a performance sanity guard
  with a [performance guide](docs/performance.md).
- [**Phase 6 — optional logging**](docs/phase_6.md) — an opt-in, level-gated
  `:log` (on `new/1`, per run, or via application config) that emits each run
  step through `Logger`, silent by default.

Planned next:

- **Phase 7** — publication: a CHANGELOG, ExDoc, and a Hex release workflow.

## Development

```sh
mix deps.get
mix test
```

The project targets Elixir 1.20, which runs the compiler's native type checker by
default. CI compiles with `--warnings-as-errors`, so type-checker warnings fail the
build.

Benchmarks (see [benchmarks](docs/benchmarks.md)), performance
([performance](docs/performance.md)), and coverage (ExCoveralls):

```sh
mix bench            # run the benchmark suites (schedule, store, fact)
mix coveralls.html   # coverage report + HTML in cover/; fails if below the ratchet
```

The [v0.1.0 report](docs/v0.1.0.md) records a full benchmark run and the per-module
coverage breakdown for that release.

## License

MIT — see [LICENSE](LICENSE).
