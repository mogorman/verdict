defmodule Verdict.Template do
  @moduledoc """
  Renders typed `eex_*` markers inside an event's `params`.

  A `params` value shaped `%{eex_string: "…"}` (atom or string key, the sole key) is
  an EEx template: when the rule's event is rendered, it is evaluated with `EEx`
  (stdlib), then coerced to the type named by the key:

    * `eex_string`   – the rendered string
    * `eex_integer`  – an integer (the rendered string must parse as one)
    * `eex_float`    – a float (`"5"` → `5.0`)
    * `eex_number`   – an integer if the string has no `.`, else a float
    * `eex_boolean`  – `true` / `false`
    * `eex_list`     – a list, parsed from the rendered string as JSON
    * `eex_object`   – a map, parsed from the rendered string as JSON

  Plain values (anything other than these markers) pass through untouched. Every
  template renders against a binding built from the run's almanac:

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
  ill-formed template is rejected there, and a rendered value that does not match
  the marker's type raises at render time. EEx runs arbitrary Elixir, so templates
  must only come from trusted rule sources.
  """
  alias Verdict.Almanac

  # The typed `eex_*` marker types, in editor order. The marker key is `eex_<type>`.
  @eex_marker_types [:string, :integer, :float, :number, :boolean, :list, :object]

  # The `eex_*` marker keys and the type each coerces its rendered string to.
  @eex_markers Map.new(Enum.map(@eex_marker_types, fn type -> {"eex_#{type}", type} end))

  @doc "The typed `eex_*` event-template marker types, in editor order."
  @spec marker_types() :: [atom()]
  def marker_types, do: @eex_marker_types

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

  @doc "Recursively renders `eex_*` markers in `value`, replacing each with its coerced value."
  @spec render(term(), keyword(), boolean()) :: term()
  def render(value, binding, allow_unsafe) do
    case value do
      map when is_map(map) ->
        case marker_type(map) do
          nil -> Map.new(map, fn {k, v} -> {k, render(v, binding, allow_unsafe)} end)
          type -> render_typed(map, type, binding, allow_unsafe)
        end

      list when is_list(list) ->
        Enum.map(list, &render(&1, binding, allow_unsafe))

      other ->
        other
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
    case value do
      map when is_map(map) ->
        case marker_type(map) do
          nil -> Map.values(map) |> Enum.flat_map(&walk/1)
          _type -> syntax_errors(template_of(map))
        end

      list when is_list(list) ->
        Enum.flat_map(list, &walk/1)

      _ ->
        []
    end
  end

  # Returns the target type for an `eex_*` marker map (a single-key map with a binary
  # value), or `nil` if it is not a marker.
  defp marker_type(%{} = map) when map_size(map) == 1 do
    [{key, value}] = Map.to_list(map)
    if is_binary(value), do: Map.get(@eex_markers, to_string(key))
  end

  defp marker_type(_), do: nil

  # The template string of a single-key marker map.
  defp template_of(%{} = map) when map_size(map) == 1 do
    [{_key, template}] = Map.to_list(map)
    template
  end

  defp render_typed(map, type, binding, allow_unsafe) do
    rendered(template_of(map), binding, allow_unsafe)
    |> then(fn value -> coerce(type, value) end)
  end

  # Renders `template` to a string: enforce the safe/unsafe gate, then evaluate the
  # cached compiled AST with the run's binding. The capturing engine accumulates text,
  # interpolations, and control-flow block results into one iodata value (the default
  # EEx engine drops block output).
  defp rendered(template, binding, allow_unsafe) do
    unless safe?(template) or allow_unsafe do
      raise ArgumentError,
            "event template #{inspect(template)} uses EEx control flow; " <>
              "set allow_unsafe_eex: true to permit it"
    end

    compiled(template)
    |> Code.eval_quoted(binding)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  # Coerces a rendered template string to the marker's type.
  defp coerce(:string, value), do: value
  defp coerce(:integer, value), do: parse_integer!(value)
  defp coerce(:float, value), do: parse_float!(value)
  defp coerce(:number, value), do: parse_number!(value)
  defp coerce(:boolean, value), do: parse_boolean!(value)
  defp coerce(:list, value), do: parse_json!(value, "list", &is_list/1)
  defp coerce(:object, value), do: parse_json!(value, "object", &is_map/1)

  defp parse_integer!(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        raise ArgumentError,
              "event integer template rendered #{inspect(value)}, which is not an integer"
    end
  end

  defp parse_float!(value) do
    case Float.parse(value) do
      {float, ""} ->
        float

      _ ->
        raise ArgumentError,
              "event float template rendered #{inspect(value)}, which is not a float"
    end
  end

  defp parse_number!(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> parse_float!(value)
    end
  end

  defp parse_boolean!(value) do
    case value do
      "true" ->
        true

      "false" ->
        false

      _ ->
        raise ArgumentError,
              "event boolean template rendered #{inspect(value)}, which is not a boolean"
    end
  end

  # Parses the rendered string as JSON and confirms it has the shape the marker names.
  defp parse_json!(value, kind, shape?) do
    result =
      try do
        :json.decode(value)
      rescue
        e ->
          raise ArgumentError,
                "event #{kind} template rendered #{inspect(value)}, which is not valid JSON: " <>
                  Exception.message(e)
      end

    unless shape?.(result) do
      raise ArgumentError,
            "event #{kind} template rendered #{inspect(value)}, which is not a valid #{kind}"
    end

    result
  end

  # Compiles `template` with the capturing engine and caches the quoted AST in the
  # process dictionary, so repeated renders neither recompile (tokenize + parse)
  # nor re-emit stdlib EEx's "won't be output unless it starts with `<%=`" notice.
  # The AST is binding-independent; the run's binding is supplied at eval time.
  defp compiled(template) do
    key = {__MODULE__, :compiled}
    cache = Process.get(key, %{})

    case Map.fetch(cache, template) do
      {:ok, ast} ->
        ast

      :error ->
        ast = EEx.compile_string(template, engine: Verdict.Template.Engine)
        Process.put(key, Map.put(cache, template, ast))
        ast
    end
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
