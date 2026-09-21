defmodule Verdict.Bench.Store do
  @moduledoc """
  Wall time of `Verdict.Engine.run/3` across the store backends at a fixed
  workload.

    * `:pure`     – a plain struct; rules and facts live in the engine itself.
    * `:genserver` – a stateful store held in a GenServer's process state.
    * `:ets`      – a GenServer with rules/facts in public ETS tables.

  Each backend's engine (and its backing process, where applicable) is built
  once outside the timed closure; `run/3` only reads rules/facts from it.
  """
  require Logger
  alias Verdict.{Bench.Report, Bench.Support, Engine}

  @backends [:pure, :genserver, :ets]
  @scale 200
  @width 2

  def run do
    benchmarks =
      for backend <- @backends do
        engine = Support.engine(@scale, @width, store: backend)
        {Atom.to_string(backend), fn -> Engine.run(engine, %{}) end}
      end

    Logger.info(
      "store benchmark: #{Enum.join(Enum.map(@backends, &Atom.to_string/1), ", ")} " <>
        "(scale #{@scale}, #{@width} conditions/rule)"
    )

    suite =
      Benchee.run(Map.new(benchmarks),
        formatters: [
          Benchee.Formatters.Console,
          {Benchee.Formatters.HTML, file: "bench/results/store/index.html", auto_open: false}
        ],
        time: 1,
        warmup: 0.5
      )

    Report.write_csv(suite, "bench/results/store.csv")
  end
end
