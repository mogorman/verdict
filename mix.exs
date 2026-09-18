defmodule JsonRules.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mogorman/ecto-json-rules"

  def project do
    [
      app: :ecto_json_rules,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      test_ignore_filters: [~r"support/.*\.ex$"]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.14"}
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
      main: "JsonRules",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
