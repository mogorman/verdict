defmodule JsonRules.Store.Pure do
  @moduledoc """
  The `:pure` store backend (the MVP default).

  The store is a plain struct held in the caller's memory; no process is
  started and no supervisor is involved. Because the struct is immutable,
  mutations return a **new** store; `JsonRules.Engine` rebinds it for you.

  This is the lowest-overhead backend and is ideal for simple, short-lived
  workloads or when you want to keep the engine entirely in your own
  dataflow.
  """
  @behaviour JsonRules.Store

  alias JsonRules.Rule

  defstruct rules: %{}, facts: %{}, options: []

  @type t :: %__MODULE__{
          rules: map(),
          facts: map(),
          options: keyword()
        }

  @impl true
  def init(options) do
    %__MODULE__{options: options}
  end

  @impl true
  def add_rule(%__MODULE__{} = store, %Rule{} = rule) do
    rule = ensure_id(rule)
    {%{store | rules: Map.put(store.rules, rule.id, rule)}, rule}
  end

  @impl true
  def remove_rule(%__MODULE__{} = store, key) do
    cond do
      Map.has_key?(store.rules, key) ->
        {%{store | rules: Map.delete(store.rules, key)}, true}

      true ->
        {matched, remaining} =
          Enum.split_with(store.rules, fn {_id, rule} -> rule.name == key end)

        {%{store | rules: Map.new(remaining)}, length(matched) > 0}
    end
  end

  @impl true
  def get_rule(%__MODULE__{} = store, id) when is_binary(id) do
    {store, Map.get(store.rules, id)}
  end

  @impl true
  def rules(%__MODULE__{} = store) do
    {store, Map.values(store.rules)}
  end

  @impl true
  def add_fact(%__MODULE__{} = store, id, definition) when is_binary(id) do
    %{store | facts: Map.put(store.facts, id, definition)}
  end

  @impl true
  def remove_fact(%__MODULE__{} = store, id) when is_binary(id) do
    %{store | facts: Map.delete(store.facts, id)}
  end

  @impl true
  def facts(%__MODULE__{} = store) do
    {store, store.facts}
  end

  @impl true
  def options(%__MODULE__{} = store) do
    {store, store.options}
  end

  defp ensure_id(%Rule{id: id} = rule) when is_binary(id), do: rule
  defp ensure_id(%Rule{} = rule), do: %{rule | id: Ecto.UUID.generate()}
end
