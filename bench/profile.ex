defmodule Verdict.Bench.Profile do
  @moduledoc """
  CPU-time profiling of `Verdict.Engine.run/3` with Erlang's built-in `:tprof`
  statistical profiler (no extra dependency — `:tprof` ships with the runtime).

  Each configuration builds a representative engine (reusing `Verdict.Bench.Data`
  and `Verdict.Bench.Support`) chosen to stress a different part of the engine,
  warms it up, then runs `Engine.run/3` in a tight loop under `:tprof` for a few
  seconds of work and prints a per-function time breakdown (CALLS / TIME / %),
  sorted by % of total descending. The same table is written to
  `bench/profile/<label>.txt`.

  Run with `mix bench profile`.
  """
  alias Verdict.{Bench.Data, Bench.Support, Engine}

  # Target amount of profiled work per configuration (~wall time, pre-overhead).
  @target_us 2_000_000

  # Each configuration is profiled in every report mode so the per-function
  # hotspots (and the per-run wall time) can be compared mode by mode.
  @reports [:full, :result_only, :failures_only]

  @doc "Profiles every configuration, in every report mode."
  def run do
    File.mkdir_p!(Path.expand("bench/profile"))

    for {label, build, run_opts} <- profiles(),
        report <- @reports do
      profile("#{label}_#{report}", build, Keyword.put(run_opts, :report, report))
    end
  end

  # `{label, engine_builder/0, Engine.run/3 options}`
  defp profiles do
    [
      # Common case: many cheap leaves — operator resolution, leaf allocation and
      # combinator aggregation throughput.
      {"serial_wide_fast", fn -> Support.engine(200, Support.width(:wide)) end, []},
      # Realistic shape: JSONPath `path`s, a named `condition:` ref, mixed operators.
      {"serial_realistic", fn -> Data.engine(200) end, []},
      # Per-run setup floor: a failing head short-circuits each rule to one leaf.
      {"serial_shortcircuit", fn -> Data.engines_engine(500, tail_width: 3) end, []},
      # Parallel machinery: Task workers + the shared-almanac round-trips.
      {
        "parallel_wide_fast",
        fn -> Data.matrix_engine(200, shape: :wide, speed: :fast, cache: true) end,
        [schedule: :parallel, strict: true]
      }
    ]
  end

  defp profile(label, build, run_opts) do
    engine = build.()
    per_run_us = estimate(engine, run_opts)
    iterations = max(200, min(50_000, div(@target_us, max(1, per_run_us))))

    # Warm up: trigger module loading, beam caching and scheduler init so none of
    # that one-time cost shows up in the profile.
    for _ <- 1..10, do: Engine.run(engine, %{}, run_opts)

    run = fn ->
      for _ <- 1..iterations, do: Engine.run(engine, %{}, run_opts)
    end

    {_result, trace} = :tprof.profile(run, %{type: :call_time, report: :return})
    inspected = :tprof.inspect(trace, :total, {:percent, :descending})

    IO.puts("\n===== #{label} (#{iterations} runs, ~#{per_run_us} us/run unprofiled) =====")
    :tprof.format(inspected)

    path = Path.expand("bench/profile/#{label}.txt")
    {:ok, device} = :file.open(path, [:write])
    :tprof.format(device, inspected)
    :file.close(device)
    IO.puts("(written to #{path})")
  end

  # Per-run wall time (unprofiled, warm), in microseconds — the median of several
  # samples after a warm-up, so the printed headline is a steady-state figure and
  # the loop is sized against it. A single cold first run is dominated by
  # one-time costs (task spawn, scheduler init), so it is not representative.
  defp estimate(engine, run_opts) do
    for _ <- 1..10, do: Engine.run(engine, %{}, run_opts)

    samples =
      for _ <- 1..50 do
        {us, _result} = :timer.tc(fn -> Engine.run(engine, %{}, run_opts) end)
        us
      end

    samples |> Enum.sort() |> Enum.at(25)
  end
end
