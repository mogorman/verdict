defmodule Verdict.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      test_coverage: [tool: ExCoveralls, export: "cov"]
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.14"},
      {:json_path, "~> 0.4.1"},
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test}
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
