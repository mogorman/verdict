# From JSON back to JSON: the completed result

[From a JSON payload](../README.md#from-a-json-payload) covers the first half —
decoding a JSON payload into an engine and running it. This page is the other half:
serializing the **completed result** of a run back to JSON, so the whole flow is
**JSON in → JSON out** with no hand-rolling.

The entry points:

- `Verdict.RunResult.to_map/1` — the whole run: `events`, `failure_events`, and one
  entry per rule (`results`), in priority order.
- `Verdict.RuleResult.to_map/1` — a single rule's result.

Both return maps with **string keys**. Encode with OTP 28's built-in `:json`
(`:json.encode/1` returns an iolist, so pipe through `IO.iodata_to_binary/1`).

## The flow

A payload with facts and rules:

```json
{
  "facts": { "age": 30, "segment": "european" },
  "rules": [
    {
      "name": "young-european",
      "priority": 5,
      "event": { "type": "targeted", "params": { "audience": "under-40" } },
      "conditions": {
        "all": [
          { "fact": "age", "operator": "lessThan", "value": 40 },
          { "fact": "segment", "operator": "equal", "value": "european" }
        ]
      }
    },
    {
      "name": "senior",
      "event": { "type": "senior-offer" },
      "conditions": { "all": [ { "fact": "age", "operator": "greaterThan", "value": 65 } ] }
    }
  ]
}
```

```elixir
alias Verdict.{Engine, RunResult}

decoded = :json.decode(payload)

engine =
  decoded["rules"]
  |> Enum.reduce(
    Map.to_list(decoded["facts"])
    |> Enum.reduce(Engine.new(), fn {id, value}, e -> Engine.add_fact(e, id, value) end),
    fn rule, e ->
      {:ok, e, _} = Engine.add_rule(e, rule)
      e
    end
  )

json_out =
  engine
  |> Engine.run(%{})
  |> RunResult.to_map()
  |> :json.encode()
  |> IO.iodata_to_binary()
```

## The output

```json
{
  "events": [
    { "type": "targeted", "params": { "audience": "under-40" } }
  ],
  "failure_events": [
    { "type": "senior-offer" }
  ],
  "results": [
    {
      "name": "young-european",
      "priority": 5,
      "result": true,
      "event": { "type": "targeted", "params": { "audience": "under-40" } },
      "conditions": {
        "result": true,
        "changes": [
          { "fact": "age", "operator": "lessThan", "value": 40, "actual": 30, "factResult": 30, "result": true },
          { "fact": "segment", "operator": "equal", "value": "european", "actual": "european", "factResult": "european", "result": true }
        ],
        "errors": [],
        "empty_values": []
      }
    },
    {
      "name": "senior",
      "priority": 1,
      "result": false,
      "event": { "type": "senior-offer" },
      "conditions": {
        "result": false,
        "changes": [],
        "errors": [
          { "fact": "age", "operator": "greaterThan", "value": 65, "actual": 30, "factResult": 30, "result": false }
        ],
        "empty_values": []
      }
    }
  ]
}
```

## Reading the report

- **`events` / `failure_events`** — the events of the rules that fired / did not
  fire (a fired rule emits its event as a success; a rule whose conditions are
  falsy emits it as a failure).
- **`results`** — one entry per rule, in descending `priority` order. Each has the
  rule's `name` and `priority`, whether it fired (`result`), its `event`, and a
  `conditions` report.
- **`conditions`** is the evaluation report for that rule:
  - `changes` — the leaves that **passed**, in evaluation order.
  - `errors` — the leaves that **failed**.
  - `empty_values` — the leaves **short-circuited** before they were reached (an
    `all` stops at its first failure, an `any` at its first pass).
  - `result` — whether the rule's conditions as a whole were truthy.

Each leaf carries:

| Key          | Meaning                                                        |
| ------------ | -------------------------------------------------------------- |
| `fact`       | the fact the leaf reads                                         |
| `operator`   | the operator applied                                            |
| `value`      | the expected value the operator compared against (fact refs resolved) |
| `actual`     | the fact value the operator saw (the leaf's `path` applied)     |
| `factResult` | the raw computed fact value (before `path`)                     |
| `result`     | whether this leaf passed                                        |

A failing rule's failing leaves are in `conditions.errors` (with `result: false`);
a passing rule's leaves are in `conditions.changes`.

## A note on encodability

The report's `value`, `actual`, and `factResult` are the raw Elixir terms the engine
computed. The whole result is directly JSON-encodable as long as your facts produce
JSON-compatible data — string-keyed maps, lists, numbers, strings, booleans, and
`nil` (the normal case for JSON-derived facts). If a fact returns something
JSON-incompatible (an atom-keyed map, an atom, a function, ...), encode with a custom
`:json` encoder or normalize those values first.
