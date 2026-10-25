defmodule Verdict.Rule do
  @moduledoc """
  A rule: a set of conditions and a single event.

  A `Rule` is an Ecto **schema** (not tied to any repo or database). An
  `Ecto.Changeset` casts and validates JSON-shaped attributes into a typed
  struct; the resulting struct is stored by a `Verdict.Store`.

  Rules carry a `priority` (default `1`) that orders their evaluation relative
  to other rules, and a `name` used to identify them in results. A rule (or any
  condition inside it) may also carry arbitrary data in an `extra` map.

  A rule loads from JSON via `changeset/2` and serializes back out with
  `to_map/1` (and an engine's whole set with `Verdict.Engine.rules_as_map/1`):
  for well-formed rules `to_map/1` is the exact inverse of the cast, so
  `decode → add_rule → to_map` returns the payload unchanged. Facts and operators
  hold functions and so are not serializable — only rules round-trip.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Verdict.{Condition, Event, Types}

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "rules" do
    field(:name, :string)
    field(:priority, :integer, default: 1)
    field(:extra, :map, default: %{})
    embeds_one(:event, Event)
    field(:conditions, Types.Condition)
    timestamps()
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          priority: integer(),
          extra: map(),
          event: Event.t() | nil,
          conditions: Condition.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc """
  Casts and validates `attrs` into a rule changeset.

  `attrs` may use string or atom keys. Required: `:event` (with a `type`) and
  `:conditions` (whose root must be `all`, `any`, `not` or a condition
  reference). `:priority` must be a positive integer. `:extra` is an optional
  map of arbitrary custom properties carried along with the rule.
  """
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = rule, attrs) do
    rule
    |> cast(attrs, [:name, :priority, :extra, :conditions])
    |> put_event(attrs)
    |> validate_required([:event, :conditions])
    |> validate_number(:priority, greater_than: 0)
    |> validate_change(:conditions, &validate_conditions_tree/2)
    |> ensure_id()
  end

  @doc """
  Converts the rule back into a JSON-compatible map (the inverse of
  `changeset/2`). Emits string keys.

  `id` and the timestamps are omitted (they are Ecto internals, not part of the
  rule's JSON). A `priority` of `1` (the default) and an empty `extra` map are
  omitted, mirroring `Verdict.Types.Condition.to_map/1`. `conditions` is
  serialized via `Verdict.Types.Condition.to_map/1` and `event` via
  `Verdict.Event.to_map/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = rule) do
    base = %{
      "name" => rule.name,
      "event" => Event.to_map(rule.event),
      "conditions" => Types.Condition.to_map(rule.conditions)
    }

    base
    |> put_priority(rule.priority)
    |> put_extra(rule.extra)
  end

  defp put_priority(map, nil), do: map
  defp put_priority(map, 1), do: map
  defp put_priority(map, priority), do: Map.put(map, "priority", priority)

  defp put_extra(map, extra) when is_map(extra) and map_size(extra) == 0, do: map
  defp put_extra(map, extra), do: Map.put(map, "extra", extra)

  # There is no repo to trigger primary-key autogeneration, so a UUID id is
  # assigned client-side when the rule is created.
  defp ensure_id(changeset) do
    case Map.get(changeset.data, :id) || changeset.changes[:id] do
      nil -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end

  # Casts the event from `attrs` and sets it wholesale via `put_embed/3`, which
  # sidesteps `cast_embed`'s id matching — the `event` embed has no id, so
  # `cast_embed` raises when updating a rule that already has one. The event is
  # validated by `Event.changeset/2` and its errors merged into the rule.
  defp put_event(changeset, attrs) do
    case Map.get(attrs, :event) || Map.get(attrs, "event") do
      nil ->
        changeset

      event_attrs ->
        event = Event.changeset(changeset.data.event || %Event{}, event_attrs(event_attrs))
        put_embed(changeset, :event, event)
    end
  end

  # Normalizes the event's `type` / `params` from string or atom keys.
  defp event_attrs(map) do
    %{
      type: Map.get(map, :type, Map.get(map, "type")),
      params: Map.get(map, :params, Map.get(map, "params"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp validate_conditions_tree(field, %Condition{} = tree) do
    tree
    |> walk("$")
    |> prepend_root_check(tree)
    |> Enum.map(fn message -> {field, message} end)
  end

  defp prepend_root_check(errors, %Condition{kind: kind})
       when kind in [:all, :any, :not, :ref] do
    errors
  end

  defp prepend_root_check(errors, _other) do
    ["conditions root must be all, any, not, or a condition reference" | errors]
  end

  defp walk(%Condition{} = node, path) do
    priority_errors(node, path) ++ kind_errors(node, path)
  end

  # Operator existence is checked at evaluation time (where the engine's custom
  # operators are known); this is structural validation only.
  defp kind_errors(%Condition{kind: :leaf}, _path), do: []

  defp kind_errors(%Condition{kind: :all, children: children}, path),
    do: walk_children(children, path)

  defp kind_errors(%Condition{kind: :any, children: children}, path),
    do: walk_children(children, path)

  defp kind_errors(%Condition{kind: :not, child: child}, path),
    do: walk(child, path <> ".not")

  defp kind_errors(%Condition{kind: :ref}, _path), do: []

  defp kind_errors(%Condition{kind: kind}, _path),
    do: ["#{kind} condition has an invalid shape"]

  defp walk_children(children, path) do
    children
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> walk(child, "#{path}[#{index}]") end)
  end

  # A leaf's priority may be `nil` (its order is then dictated by the fact's
  # registered priority); any explicit priority must be a positive integer.
  defp priority_errors(%Condition{priority: nil}, _path), do: []

  defp priority_errors(%Condition{priority: priority}, _path)
       when is_integer(priority) and priority > 0 do
    []
  end

  defp priority_errors(%Condition{priority: priority}, path),
    do: ["#{path} priority must be a positive integer, got: #{inspect(priority)}"]
end
