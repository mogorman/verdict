defmodule JsonRules do
  @moduledoc """
  A rules engine expressed as data, modelled with Ecto and evaluated in Elixir.

  `JsonRules` is an Elixir/Ecto reimplementation of
  [json-rules-engine](https://github.com/CacheControl/json-rules-engine).
  Rules are composed of simple, easy-to-read condition trees (expressed as
  maps, JSON-compatible) plus a single event. When the engine runs, each
  rule's conditions are evaluated against a set of *facts*; if the result is
  truthy the rule's event is emitted as a success, otherwise as a failure.

  ## Modelled with Ecto, stored without a database

  A `JsonRules.Rule`, its `JsonRules.Event`, and the recursive
  `JsonRules.Condition` tree are Ecto schema / embedded-schema / custom-type
  definitions. An `Ecto.Changeset` casts and validates the JSON-shaped input
  into typed structs. No `Ecto.Repo` and no database are used: the validated
  structs are held by a pluggable, in-memory `JsonRules.Store`.

  ## A layered store

  The store is selectable at engine construction so overhead scales with the
  workload:

    * `:pure`      – the engine is a plain struct; no process. (default)
    * `:genserver` – a stateful store in a GenServer's process state.
    * `:ets`       – a GenServer with rules/facts in public ETS tables.

  ## Serial or parallel evaluation

  Scheduling is orthogonal to the store and selectable via the `:schedule`
  option:

    * `:serial`   – evaluate priority buckets one at a time. (default)
    * `:parallel` – run every item in a priority bucket concurrently, then move
      to the next bucket.

  Both rules and conditions carry a `priority` (default 1); higher priority
  runs first. Facts are computed lazily and cached in a per-run
  `JsonRules.Almanac`.

  See `JsonRules.Engine` for the API and the README for worked examples.
  """

  alias JsonRules.Engine

  @doc """
  Creates a new engine.

  Convenience alias for `JsonRules.Engine.new/1`.
  """
  @spec new(keyword()) :: Engine.t()
  def new(opts \\ []) do
    Engine.new(opts)
  end
end
