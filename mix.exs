defmodule Verdict.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/mogorman/verdict"

  def project do
    [
      app: :verdict,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      test_ignore_filters: [~r"support/.*\.ex$"],
      test_coverage: [tool: ExCoveralls, export: "cov"],
      dialyzer: dialyzer()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test,
        "coveralls.github": :test,
        "coveralls.post": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :tools]
    ]
  end

  # Dialyzer (via dialyxir) configuration. A hard gate: any warning is an error.
  #
  # The PLTs live under `priv/plts/` (gitignored) so they can be cached in CI and
  # kept independent of `_build/`. `:app_tree` pulls the whole dependency tree into
  # the PLT so our calls are checked against Ecto / json_path / ... types.
  #
  # The flag set favours signal over noise. The valid warning options differ by
  # OTP release (this set is verified against OTP 28), so if you bump the OTP
  # version, re-check `flags` — an unknown option halts the run. Flags that are
  # intentionally *not* enabled (noisy here): `:underspecs`, `:overspecs`,
  # `:no_return`, `:no_opaque`.
  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/project.plt"},
      plt_core_path: "priv/plts/core.plt",
      plt_add_deps: :app_tree,
      # `:mix` is a build-time app (not a runtime dep), so it is not in the dep
      # tree; add it so `Mix.*` calls in lib/mix/tasks are checked against real types.
      plt_add_apps: [:mix],
      flags: [:unmatched_returns, :unknown, :missing_return, :error_handling],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.14"},
      {:json_path, "~> 0.4.1"},
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "An Ecto-backed reimplementation of json-rules-engine for Elixir. " <>
      "Rules, conditions and events are modelled with Ecto schemas and changesets " <>
      "and stored in a pluggable in-memory backend (no database)."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Verdict",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
