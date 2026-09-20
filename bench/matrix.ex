defmodule JsonRules.Bench.Matrix do
  @moduledoc """
  Wall time of `JsonRules.Engine.run/3` across the **full configuration cube** —
  every vector crossed, so their interactions show:

    * **store** — `:pure` / `:genserver` / `:ets` (how rules and facts are held);
    * **schedule** — `:serial` vs `:parallel`;
    * **short-circuit** — `strict: false` (a decided `all`/`any` stops early) vs
      `strict: true` (every condition is evaluated);
    * **fact speed** — cheap (`:fast`) vs expensive (`:slow`) tail fact;
    * **fact caching** — cached vs `cache: false` (recomputed on every reference);
    * **rule shape** — narrow×flat, wide×flat, narrow×nested, wide×nested
      (`JsonRules.Bench.Data.shapes/0`), each a cheap deciding head over a tail of
      leaves at distinct priorities.

  `3 × 2 × 2 × 2 × 2 × 4 = 96` scenarios at a fixed scale. The results are written
  to `bench/results/matrix.csv`; `docs/benchmarks.md` and `docs/v0.1.0.md` present
  them as a table per rule shape.
  """
  require Logger
  alias JsonRules.{Bench.Data, Bench.Report, Engine}

  @scale 100
  @stores [:pure, :genserver, :ets]
  @schedules [:serial, :parallel]
  @stricts [false, true]
  @speeds [:fast, :slow]
  @caches [true, false]
  @shapes Data.shapes()

  def run do
    cases = all_cases()

    Logger.info(
      "matrix benchmark: #{length(cases)} cases (scale #{@scale}) — " <>
        "store x schedule x short-circuit x speed x cache x shape"
    )

    suite =
      Benchee.run(Map.new(cases),
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.HTML, file: "bench/results/matrix/index.html", auto_open: false}
        ],
        time: 1,
        warmup: 0.5
      )

    Report.write_csv(suite, "bench/results/matrix.csv")
  end

  defp all_cases do
    for {shape, _width, _depth} <- @shapes,
        store <- @stores,
        schedule <- @schedules,
        strict <- @stricts,
        speed <- @speeds,
        cache <- @caches do
      engine = Data.matrix_engine(@scale, store: store, shape: shape, speed: speed, cache: cache)

      label =
        "#{shape}|#{store}|#{schedule}|#{strict_label(strict)}|#{speed}|#{cache_label(cache)}"

      {label, fn -> Engine.run(engine, %{}, schedule: schedule, strict: strict) end}
    end
  end

  defp strict_label(false), do: "shortcircuit"
  defp strict_label(true), do: "strict"
  defp cache_label(true), do: "cached"
  defp cache_label(false), do: "uncached"
end
