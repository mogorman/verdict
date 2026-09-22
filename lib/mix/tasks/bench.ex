defmodule Mix.Tasks.Bench do
  @moduledoc """
  Runs the JSON-Rules benchmark suites (built on Benchee).

      mix bench            # run all suites
      mix bench schedule   # schedule × scale × distribution (cheap facts)
      mix bench store      # store backends (:pure / :genserver / :ets)
       mix bench fact       # fact cost (constant vs dynamic)
       mix bench slowfacts  # realistic dataset: slow facts × schedule × scale
        mix bench engines    # schedule × short-circuit: the advantage of each engine
        mix bench matrix     # full matrix: store × schedule × short-circuit × speed × caching × shape
        mix bench profile    # CPU-time profile of Engine.run/3 via :tprof (per-function hotspots)

  The suites live in `bench/` and are required on demand, so the benchmark
  tooling is never compiled into the shipped library. Benchee results (CSV and
  HTML) are written to `bench/results/`.
  """
  use Mix.Task

  @shortdoc "Runs the JSON-Rules benchmark suites (schedule, store, fact-cost, slow-facts, engines, matrix, profile)"

  @targets [
    {"schedule", "bench/schedule.ex", Verdict.Bench.Schedule},
    {"store", "bench/store.ex", Verdict.Bench.Store},
    {"fact", "bench/fact_cost.ex", Verdict.Bench.FactCost},
    {"slowfacts", "bench/slow_facts.ex", Verdict.Bench.SlowFacts},
    {"engines", "bench/engines.ex", Verdict.Bench.Engines},
    {"matrix", "bench/matrix.ex", Verdict.Bench.Matrix},
    {"profile", "bench/profile.ex", Verdict.Bench.Profile}
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    File.mkdir_p!(Path.expand("bench/results"))
    _ = Code.ensure_loaded(:tprof)
    require_file("bench/report.ex")
    require_file("bench/support.ex")
    require_file("bench/data.ex")

    for {_name, file, module} <- selected(args) do
      require_file(file)
      module.run()
    end
  end

  defp selected([]), do: @targets

  defp selected([name]) do
    case Enum.find(@targets, fn {target, _file, _module} -> target == name end) do
      nil ->
        raise Mix.Error,
              "unknown benchmark #{inspect(name)}; available: " <>
                Enum.join(Enum.map(@targets, &elem(&1, 0)), ", ")

      entry ->
        [entry]
    end
  end

  defp selected([_ | _]) do
    raise Mix.Error, "usage: mix bench [#{Enum.join(Enum.map(@targets, &elem(&1, 0)), "|")}]"
  end

  # `Code.require_file/1` returns `nil` if the file is already loaded and a
  # `[{module, beam}]` list if it was just compiled; a missing or uncompilable file
  # raises `Code.Error`, which surfaces as the task failing.
  defp require_file(path) do
    case Code.require_file(path) do
      nil -> :ok
      list when is_list(list) -> :ok
    end
  end
end
