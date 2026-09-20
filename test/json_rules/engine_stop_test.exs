defmodule JsonRules.EngineStopTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Almanac, Engine, RunResult}
  alias JsonRules.TestSupport

  @event %{type: "adult-human-admins"}

  defp stopped_engine(age_counter, segment_counter) do
    Engine.new()
    |> TestSupport.add_rule(%{
      conditions: %{any: [%{fact: "age", operator: "greaterThanInclusive", value: 18}]},
      event: @event,
      priority: 100
    })
    |> TestSupport.add_rule(%{
      conditions: %{any: [%{fact: "segment", operator: "equal", value: "human"}]},
      event: @event
    })
    |> Engine.add_fact("age", fn _p, _a ->
      TestSupport.inc(age_counter)
      20
    end)
    |> Engine.add_fact("segment", fn _p, _a ->
      TestSupport.inc(segment_counter)
      "human"
    end)
    |> Engine.on("success", fn _event, almanac, _rr ->
      Almanac.stop(almanac)
    end)
  end

  test "stop() halts the run: later rules are skipped and their facts never computed" do
    age_counter = TestSupport.start_counter()
    segment_counter = TestSupport.start_counter()

    %RunResult{events: events} = Engine.run(stopped_engine(age_counter, segment_counter))

    # only the higher-priority rule fired before the stop
    assert length(events) == 1
    assert TestSupport.count(age_counter) == 1
    assert TestSupport.count(segment_counter) == 0
  end
end
