defmodule Verdict.ConditionTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Condition, Rule}
  alias Verdict.Types.Condition, as: ConditionType

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

    test "a leaf has no priority by default; an explicit priority is kept" do
      assert {:ok, %Condition{priority: nil}} =
               ConditionType.from_map(%{fact: "a", operator: "equal", value: 1})

      assert {:ok, %Condition{priority: 7}} =
               ConditionType.from_map(%{fact: "a", operator: "equal", value: 1, priority: 7})
    end

    test "a boolean node defaults its priority to 1" do
      assert {:ok, %Condition{priority: 1}} =
               ConditionType.from_map(%{all: [%{fact: "a", operator: "equal", value: 1}]})
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

  describe "ConditionType Ecto.Type callbacks" do
    test "type, embed_as, load, dump, and equal?" do
      assert ConditionType.type() == :map
      assert ConditionType.embed_as(:column) == :map

      {:ok, tree} = ConditionType.from_map(%{"fact" => "a", "operator" => "equal", "value" => 1})
      assert {:ok, ^tree} = ConditionType.load(tree)

      assert {:ok, %{"fact" => "a", "operator" => "equal", "value" => 1}} =
               ConditionType.dump(tree)

      assert ConditionType.equal?(tree, tree)
      refute ConditionType.equal?(tree, %{})
    end

    test "cast/1 passes a Condition through and rejects nil or non-maps" do
      {:ok, tree} = ConditionType.from_map(%{"fact" => "a", "operator" => "equal", "value" => 1})
      assert {:ok, ^tree} = ConditionType.cast(tree)
      assert {:ok, _} = ConditionType.cast(%{"fact" => "a", "operator" => "equal", "value" => 1})
      assert {:error, _} = ConditionType.cast(nil)
      assert {:error, _} = ConditionType.cast("nope")
    end
  end

  describe "ConditionType from_map/to_map edges" do
    test "a leaf with path and params round-trips" do
      original = %{
        "fact" => "obj",
        "operator" => "equal",
        "value" => 1,
        "path" => "$.a",
        "params" => %{"p" => 1}
      }

      assert {:ok, tree} = ConditionType.from_map(original)
      assert ConditionType.to_map(tree) == original
    end

    test "a node with an extra map round-trips" do
      original = %{
        "all" => [%{"fact" => "a", "operator" => "equal", "value" => 1}],
        "extra" => %{"owner" => "me"}
      }

      assert {:ok, tree} = ConditionType.from_map(original)
      assert ConditionType.to_map(tree) == original
    end

    test "rejects an empty reference, a non-string path, and non-map params" do
      assert {:error, _} = ConditionType.from_map(%{"condition" => ""})

      assert {:error, _} =
               ConditionType.from_map(%{"fact" => "a", "operator" => "equal", "path" => 12})

      assert {:error, _} =
               ConditionType.from_map(%{"fact" => "a", "operator" => "equal", "params" => 12})
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

    test "accepts an unknown operator (existence is checked at run time)" do
      # Operator existence is validated during evaluation, where the engine's
      # custom operators are known — not at cast time.
      changeset =
        Rule.changeset(%Rule{}, %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "x", operator: "nope", value: 1}]}
        })

      assert changeset.valid?
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

    test "rejects a non-positive priority on a condition" do
      changeset =
        Rule.changeset(%Rule{}, %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1, priority: 0}]}
        })

      refute changeset.valid?
      assert error_for(changeset, :conditions)
    end

    test "keeps an existing id instead of generating one" do
      changeset =
        Rule.changeset(%Rule{id: "keep-me"}, %{
          event: %{type: "e"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 1}]}
        })

      assert Ecto.Changeset.apply_changes(changeset).id == "keep-me"
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
