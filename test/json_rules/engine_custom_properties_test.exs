defmodule JsonRules.EngineCustomPropertiesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Condition, Engine, Types}
  alias JsonRules.TestSupport

  # Ported from the reference `engine-custom-properties.test.js`. Custom
  # properties live in an explicit `extra` map on the rule and on each condition
  # (the reference engine preserves arbitrary top-level keys instead). Facts are
  # opaque terms and do not carry custom properties.

  describe "extra" do
    test "is preserved on a rule" do
      {_engine, rule} = TestSupport.add_rule_with(Engine.new(), %{extra: %{customId: "uuid"}})
      assert rule.extra == %{customId: "uuid"}
    end

    test "is preserved on a boolean condition" do
      conditions = %{
        extra: %{customId: "uuid1"},
        all: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]
      }

      {_engine, rule} = TestSupport.add_rule_with(Engine.new(), %{conditions: conditions})
      assert %Condition{kind: :all, extra: %{customId: "uuid1"}} = rule.conditions
    end

    test "is preserved on a leaf condition" do
      conditions = %{
        all: [
          %{extra: %{customId: "uuid"}, fact: "age", operator: "greaterThanInclusive", value: 18}
        ]
      }

      {_engine, rule} = TestSupport.add_rule_with(Engine.new(), %{conditions: conditions})
      assert [%Condition{kind: :leaf, extra: %{customId: "uuid"}}] = rule.conditions.children
    end

    test "round-trips through the condition JSON map" do
      {_engine, rule} =
        TestSupport.add_rule_with(Engine.new(), %{
          conditions: %{all: [%{extra: %{note: "y"}, fact: "age", operator: "equal", value: 1}]}
        })

      map = Types.Condition.to_map(rule.conditions)
      assert Enum.at(map["all"], 0)["extra"] == %{note: "y"}
    end
  end
end
