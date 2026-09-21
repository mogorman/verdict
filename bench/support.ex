defmodule Verdict.Bench.Support do
  @moduledoc """
  Shared builders for the JSON-Rules benchmark suites.

  Each builder returns a fully-populated `Verdict.Engine` (facts and rules
  already registered) so the benchmarked `Verdict.Engine.run/3` only has to
  evaluate — setup cost is excluded from the timed closure.
  """
  alias Verdict.Engine

  # The widest rule in the suite: enough facts for a `wide` rule.
  @max_width 20

  @doc "A single rule: an `all` over `width` conditions (each fires)."
  def rule(width) do
    %{
      event: %{type: "ev"},
      conditions: %{
        all:
          for i <- 1..width do
            %{fact: "f#{i}", operator: "equal", value: i * 10}
          end
      }
    }
  end

  @doc "The number of conditions per rule for a given distribution."
  def width(:wide), do: 20
  def width(:narrow), do: 2

  @doc """
  Builds an engine with `scale` rules, each `width` conditions wide, over
  `@max_width` constant facts. `:store` (in `opts`) selects the backend.
  """
  def engine(scale, width, opts \\ []) do
    store = Keyword.get(opts, :store, :pure)

    engine = Engine.new(store: store)

    engine =
      Enum.reduce(1..@max_width, engine, fn i, acc ->
        Engine.add_fact(acc, "f#{i}", i * 10)
      end)

    Enum.reduce(1..scale, engine, fn _i, acc ->
      {:ok, acc, _rule} = Engine.add_rule(acc, rule(width))
      acc
    end)
  end
end
