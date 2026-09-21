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

Top rows for each workload (full tables in `bench/profile/<label>.txt`):

`serial_wide_fast` — dominated by building operator explanation strings:

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
'Elixir.Inspect.Algebra':format/4         12800000    1010239      0.08  [7.43]
'Elixir.Kernel':inspect/2                  3200000     790378      0.25  [5.81]
'Elixir.Inspect.Integer':inspect/2         3200000     521272      0.16  [3.83]
'Elixir.Inspect.Opts':default_inspect_fun/0 3200000    487666      0.15  [3.59]
'Elixir.Keyword':get/3                     4802800     479771      0.10  [3.53]
'Elixir.Inspect':inspect/2                 3200000     357847      0.11  [2.63]
'Elixir.Inspect.Opts':new/1                3200000     342545      0.11  [2.52]
lists:do_flatten/2                         5040600     340922      0.07  [2.51]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2    2721200     313574      0.12  [2.31]
'Elixir.Verdict.Evaluation':leaf/2          800000     311402      0.39  [2.29]
```

`serial_realistic` — dominated by re-parsing JSONPath on every fact reference:

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
'Elixir.Enumerable.List':reduce/3         5434800     377138      0.07  [6.53]
'Elixir.JSONPath.AST':validation/2        4795200     350125      0.07  [6.06]
'Elixir.JSONPath.AST':'-validation/2-fun-0-'/3 3196800  254044   0.08  [4.40]
'Elixir.Inspect.Algebra':format/4         2611600     224018      0.09  [3.88]
'Elixir.Enumerable':reduce/3              1665200     146729      0.09  [2.54]
'Elixir.Enum':reduce_while/3              1665200     137405      0.08  [2.38]
'Elixir.Enumerable':'impl_for!'/1         1705200     136221      0.08  [2.36]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2   1347200     133186      0.10  [2.30]
'Elixir.Code.Identifier':escape/5         1092000     130186      0.12  [2.25]
'Elixir.Kernel':inspect/2                  480000     125978      0.26  [2.18]
```

`serial_shortcircuit` — the same JSONPath cost, larger still (17.5M path validations):

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
'Elixir.JSONPath.AST':validation/2       17568000    2633293      0.15  [14.26]
'Elixir.Enumerable.List':reduce/3       20008488    1435747      0.07  [ 7.77]
'Elixir.JSONPath.AST':'-validation/2-fun-0-'/3 11712000  935352  0.08  [ 5.06]
'Elixir.Enumerable':reduce/3             6100488     540907      0.09  [ 2.93]
'Elixir.Enum':reduce_while/3             6100488     539395      0.09  [ 2.92]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2  4150928     505907      0.12  [ 2.74]
'Elixir.Enumerable':'impl_for!'/1        6100488     489748      0.08  [ 2.65]
'Elixir.Keyword':get/3                   1958832     400347      0.20  [ 2.17]
'Elixir.Inspect.Integer':inspect/2        976000     370310      0.38  [ 2.00]
'Elixir.Inspect.Algebra':format/4         3904000     354576      0.09  [ 1.92]
```

`parallel_wide_fast` — the parallel machinery (a `Task` per rule, GenServer round-trips)
plus the same explanation-string cost:

```
FUNCTION                                   CALLS  TIME (us)  PER CALL  [   %]
gen:do_call/4                              1361004    1569637      1.15  [ 5.37]
'Elixir.Inspect.Algebra':format/4        10880000    1257342      0.12  [ 4.30]
'Elixir.Kernel':inspect/2                 2720000    1041284      0.38  [ 3.56]
erlang:send/3                              1360804    1015498      0.75  [ 3.47]
lists:keyfind/3                            4165400     997282      0.24  [ 3.41]
gen:reply/2                                1361004     970562      0.71  [ 3.32]
'Elixir.Enum':'-map/2-lists^map/1-1-'/2   4481000     713006      0.16  [ 2.44]
gen_server:loop/5                          1361004     661322      0.49  [ 2.26]
lists:do_flatten/2                         6960000     636764      0.09  [ 2.18]
'Elixir.Inspect.Integer':inspect/2        2720000     630631      0.23  [ 2.16]
```

## Optimization opportunities

Ranked by the share of time they represent across the workloads. Each names the code,
why it is hot, and the change that removes it.

### 1. Build operator explanations once, or lazily — ~30–45% of the wide runs

Every built-in operator builds **both** the pass and the fail explanation strings, and
each string `inspect`s **both** operands (operators.ex, `equal/2` … `f/1`):

```elixir
defp equal(a, b), do: res(a == b, "#{f(a)} equals #{f(b)}", "#{f(a)} is not equal to #{f(b)}")
defp f(value), do: inspect(value)
defp res(true, ok, _), do: {true, ok}
defp res(false, _ok, bad), do: {false, bad}
```

So each leaf calls `inspect/1` on `a` **twice** and on `b` **twice**, builds two
strings, and throws one away. The profile shows this directly: in `serial_wide_fast`
`Kernel.inspect/2` runs 3.2M times for 800k leaves (≈4 inspects per leaf), and the
whole `Inspect.*` + `iolist_to_binary` cluster is ~45% of the run. Two fixes, either
or both:

- **Inspect each operand once, and only the branch that's taken.** Hoist
  `a_s = inspect(a)` / `b_s = inspect(b)` and build a single string in an `if`.
  Roughly halves this cost with no API change.
- **Make the explanation lazy.** The string only matters when the run's `errors` (or a
  `debug` log line) is actually read. Return a zero-arity thunk from the operator and
  materialize it in the evaluator only when the leaf's error is emitted. That removes
  the cost from the passing-leaf path entirely.

### 2. Compile JSONPath once, not per fact reference — ~25–40% of the realistic / short-circuit runs

`default_resolve_path/2` hands the raw path string to `JSONPath.values/2` on **every**
leaf (evaluation.ex:301–313):

```elixir
defp default_resolve_path(fact_value, path) do
  case JSONPath.values(fact_value, normalize_json_path(path)) do ...
