defmodule Verdict.Bench.Engines do
  @moduledoc """
  Wall time of `Verdict.Engine.run/3` across the engine-configuration matrix,
  chosen to make the **advantage of each engine** visible:

    * **schedule** — `:serial` vs `:parallel`.
    * **short-circuit** — `strict: false` (a decided `all`/`any` stops early,
      skipping the rest) vs `strict: true` (every condition is evaluated, for a
      complete report).

  The dataset (`Verdict.Bench.Data.engines_engine/2`) gives each rule a cheap
  head that decides its `all` early, followed by an expensive tail of slow
  `fraud_score` conditions. The trade-offs the matrix exposes:

    * **short-circuit** skips the expensive tail → the fastest configuration;
    * **strict** must evaluate the whole tail → slow under `:serial`, but
      `:parallel` overlaps the tail across workers → the advantage of the
      parallel engine when a complete evaluation is required.
  """
  require Logger
  alias Verdict.{Bench.Data, Bench.Report, Engine}

  @scales [100, 500, 2000]
  @stricts [false, true]
  @schedules [:serial, :parallel]
  @tail_width 3

  def run do
    # Engines are built once, outside the timed closures.
    benchmarks =
      for strict <- @stricts,
          scale <- @scales,
          schedule <- @schedules do
        engine = Data.engines_engine(scale, tail_width: @tail_width)

        {
          "#{short_circuit_label(strict)}/#{schedule}/scale#{scale}",
          fn -> Engine.run(engine, %{}, schedule: schedule, strict: strict) end
        }
      end

    Logger.info(
      "engines benchmark: #{length(benchmarks)} cases " <>
        "(scales #{inspect(@scales)}, strict #{inspect(@stricts)}, " <>
        "schedules #{inspect(@schedules)}, tail width #{@tail_width})"
    )

    suite =
      Benchee.run(Map.new(benchmarks),
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.HTML, file: "bench/results/engines/index.html", auto_open: false}
        ],
        time: 1,
        warmup: 0.5
      )

    Report.write_csv(suite, "bench/results/engines.csv")
  end

  defp short_circuit_label(false), do: "shortcircuit"
  defp short_circuit_label(true), do: "strict"
end
