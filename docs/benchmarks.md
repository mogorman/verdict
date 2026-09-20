# Benchmarks

This project ships a benchmark suite built on
[Benchee](https://github.com/bencheeorg/benchee), runnable with `mix bench`. It is a
development tool only: the benchmark code lives in `bench/` and the task in
`lib/mix/tasks/bench.ex`, so neither is compiled into the shipped library.

```sh
mix deps.get
mix bench             # all three suites
mix bench schedule    # just one suite
mix bench store
mix bench fact
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

## Tuning

The suites use `time: 1, warmup: 0.5` (seconds) per scenario to keep a full run short.
To get tighter numbers, raise `time`/`warmup` in the suite's `Benchee.run/2` call, or
pass Benchee's `profile:`/`percentiles:` options. The workload sizes (`@scales`,
`@scale`, `@work`, `@width`) are module attributes at the top of each file under
`bench/` and can be tuned freely.

> **Note on absolute numbers:** results depend on the machine, its load, and the
> BEAM VM's warm-up state. Use them to compare *variants against each other* on the
> same machine, not as stable constants.
