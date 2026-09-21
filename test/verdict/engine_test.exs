defmodule Verdict.EngineTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}
  alias Verdict.TestSupport

  describe "example 01: hello world" do
    test "emits the event when the fact matches" do
      engine = Engine.new() |> Engine.add_fact("name", "world")

      {:ok, engine, _} =
        Engine.add_rule(engine, %{
          event: %{type: "greeting", params: %{message: "Hello world!"}},
          conditions: %{all: [%{fact: "name", operator: "equal", value: "world"}]}
        })

      %RunResult{events: [event]} = Engine.run(engine, %{})
      assert event.type == "greeting"
      assert event.params == %{message: "Hello world!"}
    end
  end

  describe "example 02: nested boolean logic (fouled out)" do
    test "40-minute game with 5 fouls" do
      {:ok, engine, _} = fouled_out_engine()
      %RunResult{events: [event]} = Engine.run(engine, %{gameDuration: 40, personalFoulCount: 5})
      assert event.type == "fouledOut"
    end

    test "48-minute game with only 5 fouls does not fire" do
      {:ok, engine, _} = fouled_out_engine()

      %RunResult{events: [], failure_events: [event]} =
        Engine.run(engine, %{gameDuration: 48, personalFoulCount: 5})

      assert event.type == "fouledOut"
    end

    test "48-minute game with 6 fouls" do
      {:ok, engine, _} = fouled_out_engine()
      %RunResult{events: [event]} = Engine.run(engine, %{gameDuration: 48, personalFoulCount: 6})
      assert event.type == "fouledOut"
    end

    defp fouled_out_engine do
      Engine.new()
      |> Engine.add_rule(%{
        name: "fouled-out",
        event: %{type: "fouledOut", params: %{message: "Player has fouled out!"}},
        conditions: %{
          any: [
            %{
              all: [
                %{fact: "gameDuration", operator: "equal", value: 40},
                %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 5}
              ]
            },
            %{
              all: [
                %{fact: "gameDuration", operator: "equal", value: 48},
                %{fact: "personalFoulCount", operator: "greaterThanInclusive", value: 6}
              ]
            }
          ]
        }
      })
    end
  end

  describe "example 03: dynamic facts" do
    test "a fact function receives params and computes a value" do
      products = %{"widget" => %{price: 150}, "gadget" => %{price: 50}}

      engine =
        Engine.new()
        |> Engine.add_fact("product-price", fn params, _almanac ->
          Map.fetch!(products, params["productId"]).price
        end)

      {:ok, engine, _} =
        Engine.add_rule(engine, %{
          event: %{type: "expensive"},
          conditions: %{
            all: [
              %{
                fact: "product-price",
                params: %{"productId" => "widget"},
                operator: "greaterThan",
                value: 100
              }
            ]
          }
        })

      %RunResult{events: [event]} = Engine.run(engine, %{})
      assert event.type == "expensive"
    end
  end

  describe "fact dependencies and caching" do
    test "a fact can read another fact via the almanac" do
      engine =
        Engine.new()
        |> Engine.add_fact("account-info", fn _p, _a ->
          %{company: "microsoft", status: "active"}
        end)
        |> Engine.add_fact("company", fn _p, almanac ->
          Verdict.Almanac.fact_value(almanac, "account-info").company
        end)

      {:ok, engine, _} =
        Engine.add_rule(engine, %{
          event: %{type: "is-microsoft"},
          conditions: %{all: [%{fact: "company", operator: "equal", value: "microsoft"}]}
        })

      %RunResult{events: [event]} = Engine.run(engine, %{})
      assert event.type == "is-microsoft"
    end

    test "a shared fact is computed only once per run" do
      engine =
        Engine.new()
        |> Engine.add_fact("expensive", fn _p, _a ->
          send(self(), :computed)
          42
        end)

      {:ok, engine, _} =
        Engine.add_rule(engine, %{
          event: %{type: "ok"},
          conditions: %{
            all: [
              %{fact: "expensive", operator: "equal", value: 42},
              %{fact: "expensive", operator: "greaterThan", value: 1}
            ]
          }
        })

      Engine.run(engine, %{})
      assert_received :computed
      refute_receive :computed
    end

    test "runtime facts override registered facts for a single run" do
      engine =
        Engine.new()
        |> Engine.add_fact("answer", 41)

      {:ok, engine, _} =
        Engine.add_rule(engine, %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "answer", operator: "equal", value: 42}]}
        })

      %RunResult{events: []} = Engine.run(engine, %{})
      %RunResult{events: [event]} = Engine.run(engine, %{answer: 42})
      assert event.type == "e"
    end
  end

  describe "priority ordering" do
    test "rules run in descending priority order" do
      {:ok, e1, _} =
        Engine.add_rule(Engine.new(), %{event: %{type: "low"}, priority: 1, conditions: single(1)})

      {:ok, e2, _} =
        Engine.add_rule(e1, %{event: %{type: "high"}, priority: 10, conditions: single(1)})

      {:ok, e3, _} =
        Engine.add_rule(e2, %{event: %{type: "mid"}, priority: 5, conditions: single(1)})

      %RunResult{results: results} = Engine.run(e3, %{x: 1})
      assert Enum.map(results, fn rr -> rr.rule.event.type end) == ["high", "mid", "low"]
    end

    defp single(value), do: %{all: [%{fact: "x", operator: "equal", value: value}]}
  end

  describe "undefined facts" do
    test "raises by default" do
      {:ok, engine, _} =
        Engine.add_rule(Engine.new(), %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "missing", operator: "equal", value: 1}]}
        })

      assert_raise Verdict.UndefinedFactError, fn -> Engine.run(engine, %{}) end
    end

    test "allow_undefined_facts treats them as nil" do
      engine = Engine.new(allow_undefined_facts: true)

      {:ok, engine, _} =
        Engine.add_rule(engine, %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "missing", operator: "notEqual", value: 1}]}
        })

      %RunResult{events: [event]} = Engine.run(engine, %{})
      assert event.type == "e"
    end
  end

  describe "errors" do
    test "a fact that raises surfaces the error out of run/3" do
      engine =
        Engine.new()
        |> Engine.add_fact("age", fn _p, _a ->
          raise "problem occurred"
        end)
        |> TestSupport.add_rule(%{
          conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 21}]},
          event: %{type: "generic"}
        })

      assert_raise RuntimeError, ~r/problem occurred/, fn -> Engine.run(engine) end
    end
  end

  describe "remove_rule/2" do
    test "removes a rule by name" do
      {:ok, engine, _} =
        Engine.add_rule(Engine.new(), %{
          name: "r",
          event: %{type: "e"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
        })

      {engine, true} = Engine.remove_rule(engine, "r")
      %RunResult{events: []} = Engine.run(engine, %{x: 1})
    end

    test "returns false when nothing matches" do
      engine = Engine.new()
      {_engine, false} = Engine.remove_rule(engine, "does-not-exist")
    end
  end

  describe "store backend selection" do
    test "pure is the default" do
      assert %Engine{store_module: Verdict.Store.Pure} = Engine.new()
    end

    test "genserver starts a GenServer-backed store" do
      assert %Engine{store_module: Verdict.Store.GenServer, store: pid} =
               Engine.new(store: :genserver)

      assert is_pid(pid)
    end

    test "ets starts an ETS-backed store" do
      assert %Engine{store_module: Verdict.Store.Ets, store: pid} =
               Engine.new(store: :ets)

      assert is_pid(pid)
    end

    test "unknown backends raise" do
      assert_raise ArgumentError, fn -> Engine.new(store: :nope) end
    end
  end
end
