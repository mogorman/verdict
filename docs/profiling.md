# Profiling

Where the time actually goes inside `Engine.run/3`. This is the complement to
[benchmarks](benchmarks.md): benchmarks answer *how fast is a scenario*; profiling
answers *what the engine is spending its time on*, so we know what to optimize.

It is a development tool only. `mix bench profile` runs OTP's statistical profiler
(`:tprof`, from the `tools` application) over four representative workloads and
reports, per function, how much of the run's time was spent in it. The harness lives
in `bench/profile.ex` (`Verdict.Bench.Profile`) and the task in
`lib/mix/tasks/bench.ex`, so neither is compiled into the shipped library. `:tprof`
is declared as an application in `mix.exs` (`extra_applications`); it is a standard
OTP app and is used nowhere else in the project.

## Running it

```sh
mix bench profile
```

Prints one table per workload to stdout and writes the full table for each to
`bench/profile/<label>.txt` (gitignored). Absolute figures depend on the machine; the
*relative* split is what matters, and the tables below are illustrative, not
guaranteed.

## How it works

For each workload it:

1. **Builds the engine once** — facts and rules registered up front, exactly as in the
   benchmarks, so `Engine.run/3` (not setup) is what's measured.
2. **Warm-up runs** — let the BEAM settle (atom cache, code paths) before sampling.
3. **Profiles a batch of `Engine.run/3` calls** with `:tprof.profile/2` and
   `type: :call_time` — a *sampled*, statistical profile that reports the time spent
   in each function inclusive of its callees. Sampling means small numbers jitter;
   read the table, not the units.
4. **Renders the top functions** with `:tprof.inspect/3` (by total time, descending)
   and `:tprof.format/1`.

The four workloads are chosen to stress different parts of the engine:

| label                | workload                                              | stresses                        |
| -------------------- | ----------------------------------------------------- | ------------------------------- |
| `serial_wide_fast`   | 200 rules × 20 conditions, serial, pure store          | leaf volume (operators + maps)  |
| `serial_realistic`   | the realistic 200-rule transaction-risk ruleset, serial | JSONPath fact references       |
| `serial_shortcircuit`| 500 rules, tail width 3, serial                        | short-circuit + JSONPath        |
| `parallel_wide_fast` | 200 wide/fast matrix rules, `:parallel` + shared almanac | per-rule tasks + GenServer   |

## Reading a table

```
FUNCTION                              CALLS  TIME (us)  PER CALL  [    %]
```

- **CALLS** — how many times the function ran over the whole profiled batch.
- **TIME (us)** — total microseconds spent *in* that function including its callees
  (`call_time`), so a parent and its children can both look big.
- **PER CALL** — `TIME / CALLS`. A high per-call cost on a rarely-called function is a
  different problem (a slow one-off) than a low per-call cost on a
  millions-of-times function (a tight loop that adds up).
- **[ % ]** — the function's share of total profiled time. Read top-to-bottom; the
  first ~15 rows usually hold 60%+ of the cost.

## What the profile shows

