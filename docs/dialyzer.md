# Dialyzer

[Back to the README](../README.md#development)

Verdict is type-checked by **Dialyzer** (via the [`dialyxir`](https://github.com/jeremyjh/dialyxir)
wrapper) on top of Elixir's native compiler type checker. CI treats it as a **hard
gate**: any warning fails the build.

## Why Dialyzer, on top of the native checker?

Elixir 1.18+ runs a native type checker at compile time (already enabled here, and
gated by `mix compile --warnings-as-errors`). Dialyzer is stricter and operates on
the **BEAM bytecode**, so it can see across modules and across **dependencies**:

- `unmatched_returns` — a return type that doesn't match the `@spec` (e.g. a
  function built an `Ecto.Changeset` whose `changes` are lists while the spec said
  maps);
- `unknown` — calls to functions or types not present in the PLT (typos, missing
  specs, an untyped dependency);
- `missing_return` — a clause that can fall through without returning;
- `error_handling` — a call to a function that can `raise`/`exit` in a position
  that is expected to return.

The native checker is more local and cannot check our calls against Ecto's /
`json_path`'s types; Dialyzer can, because those apps are in the PLT.

## Configuration

Everything lives in the `dialyzer:` key of `mix.exs` (`MixProject.dialyzer/0`):

```elixir
dialyzer: [
  # Stable PLT locations (gitignored), cached in CI.
  plt_file: {:no_warn, "priv/plts/project.plt"},
  plt_core_path: "priv/plts/core.plt",
  # Pull the whole runtime dependency tree into the PLT so our calls are checked
  # against Ecto / json_path / ... types.
  plt_add_deps: :app_tree,
  # :mix is a build-time app (not a runtime dep); add it so Mix.* calls in
  # lib/mix/tasks are checked against real types.
  plt_add_apps: [:mix],
  flags: [:unmatched_returns, :unknown, :missing_return, :error_handling],
  ignore_warnings: ".dialyzer_ignore.exs",
  list_unused_filters: true
]
```

### The flag set

The valid warning options **differ by OTP release** (an unknown option halts the
run), so if you bump the OTP version, re-check `flags` against
`mix dialyzer.explain`. This set is verified against OTP 28. It favours signal over
noise. Intentionally **not** enabled (noisy here): `:underspecs`, `:overspecs`,
`:no_return`, `:no_opaque`. Note that the opaque-type warnings (`call_with_opaque`
/ `call_without_opaque`) are an **always-on core check** — no flag toggles them;
see [Suppressing warnings](#suppressing-warnings).

## Running it

```sh
# First time only: build the PLTs (~1 minute). Afterwards this is fast.
mix dialyzer --plt

# Analyze lib/ (the default env).
mix dialyzer

# Also cover test/: compile + analyze in the test env.
MIX_ENV=test mix dialyzer
```

`mix dialyzer` compiles the project first (unless `--no-compile`), checks whether
the PLT is up to date, and analyzes the app's compiled modules. `--format github`
prints warnings as GitHub Actions annotations (used by CI). `bench/` is dynamic
dev tooling (loaded with `Code.require_file/1`) and is intentionally out of scope.

## Suppressing warnings

A warning is almost always worth fixing. When it is a genuine false positive, use
the narrowest tool that works, in this order:

1. **Fix the code or the spec.** Most warnings are a spec that is slightly wrong
   (too wide or too narrow) or a real bug. This is the default.
2. **A co-located `@dialyzer` attribute** — self-documenting, lives next to the
   offending code.
   ```elixir
   # Module-level: ignore opaque-type warnings in this module (used by
   # Verdict.Evaluation, where a local MapSet triggers a spurious
   # call_without_opaque).
   @dialyzer :no_opaque

   # Function-level: suppress all warnings for one function.
   @dialyzer {:nowarn_function, some_function: 2}
   ```
3. **`.dialyzer_ignore.exs`** — a last resort, for noise that cannot be fixed
   locally (e.g. an upstream dependency that is not fully typed). Keep it as small
   as possible. `mix dialyzer --list-unused-filters` reports entries that match
   nothing anymore; delete those (CI keeps the file honest via
   `list_unused_filters: true`).

## Continuous integration

The `dialyzer` job in [.github/workflows/ci.yml](../.github/workflows/ci.yml) runs
in parallel with the tests:

1. Restores the cached PLTs from `priv/plts/` (keyed on OS, OTP, Elixir, and the
   `mix.lock` hash — so any dependency change forces a fresh PLT);
2. `mix dialyzer --plt` builds/refreshes them;
3. `mix dialyzer --format github` analyzes and **fails the build on any warning**,
   annotating the diff.

The PLTs are gitignored (`/priv/plts/`) and live in `priv/` so they can be cached
independently of `_build/`.
