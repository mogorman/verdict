defmodule JsonRules.Condition do
  @moduledoc """
  A single node in a rule's condition tree.

  A condition is one of:

    * `:leaf` – a `{fact, operator, value}` comparison, with optional `path`
      and `params`. Evaluated by computing the fact and applying the operator
      to the condition `value`.
    * `:all`  – truthy only when *every* child in `children` is truthy.
    * `:any`  – truthy when *at least one* child in `children` is truthy.
    * `:not`  – the negation of its single `child`.
    * `:ref`  – a reference to a named condition registered on the engine
      (Phase 2).

  Every node carries a `priority` (default `1`). Higher-priority nodes run
  before lower-priority ones; nodes of equal priority are evaluated together
  (in parallel when the engine is scheduled with `:parallel`).

  Instances of this struct are produced by `JsonRules.Types.Condition` from a
  JSON-shaped map, and consumed by `JsonRules.Evaluator`.
  """

  @type kind :: :all | :any | :not | :ref | :leaf

  defstruct kind: nil,
            children: nil,
            child: nil,
            ref: nil,
            fact: nil,
            operator: nil,
            value: nil,
            path: nil,
            params: nil,
            priority: 1

  @type t :: %__MODULE__{
          kind: kind() | nil,
          children: [t()] | nil,
          child: t() | nil,
          ref: String.t() | nil,
          fact: String.t() | nil,
          operator: String.t() | nil,
          value: term(),
          path: String.t() | nil,
          params: map() | nil,
          priority: integer()
        }
end
