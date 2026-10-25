defmodule Verdict.RuleRoundTripTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Condition, Engine, Event, Rule}

  defp to_rule(json) do
    %Rule{}
    |> Rule.changeset(json)
    |> Ecto.Changeset.apply_changes()
  end

  describe "Event.to_map/1" do
    test "emits type and params with string keys" do
      event = %Event{type: "event-1", params: %{"eventParam" => 1}}
      assert Event.to_map(event) == %{"type" => "event-1", "params" => %{"eventParam" => 1}}
    end

    test "omits an empty params map" do
      assert Event.to_map(%Event{type: "event-2", params: %{}}) == %{"type" => "event-2"}
    end
  end

  describe "Rule.to_map/1" do
    test "round-trips a minimal rule" do
      original = %{
        "name" => "first",
        "event" => %{"type" => "event-1"},
        "conditions" => %{"all" => [%{"fact" => "x", "operator" => "equal", "value" => 1}]}
      }

      assert Rule.to_map(to_rule(original)) == original
    end

    test "round-trips a rule with priority, extra, and a nested condition tree" do
      original = %{
        "name" => "first",
        "priority" => 10,
        "extra" => %{"team" => "a"},
        "event" => %{"type" => "event-1", "params" => %{"eventParam" => 1}},
        "conditions" => %{
          "all" => [
            %{
              "fact" => "high",
              "operator" => "contains",
              "value" => 2,
              "path" => "$.values",
              "params" => %{"factParam" => 1},
              "priority" => 5
            },
            %{
              "any" => [%{"fact" => "low", "operator" => "in", "value" => [2]}],
              "priority" => 2
            },
            %{"not" => %{"fact" => "x", "operator" => "equal", "value" => 3}},
            %{"condition" => "someRef"}
          ]
        }
      }

      assert Rule.to_map(to_rule(original)) == original
    end

    test "is idempotent (serializing twice is stable)" do
      original = %{
        "name" => "r",
        "priority" => 3,
        "event" => %{"type" => "e", "params" => %{"k" => 1}},
        "conditions" => %{
          "all" => [
            %{"fact" => "a", "operator" => "equal", "value" => 1, "priority" => 4},
            %{"not" => %{"fact" => "b", "operator" => "in", "value" => [1, 2]}}
          ]
        }
      }

      once = Rule.to_map(to_rule(original))
      twice = Rule.to_map(to_rule(once))
      assert once == twice
    end

    test "omits id and timestamps" do
      rule =
        to_rule(%{
          "name" => "r",
          "event" => %{"type" => "e"},
          "conditions" => %{"all" => [%{"fact" => "x", "operator" => "equal", "value" => 1}]}
        })

      assert is_binary(rule.id)
      refute Map.has_key?(Rule.to_map(rule), "id")
      refute Map.has_key?(Rule.to_map(rule), "inserted_at")
      refute Map.has_key?(Rule.to_map(rule), "updated_at")
    end

    test "omits a default priority and an empty extra map" do
      rule =
        to_rule(%{
          "name" => "r",
          "priority" => 1,
          "extra" => %{},
          "event" => %{"type" => "e"},
          "conditions" => %{"all" => [%{"fact" => "x", "operator" => "equal", "value" => 1}]}
        })

      map = Rule.to_map(rule)
      refute Map.has_key?(map, "priority")
      refute Map.has_key?(map, "extra")
    end

    test "omits a nil priority" do
      rule = %Rule{
        name: "r",
        priority: nil,
        event: %Event{type: "e"},
        conditions: %Condition{kind: :ref, ref: "someRef"}
      }

      refute Map.has_key?(Rule.to_map(rule), "priority")
    end

    test "round-trips sample_facts and omits it when absent" do
      original = %{
        "name" => "r",
        "event" => %{"type" => "e"},
        "conditions" => %{"all" => [%{"fact" => "x", "operator" => "equal", "value" => 1}]},
        "sample_facts" => %{"player" => %{"hp" => 3}}
      }

      assert Rule.to_map(to_rule(original)) == original

      empty =
        to_rule(%{
          "name" => "r",
          "event" => %{"type" => "e"},
          "conditions" => %{"all" => [%{"fact" => "x", "operator" => "equal", "value" => 1}]}
        })

      refute Map.has_key?(Rule.to_map(empty), "sample_facts")
    end
  end

  describe "Rule.changeset/2" do
    test "rejects a condition tree with an unknown kind" do
      cs = Rule.changeset(%Rule{}, %{event: %{type: "e"}, conditions: %Condition{kind: :bogus}})
      refute cs.valid?
      assert Enum.any?(cs.errors, fn {field, _} -> field == :conditions end)
    end
  end

  describe "Engine.rules_as_map/1" do
    test "returns the engine's rules as maps in descending priority order" do
      {:ok, engine, _} =
        Engine.new()
        |> Engine.add_rule(%{
          name: "low",
          priority: 1,
          event: %{type: "e1"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
        })

      {:ok, engine, _} =
        engine
        |> Engine.add_rule(%{
          name: "high",
          priority: 10,
          event: %{type: "e2"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 2}]}
        })

      [high, low] = Engine.rules_as_map(engine)
      assert high["name"] == "high"
      assert high["priority"] == 10
      assert high["event"]["type"] == "e2"
      assert low["name"] == "low"
      # priority 1 is the default, so it is omitted from the map
      refute Map.has_key?(low, "priority")
    end
  end
end
