defmodule Verdict.StoreBehaviourTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Engine, Fact, Rule}
  alias Verdict.Types.Condition

  # Every built-in backend implements the `Verdict.Store` behaviour, so the
  # operation contract is exercised once per backend. This covers the callback
  # wrappers, the `handle_call` clauses, and the shared `Verdict.Store.State`
  # functions all at once.

  test "pure store honours the behaviour contract" do
    contract(Verdict.Store.Pure)
  end

  test "genserver store honours the behaviour contract" do
    contract(Verdict.Store.GenServer)
  end

  test "ets store honours the behaviour contract" do
    contract(Verdict.Store.Ets)
  end

  test "start_link returns a live store process (genserver)" do
    assert {:ok, pid} = Verdict.Store.GenServer.start_link([])
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "start_link returns a live store process (ets)" do
    assert {:ok, pid} = Verdict.Store.Ets.start_link([])
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "terminate cleans up the process (genserver)" do
    store = Verdict.Store.GenServer.create([])
    assert Process.alive?(store)
    GenServer.stop(store)
    refute Process.alive?(store)
  end

  test "terminate deletes the ETS tables (ets)" do
    table = :"ets_terminate_#{System.unique_integer([:positive])}"
    store = Verdict.Store.Ets.create(table: table)

    Verdict.Store.Ets.add_rule(store, rule())
    assert :ets.info(:"#{table}.rules") != :undefined

    GenServer.stop(store)
    assert :ets.info(:"#{table}.rules") == :undefined
    assert :ets.info(:"#{table}.facts") == :undefined
  end

  # Exercises every Store callback against one backend. `mod` must be any module
  # implementing the `Verdict.Store` behaviour.
  defp contract(mod) do
    initial = mod.create([])
    store = initial

    try do
      # rules: add, list, get (hit/miss), remove by id
      {store, added} = mod.add_rule(store, rule())
      assert added.id
      {store, [listed]} = mod.rules(store)
      assert listed.id == added.id
      {store, got} = mod.get_rule(store, added.id)
      assert got.id == added.id
      {store, nil} = mod.get_rule(store, "no-such-id")
      {store, true} = mod.remove_rule(store, added.id)
      {store, false} = mod.remove_rule(store, added.id)
      {store, []} = mod.rules(store)

      # rules: remove by name removes every match
      {store, _} = mod.add_rule(store, named_rule("dup"))
      {store, _} = mod.add_rule(store, named_rule("dup"))
      {store, [_a, _b]} = mod.rules(store)
      {store, true} = mod.remove_rule(store, "dup")
      {store, []} = mod.rules(store)

      # facts: add, list, remove
      store = mod.add_fact(store, Fact.new("age", 22))
      {store, facts} = mod.facts(store)
      assert Map.has_key?(facts, "age")
      store = mod.remove_fact(store, "age")
      {store, %{}} = mod.facts(store)

      # operators: add, list, remove
      store = mod.add_operator(store, "myOp", fn a, b -> a == b end)
      {store, ops} = mod.operators(store)
      assert Map.has_key?(ops, "myOp")
      store = mod.remove_operator(store, "myOp")
      {store, %{}} = mod.operators(store)

      # decorators: add, list, remove
      store = mod.add_decorator(store, "myDec", fn a, b, next -> next.(a, b) end)
      {store, decs} = mod.decorators(store)
      assert Map.has_key?(decs, "myDec")
      store = mod.remove_decorator(store, "myDec")
      {store, %{}} = mod.decorators(store)

      # conditions: add, list, remove (hit/miss)
      store = mod.add_condition(store, "over18", condition())
      {store, conds} = mod.conditions(store)
      assert Map.has_key?(conds, "over18")
      {store, true} = mod.remove_condition(store, "over18")
      {store, false} = mod.remove_condition(store, "over18")
      {_store, %{}} = mod.conditions(store)
    after
      stop_if_process(initial)
    end
  end

  defp rule do
    {:ok, _engine, rule} =
      Engine.add_rule(Engine.new(), %{
        event: %{type: "t"},
        conditions: %{all: [%{fact: "a", operator: "equal", value: 1}]}
      })

    rule
  end

  defp named_rule(name) do
    {:ok, _engine, rule} =
      Engine.add_rule(Engine.new(), %{
        name: name,
        event: %{type: "t"},
        conditions: %{all: [%{fact: "a", operator: "equal", value: 1}]}
      })

    rule
  end

  defp condition do
    {:ok, tree} = Condition.from_map(%{all: [%{fact: "a", operator: "equal", value: 1}]})
    tree
  end

  # Stop the store process if `create/1` started one (the process backends do;
  # the pure backend returns a plain struct).
  defp stop_if_process(store), do: if(is_pid(store), do: GenServer.stop(store), else: :ok)
end
