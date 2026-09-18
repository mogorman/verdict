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

## A layered store

The store is selected at engine construction so overhead scales with the workload:

| Backend     | What it is                                   | Status |
| ----------- | -------------------------------------------- | ------ |
| `:pure`     | the engine is a plain struct; no process     | MVP (default) |
| `:genserver`| a stateful store in a GenServer's state      | Phase 2 |
| `:ets`      | a GenServer backed by an ETS table           | Phase 2 |

Evaluation is **independent of the store**: the evaluator is pure and operates on
an immutable snapshot of the store's contents.

## Serial or parallel evaluation

Scheduling is orthogonal to the store, selected via `:schedule`:

| Mode        | Behaviour                                                        | Status |
| ----------- | ---------------------------------------------------------------- | ------ |
| `:serial`   | priority buckets run one at a time                               | MVP (default) |
| `:parallel` | items within a priority bucket run concurrently, then the next   | Phase 2 |

Both **rules** and **conditions** carry a `priority` (default `1`); higher
priority runs first. Evaluation is *strict* by default — every priority bucket is
fully evaluated. A per-run `short_circuit` option (Phase 2) stops an `all`/`any`
as soon as its outcome is decided.

**Facts** are computed lazily and cached in a per-run `JsonRules.Almanac`
(a shared in-memory cache) so a fact referenced by several conditions — or by
other facts — is computed only once.

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

## Status

This is the **MVP (Phase 1)**: the core engine with `:pure` store and `:serial`
scheduling. Planned for Phase 2: `:genserver` and `:ets` store backends,
`:parallel` scheduling, the `short_circuit` option, `path` (JSONPath) resolution,
operator decorators and custom operators, named condition references,
comparing-facts, rule success/failure callbacks, `replace_facts_in_event_params`,
and JSON round-tripping.

## Development

```sh
mix deps.get
mix test
```

The project targets Elixir 1.20, which runs the compiler's native type checker by
default. CI compiles with `--warnings-as-errors`, so type-checker warnings fail the
build.

## License

MIT — see [LICENSE](LICENSE).
