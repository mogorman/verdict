# Phase 1 — the core engine (MVP)

Phase 1 is the working core of `JsonRules`: a pure, Ecto-typed rules engine that
evaluates human-readable condition trees against a set of **facts** and reports —
as a `Ecto.Changeset` — exactly how each rule fired.

## What this phase delivers

- An **Ecto data model with no database**: `JsonRules.Rule` (a schema),
  `JsonRules.Event` (an embedded schema), a recursive `JsonRules.Condition` tree
  behind a custom `Ecto.Type`, and `Ecto.Changeset` validation of JSON-shaped
  input.
- A **pluggable store**. The default `:pure` backend is a plain struct (no
  process); evaluation is pure and independent of the store.
- **Facts** — constants or `(params, almanac)` functions, computed lazily and
  cached per run in a `JsonRules.Almanac`, so a fact used by several conditions —
  or by other facts — is computed only once.
- Ten built-in **operators**.
- Condition trees of `all` / `any` / `not` with a per-node `priority`.
- A **changeset evaluation report** (`valid?`, `changes`, `errors`, `data.facts`,
  `empty_values`).
- **Short-circuiting**: an `all`/`any` stops as soon as its outcome is decided
  (skipped leaves are reported in `empty_values`); `strict: true` evaluates all.
- A **JSON payload** entry point built on OTP 28's built-in `:json`.

## The engine, rules and conditions

An engine is created with `Engine.new/1`, filled with rules and facts, then run
with `Engine.run/3`. A rule is a condition tree plus a single event; when the
tree is truthy the event is a *success*, otherwise a *failure*.

```elixir
engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_fact("gameDuration", 40)
  |> JsonRules.Engine.add_fact("personalFoulCount", 6)

# (40-minute game AND 5+ fouls) OR (48-minute game AND 6+ fouls)
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
event.type   #=> "fouledOut"
event.params #=> %{message: "Player has fouled out!"}
```

A condition tree is built from:

- a **leaf** — `{fact, operator, value}` (optionally with `params`);
- **`all`** — truthy when *every* child is truthy;
- **`any`** — truthy when *at least one* child is truthy;
- **`not`** — the negation of its single child;
- a **`priority`** (default `1`) — higher runs first.

## Facts

A fact is a constant or a function of `(params, almanac)` (or `(params)`):

```elixir
products = %{"widget" => %{price: 150}}

engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_fact("product-price", fn params, _almanac ->
    Map.fetch!(products, params["productId"]).price
  end)
```

`params` are supplied by the condition (`%{fact: ..., params: %{"productId" => "widget"}}`).
A fact can read other facts through the almanac (fact dependencies):

```elixir
engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_fact("account-info", fn _p, _a -> %{company: "microsoft"} end)
  |> JsonRules.Engine.add_fact("company", fn _p, almanac ->
    JsonRules.Almanac.fact_value(almanac, "account-info").company
  end)
```

Facts are cached per run, so a fact (and any facts it reads) is computed only
once no matter how many conditions reference it.

## Operators

The ten built-in operators:

| Operator               | Meaning                                  |
| ---------------------- | ---------------------------------------- |
| `equal`                | fact equals value                        |
| `notEqual`             | fact does not equal value                |
| `lessThan`             | fact < value                             |
| `lessThanInclusive`    | fact <= value                            |
| `greaterThan`          | fact > value                             |
| `greaterThanInclusive` | fact >= value                            |
| `in`                   | fact is a member of value (a list)       |
| `notIn`                | fact is not a member of value (a list)   |
| `contains`             | fact (a list) includes value             |
| `doesNotContain`       | fact (a list) does not include value     |

Custom operators, operator decorators and composite operators arrive in
[Phase 2](./phase_2.md#custom-operators-and-decorators).

## The evaluation report

`Engine.run/3` returns a `JsonRules.RunResult`. Its `results` is a list of
`{rule, changeset}` pairs where the changeset is that rule's **evaluation
report**:

```elixir
%JsonRules.RunResult{results: [{_rule, changeset}]} =
  JsonRules.Engine.run(engine, %{})

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

- `valid?` — whether the rule fired.
- `changes` — the conditions that **passed** (a list, so one fact may appear
  under several conditions without overwriting).
- `errors` — the conditions that **failed**, each carrying the operator's
  explanation, the expected `value` and the `actual` fact value.
- `data.facts` — the computed fact values.
- `empty_values` — conditions **short-circuited** before they were reached.

`changes` and `errors` are keyed by the fact's name (an atom). The first `any`
branch above matched, so evaluation stopped and the second branch's leaves landed
in `empty_values` instead of being evaluated.

## Short-circuiting

By default an `all` stops at its first failing child and an `any` stops at its
first passing child; the un-evaluated siblings are reported in `empty_values`.
Pass `strict: true` to evaluate every condition regardless:

```elixir
# evaluate all conditions, even after the outcome is known
JsonRules.Engine.new(strict: true)
# ...or per run:
JsonRules.Engine.run(engine, %{}, strict: true)
```

## From a JSON payload

Rules (and optionally the facts they run against) usually arrive as JSON. OTP 28
ships a built-in `:json` module, so the whole flow is `:json.decode/1` followed by
the public API. Decoded objects have string keys, which the casts and the almanac
accept as-is:

```elixir
payload = """
{
  "facts": { "gameDuration": 40, "personalFoulCount": 6 },
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

%JsonRules.RunResult{events: [event]} = JsonRules.Engine.run(engine, decoded["facts"])
event.type #=> "fouledOut"
```

## What's next

[Phase 2 — the core rule language](./phase_2.md) adds fact paths (JSONPath),
custom operators, operator decorators, comparing facts, named condition
references and custom properties.
