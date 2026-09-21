defmodule Verdict.RuleResult do
  @moduledoc """
  The outcome of evaluating a single rule during a run.

  A rule result carries the evaluated `rule`, its evaluation `changeset` (the
  report described in `Verdict.Evaluation`), the `event` the rule emits, and
  whether the rule fired (`valid?`). The same struct is handed to event
  callbacks (`Verdict.Engine.on/3`) as their third argument and collected into
  `Verdict.RunResult.results`.

  `event` is the rule's declared event; when the engine is configured with
  `replace_facts_in_event_params: true`, the fact references in `event.params`
  are resolved to their computed values first.
  """
  alias Verdict.{Event, Rule}

  defstruct [:rule, :changeset, :event, valid?: false]

  @type t :: %__MODULE__{
          rule: Rule.t(),
          changeset: Ecto.Changeset.t(),
          event: Event.t(),
          valid?: boolean()
        }

  @doc """
  Serializes the rule result into a JSON-compatible map (string keys).

  Carries the rule's `name` and `priority`, its `event` (via
  `Verdict.Event.to_map/1`), whether it fired (`result`), and a `conditions`
  report: the leaves that were evaluated — `changes` (passed) and `errors`
  (failed), each with the `operator`, the expected `value`, the path-resolved
  `actual`, and the raw computed `factResult` — plus any leaves short-circuited
  before they were reached (`empty_values`).

  The leaf values (`value`, `actual`, `factResult`) are the raw Elixir terms the
  engine computed; the map is JSON-encodable as long as the facts produce
  JSON-compatible data (string-keyed maps, lists, numbers, strings, booleans,
  `nil`).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = rule_result) do
    %{
      "name" => rule_result.rule.name,
      "priority" => rule_result.rule.priority,
      "result" => rule_result.valid?,
      "event" => Event.to_map(rule_result.event),
      "conditions" => conditions_map(rule_result.changeset)
    }
  end

  defp conditions_map(changeset) do
    facts = (changeset.data || %{})[:facts] || %{}

    %{
      "result" => changeset.valid?,
      "changes" =>
        Enum.map(changeset.changes, fn {field, info} ->
          leaf(
            fact_name(field),
            info[:operator],
            info[:value],
            info[:actual],
            Map.get(facts, field),
            true
          )
        end),
      "errors" =>
        Enum.map(changeset.errors, fn {field, {_message, meta}} ->
          leaf(
            fact_name(field),
            Keyword.get(meta, :operator),
            Keyword.get(meta, :value),
            Keyword.get(meta, :actual),
            Map.get(facts, field),
            false
          )
        end),
      "empty_values" => Enum.map(changeset.empty_values || [], &skipped/1)
    }
  end

  defp leaf(fact, operator, value, actual, fact_result, passed?) do
    %{
      "fact" => fact,
      "operator" => operator,
      "value" => value,
      "actual" => actual,
      "factResult" => fact_result,
      "result" => passed?
    }
  end

  # An `empty_values` entry is a plain descriptor map with atom keys.
  defp skipped(descriptor) do
    base = %{
      "fact" => Map.get(descriptor, :fact),
      "operator" => Map.get(descriptor, :operator),
      "value" => Map.get(descriptor, :value)
    }

    base = if path = Map.get(descriptor, :path), do: Map.put(base, "path", path), else: base

    if params = Map.get(descriptor, :params), do: Map.put(base, "params", params), else: base
  end

  defp fact_name(field), do: to_string(field)
end
