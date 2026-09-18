defmodule JsonRules.Rule do
  @moduledoc """
  A rule: a set of conditions and a single event.

  A `Rule` is an Ecto **schema** (not tied to any repo or database). An
  `Ecto.Changeset` casts and validates JSON-shaped attributes into a typed
  struct; the resulting struct is stored by a `JsonRules.Store`.

  Rules carry a `priority` (default `1`) that orders their evaluation relative
  to other rules, and a `name` used to identify them in results.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias JsonRules.{Condition, Event, Operators, Types}

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "rules" do
    field(:name, :string)
    field(:priority, :integer, default: 1)
    embeds_one(:event, Event)
    field(:conditions, Types.Condition)
    timestamps()
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          priority: integer(),
          event: Event.t() | nil,
          conditions: Condition.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc """
  Casts and validates `attrs` into a rule changeset.

  `attrs` may use string or atom keys. Required: `:event` (with a `type`) and
  `:conditions` (whose root must be `all`, `any`, `not` or a condition
  reference). `:priority` must be a positive integer.
  """
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = rule, attrs) do
    rule
    |> cast(attrs, [:name, :priority, :conditions])
    |> cast_embed(:event)
    |> validate_required([:event, :conditions])
    |> validate_number(:priority, greater_than: 0)
    |> validate_change(:conditions, &validate_conditions_tree/2)
    |> ensure_id()
  end

  # There is no repo to trigger primary-key autogeneration, so a UUID id is
  # assigned client-side when the rule is created.
  defp ensure_id(changeset) do
    case Map.get(changeset.data, :id) || changeset.changes[:id] do
      nil -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end

  defp validate_conditions_tree(_field, nil), do: []

  defp validate_conditions_tree(field, %Condition{} = tree) do
    known = Operators.known()

    tree
    |> walk("$", known)
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

  defp walk(%Condition{} = node, path, known) do
    priority_errors(node, path) ++ kind_errors(node, path, known)
  end

  defp kind_errors(%Condition{kind: :leaf, operator: operator}, path, known) do
    if operator in known do
      []
    else
      ["#{path} uses unknown operator #{inspect(operator)}"]
    end
  end

  defp kind_errors(%Condition{kind: :all, children: children}, path, known),
    do: walk_children(children, path, known)

  defp kind_errors(%Condition{kind: :any, children: children}, path, known),
    do: walk_children(children, path, known)

  defp kind_errors(%Condition{kind: :not, child: child}, path, known),
    do: walk(child, path <> ".not", known)

  defp kind_errors(%Condition{kind: kind}, _path, _known),
    do: ["#{kind} condition has an invalid shape"]

  defp walk_children(children, path, known) do
    children
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} -> walk(child, "#{path}[#{index}]", known) end)
  end

  defp priority_errors(%Condition{priority: priority}, _path)
       when is_integer(priority) and priority > 0 do
    []
  end

  defp priority_errors(%Condition{priority: priority}, path),
    do: ["#{path} priority must be a positive integer, got: #{inspect(priority)}"]
end
