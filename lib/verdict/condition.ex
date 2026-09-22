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
    * `:ref`  – a reference to a named condition registered on the engine (see
      `Verdict.Engine.set_condition/3`).

  Boolean nodes (`all`/`any`/`not`) carry a `priority` (default `1`). A leaf
  carries an *optional* `priority`; when it is absent, the leaf's evaluation
  order is dictated by its fact's registered priority (see
  `Verdict.Fact`), defaulting to `1`. Higher-priority nodes run before
  lower-priority ones; nodes of equal priority are evaluated together.

  ## Addressing a leaf

  A leaf's `value` may be a fact reference — `%{fact: _}`, optionally with
  `params` and `path` — so one fact can be compared directly against another.
  The referenced fact is resolved through the almanac, and that resolved value
  is what the operator sees and what is recorded in the report.

  A leaf's `path` addresses *into* the fact's value instead of comparing the
  whole fact; the default resolver is JSONPath. A `path` is only applied when
  the fact value is a map or list — a scalar fact is compared as-is:

  | Expression   | Returns                                            |
  | ------------ | -------------------------------------------------- |
  | `$.a.b`      | the value at `a.b` (a scalar), or `nil`            |
  | `$.a[*].b`   | a **list** of every `a[i].b` — pair with a list op |
  | no match     | `nil`                                              |

  ## References

  A `:ref` node names a condition registered with
  `Verdict.Engine.set_condition/3` and reuses it (references may be chained and
  nested inside other conditions). A reference that was never registered raises
  unless `allow_undefined_conditions: true` is set, in which case it is `false`;
  a circular reference is detected and raised rather than looping forever.

  ## Custom properties

  A rule or any condition may carry arbitrary data in an `extra` map; it is kept
  on the struct and round-trips through the condition's JSON map.

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
            path_ast: nil,
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
          path_ast: term() | nil,
          params: map() | nil,
          priority: integer() | nil,
          extra: map()
        }
end
