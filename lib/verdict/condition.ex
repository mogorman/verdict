defmodule Verdict.Condition do
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

  Boolean nodes (`all`/`any`/`not`) carry a `priority` (default `1`). A leaf
  carries an *optional* `priority`; when it is absent, the leaf's evaluation
  order is dictated by its fact's registered priority (see
  `Verdict.Fact`), defaulting to `1`. Higher-priority nodes run before
  lower-priority ones; nodes of equal priority are evaluated together.

  Instances of this struct are produced by `Verdict.Types.Condition` from a
  JSON-shaped map, and consumed by `Verdict.Evaluator`.
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
            priority: nil,
            extra: %{}

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
          priority: integer() | nil,
          extra: map()
        }
end
