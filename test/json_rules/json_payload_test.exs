defmodule JsonRules.JsonPayloadTest do
  @moduledoc """
  Guards the "JSON blob -> run" flow documented in the README: a raw JSON
  payload (rules + facts) is decoded with OTP 28's built-in `:json` module and
  driven through the public engine API.
  """
  use ExUnit.Case, async: true

  alias JsonRules.{Engine, RunResult}

  @payload """
  {
    "facts": {
      "gameDuration": 40,
      "personalFoulCount": 6
    },
    "rules": [
      {
        "name": "fouled-out",
        "priority": 5,
        "event": { "type": "fouledOut", "params": { "message": "Player has fouled out!" } },
        "conditions": {
          "any": [
            { "all": [
                { "fact": "gameDuration", "operator": "equal", "value": 40 },
                { "fact": "personalFoulCount", "operator": "greaterThanInclusive", "value": 5 }
              ]
            },
            { "all": [
                { "fact": "gameDuration", "operator": "equal", "value": 48 },
                { "fact": "personalFoulCount", "operator": "greaterThanInclusive", "value": 6 }
              ]
            }
          ]
        }
      }
    ]
  }
  """

  test "runs a decoded JSON payload end to end" do
    decoded = :json.decode(@payload)

    engine =
      Enum.reduce(decoded["rules"], Engine.new(), fn rule, engine ->
        {:ok, engine, _rule} = Engine.add_rule(engine, rule)
        engine
      end)

    %RunResult{events: [event], failure_events: [], results: [rr]} =
      Engine.run(engine, decoded["facts"])

    cs = rr.changeset

    assert event.type == "fouledOut"
    assert event.params == %{"message" => "Player has fouled out!"}
    assert rr.rule.name == "fouled-out"

    assert cs.valid?

    assert cs.changes == [
             {:gameDuration, %{value: 40, operator: "equal", actual: 40}},
             {:personalFoulCount, %{value: 5, operator: "greaterThanInclusive", actual: 6}}
           ]

    assert cs.errors == []
    assert cs.data.facts == %{gameDuration: 40, personalFoulCount: 6}

    # The second branch was short-circuited once the first one matched.
    skipped = Enum.map(cs.empty_values, & &1.fact)
    assert skipped == ["gameDuration", "personalFoulCount"]
    assert Enum.any?(cs.empty_values, &(&1.fact == "gameDuration" and &1.value == 48))
  end
end
