# Verdict

An Elixir/Ecto reimplementation of
[json-rules-engine](https://github.com/CacheControl/json-rules-engine).

Rules are composed of simple, human-readable condition trees (expressed as maps,
JSON-compatible) plus a single **event**. When the engine runs, each rule's
conditions are evaluated against a set of **facts**; if the result is truthy the
rule's event is emitted as a *success*, otherwise as a *failure*.

## Why Ecto, without a database?

The rule data model is built from Ecto primitives:

- `Verdict.Rule` — an `Ecto.Schema`
- `Verdict.Event` — an `Ecto` embedded schema
- `Verdict.Condition` — a recursive tree behind a custom `Ecto.Type`
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

The store is a pluggable `Verdict.Store` behaviour; you can also wrap a
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

**Facts** are computed lazily and cached in a per-run `Verdict.Almanac`
(a shared in-memory cache) so a fact referenced by several conditions — or by
other facts — is computed only once.

## Logging

By default the engine is silent. Set a log threshold to have each step of a run
emitted through `Logger`:

```elixir
# per engine
engine = Verdict.Engine.new(log: :debug)

# per run (overrides the engine's level)
Verdict.Engine.run(engine, %{}, log: :info)

# or globally, in config/config.exs
config :verdict, :log, :warning
```

The effective level is resolved per run: a per-run `:log` beats a per-engine
`:log`, which beats the application config, which defaults to off. The levels are
cumulative — a run at `:debug` emits everything; a run at `:info` emits `:info`,
`:warning` and `:error` but not `:debug`; and so on. When the level is off, no
message is built and no `Logger` call is made, so the default run costs nothing
extra. The host application's own `:logger` configuration (console level,
formatters, backends) applies on top — this only decides *whether* the engine
emits. See `Verdict.Log` for the step-by-level reference.

## Installation

Add `verdict` to your `mix.exs`:

```elixir
def deps do
  [{:verdict, "~> 0.1"}]
end
```

## Usage

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("gameDuration", 40)
  |> Verdict.Engine.add_fact("personalFoulCount", 6)

