# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`eex_string` event templates.** An event `params` value shaped
  `%{eex_string: "…"}` (atom or string key) is rendered as an EEx template at run
  time and replaced by its string, so the emitted event is a filled-in JSON
  object. Templates run against the run's facts — a bare variable per fact, a
  `facts` map, and the `almanac` itself. Only `<%= expr %>` interpolation is
  allowed by default; control-flow templates need the new `allow_unsafe_eex` option
  (an engine or per-run option, with a `config :verdict, :allow_unsafe_eex`
  fallback). Templates are syntax-checked at `add_rule/2`. See `Verdict.Template`.
- `mix bench profile` now profiles **every report mode** (`:full`, `:result_only`,
  and `:failures_only`) for each configuration, writing one
  `bench/profile/<config>_<report>.txt` per combination, so per-function hotspots
  can be compared mode by mode.

### Fixed
- **`eex_string` control-flow templates rendered to `""`.** The default EEx engine
  returns only a template's trailing text, so block control flow
  (`<% if %>…<% end %>`, `<% for %>…<% end %>`, …) produced an empty string. Rendering
  now uses a capturing EEx engine (`Verdict.Template.Engine`) that accumulates static
  text, `<%= expr %>` interpolations, and each control-flow block's result into the
   output, so the whole template becomes its rendered string.
- **`eex_string` templates are compiled once per process, not on every render.** Each
  template's EEx AST is cached in the process dictionary and re-evaluated against the
  run's binding, so repeated renders neither recompile (tokenize + parse) nor
  re-emit stdlib EEx's "won't be output unless the EEx block starts with `<%=`"
   notice on every render (it now appears at most once per template per process).
- **Updating a rule's event raised instead of saving.** `changeset/2` used
  `cast_embed(:event)`, which cannot update an `embeds_one` that has no id: it raises
  whenever the rule already has an event (i.e. every update, though not a create).
  The event is now cast through `Event.changeset/2` and set wholesale with
  `put_embed/3`, so a rule's event type and params can be edited and saved.

### Changed
- **Performance: operator functions are resolved once per distinct operator, not
  once per leaf.** Each evaluated leaf's operator (built-in, custom, or
  `decorator:…` composite) is memoised in a process-local cache under a per-run
  token, so the operator name is split/resolved a single time per distinct
  `{operator, params}` (per process) instead of on every leaf. Only *evaluated*
  leaves pay to resolve, so a short-circuited leaf costs nothing, and unknown
  operators still raise only when their leaf is actually reached. In `:parallel`,
  each worker keeps its own cache. Serial `:result_only` and `:failures_only` runs
  are faster by roughly 18–40% depending on rule width.
- **Performance: the `:full` report no longer builds the pass explanation.** A
  passing leaf records only its raw `actual`/`operator`/`value` in `changes` and
  never an explanation string, so `:full` now uses the fail-only operator: the
  `inspect`-based explanation is built only for *failing* leaves. Report output is
  unchanged; `:full` runs are faster by roughly 50% on wide rules.
- **Performance: ordering a rule's leaves no longer looks fact priorities up
  through the almanac.** The per-run fact-priority map (registered priorities,
  runtime facts overriding at `1`) is built once at run setup and held on the
  evaluation context, so ordering a combinator's children is a local map read
  rather than a per-leaf almanac lookup — which was a `GenServer` round-trip per
  leaf under `:parallel`. Evaluation order is unchanged; `:parallel` runs are
  faster by roughly 5–25%.
- **Performance: `:parallel` workers read constant facts from a per-bucket
  snapshot.** Before each priority bucket runs, the `Evaluator` snapshots the
  current constant facts (one `GenServer` call per bucket) and hands the snapshot
  to every worker, so a constant fact is read locally instead of round-tripping
  through the shared almanac for every leaf (2–3 round-trips each before). Dynamic
  facts still round-trip. `:serial` is unaffected (it never snapshots).
- **Performance: assorted micro-optimizations.** Building the run result is a
  single `Enum.split_with/2` pass (was `filter` + `reject`); a combinator's child
  changesets are aggregated with `Enum.flat_map/2` instead of `map` +
  `List.flatten/1` (one fewer pass each for `changes`/`errors`/`empty_values`).
- **Benchmarking: the `mix bench profile` per-run headline is now a warm median**
  (median of 50 samples after a warm-up) instead of a single cold first-run sample,
  which was dominated by one-time costs (task spawn, scheduler init) and was not
  representative of steady-state run time.

### Notes
- **`:parallel` runtime-fact visibility is now per-bucket.** A runtime fact added by
  a callback in an *earlier* priority bucket is always visible to *later* buckets.
  A runtime fact added within the *same* bucket is read through the live shared
  almanac (best-effort, as before) — a sibling rule in the same bucket sees it only
   if it happens to read it after the callback ran. `:serial` is unaffected. See
   the `Verdict.Almanac.Shared` moduledoc.

## [0.1.1] - 2026-09-19

- Bump version.
- Added Dialyzer as a hard gate (any warning is an error) and `:result_only` /
  `:failures_only` report modes; reached 100% line coverage.

## [0.1.0]

- Initial public release: an Ecto-backed, in-memory reimplementation of
  [json-rules-engine](https://github.com/CacheControl/json-rules-engine) with
  pluggable stores (`:pure` / `:genserver` / `:ets`), serial and parallel
  scheduling, custom operators and decorators, named conditions, and a
  benchmarking suite.
