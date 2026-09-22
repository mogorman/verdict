defmodule Verdict.Types.Condition do
  @moduledoc """
  An `Ecto.Type` for the recursive condition tree.

  Casting converts a JSON-shaped map (string or atom keys) into a tree of
  `Verdict.Condition` structs, validating the *structure* of the tree:

    * a node must be one of `all`, `any`, `not`, `condition` (reference) or a
      leaf (`fact`);
    * `all` / `any` must contain a list of conditions;
    * `not` must contain a single condition;
    * a leaf must name a `fact` and an `operator`.

  *Semantic* validation (operator whitelist, positive priorities, root kind) is
  performed by `Verdict.Rule.changeset/2`, keeping this type focused on shape.
  """
  @behaviour Ecto.Type

  alias Verdict.Condition

  @impl true
  def type, do: :map

  @impl true
  def cast(%Condition{} = condition), do: {:ok, condition}

  @impl true
  def cast(nil), do: {:error, message: "is required"}

  @impl true
  def cast(map) when is_map(map), do: from_map(map)

  @impl true
  def cast(_other), do: {:error, message: "must be a condition map"}

  @impl true
  def load(term), do: {:ok, term}

  @impl true
  def dump(term), do: {:ok, to_map(term)}

  @impl true
  def embed_as(_type), do: :dump

  @impl true
  def equal?(a, b), do: a == b

  @doc """
  Converts a JSON-shaped condition map into a `t:Verdict.Condition/0` tree.

  Returns `{:ok, tree}` on success or `{:error, keyword()}` describing the
  structural problem.
  """
  @spec from_map(map()) :: {:ok, Condition.t()} | {:error, keyword()}
  def from_map(map) when is_map(map) do
    build_node(map)
  end

  @doc "Converts a `t:Verdict.Condition/0` tree back into a JSON-shaped map."
  @spec to_map(Condition.t()) :: map()
  def to_map(%Condition{kind: :all, children: children, priority: priority, extra: extra}) do
    with_extra(with_priority(%{"all" => Enum.map(children || [], &to_map/1)}, priority), extra)
  end

  def to_map(%Condition{kind: :any, children: children, priority: priority, extra: extra}) do
    with_extra(with_priority(%{"any" => Enum.map(children || [], &to_map/1)}, priority), extra)
  end

  def to_map(%Condition{kind: :not, child: child, priority: priority, extra: extra}) do
    with_extra(with_priority(%{"not" => to_map(child)}, priority), extra)
  end

  def to_map(%Condition{kind: :ref, ref: ref, priority: priority, extra: extra}) do
    with_extra(with_priority(%{"condition" => ref}, priority), extra)
  end

  def to_map(%Condition{
        kind: :leaf,
        fact: fact,
        operator: operator,
        value: value,
        path: path,
        params: params,
        priority: priority,
        extra: extra
      }) do
    base = %{"fact" => fact, "operator" => operator, "value" => value}
    base = if path, do: Map.put(base, "path", path), else: base
    base = if params, do: Map.put(base, "params", params), else: base
    with_extra(with_priority(base, priority), extra)
  end

  # ---------------------------------------------------------------------------
  # Casting helpers
  # ---------------------------------------------------------------------------

  defp build_node(map) do
    cond do
      has?(map, "all") -> boolean(:all, map, "all")
      has?(map, "any") -> boolean(:any, map, "any")
      has?(map, "not") -> not_node(map)
      has?(map, "condition") -> ref_node(map)
      has?(map, "fact") -> leaf_node(map)
      true -> {:error, message: "must define all, any, not, condition or fact"}
    end
  end

  defp boolean(kind, map, key) do
    case get(map, key) do
      list when is_list(list) ->
        case map_ok(list, &build_node/1) do
          {:ok, children} ->
            {:ok,
             %Condition{
               kind: kind,
               children: children,
               priority: priority(map) || 1,
               extra: extra(map)
             }}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        {:error, message: "#{key} must be a list of conditions, got: #{inspect_trunc(other)}"}
    end
  end

  defp not_node(map) do
    case get(map, "not") do
      inner when is_map(inner) ->
        case build_node(inner) do
          {:ok, child} ->
            {:ok,
             %Condition{kind: :not, child: child, priority: priority(map) || 1, extra: extra(map)}}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        {:error, message: "not must contain a single condition, got: #{inspect_trunc(other)}"}
    end
  end

  defp ref_node(map) do
    case get(map, "condition") do
      name when is_binary(name) and name != "" ->
        {:ok, %Condition{kind: :ref, ref: name, priority: priority(map) || 1, extra: extra(map)}}

      other ->
        {:error,
         message: "condition reference must be a non-empty string, got: #{inspect_trunc(other)}"}
    end
  end

  defp leaf_node(map) do
    with {:ok, fact} <- require_binary(map, "fact"),
         {:ok, operator} <- require_binary(map, "operator"),
         {:ok, path} <- optional_binary(map, "path"),
         {:ok, params} <- optional_map(map, "params") do
      {:ok,
       %Condition{
         kind: :leaf,
         fact: fact,
         operator: operator,
         value: get(map, "value"),
         path: path,
         path_ast: compile_path(path),
         params: params,
         priority: priority(map),
         extra: extra(map)
       }}
    end
  end

  # A node's explicit priority, or `nil` when the map does not set one. Boolean
  # and reference nodes are defaulted to 1 by their builders; a leaf keeps `nil`
  # so its evaluation order can be dictated by its fact's priority.
  defp priority(map), do: get(map, "priority")

  defp with_priority(map, nil), do: map
  defp with_priority(map, 1), do: map
  defp with_priority(map, priority), do: Map.put(map, "priority", priority)

  # Precompiles a leaf's JSONPath once, at cast time, so `Verdict.Evaluation` can
  # run it against the fact value without re-parsing the path string on every run.
  # `JSONPath.build/1` is non-raising: an invalid path is stored as `{:error, _}`
  # and evaluates to `nil` at run time, exactly as re-parsing it would. A leaf
  # without a `path` compiles to `nil`. The reference engine's member-access form
  # `$.obj.['key']` is normalized to the RFC-9535 `$.obj['key']` here, once.
  defp compile_path(nil), do: nil
  defp compile_path(path), do: JSONPath.build(String.replace(path, ".[", "["))

  # A node's optional `extra` map carries arbitrary custom properties.
  defp extra(map) do
    case get(map, "extra") do
      nil -> %{}
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp with_extra(map, extra) when map_size(extra) == 0, do: map
  defp with_extra(map, extra), do: Map.put(map, "extra", extra)

  defp has?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))
  end

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp require_binary(map, key) do
    case get(map, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      value ->
        {:error, message: "#{key} must be a non-empty string, got: #{inspect_trunc(value)}"}
    end
  end

  defp optional_binary(map, key) do
    case get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, message: "#{key} must be a string, got: #{inspect_trunc(value)}"}
    end
  end

  defp optional_map(map, key) do
    case get(map, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      value -> {:error, message: "#{key} must be a map, got: #{inspect_trunc(value)}"}
    end
  end

  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_trunc(term) do
    term
    |> inspect()
    |> String.slice(0, 80)
  end
end
