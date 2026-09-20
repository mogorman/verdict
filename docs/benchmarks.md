# Benchmarks

This project ships a benchmark suite built on
[Benchee](https://github.com/bencheeorg/benchee), runnable with `mix bench`. It is a
development tool only: the benchmark code lives in `bench/` and the task in
`lib/mix/tasks/bench.ex`, so neither is compiled into the shipped library.

```sh
mix deps.get
mix bench             # all four suites
mix bench schedule    # just one suite
mix bench store
mix bench fact
mix bench slowfacts
```

Each suite prints a Benchee console table and writes two artifacts to
`bench/results/`:

- `<suite>.csv` — one row per scenario: `name, ips, average_ms, median_ms,
  deviation_pct, p99_ms, samples`. Diff-able, so it's friendly to review in a PR or
  track over time.
- `<suite>/` — an [**`benchee_html`](https://hex.pm/packages/benchee_html) report:
  open `<suite>/index.html` for the index, with a comparison page and a detail page
  (with graphs) per scenario, plus a shared `assets/` folder.

`bench/results/` is gitignored; the artifacts are for local inspection.

## How a suite is structured

Every suite follows the same shape:

1. **Build the engines up front.** Facts and rules are registered *before* the timed
   closure, so `Engine.run/3` — not setup — is what gets measured.
2. **Benchmark `Engine.run/3`.** Each Benchee scenario is a name and a closure that
   calls `Engine.run/3` on a pre-built engine.
3. **Write the report.** The HTML report is written by the `benchee_html` formatter
   (passed in `formatters:`). The `%Benchee.Suite{}` returned by `Benchee.run/2` is
   also fed to `JsonRules.Bench.Report`, which writes the CSV.

Benchee 1.5+ ships only a console formatter and a tagged-suite saver, so the HTML
report comes from the official [`benchee_html`](https://hex.pm/packages/benchee_html)
plugin. There is no first-party CSV formatter, so `bench/report.ex`
(`JsonRules.Bench.Report`) reads the suite's run-time statistics and writes the CSV —
see it for the column definitions.

## The suites

### `mix bench schedule`

`:serial` vs `:parallel` across two axes:

- **scale** — the number of rules: `50`, `200`, `1000`.
- **distribution** — `wide` (20 conditions per rule, so each rule is expensive) vs
  `narrow` (2 conditions per rule, so each rule is cheap).

`:parallel` only helps when there is enough independent, expensive work to overlap.
`wide` is the case where it should win; `narrow` shows whether the parallel
machinery's overhead (a per-run shared-almanac GenServer that every fact lookup
round-trips through) wins out when the rules are cheap. On a single machine, at these
sizes the shared-almanac round-trips typically make `:parallel` *slower* — the point
of the suite is to make that trade-off visible, not to crown a winner.

### `mix bench store`

The three store backends — `:pure`, `:genserver`, `:ets` — at a fixed workload (200
rules, 2 conditions each). Each backend's engine (and its backing process, for
`:genserver`/`:ets`) is built once and reused across iterations. Expect
`:pure` (a plain struct) to be fastest, with `:ets` the slowest of the three.

### `mix bench fact`

Fact computation cost, crossed with schedule:

- **fact** — `constant` (a precomputed term, O(1) to read) vs `dynamic` (an O(n)
  reduction, `cache: false` so it is recomputed on *every* rule reference rather than
  once per run).
- **schedule** — `:serial` vs `:parallel`.

A `:serial` run pays an expensive fact's cost straight-line (once per rule); a
`:parallel` run overlaps that work across worker processes (each worker computes the
fact in its own process), so it can hide much of the cost. The gap between
`serial/dynamic` and `parallel/dynamic` is the story the suite tells.

### The `Data` dataset

The earlier suites build rules over a synthetic `f1..f20` fact set.
`bench/data.ex` (`JsonRules.Bench.Data`) is a **realistic, reusable** dataset — a
transaction-risk ruleset — used by the `slowfacts` suite:

- **structured facts** (`transaction`, `customer`) read with JSONPath `path`s,
  plus scalar facts;
- a **mix of operators** (`greaterThanInclusive`, `notEqual`, `lessThanInclusive`,
  `in`, `contains`), `all`/`any` trees, priorities, and a **named condition**
  (`high_risk`) referenced with `condition:`;
- a **slow fact** (`fraud_score`): a constant by default, or (with `slow: true`)
  an expensive `cache: false` dynamic fact that returns the *same* value as the
  constant but costs real work to compute — so the fast and slow engines evaluate
  the identical rules and differ only in computation cost.

`Data.engine(count, opts)` builds a fully-populated engine for `count` rules
(options: `:store`, `:slow`, `:work`).

### `mix bench slowfacts`

The `schedule` suite uses cheap, constant facts, so `:parallel` only shows its
overhead. This suite flips that: it runs the realistic `Data` dataset with an
**expensive `fraud_score`** recomputed on every rule reference. `:serial` pays that
cost straight-line; `:parallel` overlaps it across worker processes.

- **scale** — number of rules: `100`, `500`, `2000`.
- **speed** — `slow` (expensive `fraud_score`) vs `fast` (a constant, the baseline).
- **schedule** — `:serial` vs `:parallel`.

This is where `:parallel` is expected to **win**, and it does — the speedup grows
with scale because there is more independent work to overlap:

| scale | serial avg | parallel avg | parallel vs serial |
| ---: | ---: | ---: | ---: |
| 100 | 37.9 ms | 6.7 ms | ~5.6x faster |
| 500 | 185.9 ms | 24.2 ms | ~7.7x faster |
| 2000 | 772.6 ms | 84.3 ms | ~9.2x faster |

With the `fast` baseline the relationship inverts — `:parallel` is *slower* (its
shared-almanac overhead dominates when facts are cheap) — so the `schedule` and
`slowfacts` suites together make the full crossover visible: cheap rules favour
`:serial`, expensive independent facts favour `:parallel`.

> The table above is from a 24-core Ryzen 9 5900X; re-run `mix bench slowfacts` on
> a machine that resembles production before choosing a schedule.

### `mix bench engines`

The `slowfacts` suite leaves short-circuiting on. This suite adds the
**short-circuit** axis (`strict`) to show the advantage of each engine
configuration. Its dataset (`JsonRules.Bench.Data.engines_engine/2`) gives every
rule a cheap head that decides its `all` early, followed by an expensive tail of
slow `fraud_score` conditions:

- **short-circuit** (`strict: false`, the default) stops the `all` at the failing
  head and **skips the tail**;
- **strict** (`strict: true`) evaluates every condition, for a complete report.

Axes: `strict` × `scale` (100/500/2000) × `schedule` (serial/parallel), with 3 slow
conditions in each rule's tail.

| config | scale 100 | scale 500 | scale 2000 |
| --- | ---: | ---: | ---: |
| short-circuit, serial | 0.74 ms | 3.52 ms | 16.44 ms |
| short-circuit, parallel | 1.65 ms | 7.89 ms | 32.81 ms |
| strict, serial | 105.6 ms | 530.4 ms | 2122.6 ms |
| strict, parallel | 11.1 ms | 45.6 ms | 189.3 ms |

Three advantages fall out of the matrix:

- **Short-circuit is the biggest lever** — skipping the tail makes it ~130-140x
  faster than `strict` at the same scale. Use it whenever you do not need every
  condition's result.
- **Under short-circuit, `:serial` beats `:parallel`** (~2x) — once the tail is
  skipped there is little independent work to overlap, so the parallel machinery's
  overhead wins out.
- **Under `strict`, `:parallel` wins** (~9.5-11.6x) — it *must* evaluate the
  expensive tail and overlaps that work across workers. This is the parallel
  engine's advantage: complete evaluation of expensive rules.

> Same 24-core machine as above; re-run `mix bench engines` on your own before
> choosing an engine.

## Tuning

The suites use `time: 1, warmup: 0.5` (seconds) per scenario to keep a full run short.
To get tighter numbers, raise `time`/`warmup` in the suite's `Benchee.run/2` call, or
pass Benchee's `profile:`/`percentiles:` options. The workload sizes (`@scales`,
`@scale`, `@work`, `@width`) are module attributes at the top of each file under
`bench/` and can be tuned freely.

> **Note on absolute numbers:** results depend on the machine, its load, and the
> BEAM VM's warm-up state. Use them to compare *variants against each other* on the
> same machine, not as stable constants.
