defmodule Verdict.RunResultTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}

  # Three rules: one that passes (all), one that passes with a short-circuit (any),
  # and one that fails (all). Facts return JSON-encodable values so the whole
  # result serializes to JSON.
  defp engine do
    engine =
      Engine.new()
      |> Engine.add_fact("age", 30)
      |> Engine.add_fact("segment", "european")

    {:ok, engine, _} =
      Engine.add_rule(engine, %{
        name: "young-european",
        priority: 5,
        event: %{type: "targeted", params: %{"audience" => "under-40"}},
        conditions: %{
          all: [
            %{fact: "age", operator: "lessThan", value: 40},
            %{fact: "segment", operator: "equal", value: "european"}
          ]
        }
      })

    {:ok, engine, _} =
      Engine.add_rule(engine, %{
        name: "either",
        priority: 3,
        event: %{type: "either"},
        conditions: %{
          any: [
            %{fact: "segment", operator: "equal", value: "european"},
            %{fact: "age", operator: "equal", value: 999}
          ]
        }
      })

    {:ok, engine, _} =
      Engine.add_rule(engine, %{
        name: "senior",
        event: %{type: "senior-offer"},
        failure_event: %{type: "not-senior"},
        conditions: %{all: [%{fact: "age", operator: "greaterThan", value: 65}]}
      })

    engine
  end

  describe "RunResult.to_map/1" do
    test "serializes events, failure events, and per-rule results" do
      map = engine() |> Engine.run(%{}) |> RunResult.to_map()

      assert Enum.map(map["events"], & &1["type"]) == ["targeted", "either"]
      assert Enum.map(map["failure_events"], & &1["type"]) == ["not-senior"]

      # Results are in descending priority order.
      [passed, short_circuited, failed] = map["results"]
      assert Enum.map(map["results"], & &1["name"]) == ["young-european", "either", "senior"]

      # A passing rule.
      assert passed["name"] == "young-european"
      assert passed["priority"] == 5
      assert passed["result"] == true
      assert passed["event"] == %{"type" => "targeted", "params" => %{"audience" => "under-40"}}
      refute Map.has_key?(passed, "failure_event")
      assert passed["conditions"]["result"] == true
      assert passed["conditions"]["errors"] == []
      assert passed["conditions"]["empty_values"] == []

      age_leaf = find_leaf(passed["conditions"]["changes"], "age")

      assert age_leaf == %{
               "fact" => "age",
               "operator" => "lessThan",
               "value" => 40,
               "actual" => 30,
               "factResult" => 30,
               "result" => true
             }

      # A rule that short-circuited: the deciding leaf passed, the other was skipped.
      assert short_circuited["result"] == true
      assert find_leaf(short_circuited["conditions"]["changes"], "segment")["result"] == true
      assert short_circuited["conditions"]["errors"] == []

      [skipped] = short_circuited["conditions"]["empty_values"]
      assert skipped == %{"fact" => "age", "operator" => "equal", "value" => 999}

      # A failing rule: the leaf is reported under errors, and only its
      # failure event appears (no "event" key).
      assert failed["name"] == "senior"
      assert failed["priority"] == 1
      assert failed["result"] == false
      assert failed["failure_event"] == %{"type" => "not-senior"}
      refute Map.has_key?(failed, "event")
      assert failed["conditions"]["result"] == false
      assert failed["conditions"]["changes"] == []

      [error_leaf] = failed["conditions"]["errors"]

      assert error_leaf == %{
               "fact" => "age",
               "operator" => "greaterThan",
               "value" => 65,
               "actual" => 30,
               "factResult" => 30,
               "result" => false
             }
    end

    test "the serialized result is JSON-encodable and round-trips" do
      map = engine() |> Engine.run(%{}) |> RunResult.to_map()

      json = map |> :json.encode() |> IO.iodata_to_binary()
      assert is_binary(json)
      assert :json.decode(json) == map
    end
  end

  defp find_leaf(leaves, fact) do
    Enum.find(leaves, fn leaf -> leaf["fact"] == fact end)
  end
end
