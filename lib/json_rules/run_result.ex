defmodule JsonRules.RunResult do
  @moduledoc """
  The outcome of a single `JsonRules.Engine.run/3` call.

  Holds the events and results for both the successful and failed rules.
  """
  alias JsonRules.{Event, RuleResult}

  defstruct events: [], failure_events: [], results: [], failure_results: []

  @type t :: %__MODULE__{
          events: [Event.t()],
          failure_events: [Event.t()],
          results: [RuleResult.t()],
          failure_results: [RuleResult.t()]
        }
end

defmodule JsonRules.RuleResult do
  @moduledoc """
  The outcome of evaluating a single rule: whether it succeeded and the event
  it would emit.
  """
  alias JsonRules.Event

  defstruct [:id, :name, :priority, :result, :event]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          priority: integer(),
          result: boolean(),
          event: Event.t() | nil
        }
end
