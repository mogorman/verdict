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

  Templates are sandboxed. Only functions from a whitelist of modules may be called.
  The default set is `Enum`, `Map`, `Integer`, `Float`, `String`, `Regex`, `Tuple`,
  `Date`, `Time`, `NaiveDateTime`, `DateTime`, `Keyword`, `MapSet`, `Stream`, `Range`,
  `List`, the OTP `:math` and `:json` modules, and the Elixir `JSON` wrapper; extend
  it with
  `config :verdict, :eex_whitelist`
  or the `:eex_whitelist` engine option. Math operators (`+`, `-`, …), a few math
  functions (`abs`, `min`, `max`, `round`, `truncate`), anonymous functions, control
  flow (`<% if %>`, `<% for %>`, `<% … do %>`), literals, and the run's fact variables
  are always allowed. Anything else — other modules, Erlang primitives such as
  `:os.cmd/1`, and non-math Kernel functions — is rejected when the rule is created
  (`Verdict.Engine.add_rule/2`) and again at render time. `allow_unsafe_eex` (engine or
  per-run) disables the sandbox for trusted rule sources. `String` and `Access` are
  always permitted because the template mechanism itself depends on them. Templates
  are syntax-checked at rule creation; an ill-formed or non-whitelisted template is
  rejected there, and a rendered value that does not match the marker's type raises at
  render time.
  """
  alias Verdict.Almanac

  # The typed `eex_*` marker types, in editor order. The marker key is `eex_<type>`.
  @eex_marker_types [:string, :integer, :float, :number, :boolean, :list, :object]

  # The `eex_*` marker keys and the type each coerces its rendered string to.
  @eex_markers Map.new(Enum.map(@eex_marker_types, fn type -> {"eex_#{type}", type} end))

  # Modules always permitted regardless of config: the template mechanism depends on
  # them (the String.Chars.to_string/1 wrapper on every interpolation, and Access.get/2
  # for bracket access such as facts["name"]).
  @required_modules [:Access, :String]

  # The default user-configurable whitelist (extend via config :verdict,
  # :eex_whitelist or the :eex_whitelist engine option). The OTP :json and :math
  # modules and the Elixir JSON wrapper are included for JSON and math handling;
  # any other module is rejected.
  @default_whitelist [
    :Enum,
    :Map,
    :Integer,
    :Float,
    :String,
    :Regex,
    :Tuple,
    :Date,
    :Time,
    :NaiveDateTime,
    :DateTime,
    :Keyword,
    :MapSet,
    :Stream,
    :Range,
    :List,
    :json,
    :JSON,
    :math
  ]

  # Arithmetic / comparison / boolean operators, always allowed in a template.
  @operators [
    :+,
    :-,
    :*,
    :/,
    :div,
    :rem,
    :band,
    :bor,
    :bxor,
    :bsl,
    :bsr,
    :==,
    :!=,
    :===,
    :!==,
    :<,
    :>,
    :<=,
    :>=,
    :++,
    :--,
    :and,
    :or,
    :not,
    :in,
    :=~,
    :|,
    :|>
  ]

  # Bare Kernel math functions (not operators), allowed by name.
  @kernel_math [:abs, :min, :max, :round, :truncate]

  # Structural keywords (control flow, blocks, fn clauses) — not function calls.
  @structural [:if, :case, :cond, :for, :try, :receive, :__block__, :->, :when, :__struct__]

  @doc "The typed `eex_*` event-template marker types, in editor order."
  @spec marker_types() :: [atom()]
  def marker_types, do: @eex_marker_types

  @doc "The default `:eex_whitelist` modules (see the moduledoc)."
  @spec default_whitelist() :: [atom()]
  def default_whitelist, do: @default_whitelist

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
  @spec render(term(), keyword(), boolean(), [atom()]) :: term()
  def render(value, binding, allow_unsafe, whitelist \\ default_whitelist()) do
    case value do
      map when is_map(map) ->
        case marker_type(map) do
          nil -> Map.new(map, fn {k, v} -> {k, render(v, binding, allow_unsafe, whitelist)} end)
          type -> render_typed(map, type, binding, allow_unsafe, whitelist)
        end

      list when is_list(list) ->
        Enum.map(list, &render(&1, binding, allow_unsafe, whitelist))

      other ->
        other
    end
  end

  @doc """
  Recursively checks every `eex_*` marker in `value` for valid EEx syntax and
  whitelist compliance.

  Returns `:ok` or `{:error, [message]}`.
  """
  @spec validate(term(), [atom()], boolean()) :: :ok | {:error, [String.t()]}
  def validate(value, whitelist \\ default_whitelist(), allow_unsafe \\ false) do
    errors = walk(value, whitelist, allow_unsafe)
    if errors == [], do: :ok, else: {:error, errors}
  end

  # Collects syntax and whitelist errors in a flat list. `allow_unsafe` skips the
  # whitelist guard (syntax only), for trusted-source engines.
  defp walk(value, whitelist, allow_unsafe) do
    case value do
      map when is_map(map) ->
        case marker_type(map) do
          nil -> Map.values(map) |> Enum.flat_map(&walk(&1, whitelist, allow_unsafe))
          _type -> template_errors(template_of(map), whitelist, allow_unsafe)
        end

      list when is_list(list) ->
        Enum.flat_map(list, &walk(&1, whitelist, allow_unsafe))

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

  defp render_typed(map, type, binding, allow_unsafe, whitelist) do
    rendered(template_of(map), binding, allow_unsafe, whitelist)
    |> then(fn value -> coerce(type, value) end)
  end

  # Renders `template` to a string: guard the cached compiled AST against the
  # whitelist (unless `allow_unsafe` bypasses the sandbox), then evaluate it with the
  # run's binding. The capturing engine accumulates text, interpolations, and
  # control-flow block results into one iodata value (the default EEx engine drops
  # block output).
  defp rendered(template, binding, allow_unsafe, whitelist) do
    ast = compiled(template)

    if allow_unsafe do
      eval(ast, binding)
    else
      case guard(ast, whitelist) do
        :ok -> eval(ast, binding)
        {:error, reason} -> raise ArgumentError, "event template #{inspect(template)}: #{reason}"
      end
    end
  end

  defp eval(ast, binding) do
    ast
    |> Code.eval_quoted(binding)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  # Checks a compiled template AST against `whitelist`. Returns `:ok` or
  # `{:error, message}`. Only whitelisted module functions (plus `@required_modules`)
  # may be called; operators, math functions, anonymous functions, control flow,
  # literals and variables are allowed; anything else is rejected.
  @spec guard(term(), [atom()]) :: :ok | {:error, String.t()}
  def guard(ast, whitelist) do
    allowed = MapSet.new(@required_modules ++ whitelist)

    try do
      _ =
        Macro.prewalk(ast, fn node ->
          case guard_node(node, allowed) do
            :ok -> node
            {:error, reason} -> throw({:blocked, reason})
          end
        end)

      :ok
    catch
      {:blocked, reason} -> {:error, reason}
    end
  end

  # Classifies a single AST node: `:ok` to allow (and recurse) or `{:error, _}` to block.
  defp guard_node(node, allowed) do
    case node do
      # Remote call: an Elixir alias or an Erlang/resolved module reference.
      {{:., _, module_part}, _, _} ->
        case module_head(module_part) do
          nil ->
            {:error, "uses unsupported call syntax"}

          mod ->
            if mod in allowed do
              :ok
            else
              {:error, "module #{inspect(mod)} is not in the allowed EEx whitelist"}
            end
        end

      # An operator or an anonymous function: always fine.
      {name, _, _} when is_atom(name) and (name in @operators or name == :fn) ->
        :ok

      # The `.` qualifier and the module reference inside a call are data, not calls;
      # a bare variable is likewise fine.
      {:., _, _} ->
        :ok

      {:__aliases__, _, _} ->
        :ok

      {name, _, nil} when is_atom(name) ->
        :ok

      # A structural keyword (if/case/for/…) or a bare Kernel function call. EEx
      # compiles calls with only line/column metadata, so a call is any atom-headed
      # node with a list of arguments that is neither a keyword nor a math function.
      {name, _, args} when is_atom(name) and is_list(args) ->
        if name in @structural or name in @kernel_math do
          :ok
        else
          {:error, "function #{inspect(name)} is not allowed in an EEx template"}
        end

      # Literals and anything else: allow.
      _ ->
        :ok
    end
  end

  # The top-level module of a remote-call target, whose form is `[module_ref, fun]`.
  # `module_ref` may be an alias (`{:__aliases__, _, [Mod, …]}`) or a module atom that
  # may be fully qualified (`:"Elixir.String.Chars"`). Both normalize to the head
  # module (`:String`); an Erlang module stays its lowercase atom (`:os`).
  defp module_head([module_ref | _]) do
    case module_ref do
      {:__aliases__, _, [head | _]} ->
        head

      atom when is_atom(atom) ->
        atom
        |> Atom.to_string()
        |> String.replace_prefix("Elixir.", "")
        |> String.split(".")
        |> hd()
        |> String.to_atom()

      _ ->
        nil
    end
  end

  defp module_head(_), do: nil

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
        ast = compile!(template)
        Process.put(key, Map.put(cache, template, ast))
        ast
    end
  end

  # Compiles `template` with the capturing engine, raising on invalid EEx.
  defp compile!(template) do
    EEx.compile_string(template, engine: Verdict.Template.Engine)
  end

  # Syntax-checks a template and, if valid and `allow_unsafe` is false, guards its
  # compiled AST against the whitelist. Returns a (possibly empty) list of errors.
  defp template_errors(template, whitelist, allow_unsafe) when is_binary(template) do
    try do
      ast = compile!(template)

      if allow_unsafe do
        []
      else
        case guard(ast, whitelist) do
          :ok ->
            []

          {:error, reason} ->
            ["event template #{inspect(template)}: #{reason}"]
        end
      end
    rescue
      e -> ["event template #{inspect(template)} is not valid EEx: #{Exception.message(e)}"]
    end
  end

  defp template_errors(_template, _whitelist, _allow_unsafe), do: []
end