# (has committed 5 fouls AND a 40-minute game) OR (6 fouls AND a 48-minute game)
{:ok, engine, _rule} =
  Verdict.Engine.add_rule(engine, %{
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

%Verdict.RunResult{events: [event]} = Verdict.Engine.run(engine, %{})
event.type    #=> "fouledOut"
event.params  #=> %{message: "Player has fouled out!"}
```

### Events

An event's `params` values may be EEx templates. A value shaped `%{eex_string: "…"}`
(atom or string key, the sole key) is an EEx template rendered at run time; the key
names the type the rendered string is coerced to:

| Marker        | Rendered string becomes            |
| ------------- | ----------------------------------- |
| `eex_string`  | a string                            |
| `eex_integer` | an integer (`"10"`)                 |
| `eex_float`   | a float (`"10"` → `10.0`)           |
| `eex_number`  | an integer if whole, else a float   |
| `eex_boolean` | `true` / `false`                    |
| `eex_list`    | a list, parsed from JSON            |
| `eex_object`  | a map, parsed from JSON             |

Plain values (anything else) pass through untouched. Every template runs against
the run's facts — a bare variable for each fact, a `facts` map, and the `almanac`
itself:

```elixir
engine = Verdict.Engine.new() |> Verdict.Engine.add_fact("name", "Mog")

{:ok, engine, _rule} =
  Verdict.Engine.add_rule(engine, %{
    event: %{
      type: "scored",
      params: %{
        message: %{eex_string: "Hello <%= name %>!"},          # bare fact variable
        meta: %{eex_string: "score=<%= facts[\"score\"] %>"},  # indexed by id
        score: %{eex_integer: "<%= score %>"},                 # -> integer
        active: %{eex_boolean: "<%= ok %>"}                    # -> true
      }
    },
    conditions: %{any: [%{fact: "ok", operator: "equal", value: true}]}
  })

%Verdict.RunResult{events: [%{params: params}]} =
  Verdict.Engine.run(engine, %{ok: true, score: 10})

params  #=> %{message: "Hello Mog!", meta: "score=10", score: 10, active: true}
```

Only `<%= expr %>` interpolation is allowed by default; a template that uses EEx
control flow (which may run arbitrary code) needs `allow_unsafe_eex: true`, on
`new/1` or per run:

```elixir
engine = Verdict.Engine.new(allow_unsafe_eex: true)
# params: %{note: %{eex_string: "<%= if n do %>yes<% end %>"}}
```

### Facts

A fact is a constant or a function of `(params, almanac)`:

```elixir
products = %{"widget" => %{price: 150}}

engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_fact("product-price", fn params, _almanac ->
    Map.fetch!(products, params["productId"]).price
  end)
  |> then(fn engine ->
    {:ok, engine, _} =
      Verdict.Engine.add_rule(engine, %{
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
|> Verdict.Engine.add_fact("account-info", fn _p, _a -> %{company: "microsoft"} end)
|> Verdict.Engine.add_fact("company", fn _p, almanac ->
  Verdict.Almanac.fact_value(almanac, "account-info").company
end)
```

### Operators

`equal`, `notEqual`, `lessThan`, `lessThanInclusive`, `greaterThan`,
`greaterThanInclusive`, `in`, `notIn`, `contains`, `doesNotContain`.

Custom operators (registered with `add_operator/3`) may return their own
`{passed?, explanation}` for the report and may be 3-arity —
`(fact_value, json_value, params)` — to be parameterized by the condition's `params`.
See `Verdict.Operators` for the decorator and composite names and examples.

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
  Enum.reduce(decoded["rules"], Verdict.Engine.new(), fn rule, engine ->
    {:ok, engine, _rule} = Verdict.Engine.add_rule(engine, rule)
    engine
  end)

%Verdict.RunResult{events: [event], results: [{_rule, changeset}]} =
  Verdict.Engine.run(engine, decoded["facts"])

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
`Verdict.Evaluation` for the full report shape.

The round-trip runs in reverse, too. A stored rule serializes back to a
JSON-compatible map with `Verdict.Rule.to_map/1`, and an engine's whole rule set
with `Verdict.Engine.rules_as_map/1` (in descending priority order). For
well-formed rules `to_map/1` is the exact inverse of the cast, so
`decode → add_rule → to_map` returns a payload's rules unchanged. Facts and
operators hold functions and so are not serializable.

The **completed result** of a run serializes the same way —
`Verdict.RunResult.to_map/1` (the whole run) and `Verdict.RuleResult.to_map/1`
(one rule) — so a JSON payload can flow in and a JSON result can flow out. See
[From JSON back to JSON: the completed result](docs/result_json.md) for the full
flow and the report shape.

## One-shot return

`Verdict.return/3` builds an engine, registers the rules, and runs them in a
single call. `rules` may be a JSON string (a rule object or an array of them),
a map, a `Verdict.Rule` struct, or a list of any of those; `facts` may be a
JSON string or a map of `name` to value (a value may be a function for a
dynamic fact). The options accept any `Verdict.Engine.new/1` key — `:strict`,
`:schedule`, `:store`, `:log`, and so on.

```elixir
rules = """
{ "event": { "type": "fouledOut" },
  "conditions": { "all": [
      { "fact": "personalFoulCount", "operator": "greaterThanInclusive", "value": 6 }
  ] } }
"""

# {:ok, %Verdict.RunResult{events: [event]}}
Verdict.return(rules, %{"personalFoulCount" => 6})

# same, but return the result directly and raise on a bad rule / malformed JSON
%Verdict.RunResult{} = Verdict.return!(rules, %{"personalFoulCount" => 6})

# options pass straight through to the engine
Verdict.return!(rules, %{"personalFoulCount" => 6},
  schedule: :parallel, strict: true, store: :genserver)
```

`return/3` returns `{:ok, %RunResult{}}`, `{:error, changeset}` (an invalid rule),
or `{:error, {:bad_json, message}}`. `return!/3` returns the `RunResult` directly
and raises `Verdict.InvalidRuleError` (carrying the failing `changeset`) or
`Verdict.InvalidJSONError` (carrying the decoder's `reason` and `input`).

## Modules

Every part of the engine is a focused module with its own reference (its
`@moduledoc`, rendered by ExDoc):

| Module                                          | What it is |
| ----------------------------------------------- | ---------- |
| `Verdict.Engine`                                | the public API: build an engine, add rules / facts / operators / named conditions, register callbacks, and run |
| `Verdict`                                       | the one-shot `return/3` / `return!/3` entry point |
| `Verdict.Rule`, `Verdict.Event`, `Verdict.Condition` | the Ecto data model |
| `Verdict.Fact`                                  | constant or dynamic facts |
| `Verdict.Operators`                             | the built-in comparison operators, plus custom operators, decorators and composites |
| `Verdict.Template`                              | renders `eex_string` EEx templates in an event's `params` |
| `Verdict.Almanac`                               | the per-run fact store / cache (`ProcessLocal` and `Shared` backends) |
| `Verdict.Store`                                 | the pluggable rule / fact store (`:pure`, `:genserver`, `:ets`) |
| `Verdict.Evaluator`                             | the pure, serial or parallel run loop |
| `Verdict.Evaluation`                            | the pure condition-tree evaluation and the changeset report |
| `Verdict.RunResult` / `Verdict.RuleResult`      | the outcome of a run / a rule |
| `Verdict.Log`                                   | optional, level-gated logging |

For a field-by-field reference to every type and how a run flows through the
engine, see [Architecture & data types](docs/architecture.md).

## Development

```sh
mix deps.get
mix test
```

The suite includes an **acceptance test**
(`test/json_rules/engine_acceptance_test.exs`) that ports the reference engine's
end-to-end scenario, and a **performance sanity guard**
(`test/json_rules/engine_performance_test.exs`) that fails CI on a catastrophic
regression.

The project targets Elixir 1.20, which runs the compiler's native type checker by
default, and is additionally checked with **Dialyzer** — a stricter, BEAM-level
checker that also validates calls against dependency types (Ecto, `json_path`).
CI compiles with `--warnings-as-errors` and runs Dialyzer as a **hard gate**, so
type-checker warnings fail the build. See [Dialyzer](docs/dialyzer.md) for the
setup, the flag set, and how to suppress genuine false positives.

Benchmarks (see [benchmarks](docs/benchmarks.md)), profiling
([profiling](docs/profiling.md)), performance ([performance](docs/performance.md)),
type-checking ([Dialyzer](docs/dialyzer.md)), and coverage (ExCoveralls):

```sh
mix bench            # run the benchmark suites (schedule, store, fact, slowfacts, engines, matrix)
mix bench profile    # profile Engine.run/3 to find hotspots (OTP :tprof)
mix dialyzer         # type-check with Dialyzer (CI runs this as a hard gate)
mix coveralls.html   # coverage report + HTML in cover/; fails if below the ratchet
```

The [v0.1.0 report](docs/v0.1.0.md) records a full benchmark run and the per-module
coverage breakdown for that release.

## AI assistance

This project was implemented with the help of [opencode](https://opencode.ai), an AI
coding CLI, using the Qwen 3.8 27B model.

## License

MIT — see [LICENSE](LICENSE).
