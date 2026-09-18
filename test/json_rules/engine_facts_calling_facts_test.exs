defmodule JsonRules.EngineFactsCallingFactsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Almanac, Engine, RunResult}
  alias JsonRules.TestSupport

  @event %{type: "early-twenties"}
  @data %{"age" => 20, "zipCode" => 80211}

  defp base_engine(data_counter, demo_counter) do
    Engine.new()
    |> Engine.add_fact("demographic-data", fn _params, _almanac ->
      TestSupport.inc(data_counter)
      @data
    end)
    |> Engine.add_fact("demographics", fn params, almanac ->
      TestSupport.inc(demo_counter)
      data = Almanac.fact_value(almanac, "demographic-data")
      Map.fetch!(data, params["field"])
    end)
  end

  test "a fact can retrieve other fact values; cache keys vary with params" do
    data_counter = TestSupport.start_counter()
    demo_counter = TestSupport.start_counter()

    engine =
      base_engine(data_counter, demo_counter)
      |> TestSupport.add_rule(%{
        event: @event,
        conditions: %{
          all: [
            %{
              fact: "demographics",
              params: %{"field" => "age"},
              operator: "lessThanInclusive",
              value: 25
            },
            %{
              fact: "demographics",
              params: %{"field" => "zipCode"},
              operator: "equal",
              value: 80211
            }
          ]
        }
      })

    %RunResult{events: events} = Engine.run(engine)
    assert length(events) == 1
    assert TestSupport.count(data_counter) == 1
    assert TestSupport.count(demo_counter) == 2
  end

  test "a fact value is shared across rules referencing the same params" do
    data_counter = TestSupport.start_counter()
    demo_counter = TestSupport.start_counter()

    engine =
      base_engine(data_counter, demo_counter)
      |> TestSupport.add_rule(%{
        event: @event,
        conditions: %{
          all: [
            %{
              fact: "demographics",
              params: %{"field" => "age"},
              operator: "lessThanInclusive",
              value: 25
            },
            %{
              fact: "demographics",
              params: %{"field" => "zipCode"},
              operator: "equal",
              value: 80211
            }
          ]
        }
      })
      |> TestSupport.add_rule(%{
        event: @event,
        conditions: %{
          all: [
            %{
              fact: "demographics",
              params: %{"field" => "age"},
              operator: "greaterThanInclusive",
              value: 20
            }
          ]
        }
      })

    %RunResult{events: events} = Engine.run(engine)
    assert length(events) == 2
    assert TestSupport.count(data_counter) == 1
    assert TestSupport.count(demo_counter) == 2
  end
end
