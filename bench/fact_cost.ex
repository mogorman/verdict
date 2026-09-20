defmodule JsonRules.Bench.FactCost do
  @moduledoc """
  Wall time of `JsonRules.Engine.run/3` as a fact's computation cost varies,
  crossed with schedule.

    * fact: `constant` (a precomputed term, O(1) to read) vs `dynamic`
      (an expensive function, `cache: false` so it is recomputed on **every**
      rule reference rather than once per run).
    * schedule: `:serial` vs `:parallel`.

  `:parallel` can hide a costly fact's latency by overlapping its computation
  across worker processes; `:serial` pays it straight-line.
  """
  require Logger
  alias JsonRules.{Bench.Report, Engine}

  @scale 100
  @work 20_000

  # An expensive dynamic fact: a genuinely O(n) reduction (Enum.sum/1 on a Range
  # is O(1) via the arithmetic-series formula, so a reduce is used instead).
  defp costly(_params, _almanac), do: Enum.reduce(1..@work, 0, fn i, acc -> acc + i end)

  def run do
    # 1..@work sums to @work * (@work + 1) / 2.
    value = div(@work * (@work + 1), 2)

    constant_engine =
      Engine.new()
      |> Engine.add_fact("costly", value)
      |> add_rules(@scale, value)

    dynamic_engine =
      Engine.new()
      |> Engine.add_fact("costly", &costly/2, cache: false)
      |> add_rules(@scale, value)

    benchmarks =
      for {label, engine} <- [{"constant", constant_engine}, {"dynamic", dynamic_engine}],
          schedule <- [:serial, :parallel] do
        {
          "#{schedule}/#{label}",
          fn -> Engine.run(engine, %{}, schedule: schedule) end
        }
      end

    Logger.info("fact-cost benchmark: scale #{@scale}, ~#{@work} ops per dynamic fact reference")

    suite =
      Benchee.run(Map.new(benchmarks),
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.HTML, file: "bench/results/fact/index.html", auto_open: false}
        ],
        time: 1,
        warmup: 0.5
      )

    Report.write_csv(suite, "bench/results/fact.csv")
  end

  defp add_rules(engine, scale, value) do
    Enum.reduce(1..scale, engine, fn _i, engine ->
      {:ok, engine, _rule} =
        Engine.add_rule(engine, %{
          event: %{type: "ev"},
          conditions: %{all: [%{fact: "costly", operator: "equal", value: value}]}
        })

      engine
    end)
  end
end
