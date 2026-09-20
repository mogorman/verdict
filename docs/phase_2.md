# Phase 2 — the core rule language

Phase 2 extends the Phase 1 core with the richer building blocks of the reference
engine: addressing into facts, pluggable operators, and reusable, composable
conditions. Everything builds on the same pure evaluator and changeset report, so
the Phase 1 mental model is unchanged.

## What this phase delivers

- **Fact paths** — address into a fact's structure with JSONPath (`path`).
- **`allow_undefined_facts`** — treat a missing fact as `nil` instead of raising.
- **Custom operators** — register your own comparison logic.
- **Operator decorators** — six built-ins plus custom ones, combined into
  **composite operators** with `:`.
- **Comparing facts** — compare one fact directly against another.
- **Condition references** — register a named condition and reuse it in any rule
  (including inside other conditions), with a cycle guard and
  `allow_undefined_conditions`.
- **Custom properties** — carry arbitrary data in an `extra` map on a rule or any
  condition.

## Fact paths (JSONPath)

A leaf condition may name a `path` to address into the fact's value instead of
comparing the whole fact. The engine's default resolver is JSONPath:

```elixir
engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_fact("player", fn _p, _a -> %{stats: %{level: 12, hp: 80}} end)

{:ok, engine, _rule} =
  JsonRules.Engine.add_rule(engine, %{
    event: %{type: "high-level"},
    conditions: %{
      all: [%{fact: "player", path: "$.stats.level", operator: "greaterThanInclusive", value: 10}]
    }
  })

%{events: [event]} = JsonRules.Engine.run(engine, %{})
event.type #=> "high-level"
```

Path results are normalized for comparison:

| Expression        | Returns                                          |
| ----------------- | ------------------------------------------------ |
| `$.a.b`           | the value at `a.b` (a scalar), or `nil`          |
| `$.a[*].b`        | a **list** of every `a[i].b` — pair with a list operator |
| no match          | `nil`                                            |

```elixir
# wildcard over a list -> a list, so use a list operator
conditions = %{
  all: [
    %{fact: "users", path: "$.phoneNumbers[*].type", operator: "contains", value: "iPhone"}
  ]
}
```

A `path` is only applied when the fact value is a map or a list (mirroring the
reference engine); a scalar fact is compared as-is.

### `allow_undefined_facts`

By default a condition on a fact that was never registered (and not supplied to
`run/3`) raises. Opt in to treating missing facts as `nil`:

```elixir
engine = JsonRules.Engine.new(allow_undefined_facts: true)
# or per run:
JsonRules.Engine.run(engine, %{}, allow_undefined_facts: true)
```

## Custom operators and decorators

### Custom operators

Register a `(fact_value, json_value) -> boolean` function under a name. A custom
operator takes precedence over a built-in of the same name while the engine is in
use; operator existence is checked at evaluation time, so the name need not exist
at `add_rule` time.

```elixir
engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_operator("startsWithLetter", fn fact_value, letter ->
    String.starts_with?(to_string(fact_value), letter)
  end)

{:ok, engine, _rule} =
  JsonRules.Engine.add_rule(engine, %{
    event: %{type: "match"},
    conditions: %{all: [%{fact: "name", operator: "startsWithLetter", value: "J"}]}
  })

JsonRules.Engine.remove_operator(engine, "startsWithLetter")  # unregister
```

### Operator decorators

A decorator receives `(fact_value, json_value, next)` — where `next` is the
wrapped operator — and returns a boolean. Six are built in:

| Decorator      | Meaning                                                     |
| -------------- | ----------------------------------------------------------- |
| `someFact`     | the fact is a list and *some* element satisfies `next`      |
| `someValue`    | the value is a list and *some* element satisfies `next`     |
| `everyFact`    | the fact is a list and *every* element satisfies `next`     |
| `everyValue`   | the value is a list and *every* element satisfies `next`    |
| `swap`         | evaluate `next` with the fact and value swapped             |
| `not`          | negate the result of `next`                                 |

Combine a decorator (or several) with a base operator into a **composite name**
using `:` — the leftmost decorator is applied outermost:

```elixir
# at least one element of the list fact is >= 80
conditions = %{all: [%{fact: "scores", operator: "someFact:greaterThanInclusive", value: 80}]}

# several decorators compose: for every element of the value-list,
# the fact has some element equal to it
conditions = %{all: [%{fact: "ids", operator: "everyValue:someFact:equal", value: [1, 2]}]}
```

