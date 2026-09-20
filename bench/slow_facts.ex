defmodule JsonRules.Bench.SlowFacts do
  @moduledoc """
  Wall time of `JsonRules.Engine.run/3` on the realistic
  `JsonRules.Bench.Data` dataset as the **slow fact** dominates, crossed with
  schedule and rule scale.

  The dataset's `fraud_score` fact is expensive and `cache: false`, so it is
  recomputed on **every** rule reference. `:serial` pays that cost straight-line;
  `:parallel` overlaps it across worker processes. This is the case where the
  `:parallel` scheduler is expected to **win** — the contrast to the `schedule`
  suite, where cheap facts make its shared-almanac overhead dominate.

  A `fast` variant (the same dataset with a constant `fraud_score`) is included as
  the baseline so the crossover is visible in one table.
  """
  require Logger
  alias JsonRules.{Bench.Data, Bench.Report, Engine}

  @scales [100, 500, 2000]
  @speeds [:fast, :slow]
  @schedules [:serial, :parallel]

  def run do
    # Engines are built once, outside the timed closures.
    benchmarks =
      for speed <- @speeds,
          scale <- @scales,
          schedule <- @schedules do
        engine = Data.engine(scale, slow: speed == :slow)

        {
          "#{schedule}/scale#{scale}/#{speed}",
          fn -> Engine.run(engine, %{}, schedule: schedule) end
        }
      end

    Logger.info(
      "slow-facts benchmark: #{length(benchmarks)} cases " <>
        "(scales #{inspect(@scales)}, speeds #{inspect(@speeds)}, " <>
        "schedules #{inspect(@schedules)})"
    )

    suite =
      Benchee.run(Map.new(benchmarks),
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.HTML, file: "bench/results/slowfacts/index.html", auto_open: false}
        ],
        time: 1,
        warmup: 0.5
      )

    Report.write_csv(suite, "bench/results/slowfacts.csv")
  end
end
