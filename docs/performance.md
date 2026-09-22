# Performance

This page summarizes the engine's performance **characteristics** and how to pick
configuration options. For reproducible, per-scenario numbers use the benchmark
suite: `mix bench` (see `benchmarks.md`). Absolute figures depend on the machine,
its load, and the BEAM VM's warm-up state — treat them as relative, not as stable
constants.

## A reference point

Running **1000 two-condition rules** over two cached constant facts on a single
process takes on the order of **single-digit milliseconds** (a couple of ms for `any`,
~8 ms for `all`, measured locally). The evaluation core is pure and allocation-light;
a rule's cost is dominated by its condition tree, the facts it reads, and the
operator work.

A lightweight sanity test (`test/json_rules/engine_performance_test.exs`) re-checks
that a 1000-rule run both returns the right results and stays well under a generous
budget, so a catastrophic regression (an accidental quadratic, a runaway) fails CI
rather than shipping silently. It is deliberately loose so it does not flake.

## Choosing a store

The store is selected at construction and affects how rules/facts are held, not how
they are evaluated. Overhead, lowest first:

| Backend      | What it is                                   | When to use                                |
| ------------ | -------------------------------------------- | ------------------------------------------ |
| `:pure`      | a plain struct, no process (default)         | the common case; no shared mutable state   |
| `:genserver` | rules/facts in a GenServer's state           | when you need a supervised, addressable store |
| `:ets`       | a GenServer with rules/facts in ETS tables   | very large rule sets or many readers       |

If you do not need a shared, long-lived store, stay on `:pure` — it is the fastest
and has the least machinery.

## Serial vs parallel

Scheduling is orthogonal to the store (`:serial` is the default).

- **`:serial`** evaluates priority buckets one rule at a time. It has no extra
  machinery and is the right default.
- **`:parallel`** runs the rules within each priority bucket concurrently over a
  *shared* almanac (a short-lived GenServer). Constant facts are read from a
  per-bucket snapshot held in each worker, so they need no round-trip; only
  dynamic-fact lookups round-trip through the shared process.

`:parallel` only wins when there is enough **independent, expensive** work to overlap
— i.e. many rules, each with a wide condition tree or an expensive dynamic fact. For
cheap, narrow rules the per-rule task overhead (and any dynamic-fact round-trips)
dominate and `:parallel` is *slower* than `:serial`. The `mix bench schedule` suite
(wide vs narrow rules at several scales) exists to make that trade-off visible on your
machine rather than to crown a universal winner.

## Facts

- **Constant facts** are stored values: reading one is O(1).
- **Dynamic facts** (a `(params, almanac)` function) are **cached per run by default**,
  so each unique `{fact, params}` is computed once no matter how many conditions read
  it.
- Passing `cache: false` recomputes a dynamic fact on **every** reference — useful when
  the fact's value can change mid-run, but it multiplies the cost by the number of
  references. An expensive dynamic fact with `cache: false` is the single biggest
  per-rule cost; under `:parallel` that work can be overlapped across workers, which
  the `mix bench fact` suite shows.

## Rules of thumb

- Default to `:pure` + `:serial`; change only with a measured reason.
- Prefer cached dynamic facts over `cache: false` unless the value genuinely changes
  during a run.
- Reach for `:parallel` only for large batches of expensive, independent rules, and
  confirm it with `mix bench schedule` on a machine that resembles production.
