defmodule JsonRules.Bench.Schedule do
  @moduledoc """
  Wall time of `JsonRules.Engine.run/3` across schedule × scale × distribution.

    * schedule: `:serial` (rules one at a time) vs `:parallel` (a priority bucket's
      rules run concurrently over a shared almanac).
    * scale: number of rules (50 / 200 / 1000).
    * distribution: `:wide` (20 conditions per rule — each rule is expensive) vs
      `:narrow` (2 conditions per rule — each rule is cheap).

  `:wide` stresses the case where `:parallel` should help most; `:narrow` shows
  whether the overhead of the parallel machinery wins out when rules are cheap.
  """
  require Logger
  alias JsonRules.{Bench.Report, Bench.Support, Engine}

  @scales [50, 200, 1000]
  @distributions [:wide, :narrow]
  @schedules [:serial, :parallel]

  def run do
    # Engines are built once, outside the timed closures.
    benchmarks =
      for scale <- @scales,
          distribution <- @distributions,
          schedule <- @schedules do
        engine = Support.engine(scale, Support.width(distribution))

        {
          "#{schedule}/scale#{scale}/#{distribution}",
          fn -> Engine.run(engine, %{}, schedule: schedule) end
        }
      end

    Logger.info(
      "schedule benchmark: #{length(benchmarks)} cases " <>
        "(scales #{inspect(@scales)}, distributions #{inspect(@distributions)}, " <>
        "schedules #{inspect(@schedules)})"
    )

    suite =
      Benchee.run(Map.new(benchmarks),
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.HTML, file: "bench/results/schedule/index.html", auto_open: false}
        ],
        time: 1,
        warmup: 0.5
      )

    Report.write_csv(suite, "bench/results/schedule.csv")
  end
end
