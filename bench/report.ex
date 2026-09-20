defmodule JsonRules.Bench.Report do
  @moduledoc """
  Renders the CSV artifact for a `Benchee.Suite` (the value returned by
  `Benchee.run/2`).

  The HTML report is produced by the official `benchee_html` plugin (wired into the
  `formatters:` of each suite). This module only writes the diff-able CSV, which
  Benchee does not ship a formatter for: it reads the suite's run-time statistics
  and emits one row per scenario.
  """

  @columns [:name, :ips, :average_ms, :median_ms, :deviation_pct, :p99_ms, :samples]

  @doc "One row per scenario, with run-time statistics in milliseconds."
  def rows(%{scenarios: scenarios}) do
    Enum.map(scenarios, fn scenario ->
      stats = scenario.run_time_data.statistics
      average = stats.average

      %{
        name: scenario.name,
        ips: stats.ips,
        average_ms: ns_to_ms(average),
        median_ms: ns_to_ms(stats.median),
        deviation_pct: pct(stats.std_dev, average),
        p99_ms: ns_to_ms(Map.get(stats.percentiles, 99)),
        samples: stats.sample_size
      }
    end)
  end

  @doc "A CSV string (header + one row per scenario)."
  def to_csv(suite) do
    header = Enum.join(@columns, ",")

    rows =
      suite
      |> rows()
      |> Enum.map(fn row ->
        @columns
        |> Enum.map(fn column -> num(row[column]) end)
        |> Enum.join(",")
      end)

    [header | rows]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc "Writes the CSV for `suite` to `path` and returns `path`."
  def write_csv(suite, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, to_csv(suite))
    path
  end

  # --- internals -------------------------------------------------------------

  defp ns_to_ms(nil), do: nil
  defp ns_to_ms(ns), do: ns / 1_000_000

  defp pct(nil, _average), do: nil
  defp pct(std_dev, average) when average > 0, do: std_dev / average * 100.0
  defp pct(_std_dev, _average), do: nil

  defp num(nil), do: ""
  defp num(value) when is_integer(value), do: to_string(value)
  defp num(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp num(value), do: to_string(value)
end
