defmodule Verdict.Evaluator do
  @moduledoc """
  The pure evaluation core.

   `run/4` evaluates a set of rules against a set of facts and returns a
   `Verdict.RunResult`. Rules are grouped into priority buckets and the buckets
   run highest-priority first. Each rule's condition tree is evaluated by
   `Verdict.Evaluation` into a pure `Ecto.Changeset` report; the run collects
   the events of the valid rules, the failure events of the invalid ones, and the
   per-rule reports (in priority order).

   Scheduling is selected by the `:schedule` option: `:serial` evaluates a bucket's
   rules one at a time; `:parallel` runs them concurrently over a shared almanac
   (bounded by `:parallel_concurrency`). Short-circuiting of a rule's conditions
   (and its `strict` override) live in `Verdict.Evaluation`.
  """
  alias Verdict.{
    Almanac,
    Evaluation,
    EvaluationContext,
    Fact,
    Log,
    Rule,
    RuleResult,
    RunResult
  }

  @type opts :: keyword()

  @doc """
  Evaluates `rules` (a list of `Verdict.Rule`) using `defs` (registered facts)
  and `runtime_facts` (facts supplied for this run).

  `opts` may include `:allow_undefined_facts`, `:strict`, `:path_resolver` and
  `:allow_undefined_conditions`, plus the engine's `:operators` and
  `:conditions` registries (added by `Verdict.Engine.run/3`).
  """
  @spec run([Rule.t()], Verdict.Fact.registry(), Almanac.fact_map(), opts()) :: RunResult.t()
  def run(rules, defs, runtime_facts, opts) do
    schedule = Keyword.get(opts, :schedule, :serial)
    log = Keyword.get(opts, :log)
    almanac = Almanac.new(defs, runtime_facts, Keyword.put(opts, :backend, backend_for(schedule)))

    operators = Keyword.get(opts, :operators, %{})
    decorators = Keyword.get(opts, :decorators, %{})
    conditions = Keyword.get(opts, :conditions, %{})
    report = Keyword.get(opts, :report, :full)

    # A flat fact-priority map (registered priorities, runtime facts overriding at
    # 1) held locally so ordering a combinator's children never looks a fact's
    # priority up through the almanac — that would be a GenServer round-trip per
    # leaf in `:parallel`.
    fact_priorities = fact_priorities(defs, runtime_facts)

    # A per-run token for the process-local operator cache (see
    # `Verdict.Evaluation`). Each process memoises the resolved function for a
    # distinct `{operator, params}` under this token on first use, so only
    # evaluated leaves pay to resolve their operator.
    memo_token = make_ref()

    context = %EvaluationContext{
      almanac: almanac,
      operators: operators,
      decorators: decorators,
      conditions: conditions,
      fact_priorities: fact_priorities,
      memo_token: memo_token,
      path_resolver: Keyword.get(opts, :path_resolver),
      allow_undefined_conditions: Keyword.get(opts, :allow_undefined_conditions, false),
      strict: Keyword.get(opts, :strict, false),
      report: report,
      log: log
    }

    callbacks = Keyword.get(opts, :callbacks, %{})
    rule_callbacks = Keyword.get(opts, :rule_callbacks, %{})
    replace_facts = Keyword.get(opts, :replace_facts_in_event_params, false)
    buckets = rules |> Enum.group_by(& &1.priority) |> by_priority_desc()

    Log.debug(log, fn -> "run started: #{length(rules)} rules, schedule: #{inspect(schedule)}" end)

    try do
      results =
        case schedule do
          :parallel ->
            concurrency = Keyword.get(opts, :parallel_concurrency, System.schedulers_online())

            run_parallel(
              buckets,
              context,
              replace_facts,
              callbacks,
              rule_callbacks,
              almanac,
              concurrency
            )

          _ ->
            run_serial(buckets, context, replace_facts, callbacks, rule_callbacks, almanac)
        end

      run_result = from_results(results)

      Log.info(log, fn ->
        "run finished: #{length(run_result.events)} succeeded, #{length(run_result.failure_events)} failed"
      end)

      run_result
    after
      Almanac.destroy(almanac)
      Process.delete(memo_token)
    end
  end

  defp backend_for(:parallel), do: :shared
  defp backend_for(_), do: :process_local

  # Serial: rules are evaluated one at a time in priority order. A callback may
  # stop the run (skipping every remaining rule) or add a runtime fact that later
  # rules can read.
  defp run_serial(buckets, context, replace_facts, callbacks, rule_callbacks, almanac) do
    log = context.log

    buckets
    |> Enum.map(&elem(&1, 1))
    |> List.flatten()
    |> Enum.reduce_while([], fn rule, acc ->
      if Almanac.stopped?(almanac) do
        Log.warning(log, "run stopped")
        {:halt, acc}
      else
        rule_result = evaluate_rule(rule, context, replace_facts)
        Log.info(log, fn -> rule_line(rule, rule_result) end)
        emit_callbacks(callbacks, rule_result, almanac, log)
        emit_callbacks(rule_callbacks[rule.id] || %{}, rule_result, almanac, log)
        {:cont, [rule_result | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp rule_line(rule, rule_result) do
    "rule #{inspect(rule.name)} (priority #{rule.priority}): #{if rule_result.valid?, do: "fired", else: "did not fire"}"
  end

  # Parallel: each priority bucket's rules run concurrently (bounded by
  # `concurrency`); buckets still run one after another. A callback may stop the
  # run (skipping every later bucket) or add a runtime fact that later buckets
  # read. Results keep their submission order within a bucket (`ordered: true`).
  defp run_parallel(
         buckets,
         context,
         replace_facts,
         callbacks,
         rule_callbacks,
         almanac,
         concurrency
       ) do
    log = context.log

    Enum.reduce_while(buckets, [], fn {_priority, bucket}, acc ->
      if Almanac.stopped?(almanac) do
        Log.warning(log, "run stopped")
        {:halt, acc}
      else
        # One round-trip per bucket: snapshot the constant facts so every worker
        # in this bucket reads them locally instead of round-tripping per leaf.
        # Runtime facts added by earlier buckets are included (guaranteed
        # cross-bucket visibility); facts added within *this* bucket still resolve
        # through the live almanac (best-effort, as before).
        snapshot = Almanac.constants(almanac)
        bucket_context = %{context | fact_snapshot: snapshot}

        results =
          bucket
          |> Task.async_stream(
            fn rule ->
              # Each worker catches its own errors so a failing rule cannot crash
              # the run's consumer through a task link. The error is carried out as
              # data and re-raised (in bucket order) once the results are collected.
              try do
                rule_result = evaluate_rule(rule, bucket_context, replace_facts)
                Log.info(log, fn -> rule_line(rule, rule_result) end)
                emit_callbacks(callbacks, rule_result, almanac, log)
                emit_callbacks(rule_callbacks[rule.id] || %{}, rule_result, almanac, log)
                {:ok, rule_result}
              rescue
                e -> {:error, e, __STACKTRACE__}
              end
            end,
            max_concurrency: concurrency,
            ordered: true
          )
          |> Enum.to_list()
          |> Enum.map(fn
            {:ok, {:ok, rule_result}} -> rule_result
            {:ok, {:error, e, stack}} -> reraise(e, stack)
            other -> raise "unexpected task result: #{inspect(other)}"
          end)

        {:cont, acc ++ results}
      end
    end)
  end

  defp evaluate_rule(rule, context, replace_facts) do
    event = if replace_facts, do: resolve_event_params(rule.event, context), else: rule.event

    case Evaluation.eval(rule.conditions, context) do
      passed? when is_boolean(passed?) ->
        %RuleResult{rule: rule, changeset: nil, event: event, valid?: passed?}

      changeset ->
        %RuleResult{rule: rule, changeset: changeset, event: event, valid?: changeset.valid?}
    end
  end

  # Fires a rule's events. A successful rule emits "success" (with the full
  # event) and then its own event type (with the event params); a failed rule
  # emits only "failure".
  defp emit_callbacks(
         callbacks,
         %RuleResult{event: event, valid?: valid?} = rule_result,
         almanac,
         log
       ) do
    if valid? do
      emit(callbacks, "success", event, almanac, rule_result, log)
      emit(callbacks, event.type, event.params, almanac, rule_result, log)
    else
      emit(callbacks, "failure", event, almanac, rule_result, log)
    end
  end

  defp emit(callbacks, type, first, almanac, rule_result, log) do
    cbs = callbacks[to_string(type)] || []

    Enum.each(cbs, fn cb ->
      Log.debug(log, fn -> "callback \"#{type}\" (rule #{rule_result.rule.name})" end)
      cb.(first, almanac, rule_result)
    end)
  end

  # Resolves fact references in an event's params (see `replace_facts_in_event_params`).
  defp resolve_event_params(%{params: params} = event, context) when is_map(params) do
    resolved = Map.new(params, fn {k, v} -> {k, Evaluation.resolve_value(v, context)} end)
    %{event | params: resolved}
  end

  defp resolve_event_params(event, _context), do: event

  defp from_results(results) do
    {valid, invalid} = Enum.split_with(results, & &1.valid?)

    %RunResult{
      events: Enum.map(valid, & &1.event),
      failure_events: Enum.map(invalid, & &1.event),
      results: results
    }
  end

  defp by_priority_desc(grouped) do
    Enum.sort_by(grouped, fn {priority, _} -> -priority end)
  end

  # The effective priority of a fact for ordering, mirroring how the almanac merges
  # its defs: registered facts keep their priority, runtime facts (always 1) win.
  defp fact_priorities(defs, runtime_facts) do
    registered =
      Map.new(defs || %{}, fn {id, %Fact{priority: priority}} -> {to_string(id), priority} end)

    runtime = Map.new(runtime_facts || %{}, fn {id, _} -> {to_string(id), 1} end)
    Map.merge(registered, runtime)
  end
end
