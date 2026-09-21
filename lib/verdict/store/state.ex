defmodule Verdict.Store.State do
  @moduledoc """
  The shared in-memory state and pure transformations behind the built-in store
  backends.

  This is an **internal helper**. It holds the rule / fact / operator / decorator /
  condition registries as a plain struct and exposes pure functions that transform
  it. The `:pure`, `:genserver` and `:ets` backends all build on it so their
  behaviour stays identical.

  A custom backend does **not** need to use `State` — it only needs to implement
  the `Verdict.Store` behaviour (see its moduledoc).

  Run configuration (`schedule`, `strict`, `allow_undefined_*`, …) deliberately
  does **not** live here; it is held on the `Verdict.Engine` so a pre-started
  store can be reused without its configuration baked in.
  """
  alias Verdict.{Fact, Rule}

  defstruct rules: %{},
            facts: %{},
            operators: %{},
            decorators: %{},
            conditions: %{}

  @type t :: %__MODULE__{
          rules: map(),
          facts: Fact.registry(),
          operators: %{String.t() => Verdict.Operators.boolean_operator()},
          decorators: %{String.t() => Verdict.Operators.decorator()},
          conditions: %{String.t() => Verdict.Condition.t()}
        }

  @doc "A fresh, empty state."
  def new, do: %__MODULE__{}

  def add_rule(%__MODULE__{} = state, %Rule{} = rule) do
    rule = ensure_id(rule)
    {%{state | rules: Map.put(state.rules, rule.id, rule)}, rule}
  end

  def remove_rule(%__MODULE__{} = state, key) do
    cond do
      Map.has_key?(state.rules, key) ->
        {%{state | rules: Map.delete(state.rules, key)}, true}

      true ->
        {matched, remaining} =
          Enum.split_with(state.rules, fn {_id, rule} -> rule.name == key end)

        {%{state | rules: Map.new(remaining)}, length(matched) > 0}
    end
  end

  def get_rule(%__MODULE__{} = state, id) when is_binary(id) do
    {state, Map.get(state.rules, id)}
  end

  def rules(%__MODULE__{} = state) do
    {state, Map.values(state.rules)}
  end

  def add_fact(%__MODULE__{} = state, %Fact{} = fact) do
    %{state | facts: Map.put(state.facts, fact.id, fact)}
  end

  def remove_fact(%__MODULE__{} = state, id) when is_binary(id) do
    %{state | facts: Map.delete(state.facts, id)}
  end

  def facts(%__MODULE__{} = state) do
    {state, state.facts}
  end

  def add_operator(%__MODULE__{} = state, name, fun) when is_binary(name),
    do: %{state | operators: Map.put(state.operators, name, fun)}

  def remove_operator(%__MODULE__{} = state, name) when is_binary(name),
    do: %{state | operators: Map.delete(state.operators, name)}

  def operators(%__MODULE__{} = state) do
    {state, state.operators}
  end

  def add_decorator(%__MODULE__{} = state, name, fun) when is_binary(name),
    do: %{state | decorators: Map.put(state.decorators, name, fun)}

  def remove_decorator(%__MODULE__{} = state, name) when is_binary(name),
    do: %{state | decorators: Map.delete(state.decorators, name)}

  def decorators(%__MODULE__{} = state) do
    {state, state.decorators}
  end

  def add_condition(%__MODULE__{} = state, name, condition) when is_binary(name),
    do: %{state | conditions: Map.put(state.conditions, name, condition)}

  def remove_condition(%__MODULE__{} = state, name) when is_binary(name) do
    removed = Map.has_key?(state.conditions, name)
    {%{state | conditions: Map.delete(state.conditions, name)}, removed}
  end

  def conditions(%__MODULE__{} = state) do
    {state, state.conditions}
  end

  @doc "Returns `rule` with a generated `id` if it does not already have one."
  def ensure_id(%Rule{id: id} = rule) when is_binary(id), do: rule
  def ensure_id(%Rule{} = rule), do: %{rule | id: Ecto.UUID.generate()}
end
