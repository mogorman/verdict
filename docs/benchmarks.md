# Benchmarks

This project ships a benchmark suite built on
[Benchee](https://github.com/bencheeorg/benchee), runnable with `mix bench`. It is a
development tool only: the benchmark code lives in `bench/` and the task in
`lib/mix/tasks/bench.ex`, so neither is compiled into the shipped library.

```sh
mix deps.get
mix bench             # all six suites
mix bench schedule    # just one suite
mix bench store
mix bench fact
mix bench slowfacts
mix bench engines
mix bench matrix
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

### `mix bench matrix`

The other suites each isolate a single axis; this one **crosses all of them** — 192
scenarios at scale 100 — so their interactions show:

- **store** — `:pure` / `:genserver` / `:ets` (how rules and facts are held);
- **schedule** — `:serial` vs `:parallel`;
- **short-circuit** — `strict: false` (a decided `all`/`any` stops early) vs
  `strict: true` (every condition is evaluated);
- **fact speed** — cheap (`:fast`) vs expensive (`:slow`) tail fact;
- **fact caching** — cached vs `cache: false` (recomputed on every reference);
- **rule shape** — `JsonRules.Bench.Data.shapes/0`: a cheap deciding head over a tail
  of leaves at distinct priorities, in four geometries — `shallow` (narrow × flat,
  4 leaves), `wide` (wide × flat, 16 leaves), `nested` (narrow × nested, 4 leaves in
  `any` pairs), `wide_nested` (wide × nested, 16 leaves in `any` pairs). Flat vs
  nested keep the same number of leaves (identical leaf cost) and differ only in
  nesting depth; narrow vs wide differ in leaf count.

The result is one table per shape; rows within each are
`store × schedule × short-circuit × speed × cache` (48 rows).

#### `shallow` — narrow × flat

| store | schedule | short-circuit | speed | cache | avg (ms) |
| --- | --- | --- | --- | --- | ---: |
| `:pure` | serial | on | fast | cached | 0.805 |
| `:pure` | serial | on | fast | uncached | 0.749 |
| `:pure` | serial | on | slow | cached | 0.792 |
| `:pure` | serial | on | slow | uncached | 1.035 |
| `:pure` | serial | off | fast | cached | 1.828 |
| `:pure` | serial | off | fast | uncached | 1.694 |
| `:pure` | serial | off | slow | cached | 2.369 |
| `:pure` | serial | off | slow | uncached | 145.058 |
| `:pure` | parallel | on | fast | cached | 2.651 |
| `:pure` | parallel | on | fast | uncached | 2.696 |
| `:pure` | parallel | on | slow | cached | 1.817 |
| `:pure` | parallel | on | slow | uncached | 1.786 |
| `:pure` | parallel | off | fast | cached | 4.848 |
| `:pure` | parallel | off | fast | uncached | 2.306 |
| `:pure` | parallel | off | slow | cached | 3.121 |
| `:pure` | parallel | off | slow | uncached | 13.527 |
| `:genserver` | serial | on | fast | cached | 0.979 |
| `:genserver` | serial | on | fast | uncached | 0.947 |
| `:genserver` | serial | on | slow | cached | 0.890 |
| `:genserver` | serial | on | slow | uncached | 0.958 |
| `:genserver` | serial | off | fast | cached | 1.749 |
| `:genserver` | serial | off | fast | uncached | 1.798 |
| `:genserver` | serial | off | slow | cached | 2.459 |
| `:genserver` | serial | off | slow | uncached | 144.081 |
| `:genserver` | parallel | on | fast | cached | 1.657 |
| `:genserver` | parallel | on | fast | uncached | 1.807 |
| `:genserver` | parallel | on | slow | cached | 1.644 |
| `:genserver` | parallel | on | slow | uncached | 1.768 |
| `:genserver` | parallel | off | fast | cached | 2.560 |
| `:genserver` | parallel | off | fast | uncached | 2.349 |
| `:genserver` | parallel | off | slow | cached | 3.068 |
| `:genserver` | parallel | off | slow | uncached | 14.336 |
| `:ets` | serial | on | fast | cached | 1.287 |
| `:ets` | serial | on | fast | uncached | 1.320 |
| `:ets` | serial | on | slow | cached | 1.304 |
| `:ets` | serial | on | slow | uncached | 1.244 |
| `:ets` | serial | off | fast | cached | 2.632 |
| `:ets` | serial | off | fast | uncached | 2.191 |
| `:ets` | serial | off | slow | cached | 3.425 |
| `:ets` | serial | off | slow | uncached | 149.940 |
| `:ets` | parallel | on | fast | cached | 1.831 |
| `:ets` | parallel | on | fast | uncached | 1.917 |
| `:ets` | parallel | on | slow | cached | 1.842 |
| `:ets` | parallel | on | slow | uncached | 2.012 |
| `:ets` | parallel | off | fast | cached | 2.593 |
| `:ets` | parallel | off | fast | uncached | 2.471 |
| `:ets` | parallel | off | slow | cached | 3.176 |
| `:ets` | parallel | off | slow | uncached | 14.779 |

#### `wide` — wide × flat

| store | schedule | short-circuit | speed | cache | avg (ms) |
| --- | --- | --- | --- | --- | ---: |
| `:pure` | serial | on | fast | cached | 0.911 |
| `:pure` | serial | on | fast | uncached | 0.944 |
| `:pure` | serial | on | slow | cached | 0.962 |
| `:pure` | serial | on | slow | uncached | 0.943 |
| `:pure` | serial | off | fast | cached | 4.547 |
| `:pure` | serial | off | fast | uncached | 4.818 |
| `:pure` | serial | off | slow | cached | 5.682 |
| `:pure` | serial | off | slow | uncached | 562.714 |
| `:pure` | parallel | on | fast | cached | 1.901 |
| `:pure` | parallel | on | fast | uncached | 1.983 |
| `:pure` | parallel | on | slow | cached | 2.046 |
| `:pure` | parallel | on | slow | uncached | 2.057 |
| `:pure` | parallel | off | fast | cached | 4.869 |
| `:pure` | parallel | off | fast | uncached | 3.774 |
| `:pure` | parallel | off | slow | cached | 9.300 |
| `:pure` | parallel | off | slow | uncached | 48.758 |
| `:genserver` | serial | on | fast | cached | 1.486 |
| `:genserver` | serial | on | fast | uncached | 1.476 |
| `:genserver` | serial | on | slow | cached | 1.596 |
| `:genserver` | serial | on | slow | uncached | 1.697 |
| `:genserver` | serial | off | fast | cached | 4.788 |
| `:genserver` | serial | off | fast | uncached | 4.921 |
| `:genserver` | serial | off | slow | cached | 6.084 |
| `:genserver` | serial | off | slow | uncached | 564.671 |
| `:genserver` | parallel | on | fast | cached | 1.931 |
| `:genserver` | parallel | on | fast | uncached | 1.796 |
| `:genserver` | parallel | on | slow | cached | 3.722 |
| `:genserver` | parallel | on | slow | uncached | 2.045 |
| `:genserver` | parallel | off | fast | cached | 5.268 |
| `:genserver` | parallel | off | fast | uncached | 4.195 |
| `:genserver` | parallel | off | slow | cached | 10.902 |
| `:genserver` | parallel | off | slow | uncached | 49.204 |
| `:ets` | serial | on | fast | cached | 1.250 |
| `:ets` | serial | on | fast | uncached | 1.476 |
| `:ets` | serial | on | slow | cached | 1.252 |
| `:ets` | serial | on | slow | uncached | 1.260 |
| `:ets` | serial | off | fast | cached | 12.770 |
| `:ets` | serial | off | fast | uncached | 5.922 |
| `:ets` | serial | off | slow | cached | 6.718 |
| `:ets` | serial | off | slow | uncached | 626.851 |
| `:ets` | parallel | on | fast | cached | 3.221 |
| `:ets` | parallel | on | fast | uncached | 2.834 |
| `:ets` | parallel | on | slow | cached | 3.286 |
| `:ets` | parallel | on | slow | uncached | 2.630 |
| `:ets` | parallel | off | fast | cached | 5.391 |
| `:ets` | parallel | off | fast | uncached | 4.609 |
| `:ets` | parallel | off | slow | cached | 7.704 |
| `:ets` | parallel | off | slow | uncached | 47.421 |

#### `nested` — narrow × nested

| store | schedule | short-circuit | speed | cache | avg (ms) |
| --- | --- | --- | --- | --- | ---: |
| `:pure` | serial | on | fast | cached | 0.723 |
| `:pure` | serial | on | fast | uncached | 0.806 |
| `:pure` | serial | on | slow | cached | 0.750 |
| `:pure` | serial | on | slow | uncached | 1.328 |
| `:pure` | serial | off | fast | cached | 1.756 |
| `:pure` | serial | off | fast | uncached | 3.035 |
| `:pure` | serial | off | slow | cached | 2.285 |
| `:pure` | serial | off | slow | uncached | 143.349 |
| `:pure` | parallel | on | fast | cached | 1.559 |
| `:pure` | parallel | on | fast | uncached | 1.627 |
| `:pure` | parallel | on | slow | cached | 1.596 |
| `:pure` | parallel | on | slow | uncached | 1.649 |
| `:pure` | parallel | off | fast | cached | 2.923 |
| `:pure` | parallel | off | fast | uncached | 2.347 |
| `:pure` | parallel | off | slow | cached | 2.854 |
| `:pure` | parallel | off | slow | uncached | 23.152 |
| `:genserver` | serial | on | fast | cached | 0.956 |
| `:genserver` | serial | on | fast | uncached | 0.974 |
| `:genserver` | serial | on | slow | cached | 0.946 |
| `:genserver` | serial | on | slow | uncached | 0.918 |
| `:genserver` | serial | off | fast | cached | 2.048 |
| `:genserver` | serial | off | fast | uncached | 1.898 |
| `:genserver` | serial | off | slow | cached | 2.579 |
| `:genserver` | serial | off | slow | uncached | 141.542 |
| `:genserver` | parallel | on | fast | cached | 1.634 |
| `:genserver` | parallel | on | fast | uncached | 1.570 |
| `:genserver` | parallel | on | slow | cached | 3.039 |
| `:genserver` | parallel | on | slow | uncached | 1.624 |
| `:genserver` | parallel | off | fast | cached | 2.570 |
| `:genserver` | parallel | off | fast | uncached | 2.109 |
| `:genserver` | parallel | off | slow | cached | 3.136 |
| `:genserver` | parallel | off | slow | uncached | 13.932 |
| `:ets` | serial | on | fast | cached | 1.391 |
| `:ets` | serial | on | fast | uncached | 1.298 |
| `:ets` | serial | on | slow | cached | 1.212 |
| `:ets` | serial | on | slow | uncached | 1.217 |
| `:ets` | serial | off | fast | cached | 2.273 |
| `:ets` | serial | off | fast | uncached | 2.383 |
| `:ets` | serial | off | slow | cached | 2.877 |
| `:ets` | serial | off | slow | uncached | 143.272 |
| `:ets` | parallel | on | fast | cached | 1.944 |
| `:ets` | parallel | on | fast | uncached | 2.023 |
| `:ets` | parallel | on | slow | cached | 2.232 |
| `:ets` | parallel | on | slow | uncached | 2.637 |
| `:ets` | parallel | off | fast | cached | 3.179 |
| `:ets` | parallel | off | fast | uncached | 2.951 |
| `:ets` | parallel | off | slow | cached | 3.843 |
| `:ets` | parallel | off | slow | uncached | 15.190 |

#### `wide_nested` — wide × nested

| store | schedule | short-circuit | speed | cache | avg (ms) |
| --- | --- | --- | --- | --- | ---: |
| `:pure` | serial | on | fast | cached | 0.792 |
| `:pure` | serial | on | fast | uncached | 0.805 |
| `:pure` | serial | on | slow | cached | 0.777 |
| `:pure` | serial | on | slow | uncached | 0.802 |
| `:pure` | serial | off | fast | cached | 4.766 |
| `:pure` | serial | off | fast | uncached | 8.622 |
| `:pure` | serial | off | slow | cached | 6.068 |
| `:pure` | serial | off | slow | uncached | 566.010 |
| `:pure` | parallel | on | fast | cached | 1.740 |
| `:pure` | parallel | on | fast | uncached | 1.952 |
| `:pure` | parallel | on | slow | cached | 1.799 |
| `:pure` | parallel | on | slow | uncached | 1.856 |
| `:pure` | parallel | off | fast | cached | 5.325 |
| `:pure` | parallel | off | fast | uncached | 3.733 |
| `:pure` | parallel | off | slow | cached | 6.393 |
| `:pure` | parallel | off | slow | uncached | 50.345 |
| `:genserver` | serial | on | fast | cached | 0.975 |
| `:genserver` | serial | on | fast | uncached | 0.881 |
| `:genserver` | serial | on | slow | cached | 1.048 |
| `:genserver` | serial | on | slow | uncached | 0.911 |
| `:genserver` | serial | off | fast | cached | 7.042 |
| `:genserver` | serial | off | fast | uncached | 5.248 |
| `:genserver` | serial | off | slow | cached | 6.868 |
| `:genserver` | serial | off | slow | uncached | 557.658 |
| `:genserver` | parallel | on | fast | cached | 3.053 |
| `:genserver` | parallel | on | fast | uncached | 2.121 |
| `:genserver` | parallel | on | slow | cached | 2.232 |
| `:genserver` | parallel | on | slow | uncached | 2.126 |
| `:genserver` | parallel | off | fast | cached | 8.780 |
| `:genserver` | parallel | off | fast | uncached | 4.331 |
| `:genserver` | parallel | off | slow | cached | 6.805 |
| `:genserver` | parallel | off | slow | uncached | 51.983 |
| `:ets` | serial | on | fast | cached | 1.439 |
| `:ets` | serial | on | fast | uncached | 1.338 |
| `:ets` | serial | on | slow | cached | 3.186 |
| `:ets` | serial | on | slow | uncached | 1.402 |
| `:ets` | serial | off | fast | cached | 12.235 |
| `:ets` | serial | off | fast | uncached | 7.431 |
| `:ets` | serial | off | slow | cached | 8.130 |
| `:ets` | serial | off | slow | uncached | 639.938 |
| `:ets` | parallel | on | fast | cached | 3.511 |
| `:ets` | parallel | on | fast | uncached | 2.579 |
| `:ets` | parallel | on | slow | cached | 2.884 |
| `:ets` | parallel | on | slow | uncached | 6.106 |
| `:ets` | parallel | off | fast | cached | 13.122 |
| `:ets` | parallel | off | fast | uncached | 10.347 |
| `:ets` | parallel | off | slow | cached | 7.461 |
| `:ets` | parallel | off | slow | uncached | 55.265 |

What the full matrix shows:

- **Short-circuit is the dominant lever** — with it on, every shape/store/schedule
  collapses to ~0.7-1.5 ms (the tail is never evaluated); turning it off (`strict`)
  is where all the cost lives.
- **Width dominates when the tail is evaluated** — under `strict` + `slow` +
  `uncached` + `serial`, wide is ~4x slower than narrow (562-640 ms vs 143-150 ms).
  Width is irrelevant under short-circuit.
- **Nesting ≈ flat at equal leaf count** — `nested` ≈ `shallow`, `wide_nested` ≈
  `wide`; the `any` grouping adds only structural overhead, not leaf cost.
- **Caching only matters for a slow fact that is evaluated** — `strict` + `slow` +
  `serial`: ~5 ms cached vs 143-640 ms uncached (~30-100x).
- **`:parallel` rescues `strict` + `slow` + `uncached`** (~10-11x) by overlapping the
  recomputation, but *loses* under short-circuit (little to overlap).
- **Store**: `:pure` < `:genserver` < `:ets` under short-circuit/serial; the gap
  shrinks as the fact cost dominates and vanishes under `:parallel`.

> Same 24-core machine as above. The extreme cells (`strict` + `slow` + `uncached`,
> especially `wide`/`wide_nested`) take hundreds of ms per run, so Benchee collects
> only a few samples there — read those as order-of-magnitude. Re-run `mix bench
> matrix` on your own before choosing a configuration.

## Tuning

The suites use `time: 1, warmup: 0.5` (seconds) per scenario to keep a full run short.
To get tighter numbers, raise `time`/`warmup` in the suite's `Benchee.run/2` call, or
pass Benchee's `profile:`/`percentiles:` options. The workload sizes (`@scales`,
`@scale`, `@work`, `@width`) are module attributes at the top of each file under
`bench/` and can be tuned freely.

> **Note on absolute numbers:** results depend on the machine, its load, and the
> BEAM VM's warm-up state. Use them to compare *variants against each other* on the
> same machine, not as stable constants.
