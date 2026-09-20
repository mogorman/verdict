defmodule JsonRules.StoreEtsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, Fact, RunResult}
  alias JsonRules.Store.Ets, as: EStore
  alias JsonRules.TestSupport

  defp rule_attrs do
    %{
      event: %{type: "adult"},
      conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]}
    }
  end

  test "a run on an ets store produces the expected events" do
    engine =
      Engine.new(store: :ets)
      |> Engine.add_fact("age", 22)
      |> TestSupport.add_rule(rule_attrs())

    %RunResult{events: [event]} = Engine.run(engine)
    assert event.type == "adult"
  end

  test "matches the pure store for the same rules and facts" do
    build = fn store ->
      engine =
        Engine.new(store: store)
        |> Engine.add_fact("age", 22)
        |> Engine.add_fact("score", 90)
        |> TestSupport.add_rule(%{
          event: %{type: "adult"},
          conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
          priority: 10
        })
        |> TestSupport.add_rule(%{
          event: %{type: "nope"},
          conditions: %{any: [%{fact: "score", operator: "greaterThanInclusive", value: 100}]},
          priority: 5
        })

      Engine.run(engine)
    end

    %RunResult{} = pure = build.(:pure)
    %RunResult{} = ets = build.(:ets)

    assert Enum.sort(Enum.map(pure.events, & &1.type)) ==
             Enum.sort(Enum.map(ets.events, & &1.type))

    assert Enum.sort(Enum.map(pure.failure_events, & &1.type)) ==
             Enum.sort(Enum.map(ets.failure_events, & &1.type))
  end

  test "the store process holds rules that can be listed and removed" do
    store = EStore.create([])
    {:ok, _engine, rule} = Engine.add_rule(Engine.new(), rule_attrs())

    {_store, added} = EStore.add_rule(store, rule)

    {_store, [listed]} = EStore.rules(store)
    assert listed.id == added.id

    {_store, true} = EStore.remove_rule(store, added.id)
    {_store, []} = EStore.rules(store)
  end

  test "rules and facts are held in a named ETS table" do
    table = :"ets_test_#{System.unique_integer([:positive])}"
    {:ok, _engine, rule} = Engine.add_rule(Engine.new(), rule_attrs())

    store = EStore.create(table: table)
    {_store, added} = EStore.add_rule(store, rule)

    # the rule is directly readable from the public ETS table
    assert :ets.lookup(:"#{table}.rules", added.id) == [{added.id, added}]

    fact = Fact.new("age", 22)
    EStore.add_fact(store, fact)
    assert :ets.lookup(:"#{table}.facts", "age") == [{"age", fact}]
  end
end
