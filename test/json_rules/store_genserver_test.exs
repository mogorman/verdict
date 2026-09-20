defmodule JsonRules.StoreGenServerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}
  alias JsonRules.Store.GenServer, as: GStore
  alias JsonRules.TestSupport

  defp rule_attrs do
    %{
      event: %{type: "adult"},
      conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]}
    }
  end

  test "a run on a genserver store produces the expected events" do
    engine =
      Engine.new(store: :genserver)
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
    %RunResult{} = genserver = build.(:genserver)

    assert Enum.sort(Enum.map(pure.events, & &1.type)) ==
             Enum.sort(Enum.map(genserver.events, & &1.type))

    assert Enum.sort(Enum.map(pure.failure_events, & &1.type)) ==
             Enum.sort(Enum.map(genserver.failure_events, & &1.type))
  end

  test "the store process holds rules that can be listed and removed" do
    store = GStore.create([])
    {:ok, _engine, rule} = Engine.add_rule(Engine.new(), rule_attrs())

    {_store, added} = GStore.add_rule(store, rule)
    assert added.id

    {_store, [listed]} = GStore.rules(store)
    assert listed.id == added.id

    {_store, true} = GStore.remove_rule(store, added.id)
    {_store, []} = GStore.rules(store)
  end

  test "a pre-started store can be wrapped by an engine" do
    {:ok, pid} = GStore.start_link([])
    assert is_pid(pid)

    engine =
      Engine.new(store: {GStore, pid})
      |> Engine.add_fact("age", 22)
      |> TestSupport.add_rule(rule_attrs())

    %RunResult{events: [event]} = Engine.run(engine)
    assert event.type == "adult"

    # the store process outlives the engine that wrapped it
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end
end
