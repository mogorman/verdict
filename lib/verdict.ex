defmodule Verdict do
  @moduledoc """
  A rules engine expressed as data, modelled with Ecto and evaluated in Elixir.

  `Verdict` is an Elixir/Ecto reimplementation of
  [json-rules-engine](https://github.com/CacheControl/json-rules-engine).
  Rules are composed of simple, easy-to-read condition trees (expressed as
  maps, JSON-compatible) plus a single event. When the engine runs, each
  rule's conditions are evaluated against a set of *facts*; if the result is
  truthy the rule's event is emitted as a success, otherwise as a failure.

  ## Modelled with Ecto, stored without a database

  A `Verdict.Rule`, its `Verdict.Event`, and the recursive
  `Verdict.Condition` tree are Ecto schema / embedded-schema / custom-type
  definitions. An `Ecto.Changeset` casts and validates the JSON-shaped input
  into typed structs. No `Ecto.Repo` and no database are used: the validated
  structs are held by a pluggable, in-memory `Verdict.Store`.

  ## A layered store

  The store is selectable at engine construction so overhead scales with the
  workload:

    * `:pure`      – the engine is a plain struct; no process. (default)
    * `:genserver` – a stateful store in a GenServer's process state.
    * `:ets`       – a GenServer with rules/facts in public ETS tables.

  ## Serial or parallel evaluation

  Scheduling is orthogonal to the store and selectable via the `:schedule`
  option:

    * `:serial`   – evaluate priority buckets one at a time. (default)
    * `:parallel` – run every item in a priority bucket concurrently, then move
      to the next bucket.

  Both rules and conditions carry a `priority` (default 1); higher priority
  runs first. Facts are computed lazily and cached in a per-run
  `Verdict.Almanac`.

  ## One-shot return

  `return/3` and `return!/3` build an engine, register the given rules, and run them
  in a single call. `rules` may be a JSON string (a rule object or an array of
  them), a map, a `Verdict.Rule` struct, or a list of any of those; `facts`
  may be a JSON string or a map of `name` to value (a value may be a function
  for a dynamic fact). The options accept any `Verdict.Engine.new/1` option.

  ## Modules

  The engine is split into focused modules, each with its own reference:

    * [`Verdict.Engine`](Verdict.Engine) — the public API: build an engine, add
      rules / facts / operators / named conditions, register callbacks, and run.
    * [`Verdict`](Verdict) — the one-shot `return/3` / `return!/3` entry point
      (this module).
    * [`Verdict.Rule`](Verdict.Rule), [`Verdict.Event`](Verdict.Event),
      [`Verdict.Condition`](Verdict.Condition) — the Ecto data model.
    * [`Verdict.Fact`](Verdict.Fact) — constant or dynamic facts.
    * [`Verdict.Operators`](Verdict.Operators) — the built-in comparison
      operators, plus how to add custom ones and decorators.
    * [`Verdict.Almanac`](Verdict.Almanac) — the per-run fact store / cache, with
      the [`Verdict.Almanac.ProcessLocal`](Verdict.Almanac.ProcessLocal) and
      [`Verdict.Almanac.Shared`](Verdict.Almanac.Shared) backends.
    * [`Verdict.Store`](Verdict.Store) — the pluggable rule / fact store, with
      the `:pure`, `:genserver` and `:ets` backends.
    * [`Verdict.Evaluator`](Verdict.Evaluator) — the pure, serial or parallel
      run loop.
    * [`Verdict.Evaluation`](Verdict.Evaluation) — the pure condition-tree
      evaluation and the changeset report.
    * [`Verdict.RunResult`](Verdict.RunResult) /
      [`Verdict.RuleResult`](Verdict.RuleResult) — the outcome of a run / a rule.
    * [`Verdict.Log`](Verdict.Log) — optional, level-gated logging.
    * Errors: [`Verdict.InvalidRuleError`](Verdict.InvalidRuleError),
      [`Verdict.InvalidJSONError`](Verdict.InvalidJSONError),
      [`Verdict.UndefinedFactError`](Verdict.UndefinedFactError).

  See `Verdict.Engine` for the API and the README for worked examples.
  """

  alias Verdict.{Engine, InvalidJSONError, InvalidRuleError, Rule, RunResult}

  @type rule_input :: map() | Rule.t()
  @type rules_input :: String.t() | rule_input() | [rule_input()]
  @type facts_input :: String.t() | map()

  @doc """
  Creates a new engine.

  Convenience alias for `Verdict.Engine.new/1`.
  """
  @spec new(keyword()) :: Engine.t()
  def new(opts \\ []) do
    Engine.new(opts)
  end

  @doc """
  Builds an engine from `rules`, registers them, and runs against `facts`.

  `rules` may be a JSON string (a rule object, or an array of rule objects), a
  rule map (string or atom keys), a `Verdict.Rule` struct, or a list of any
  of those. `facts` may be a JSON string (a facts object) or a map of `name`
  to value — a value may be a `(params, almanac)` / `(params)` function for a
  dynamic fact.

  `opts` may be any `Verdict.Engine.new/1` option (e.g. `:strict`,
  `:schedule`, `:store`, `:log`); it is applied at construction and the
  run-time options override the engine defaults for this run.

  Returns `{:ok, %Verdict.RunResult{}}` on success, `{:error, changeset}` if
  a rule fails validation, or `{:error, {:bad_json, message}}` if a JSON string
  is malformed. An unsupported input type (or an invalid `:store` / `:log`)
  raises `ArgumentError`.
  """
  @spec return(rules_input(), facts_input(), keyword()) ::
          {:ok, RunResult.t()} | {:error, Ecto.Changeset.t() | {:bad_json, String.t()}}
  def return(rules, facts, opts \\ []) do
    case do_return(rules, facts, opts) do
      {:ok, result} -> {:ok, result}
      {:error, {:bad_json, message, _input}} -> {:error, {:bad_json, message}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Like `return/3` but returns the `Verdict.RunResult` directly and raises on
  failure:

    * `Verdict.InvalidRuleError` — a rule failed validation (carries the
      failing `changeset`);
    * `Verdict.InvalidJSONError` — a JSON string is malformed (carries the
      decoder's `reason` and the `input`);
    * `ArgumentError` — an input has an unsupported type.
  """
  @spec return!(rules_input(), facts_input(), keyword()) :: RunResult.t()
  def return!(rules, facts, opts \\ []) do
    case do_return(rules, facts, opts) do
      {:ok, result} ->
        result

      {:error, {:bad_json, reason, input}} ->
        raise InvalidJSONError, reason: reason, input: input

      {:error, %Ecto.Changeset{} = changeset} ->
        raise InvalidRuleError, changeset: changeset
    end
  end

  defp do_return(rules, facts, opts) do
    with {:ok, decoded_rules} <- decode_if_json(rules),
         {:ok, rule_attrs} <- normalize_rules(decoded_rules),
         {:ok, decoded_facts} <- decode_if_json(facts),
         {:ok, fact_map} <- normalize_facts(decoded_facts),
         {:ok, engine} <- add_rules(opts, rule_attrs) do
      {:ok, Engine.run(engine, fact_map, opts)}
    else
      {:error, _} = error -> error
    end
  end

  defp decode_if_json(binary) when is_binary(binary) do
    try do
      {:ok, :json.decode(binary)}
    rescue
      e -> {:error, {:bad_json, Exception.message(e), binary}}
    end
  end

  defp decode_if_json(other), do: {:ok, other}

  defp normalize_rules(list) when is_list(list) do
    {:ok, Enum.map(list, &rule_to_attrs/1)}
  end

  defp normalize_rules(value) when is_map(value) do
    {:ok, [rule_to_attrs(value)]}
  end

  defp normalize_rules(other) do
    raise ArgumentError,
          "rules must be a JSON string, a map, a %Verdict.Rule{}, or a list of those; " <>
            "got: #{inspect(other)}"
  end

  defp rule_to_attrs(%Rule{} = rule), do: Rule.to_map(rule)
  defp rule_to_attrs(map) when is_map(map), do: map

  defp rule_to_attrs(other) do
    raise ArgumentError, "each rule must be a map or %Verdict.Rule{}; got: #{inspect(other)}"
  end

  defp normalize_facts(map) when is_map(map), do: {:ok, map}

  defp normalize_facts(other) do
    raise ArgumentError, "facts must be a JSON string or a map; got: #{inspect(other)}"
  end

  defp add_rules(opts, rule_attrs) do
    engine = Engine.new(opts)

    case Enum.reduce_while(rule_attrs, engine, fn attrs, acc ->
           case Engine.add_rule(acc, attrs) do
             {:ok, acc, _rule} -> {:cont, acc}
             {:error, changeset} -> {:halt, {:error, changeset}}
           end
         end) do
      {:error, _} = error -> error
      engine -> {:ok, engine}
    end
  end
end
