defmodule JsonRules.ConditionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias JsonRules.{Condition, Rule}
  alias JsonRules.Types.Condition, as: ConditionType

  describe "ConditionType.from_map/1 (structural cast)" do
    test "builds a leaf" do
      assert {:ok, %Condition{kind: :leaf, fact: "x", operator: "equal", value: 1}} =
               ConditionType.from_map(%{"fact" => "x", "operator" => "equal", "value" => 1})
    end

    test "builds nested all / any / not" do
      assert {:ok, %Condition{kind: :all, children: [first, second, third]}} =
               ConditionType.from_map(%{
                 all: [
                   %{fact: "a", operator: "equal", value: 1},
                   %{any: [%{fact: "b", operator: "in", value: [1]}]},
                   %{not: %{fact: "c", operator: "equal", value: 2}}
                 ]
               })

      assert first.kind == :leaf
      assert second.kind == :any
      assert is_list(second.children)
      assert third.kind == :not
      assert is_struct(third.child, Condition)
    end

    test "accepts atom keys as well as string keys" do
      assert {:ok, %Condition{kind: :all}} =
               ConditionType.from_map(%{all: [%{fact: "a", operator: "equal", value: 1}]})
    end

    test "defaults priority to 1 and honours an explicit priority" do
      assert {:ok, %Condition{priority: 1}} =
               ConditionType.from_map(%{fact: "a", operator: "equal", value: 1})

      assert {:ok, %Condition{priority: 7}} =
               ConditionType.from_map(%{fact: "a", operator: "equal", value: 1, priority: 7})
    end

    test "a condition reference becomes a :ref node" do
      assert {:ok, %Condition{kind: :ref, ref: "validLogin"}} =
               ConditionType.from_map(%{"condition" => "validLogin"})
    end

    test "errors when a leaf is missing a fact" do
      assert {:error, _} = ConditionType.from_map(%{"operator" => "equal", "value" => 1})
    end

    test "errors when a leaf is missing an operator" do
      assert {:error, _} = ConditionType.from_map(%{"fact" => "a", "value" => 1})
    end

    test "errors when all is not a list" do
      assert {:error, _} = ConditionType.from_map(%{"all" => %{}})
    end

    test "errors when not is not a condition" do
      assert {:error, _} = ConditionType.from_map(%{"not" => 12})
    end

    test "errors on an unknown node shape" do
      assert {:error, _} = ConditionType.from_map(%{"foo" => "bar"})
    end
  end

  describe "ConditionType.to_map/1 (round-trip)" do
    test "round-trips a leaf" do
      original = %{"fact" => "x", "operator" => "equal", "value" => 1}
      assert {:ok, tree} = ConditionType.from_map(original)
      assert ConditionType.to_map(tree) == original
    end

    test "round-trips a nested tree with priorities" do
      original = %{
        "all" => [
          %{"fact" => "a", "operator" => "equal", "value" => 1},
          %{"not" => %{"fact" => "b", "operator" => "equal", "value" => 2}, "priority" => 3}
        ]
      }

      assert {:ok, tree} = ConditionType.from_map(original)
      assert ConditionType.to_map(tree) == original
    end
  end

  describe "Rule.changeset/2" do
    test "accepts a valid rule and generates an id" do
      changeset =
        Rule.changeset(%Rule{}, %{
          name: "r",
          event: %{type: "e"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
        })

      assert changeset.valid?
      rule = Ecto.Changeset.apply_changes(changeset)
      assert is_binary(rule.id)
      assert rule.event.type == "e"
      assert rule.priority == 1
    end

    test "requires an event" do
      changeset =
        Rule.changeset(%Rule{}, %{conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}})

      refute changeset.valid?
      assert error_for(changeset, :event)
    end

    test "requires an event type" do
      changeset =
        Rule.changeset(%Rule{}, %{
          event: %{},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
        })

      refute changeset.valid?

      assert Enum.any?(changeset.changes.event.errors, fn {field, _} -> field == :type end)
    end

    test "requires conditions" do
      changeset = Rule.changeset(%Rule{}, %{event: %{type: "e"}})
      refute changeset.valid?
      assert error_for(changeset, :conditions)
    end

    test "rejects a non-positive priority" do
      changeset =
        Rule.changeset(%Rule{}, %{
          event: %{type: "e"},
          priority: 0,
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
        })

      refute changeset.valid?
      assert error_for(changeset, :priority)
    end

    test "rejects an unknown operator" do
      changeset =
        Rule.changeset(%Rule{}, %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "x", operator: "nope", value: 1}]}
        })

      refute changeset.valid?
      assert error_for(changeset, :conditions)
    end

    test "rejects a leaf as the root" do
      changeset =
        Rule.changeset(%Rule{}, %{
          event: %{type: "e"},
          conditions: %{fact: "x", operator: "equal", value: 1}
        })

      refute changeset.valid?
      assert error_for(changeset, :conditions)
    end
  end

  defp error_for(changeset, field) do
    Enum.find_value(changeset.errors, fn
      {^field, {message, _}} -> message
      {^field, message} -> message
      _ -> false
    end)
  end
end
