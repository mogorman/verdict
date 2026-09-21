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
    * `path_resolver` – a `(value, path) -> term()` used to resolve a
      condition's `path`; when `nil` the engine's default (JSONPath) resolver
      is used;
    * `allow_undefined_conditions` – when `false` (default) an unregistered
      condition reference raises; when `true` it evaluates to false;
    * `strict` – when `true`, disables short-circuiting of `all`/`any`;
    * `log` – the logging threshold for the run (`nil`/`:off` = silent, or
      `:debug`/`:info`/`:warning`/`:error`); see `Verdict.Log`.
  """

  alias Verdict.{Almanac, Condition}

  defstruct almanac: nil,
            operators: %{},
            decorators: %{},
            conditions: %{},
            path_resolver: nil,
            allow_undefined_conditions: false,
            strict: false,
            log: nil

  @type t :: %__MODULE__{
          almanac: Almanac.t(),
          operators: %{String.t() => Verdict.Operators.boolean_operator()},
          decorators: %{String.t() => Verdict.Operators.decorator()},
          conditions: %{String.t() => Condition.t()},
          path_resolver: (term(), String.t() -> term()) | nil,
          allow_undefined_conditions: boolean(),
          strict: boolean(),
          log: atom() | nil
        }
end
