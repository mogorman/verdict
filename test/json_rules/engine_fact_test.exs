defmodule JsonRules.EngineFactTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Engine, UndefinedFactError}
  alias JsonRules.TestSupport

  @child 14
  @adult 75

  # Ported from the reference `engine-fact.test.js`. Fact *values* use string
  # keys (JSON shape) so the JSONPath resolver can traverse them.

  defp eligibility_field(params, _almanac) do
    if params[:field] == "age" do
      if params[:eligibilityId] == 1, do: @child, else: @adult
    end
  end

  defp eligibility_data(params, _almanac) do
    address = %{
      "street" => "123 Fake Street",
      "state" => %{"abbreviation" => "CO", "name" => "Colorado"},
      "zip" => "80403",
      "dot.property" => "dot-property-value",
      "occupantHistory" => [
        %{"name" => "Joe", "year" => 2011},
        %{"name" => "Jane", "year" => 2013}
      ],
      "currentOccupants" => [%{"name" => "Larry", "year" => 2020}]
    }

    age = if params[:eligibilityId] == 1, do: @child, else: @adult
    %{"age" => age, "address" => address}
  end

  defp build(conditions, opts \\ []) do
    Engine.new(opts)
    |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "ageTrigger"}})
    |> Engine.add_fact("eligibilityField", &eligibility_field/2)
    |> Engine.add_fact("eligibilityData", &eligibility_data/2)
  end

  defp emits?(result), do: Enum.any?(result.events, &(&1.type == "ageTrigger"))

  defp base_conditions(id) do
    %{
      any: [
        %{
          fact: "eligibilityField",
          operator: "lessThan",
          params: %{eligibilityId: id, field: "age"},
          value: 50
        }
      ]
    }
  end

  defp path_condition(path, value, operator) do
    %{any: [%{fact: "eligibilityData", operator: operator, path: path, value: value}]}
  end

  describe "params" do
    test "emits when the condition is met" do
      assert emits?(Engine.run(build(base_conditions(1)), %{}))
    end

    test "does not emit when the condition fails" do
      refute emits?(Engine.run(build(base_conditions(2)), %{}))
    end
  end

  describe "path" do
    test "resolves a simple path" do
      conditions = %{
        any: [
          %{
            fact: "eligibilityData",
            operator: "lessThan",
            path: "$.age",
            params: %{eligibilityId: 1},
            value: 50
          }
        ]
      }

      assert emits?(Engine.run(build(conditions), %{}))
    end

    test "does not emit when the path-resolved value fails" do
      # eligibilityId 2 -> age 75; the condition below resolves $.age == 75
      conditions = %{
        any: [
          %{
            fact: "eligibilityData",
            operator: "lessThan",
            path: "$.age",
            params: %{eligibilityId: 2},
            value: 50
          }
        ]
      }

      refute emits?(Engine.run(build(conditions), %{}))
    end

    test "extracts an array for use with array operators" do
      assert emits?(
               Engine.run(
                 build(path_condition("$.address.occupantHistory[*].year", 2011, "contains")),
                 %{}
               )
             )
    end

    test "extracts a single-element array" do
      assert emits?(
               Engine.run(
                 build(path_condition("$.address.currentOccupants[*].year", 2020, "contains")),
                 %{}
               )
             )
    end

    test "interprets an index path" do
      assert emits?(
               Engine.run(
                 build(path_condition("$.address.occupantHistory[0].year", 2011, "equal")),
                 %{}
               )
             )
    end

    test "interprets a bracket-quoted key with a dot" do
      assert emits?(
               Engine.run(
                 build(
                   path_condition("$.address.['dot.property']", "dot-property-value", "equal")
                 ),
                 %{}
               )
             )
    end

    test "does not emit when the path-resolved value does not match" do
      refute emits?(
               Engine.run(
                 build(path_condition("$.address.occupantHistory[0].year", 2010, "equal")),
                 %{}
               )
             )
    end

    test "resolves a path against a runtime fact object" do
      conditions = %{all: [%{fact: "x", path: "$.y", operator: "equal", value: 1}]}

      engine =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "ageTrigger"}})

      assert emits?(Engine.run(engine, %{"x" => %{"y" => 1}, "a" => 2}))
    end

    test "treats an invalid path as undefined" do
      assert emits?(
               Engine.run(build(path_condition("$.invalid.object[99].path", nil, "equal")), %{})
             )
    end

    test "ignores the path when the fact is not an object" do
      conditions = path_condition("$.age", 50, "lessThan")
      engine = build(conditions) |> Engine.add_fact("eligibilityData", fn _p, _a -> @child end)
      assert emits?(Engine.run(engine, %{}))
    end

    test "honors a custom path_resolver" do
      conditions = %{all: [%{fact: "x", path: "y[0]", operator: "equal", value: 99}]}

      resolver = fn value, path ->
        [key, rest] = String.split(path, "[", parts: 2)

        index =
          rest |> String.trim_leading("[") |> String.trim_trailing("]") |> String.to_integer()

        value |> Map.get(key) |> Enum.at(index)
      end

      engine =
        Engine.new(path_resolver: resolver)
        |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "ageTrigger"}})

      assert emits?(Engine.run(engine, %{"x" => %{"y" => [99]}}))
    end
  end

  describe "allow_undefined_facts" do
    test "throws when a fact is undefined by default" do
      conditions = %{all: [%{fact: "undefined-fact", operator: "equal", value: true}]}

      engine =
        Engine.new() |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "e"}})

      assert_raise UndefinedFactError, ~r/Undefined fact: undefined-fact/, fn ->
        Engine.run(engine, %{})
      end
    end

    test "treats undefined facts as falsey when enabled" do
      # The undefined fact is given higher priority so it is evaluated (and
      # resolves to nil) before the passing condition short-circuits the `any`.
      conditions = %{
        any: [
          %{fact: "undefined-fact", operator: "equal", value: true, priority: 10},
          %{
            fact: "eligibilityField",
            operator: "lessThan",
            params: %{eligibilityId: 1, field: "age"},
            value: 50
          }
        ]
      }

      engine = build(conditions, allow_undefined_facts: true)
      assert emits?(Engine.run(engine, %{}))
    end

    test "fails the rule when every condition is falsey" do
      conditions = %{
        any: [
          %{fact: "undefined-fact", operator: "equal", value: true, priority: 10},
          %{
            fact: "eligibilityField",
            operator: "lessThan",
            params: %{eligibilityId: 2, field: "age"},
            value: 50
          }
        ]
      }

      engine = build(conditions, allow_undefined_facts: true)
      refute emits?(Engine.run(engine, %{}))
    end
  end

  describe "synchronous facts" do
    test "works with synchronous, truthy values" do
      engine =
        build(base_conditions(1)) |> Engine.add_fact("eligibilityField", fn _p, _a -> 20 end)

      assert emits?(Engine.run(engine, %{}))
    end

    test "works with synchronous, falsey values" do
      engine =
        build(base_conditions(1)) |> Engine.add_fact("eligibilityField", fn _p, _a -> 100 end)

      refute emits?(Engine.run(engine, %{}))
    end
  end
end
