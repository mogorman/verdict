defmodule Verdict.Store.Pure do
  @moduledoc """
  The `:pure` store backend (the default).

  The store is a plain `Verdict.Store.State` struct held in the caller's memory;
  no process is started and no supervisor is involved. Because the struct is
  immutable, mutations return a **new** store; `Verdict.Engine` rebinds it for
  you.

  This is the lowest-overhead backend and is ideal for simple, short-lived
  workloads or when you want to keep the engine entirely in your own dataflow.
  """
  @behaviour Verdict.Store

  alias Verdict.Store.State

  # The `:pure` store handle *is* a `State` struct.
  @type t :: State.t()

  @impl true
  def create(_opts), do: State.new()

  @impl true
  def add_rule(state, rule), do: State.add_rule(state, rule)

  @impl true
  def remove_rule(state, key), do: State.remove_rule(state, key)

  @impl true
  def get_rule(state, id), do: State.get_rule(state, id)

  @impl true
  def rules(state), do: State.rules(state)

  @impl true
  def add_fact(state, fact), do: State.add_fact(state, fact)

  @impl true
  def remove_fact(state, id), do: State.remove_fact(state, id)

  @impl true
  def facts(state), do: State.facts(state)

  @impl true
  def add_operator(state, name, fun), do: State.add_operator(state, name, fun)

  @impl true
  def remove_operator(state, name), do: State.remove_operator(state, name)

  @impl true
  def operators(state), do: State.operators(state)

  @impl true
  def add_decorator(state, name, fun), do: State.add_decorator(state, name, fun)

  @impl true
  def remove_decorator(state, name), do: State.remove_decorator(state, name)

  @impl true
  def decorators(state), do: State.decorators(state)

  @impl true
  def add_condition(state, name, condition), do: State.add_condition(state, name, condition)

  @impl true
  def remove_condition(state, name), do: State.remove_condition(state, name)

  @impl true
  def conditions(state), do: State.conditions(state)
end