Register a custom decorator the same way:

```elixir
# lowercase both sides before delegating to the base operator
engine =
  JsonRules.Engine.new()
  |> JsonRules.Engine.add_operator_decorator("caseInsensitive", fn fv, jv, next ->
    next.(String.downcase(to_string(fv)), String.downcase(to_string(jv)))
  end)

{:ok, engine, _rule} =
  JsonRules.Engine.add_rule(engine, %{
    event: %{type: "ok"},
    conditions: %{all: [%{fact: "nickname", operator: "caseInsensitive:equal", value: "sam"}]}
  })

JsonRules.Engine.run(engine, %{nickname: "Sam"})  # "sam" == "sam" -> success
JsonRules.Engine.run(engine, %{nickname: "Bob"})  # -> failure

JsonRules.Engine.remove_operator_decorator(engine, "caseInsensitive")  # unregister
```

## Comparing facts

A condition's `value` may itself be a fact reference — `%{fact: _}` (optionally
with `params` and `path`) — so one fact can be compared directly against another.
The referenced fact is resolved through the almanac:

```elixir
engine = JsonRules.Engine.new()

{:ok, engine, _rule} =
  JsonRules.Engine.add_rule(engine, %{
    event: %{type: "taller-than-wide"},
    conditions: %{
      all: [
        %{fact: "height", operator: "lessThanInclusive", value: %{fact: "width"}}
      ]
    }
  })

JsonRules.Engine.run(engine, %{height: 1, width: 2})  # 1 <= 2 -> success
JsonRules.Engine.run(engine, %{height: 2, width: 1})  # 2 <= 1 -> failure
```

The resolved value is what the operator sees and what is recorded in the report
(as the condition's `value`), matching the reference engine's `valueResult`.

## Condition references

Register a named, reusable condition and reference it by name from any rule — at
the top level, nested, or inside another condition. References can be chained.

```elixir
{:ok, engine} =
  JsonRules.Engine.set_condition(engine, "over60", %{
    all: [%{fact: "age", operator: "greaterThanInclusive", value: 60}]
  })

{:ok, engine, _rule} =
  JsonRules.Engine.add_rule(engine, %{
    event: %{type: "retire"},
    conditions: %{
      all: [
        %{condition: "over60"},
        %{fact: "isRetired", operator: "equal", value: true}
      ]
    }
  })

JsonRules.Engine.remove_condition(engine, "over60")  # unregister
```

A reference that was never registered **raises** (`No condition <name> exists`)
unless you opt in to treating it as `false`:

```elixir
engine = JsonRules.Engine.new(allow_undefined_conditions: true)
```

A circular reference (a condition that, directly or transitively, references
itself) is detected and raised rather than looping forever.

## Custom properties

Attach arbitrary data to a rule or any condition in an `extra` map. It is carried
on the typed struct and round-trips through the condition's JSON map:

```elixir
{:ok, engine, rule} =
  JsonRules.Engine.add_rule(engine, %{
    event: %{type: "ok"},
    conditions: %{
      all: [%{fact: "age", operator: "equal", value: 1, extra: %{note: "checked by ops"}}]
    },
    extra: %{source: "marketing", tag: "v2"}
  })

rule.extra #=> %{source: "marketing", tag: "v2"}
```

## Engine options

The Phase 2 options, all settable on `Engine.new/1` (and, where noted, per run):

| Option                        | Default | Effect                                                        |
| ----------------------------- | ------- | ------------------------------------------------------------- |
| `allow_undefined_facts`       | `false` | a missing fact is `nil` instead of raising (per-run too)      |
| `allow_undefined_conditions`  | `false` | an unregistered reference is `false` instead of raising       |
| `path_resolver`               | JSONPath| a `(value, path) -> term()` used to resolve a condition `path`|
| `strict`                      | `false` | `false` short-circuits; `true` evaluates every condition      |

## Where this fits

Phase 2 is built on the [Phase 1](./phase_1.md) core — same engine, store,
almanac, operators and changeset report — with these building blocks layered on
top. [Phase 3](./phase_3.md) adds events, callbacks, fact priority and run
control; [Phase 4](./phase_4.md) adds `:parallel` scheduling and the pluggable
stores. The remaining work is full JSON round-tripping.