```

`values/2` re-tokenizes, re-parses, and re-validates the path each call — the
`json_path` docs say to *prefer `build/1` when running the same query multiple times,
since building the query each time performs potentially expensive semantic checks.* In
`serial_shortcircuit` `JSONPath.AST.validation/2` alone is 14.3% (17.5M calls) and the
whole parse/validate cluster is ~39%. `values/2` already accepts a built AST
(`String.t() | AST.t()`), so the fix is to compile the path **once**
(`JSONPath.build!/1` on the normalized path, at rule registration or memoized on the
path string) and pass the AST on every evaluation. The `.[`→`[` normalization folds
into that one-time compile.

### 3. One pass through a combinator's results, and cheaper leaf results

`combinator/4` (evaluation.ex:130–166) re-sorts the children by priority on every
evaluation (`group_by` + `sort_by` + `flatten`), then walks the results in **five**
separate `Enum.map`/`List.flatten` passes to gather `changes`, `errors`, `facts`, and
`empty_values`; `merge_maps/1` folds the fact maps with O(n²) `Map.merge`s. The profile
shows the tell-tale `-combinator/4-fun-N-/1` family (fun-0 … fun-9). A single fold that
accumulates all four lists at once, plus sorting only when the children aren't already
in priority order, and building the fact map in one reduce, removes most of it.

`leaf/2` (evaluation.ex:81–104) is the next tier: it allocates a
`%{facts: %{field => fact_value}}` map and a `%Ecto.Changeset{}` struct per leaf, plus
`String.to_atom/1` per run. It's harder to improve without changing the result shape,
so treat it as second-order.

### 4. Parallel: the per-rule task and the shared-almanac round-trips

In `parallel_wide_fast` the top rows are the parallel machinery, not the rules:
`gen:do_call/4` 5.4%, `erlang:send/3` 3.5%, `gen:reply/2` 3.3%, `gen_server:loop/5`
2.3%, `Task.Supervised.stream_spawn/4` 2.1%, `erlang:demonitor/2` 1.7%,
`erlang:monitor/3` 1.6% — a `Task` is spawned **per rule** (`Task.async_stream`) and
every fact lookup round-trips a GenServer call to the shared almanac
(`Almanac.Shared.handle_call/3` 0.8%, `fact_value/3` 0.7%). This is the same trade-off
the [schedule suite](benchmarks.md) makes visible: at these sizes the overhead
dominates. Give each worker a **local snapshot** of facts (a plain map, a
`:persistent_term`, or per-process ETS) instead of a GenServer call, and consider
evaluating in-process when the rule count is small enough that per-rule `Task`s can't
pay for themselves.

## Caveats

- `:tprof` is **statistical** (sampled), not deterministic — repeat a run to confirm a
  hotspot, and don't chase differences below ~1%.
- `call_time` counts a function *and* everything it calls, so parent and child rows
  overlap; use **PER CALL** to tell a genuinely expensive function from one that merely
  calls expensive things.
- The workloads here are fixed. To profile a real ruleset, add a case to
  `Verdict.Bench.Profile.profiles/0` (a label, an engine builder, a schedule, and a
  run count) and re-run `mix bench profile`.
