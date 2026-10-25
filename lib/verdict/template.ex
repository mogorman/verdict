defmodule Verdict.Template do
  @moduledoc """
  Renders `eex_string` markers inside an event's `params`.

  A `params` value shaped `%{eex_string: "…"}` (or `%{"eex_string" => "…"}`, the sole
  key) is an EEx template: when the rule's event is rendered, it is evaluated with
  `EEx` (stdlib) and replaced by its string. Plain strings and every other value pass
  through untouched, so only the magic marker becomes a template.

  Every template renders against a binding built from the run's almanac:

    * `almanac` – the per-run `%Verdict.Almanac{}` struct, so any fact (including
      computed ones) is reachable via
      `Verdict.Almanac.fact_value(almanac, "name")`;
    * `facts` – a `%{id => value}` map of the constant facts, for
      `<%= facts["name"] %>`;
    * a bare variable for each constant fact whose id is a valid Elixir identifier,
      for `<%= name %>`.

  Only `<%= expr %>` interpolation is allowed by default. A template using EEx
  control flow (`<% if %>`, `<% for %>`, `<% … do %>`) is *unsafe* and only renders
  when the run sets `allow_unsafe_eex: true`; otherwise rendering raises. Templates
  are syntax-checked when the rule is created (`Verdict.Engine.add_rule/2`); an
  ill-formed template is rejected there. EEx runs arbitrary Elixir, so templates
  must only come from trusted rule sources.
  """
  alias Verdict.Almanac

  @doc "Builds the EEx binding for an almanac. Call once per event, not per template."
  @spec binding(Almanac.t()) :: keyword()
  def binding(almanac) do
    facts = Almanac.constants(almanac)

    bare =
      facts
      |> Enum.filter(fn {name, _} -> String.match?(name, ~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/) end)
      |> Enum.map(fn {name, value} -> {String.to_atom(name), value} end)

    Keyword.merge(bare, almanac: almanac, facts: facts)
  end

  @doc "Recursively renders `eex_string` markers in `value`, replacing each with its output."
  @spec render(term(), keyword(), boolean()) :: term()
  def render(value, binding, allow_unsafe) do
    cond do
      is_map(value) and marker?(value) ->
        render_marker(value, binding, allow_unsafe)

      is_map(value) ->
        Map.new(value, fn {k, v} -> {k, render(v, binding, allow_unsafe)} end)

      is_list(value) ->
        Enum.map(value, &render(&1, binding, allow_unsafe))

      true ->
        value
    end
  end

  @doc """
  Recursively syntax-checks every `eex_string` marker in `value`.

  Returns `:ok` or `{:error, [message]}`. Checks compilation only; the
  safe/unsafe control-flow gate is enforced at render time.
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(value) do
    errors = walk(value)
    if errors == [], do: :ok, else: {:error, errors}
  end

  # Collects template-syntax errors in a flat list.
  defp walk(value) do
    cond do
      is_map(value) and marker?(value) ->
        syntax_errors(template_of(value))

      is_map(value) ->
        Map.values(value) |> Enum.flat_map(&walk/1)

      is_list(value) ->
        Enum.flat_map(value, &walk/1)

      true ->
        []
    end
  end

  # A value is an `eex_string` marker when it is a single-key map whose key is
  # `eex_string` (atom or string) and whose value is a binary.
  defp marker?(value) do
    is_map(value) and
      map_size(value) == 1 and
      (is_binary(Map.get(value, :eex_string)) or is_binary(Map.get(value, "eex_string")))
  end

  defp template_of(map), do: Map.get(map, :eex_string) || Map.get(map, "eex_string")

  defp render_marker(map, binding, allow_unsafe) do
    template = template_of(map)

    unless safe?(template) or allow_unsafe do
      raise ArgumentError,
            "event template #{inspect(template)} uses EEx control flow; " <>
              "set allow_unsafe_eex: true to permit it"
    end

    # The capturing engine accumulates text, interpolations, and control-flow block
    # results into one iodata value (the default EEx engine drops block output).
    EEx.eval_string(template, binding, [engine: Verdict.Template.Engine])
    |> IO.iodata_to_binary()
  end

  # "Safe" means interpolation-only: after stripping every `<%= … %>` tag, no `<%`
  # may remain. Anything else (control flow, `do` blocks, comments, or a `%` inside
  # an interpolation) requires `allow_unsafe_eex`.
  defp safe?(template) do
    not String.contains?(String.replace(template, ~r/<%= [^%]*? %>/, ""), "<%")
  end

  defp syntax_errors(template) when is_binary(template) do
    try do
      _ = EEx.compile_string(template, [])
      []
    rescue
      e -> ["event template #{inspect(template)} is not valid EEx: #{Exception.message(e)}"]
    end
  end

  defp syntax_errors(_), do: []
end
