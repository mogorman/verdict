defmodule JsonRules.Store do
  @moduledoc """
  The contract (behaviour) for an engine's in-memory rule/fact store.

  A store holds validated `JsonRules.Rule` structs (keyed by id) plus the
  registered facts and engine options. Evaluation is pure and lives in
  `JsonRules.Evaluator`; a store is only responsible for persistence.

  The `state` is an opaque handle. Each backend defines it differently:

    * `JsonRules.Store.Pure` – a struct the caller holds (MVP);
    * a GenServer pid / ETS-backed handle – Phase 2.

  The `JsonRules.Engine` keeps both the backend *module* and its *state* and
  dispatches through the module, so adding a backend is just implementing this
  behaviour.
  """
  alias JsonRules.Rule

  @type t :: term()

  @callback init(keyword()) :: t()
  @callback add_rule(t(), Rule.t()) :: {t(), Rule.t()}
  @callback remove_rule(t(), String.t() | atom()) :: {t(), boolean()}
  @callback get_rule(t(), String.t()) :: {t(), Rule.t() | nil}
  @callback rules(t()) :: {t(), [Rule.t()]}
  @callback add_fact(t(), String.t(), term()) :: t()
  @callback remove_fact(t(), String.t()) :: t()
  @callback facts(t()) :: {t(), map()}
  @callback options(t()) :: {t(), keyword()}
end
