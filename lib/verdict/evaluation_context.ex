defmodule Verdict.EvaluationContext do
  @moduledoc """
  The per-run environment handed to `Verdict.Evaluation`.

  Bundles everything a condition tree needs in order to evaluate:

   * `almanac` – the per-run fact store and cache (also carries
     `allow_undefined_facts`);
   * `operators` – custom operators registered on the engine
     (`%{name => fun}`); these take precedence over the built-ins;
   * `decorators` – operator decorators applied over a resolved operator;
    * `conditions` – named conditions registered on the engine
      (`%{name => Condition.t()}`), used to resolve `:ref` nodes;
    * `fact_priorities` – a flat `%{fact_id => priority}` map (registered
      priorities, runtime facts overriding at 1) used to order a combinator's
      children. Held locally so ordering never looks a fact's priority up
      through the almanac — that would be a GenServer round-trip per leaf in
      `:parallel`;
    * `fact_snapshot` – a per-bucket `%{fact_id => value}` snapshot of the
      constant facts (the `:parallel` engine captures it once per priority
      bucket). A constant fact present here is read locally instead of
      round-tripping through the shared almanac; `nil` for `:serial`;
    * `memo_token` – a per-run token for the process-local operator cache. The
      resolved function for each distinct `{operator, params}` is computed once
      (per process) and memoised under this token, so an evaluated leaf does not
      re-resolve its operator name. Only *evaluated* leaves resolve, so a
      short-circuited leaf costs nothing;
    * `path_resolver` – a `(value, path) -> term()` used to resolve a
     condition's `path`; when `nil` the engine's default (JSONPath) resolver
     is used;
    * `allow_undefined_conditions` – when `false` (default) an unregistered
      condition reference raises; when `true` it evaluates to false;
    * `allow_unsafe_eex` – when `false` (default) an event `eex_string` template
      that uses EEx control flow raises at render time; when `true` such
      templates are permitted (see `Verdict.Template`);
   * `strict` – when `true`, disables short-circuiting of `all`/`any`;
   * `report` – how much of the per-condition report to build: `:full`
     (default) builds the full changeset; `:result_only` returns just the
     boolean outcome; `:failures_only` keeps only the failing conditions;
   * `log` – the logging threshold for the run (`nil`/`:off` = silent, or
     `:debug`/`:info`/`:warning`/`:error`); see `Verdict.Log`.
  """

  alias Verdict.{Almanac, Condition}

  # How much of the per-condition report `Verdict.Evaluation` builds.
  @type report :: :full | :result_only | :failures_only

  defstruct almanac: nil,
            operators: %{},
            decorators: %{},
            conditions: %{},
            fact_priorities: %{},
            fact_snapshot: nil,
            memo_token: nil,
            path_resolver: nil,
            allow_undefined_conditions: false,
            allow_unsafe_eex: false,
            strict: false,
            report: :full,
            log: nil

  @type t :: %__MODULE__{
          almanac: Almanac.t(),
          operators: %{String.t() => Verdict.Operators.boolean_operator()},
          decorators: %{String.t() => Verdict.Operators.decorator()},
          conditions: %{String.t() => Condition.t()},
          fact_priorities: %{String.t() => integer()},
          fact_snapshot: %{String.t() => term()} | nil,
          memo_token: reference(),
          path_resolver: (term(), String.t() -> term()) | nil,
          allow_undefined_conditions: boolean(),
          allow_unsafe_eex: boolean(),
          strict: boolean(),
          report: report(),
          log: atom() | nil
        }
end