Top rows for each workload (full tables in `bench/profile/<label>.txt`). This is the state
**after** the two highest-impact fixes (see [What was addressed](#what-was-addressed) below):
the JSONPath re-parse is gone and explanation strings are built once per leaf, so what
remains is the per-leaf result/map work, the combinator's multi-pass, and — in parallel —
the per-rule task machinery.

`serial_wide_fast` — the explanation cluster (now one `inspect` per operand) is still the
largest cost, with the per-leaf map/result work close behind:

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
'Elixir.Inspect.Algebra':format/4          6400000     521762      0.08  [ 5.31]
'Elixir.Kernel':inspect/2                  1600000     404248      0.25  [ 4.12]
lists:do_flatten/2                         5040600     356770      0.07  [ 3.63]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2    2721200     317075      0.12  [ 3.23]
'Elixir.Keyword':get/3                     3202800     316476      0.10  [ 3.22]
'Elixir.Verdict.Evaluation':leaf/2          800000     306742      0.38  [ 3.12]
'Elixir.Inspect.Integer':inspect/2         1600000     263636      0.16  [ 2.68]
'Elixir.Inspect':inspect/2                 1600000     263230      0.16  [ 2.68]
'Elixir.Inspect.Opts':default_inspect_fun/0 1600000    260329      0.16  [ 2.65]
'Elixir.Map':get/3                         1600000     205060      0.13  [ 2.09]
```

`serial_realistic` — with the JSONPath parse gone, the string-explanation cluster and the
combinator/map work are the top costs:

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2    2593360     255716      0.10  [ 4.76]
lists:do_flatten/2                         2951795     197906      0.07  [ 3.68]
'Elixir.Inspect.Algebra':format/4          2513665     185014      0.07  [ 3.44]
'Elixir.Inspect.BitString':inspect/2        205205     148117      0.72  [ 2.76]
'Elixir.Kernel':inspect/2                   462000     133409      0.29  [ 2.48]
'Elixir.Code.Identifier':escape/5          1051050     132273      0.13  [ 2.46]
'Elixir.Verdict.Evaluation':combinator/4    179410     114355      0.64  [ 2.13]
'Elixir.Keyword':get/3                    1236620     113958      0.09  [ 2.12]
'Elixir.Inspect':inspect/2                  564410     107992      0.19  [ 2.01]
'Elixir.Verdict.Log':'emit?'/2              565180     104824      0.19  [ 1.95]
```

`serial_shortcircuit` — now dominated by the combinator's multi-pass and the per-leaf
map/list allocation (the former JSONPath rows are gone):

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
lists:do_flatten/2                         7132139     697281      0.10  [ 5.55]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2    6064778     608520      0.10  [ 4.84]
'Elixir.Verdict.Evaluation':'-combinator/4-fun-1-'/2 1426000 469929  0.33  [ 3.74]
erlang:binary_to_atom/1                     356500     333917      0.94  [ 2.66]
'Elixir.Keyword':get/3                    1435982     311216      0.22  [ 2.48]
'Elixir.Enum':flat_map/2                   713000     303713      0.43  [ 2.42]
'Elixir.Verdict.Evaluation':leaf_descriptor/1 1069500  300661    0.28  [ 2.39]
'Elixir.Verdict.Evaluation':combinator/4    356500     282011      0.79  [ 2.25]
'Elixir.Enum':'-group_by/3-fun-0-'/4       1782500     280999      0.16  [ 2.24]
'Elixir.Inspect.Algebra':format/4          2852000     258476      0.09  [ 2.06]
```

`parallel_wide_fast` — the parallel machinery (a `Task` per rule, GenServer round-trips)
now dominates even more clearly than the rules:

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
gen:do_call/4                              1361000    1555207      1.14  [ 6.90]
erlang:send/3                              1360800     972553      0.71  [ 4.32]
gen:reply/2                                1361000     899010      0.66  [ 3.99]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2   4481000     712493      0.16  [ 3.16]
'Elixir.Inspect.Algebra':format/4          5440000     670388      0.12  [ 2.98]
lists:do_flatten/2                         6960000     630240      0.09  [ 2.80]
erlang:monitor/3                           1360800     605399      0.44  [ 2.69]
erlang:demonitor/2                         1361200     586466      0.43  [ 2.60]
'Elixir.Task.Supervised':stream_spawn/4     40000     555033     13.88  [ 2.46]
gen_server:loop/5                          1361000     548313      0.40  [ 2.43]
```

## Optimization opportunities

What is left to win, ranked by the share of time it represents in the profile above.

### 1. The combinator: one pass, not five — the top serial cost

`combinator/4` (evaluation.ex:130–166) re-sorts the children by priority on every
evaluation (`group_by` + `sort_by` + `flatten`), then walks the results in **five**
separate `Enum.map`/`List.flatten` passes to gather `changes`, `errors`, `facts`, and
`empty_values`; `merge_maps/1` folds the fact maps with O(n²) `Map.merge`s. It is now the
largest serial cost — `serial_shortcircuit`'s top rows are all of it:
`lists:do_flatten/2` 5.6%, `Enum:map/2` 4.8%, `combinator/4-fun-1/2` 3.7%,
`Enum:flat_map/2` 2.4%, `combinator/4` 2.3%, `group_by` 2.2% — the tell-tale
`-combinator/4-fun-N-/1` family. A single fold that accumulates all four lists at once,
sorting only when the children aren't already in priority order, and building the fact
map in one reduce, removes most of it.

`leaf/2` (evaluation.ex:81–104) is the same tier: it allocates a
`%{facts: %{field => fact_value}}` map and a `%Ecto.Changeset{}` struct per leaf, plus
`String.to_atom/1` per run. It's harder to improve without changing the result shape,
so treat it as second-order.

### 2. Parallel: the per-rule task and the shared-almanac round-trips

`parallel_wide_fast` is now even more clearly the parallel machinery than the rules:
`gen:do_call/4` 6.9%, `erlang:send/3` 4.3%, `gen:reply/2` 4.0%, `erlang:monitor/3` 2.7%,
`erlang:demonitor/2` 2.6%, `Task.Supervised.stream_spawn/4` 2.5%, `gen_server:loop/5`
2.4% — a `Task` is spawned **per rule** (`Task.async_stream`) and every fact lookup
round-trips a GenServer call to the shared almanac. This is the same trade-off the
[schedule suite](benchmarks.md) makes visible: at these sizes the overhead dominates.
Give each worker a **local snapshot** of facts (a plain map, a `:persistent_term`, or
per-process ETS) instead of a GenServer call, and evaluate in-process when the rule count
is too small for per-rule `Task`s to pay for themselves.

## What was addressed

Two of the former top costs are fixed; re-profiling the same workloads confirms it:

- **Operator explanations built once, not twice.** The built-in operators used to
  `inspect` both operands twice and build both the pass and fail strings, discarding one
  (`res/3`/`f/1`). They now `inspect` each operand once and build only the branch taken.
  In `serial_wide_fast` `Kernel.inspect/2` fell from 3.2M to 1.6M calls for the same 800k
  leaves (4 → 2 per leaf) and the workload's profiled time dropped ~28%
  (13.6M → 9.8M µs).
- **JSONPath compiled once, not per fact reference.** Each leaf's path was handed to
  `JSONPath.values/2` as a raw string and re-parsed/validated on every leaf. It is now
  precompiled to an AST at rule-registration (`Verdict.Types.Condition`) and evaluated
  from the AST. `JSONPath.AST.validation/2` went from 14.3% of `serial_shortcircuit`
  (17.5M calls) and 6.1% of `serial_realistic` to **absent** from every workload, and
  `parallel_wide_fast`'s profiled time dropped ~23% (29.2M → 22.5M µs).

The lazy-explanation variant — building the string only when a failing leaf is actually
reported — is still on the table if the residual explain cost ever becomes worth chasing.

## Caveats

- `:tprof` is **statistical** (sampled), not deterministic — repeat a run to confirm a
  hotspot, and don't chase differences below ~1%.
- `call_time` counts a function *and* everything it calls, so parent and child rows
  overlap; use **PER CALL** to tell a genuinely expensive function from one that merely
  calls expensive things.
- The workloads here are fixed. To profile a real ruleset, add a case to
  `Verdict.Bench.Profile.profiles/0` (a label, an engine builder, a schedule, and a
  run count) and re-run `mix bench profile`.
