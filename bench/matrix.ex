defmodule JsonRules.Bench.Matrix do
  @moduledoc """
  Wall time of `JsonRules.Engine.run/3` across the **full configuration matrix** —
  the axes the other suites isolate are crossed here so their *interactions* show:

    * **store** — `:pure` / `:genserver` / `:ets` (how rules and facts are held);
    * **schedule** — `:serial` vs `:parallel`;
    * **short-circuit** — `strict: false` (a decided `all`/`any` stops early) vs
      `strict: true` (every condition is evaluated);
    * **fact speed** — cheap (`:fast`) vs expensive (`:slow`) tail fact;
    * **fact caching** — cached vs `cache: false` (recomputed on every reference).

  Every rule uses the same **deep, priority-varied, nested** condition tree
  (`JsonRules.Bench.Data.deep_rule/1`): a cheap head that decides the `all` early,
  followed by a nested `any` group plus leaf conditions at distinct priorities, so
  short-circuit skips the whole tail.

  Two groups:

    * **A — storage x run mode** (slow, uncached facts): `store x strict x schedule`;
    * **B — fact cost x caching** (pure store): `speed x cache x strict x schedule`.
  """
  require Logger
  alias JsonRules.{Bench.Data, Bench.Report, Engine}

  @scale 200
  @stores [:pure, :genserver, :ets]
  @schedules [:serial, :parallel]
  @stricts [false, true]

  def run do
    cases = storage_run_mode() ++ fact_cost_cache()

    Logger.info(
      "matrix benchmark: #{length(cases)} cases (scale #{@scale}) — " <>
        "A: store x short-circuit x schedule (slow, uncached facts); " <>
        "B: speed x cache x short-circuit x schedule (pure store)"
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

  # Group A: how rules/facts are stored x how they are run (slow, uncached facts).
  defp storage_run_mode do
    for store <- @stores, strict <- @stricts, schedule <- @schedules do
      engine = Data.matrix_engine(@scale, store: store, speed: :slow, cache: false)
      label = "A|#{strict_label(strict)}|#{schedule}|store=#{store}"
      {label, fn -> Engine.run(engine, %{}, schedule: schedule, strict: strict) end}
    end
  end

  # Group B: fact speed x caching x short-circuit x schedule (pure store).
  defp fact_cost_cache do
    for speed <- [:fast, :slow],
        cache <- [true, false],
        strict <- @stricts,
        schedule <- @schedules do
      engine = Data.matrix_engine(@scale, store: :pure, speed: speed, cache: cache)
      label = "B|#{strict_label(strict)}|#{schedule}|#{speed}|#{cache_label(cache)}"
      {label, fn -> Engine.run(engine, %{}, schedule: schedule, strict: strict) end}
    end
  end

  defp strict_label(false), do: "shortcircuit"
  defp strict_label(true), do: "strict"
  defp cache_label(true), do: "cached"
  defp cache_label(false), do: "uncached"
end
