defmodule JsonRules.EngineFactComparisonTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Almanac, Engine, RunResult}
  alias JsonRules.TestSupport

  # Ported from the reference `engine-fact-comparison.test.js`.

  defp fires?(engine, facts) do
    %RunResult{events: events} = Engine.run(engine, facts)
    length(events) > 0
  end

  describe "constant facts" do
    test "compares one fact against another" do
      conditions = %{
        all: [%{fact: "height", operator: "lessThanInclusive", value: %{fact: "width"}}]
      }

      engine =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "success-event"}})

      assert fires?(engine, %{height: 1, width: 2})
      refute fires?(engine, %{height: 2, width: 1})
    end

    test "records the resolved fact (actual) and value" do
      conditions = %{
        all: [%{fact: "height", operator: "lessThanInclusive", value: %{fact: "width"}}]
      }

      engine =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "success-event"}})

      %RunResult{results: [rr]} = Engine.run(engine, %{height: 1, width: 2})
      [{:height, info}] = rr.changeset.changes
      assert info[:actual] == 1
      assert info[:value] == 2
    end
  end

  describe "parameterized conditions" do
    test "honors params on both sides" do
      conditions = %{
        all: [
          %{
            fact: "widthMultiplier",
            params: %{multiplier: 2},
            operator: "equal",
            value: %{fact: "heightMultiplier", params: %{multiplier: 4}}
          }
        ]
      }

      engine =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "success-event"}})
        |> Engine.add_fact("heightMultiplier", fn params, almanac ->
          params[:multiplier] * Almanac.fact_value(almanac, "height", %{})
        end)
        |> Engine.add_fact("widthMultiplier", fn params, almanac ->
          params[:multiplier] * Almanac.fact_value(almanac, "width", %{})
        end)

      assert fires?(engine, %{height: 5, width: 10})
      refute fires?(engine, %{height: 5, width: 9})
    end
  end

  describe "parameterized conditions with path values" do
    test "honors the path on both sides" do
      conditions = %{
        all: [
          %{
            fact: "widthMultiplier",
            params: %{multiplier: 2},
            path: "$.feet",
            operator: "equal",
            value: %{fact: "heightMultiplier", params: %{multiplier: 4}, path: "$.meters"}
          }
        ]
      }

      engine =
        Engine.new()
        |> TestSupport.add_rule(%{conditions: conditions, event: %{type: "success-event"}})
        |> Engine.add_fact("heightMultiplier", fn params, almanac ->
          %{"meters" => params[:multiplier] * Almanac.fact_value(almanac, "height", %{})}
        end)
        |> Engine.add_fact("widthMultiplier", fn params, almanac ->
          %{"feet" => params[:multiplier] * Almanac.fact_value(almanac, "width", %{})}
        end)

      assert fires?(engine, %{height: 5, width: 10})
      refute fires?(engine, %{height: 5, width: 9})
    end
  end
end
