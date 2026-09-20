defmodule JsonRules.RunResult do
  @moduledoc """
  The outcome of a single `JsonRules.Engine.run/3` call.

  `results` is a list of `JsonRules.RuleResult` (in priority order); each carries
  its rule, evaluation report, event, and outcome. `events` / `failure_events`
  are the events of the valid / invalid rules respectively.
  """
  alias JsonRules.{Event, RuleResult}

  defstruct events: [], failure_events: [], results: []

  @type t :: %__MODULE__{
          events: [Event.t()],
          failure_events: [Event.t()],
          results: [RuleResult.t()]
        }

  @doc """
  Serializes the run result into a JSON-compatible map (string keys).

  `events` / `failure_events` are the events of the fired / not-fired rules (via
  `JsonRules.Event.to_map/1`); `results` is one entry per rule, in priority order
  (via `JsonRules.RuleResult.to_map/1`). See that function for the leaf-report
  shape and the JSON-encodability note on fact values.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = run_result) do
    %{
      "events" => Enum.map(run_result.events, &Event.to_map/1),
      "failure_events" => Enum.map(run_result.failure_events, &Event.to_map/1),
      "results" => Enum.map(run_result.results, &RuleResult.to_map/1)
    }
  end
end
