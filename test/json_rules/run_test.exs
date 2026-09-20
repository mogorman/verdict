defmodule JsonRules.RunTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{RuleResult, RunResult}

  @rule %{
    event: %{type: "ok"},
    conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
  }

  @rule_json ~s({"event": {"type": "ok"}, "conditions": {"all": [{"fact": "x", "operator": "equal", "value": 1}]}})

  describe "run/3" do
    test "accepts a rule map and a facts map" do
      assert {:ok, %RunResult{events: [event]}} = JsonRules.run(@rule, %{x: 1})
      assert event.type == "ok"
    end

    test "accepts a single rule as a JSON object and facts as a JSON object" do
      assert {:ok, %RunResult{events: [event]}} = JsonRules.run(@rule_json, ~s({"x": 1}))
      assert event.type == "ok"
    end

    test "accepts an array of rules as JSON" do
      rules_json = "[#{@rule_json}, #{@rule_json}]"
      assert {:ok, %RunResult{events: [_a, _b]}} = JsonRules.run(rules_json, %{x: 1})
    end

    test "accepts a %Rule{} struct" do
      {:ok, _engine, rule} = JsonRules.Engine.add_rule(JsonRules.Engine.new(), @rule)
      assert {:ok, %RunResult{events: [event]}} = JsonRules.run(rule, %{x: 1})
      assert event.type == "ok"
    end

    test "accepts a list mixing maps and structs" do
      {:ok, _engine, rule} = JsonRules.Engine.add_rule(JsonRules.Engine.new(), @rule)
      assert {:ok, %RunResult{events: [_a, _b]}} = JsonRules.run([@rule, rule], %{x: 1})
    end

    test "accepts a dynamic (function) fact via the facts map" do
      rule = %{
        event: %{type: "ok"},
        conditions: %{all: [%{fact: "double", operator: "equal", value: 4}]}
      }

      assert {:ok, %RunResult{events: [event]}} =
               JsonRules.run(rule, %{double: fn _params, _almanac -> 4 end})

      assert event.type == "ok"
    end

    test "empty rules yield no events" do
      assert {:ok, %RunResult{events: []}} = JsonRules.run([], %{})
    end

    test "returns {:error, changeset} for an invalid rule" do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               JsonRules.run(%{event: %{type: "ok"}}, %{})
    end

    test "returns {:error, {:bad_json, _}} for malformed JSON" do
      assert {:error, {:bad_json, _message}} = JsonRules.run("{not json", %{})
    end
  end

  describe "run!/3" do
    test "returns the RunResult directly" do
      assert %RunResult{events: [event]} = JsonRules.run!(@rule, %{x: 1})
      assert event.type == "ok"
    end

    test "raises InvalidRuleError on an invalid rule" do
      assert_raise JsonRules.InvalidRuleError, ~r/Invalid rule/, fn ->
        JsonRules.run!(%{event: %{type: "ok"}}, %{})
      end
    end

    test "InvalidRuleError carries the failing changeset" do
      try do
        JsonRules.run!(%{event: %{type: "ok"}}, %{})
        flunk("expected JsonRules.InvalidRuleError")
      rescue
        error in JsonRules.InvalidRuleError ->
          assert %Ecto.Changeset{valid?: false} = error.changeset
          assert [{:conditions, _}] = error.changeset.errors
          assert Exception.message(error) =~ "Invalid rule: conditions: can't be blank"
      end
    end

    test "raises InvalidJSONError on malformed JSON" do
      assert_raise JsonRules.InvalidJSONError, ~r/Invalid JSON/, fn ->
        JsonRules.run!("{nope", %{})
      end
    end

    test "InvalidJSONError carries the reason and input" do
      try do
        JsonRules.run!("{nope", %{})
        flunk("expected JsonRules.InvalidJSONError")
      rescue
        error in JsonRules.InvalidJSONError ->
          assert is_binary(error.reason)
          assert error.input == "{nope"
          assert Exception.message(error) =~ "Invalid JSON"
      end
    end
  end

  describe "options passthrough" do
    test "strict: true evaluates every condition (short-circuit off)" do
      rule = %{
        event: %{type: "ok"},
        conditions: %{
          any: [
            %{fact: "a", operator: "equal", value: 1},
            %{fact: "b", operator: "equal", value: 1}
          ]
        }
      }

      %RunResult{results: [%RuleResult{changeset: short_cs}]} =
        JsonRules.run!(rule, %{a: 1, b: 1})

      assert Enum.any?(short_cs.empty_values, &(&1.fact == "b"))

      %RunResult{results: [%RuleResult{changeset: strict_cs}]} =
        JsonRules.run!(rule, %{a: 1, b: 1}, strict: true)

      assert strict_cs.empty_values == []
    end

    test "schedule: :parallel" do
      assert %RunResult{events: [event]} = JsonRules.run!(@rule, %{x: 1}, schedule: :parallel)
      assert event.type == "ok"
    end

    test "store: :genserver" do
      assert %RunResult{events: [event]} = JsonRules.run!(@rule, %{x: 1}, store: :genserver)
      assert event.type == "ok"
    end

    test "log: :error is accepted and silent on a successful run" do
      assert %RunResult{events: [event]} = JsonRules.run!(@rule, %{x: 1}, log: :error)
      assert event.type == "ok"
    end
  end

  describe "unsupported input types" do
    test "rules must be a map, struct, list, or JSON string" do
      assert_raise ArgumentError, ~r/rules must be/, fn ->
        JsonRules.run!(42, %{})
      end
    end

    test "facts must be a map or JSON string" do
      assert_raise ArgumentError, ~r/facts must be/, fn ->
        JsonRules.run!(@rule, 42)
      end
    end

    test "each list element must be a rule" do
      assert_raise ArgumentError, ~r/each rule must be/, fn ->
        JsonRules.run!([42], %{})
      end
    end
  end
end
