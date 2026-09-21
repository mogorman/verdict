defmodule Verdict.Event do
  @moduledoc """
  The event a rule emits when it is evaluated.

  Every rule declares a single event. The event is emitted as a *success* when
  the rule's conditions evaluate truthy and as a *failure* when they do not.

  An event always has a `type` (usually a string) and an optional `params` map
  of arbitrary data.
  """
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field(:type, :string)
    field(:params, :map, default: %{})
  end

  @doc "Casts and validates event attributes. `type` is required."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) do
    event
    |> cast(attrs, [:type, :params])
    |> validate_required([:type])
  end

  @doc """
  Converts the event back into a JSON-compatible map (the inverse of
  `changeset/2`). Emits string keys; an empty `params` map is omitted.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    base = %{"type" => event.type}

    if map_size(event.params || %{}) == 0 do
      base
    else
      Map.put(base, "params", event.params)
    end
  end

  @type t :: %__MODULE__{
          type: String.t() | nil,
          params: map()
        }
end
