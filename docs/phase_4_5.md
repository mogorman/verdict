# Phase 4.5 — operator behaviors, benchmarks, and coverage

Phase 4.5 rounds out the operator model and adds two development tools that make
the engine easier to reason about over time:

- **Operator behaviors** — a custom operator may supply its **own explanation**
  (so the failure report reads in your domain's language) and may be
  **parameterized** by the condition that uses it (a 3-arity operator receives the
  condition's `params`).
- **Benchmarks** — a `mix bench` task built on [Benchee](https://github.com/bencheeorg/benchee)
  that measures scheduling, store backends, and fact cost.
- **Coverage** — [ExCoveralls](https://hex.pm/packages/excoveralls) with a coverage
  **ratchet** that fails the build if coverage regresses, posting to
  [coveralls.io](https://coveralls.io) in CI.

The evaluation core is unchanged; the operator contract simply widened. See
[benchmarks](./benchmarks.md) for the benchmark suite and
[architecture](./architecture.md) for the operator types.

## What this phase delivers

- **Custom explanations** — a custom operator may return `{passed?, explanation}`
  instead of a bare boolean; the explanation is used verbatim in the report.
- **Parameterized operators** — a custom operator may be 3-arity
  `(fact_value, json_value, params)`; the condition's `params` are handed to it.
- **`mix bench`** — three Benchee suites (`schedule`, `store`, `fact`), each writing
  a diff-able CSV and a [`benchee_html`](https://hex.pm/packages/benchee_html) report
  to `bench/results/`.
- **Coverage + ratchet** — `mix coveralls`/`mix coveralls.html` locally, a
  `minimum_coverage` ratchet in `coveralls.json`, and a `coverage` job in CI.

## Operator behaviors

### Custom explanations

Every operator in the reference engine produces a boolean, and the engine synthesizes
a generic explanation for the report. That is fine for built-ins, but a custom
operator knows *why* a value failed — so it can say so. Return a
`{passed?, explanation}` tuple and that text is used verbatim:

```elixir
engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_operator("startsWithLetter", fn fact_value, _letter ->
    {fact_value |> to_string() |> String.first() == "t",
     "value must start with the letter t"}
  end)

{:ok, engine, _} =
  Verdict.Engine.add_rule(engine, %{
    event: %{type: "op"},
    conditions: %{all: [%{fact: "name", operator: "startsWithLetter", value: "t"}]}
  })

%{results: [%{changeset: cs, valid?: false}]} = Verdict.Engine.run(engine, %{name: "nope"})
cs.errors #=> [{:name, {"value must start with the letter t", [operator: "startsWithLetter", ...]}]}
```

A custom operator that returns a **bare boolean** (as before) still works and gets a
generated explanation. Decorators and `decorator:…:operator` composites keep
generating their explanations as before; the verbatim-explanation behavior applies to
an undecorated custom operator.

### Parameterized operators

A 3-arity custom operator receives the condition's `params` map. This lets one
operator be configured per condition — the reference engine's idea of operator
parameters. The example below registers a single `inRange` operator and configures its
bounds with `params`:

```elixir
# A 3-arity operator: (fact_value, json_value, params) -> {passed?, explanation}
in_range = fn fact_value, _json_value, params ->
  min = params[:min]
  max = params[:max]
  ok = is_number(fact_value) and fact_value >= min and fact_value <= max

  {ok,
   "#{fact_value} #{if ok, do: "is within", else: "is outside"} [#{min}..#{max}]"}
end

engine =
  Verdict.Engine.new()
  |> Verdict.Engine.add_operator("inRange", in_range)

{:ok, engine, _} =
  Verdict.Engine.add_rule(engine, %{
    event: %{type: "in-band"},
    # the operator's bounds come from `params`, not from the condition `value`
    conditions: %{all: [%{fact: "score", operator: "inRange", value: nil, params: %{min: 5, max: 10}}]}
  })

Verdict.Engine.run(engine, %{score: 7})  #=> fires (7 is within [5..10])
Verdict.Engine.run(engine, %{score: 12}) #=> fails, error reads "12 is outside [5..10]"
```

Both features compose: the `inRange` operator above is *both* parameterized (it reads
`params`) *and* explanatory (it returns a tuple).

## Benchmarks

`mix bench` runs three suites. Each engine and fact set is built **outside** the timed
closure, so only `Engine.run/3` is measured. Each suite prints a console table and
writes `bench/results/<suite>.csv` plus a [`benchee_html`](https://hex.pm/packages/benchee_html)
report at `bench/results/<suite>/index.html`.

| Target            | Measures                                                                   |
| ----------------- | --------------------------------------------------------------------------- |
| `mix bench`       | all three                                                                    |
| `mix bench schedule` | `:serial` vs `:parallel` across rule count (scale) and per-rule width (distribution) |
| `mix bench store`   | the `:pure` / `:genserver` / `:ets` store backends at a fixed workload        |
| `mix bench fact`    | a constant fact vs an expensive dynamic fact, crossed with schedule          |

For details, tuning knobs, and how to read the output, see [benchmarks](./benchmarks.md).

## Coverage

ExCoveralls reports line coverage of the library (the `lib/mix/tasks/` benchmark
task is excluded — see `coveralls.json`). Run it locally:

```sh
mix coveralls        # console table
mix coveralls.html   # + an HTML report in cover/
```

A **ratchet** is set in `coveralls.json` under `coverage_options.minimum_coverage`
(currently `78.0`): `mix coveralls*` exits non-zero if coverage drops below it, so a
regression fails the build. Raise the ratchet as coverage improves.

CI runs a `coverage` job that reports + enforces the ratchet and posts to
coveralls.io via `mix coveralls.github` (the repo must be connected to
[Coveralls](https://coveralls.io) for the posting step).

## Where this fits

Phase 4.5 layers operator ergonomics and development tooling on the
[Phase 1](./phase_1.md) / [Phase 2](./phase_2.md) / [Phase 3](./phase_3.md) /
[Phase 4](./phase_4.md) core — same evaluator, almanac, store, and changeset report.
The operator contract is a **superset** of the earlier one: existing 2-arity,
boolean-returning custom operators and decorators are unaffected.
