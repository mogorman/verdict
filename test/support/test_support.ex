defmodule Verdict.TestSupport do
  @moduledoc false

  @doc "Builds a rule attribute map with defaults, mirroring the JS rule factory."
  def rule(attrs \\ %{}) do
    %{
      name: Map.get(attrs, :name, "test-rule"),
      priority: Map.get(attrs, :priority, 1),
      event:
        Map.get(attrs, :event, %{
          type: "pointCapReached",
          params: %{currency: "points", pointCap: 1000}
        }),
      conditions:
        Map.get(
          attrs,
          :conditions,
          %{all: [%{fact: "age", operator: "lessThan", value: 45}]}
        ),
      extra: Map.get(attrs, :extra, %{})
    }
  end

  @doc "Adds a rule and returns the updated engine."
  def add_rule(engine, attrs \\ %{}) do
    {:ok, engine, _rule} = Verdict.Engine.add_rule(engine, rule(attrs))
    engine
  end

  @doc "Adds a rule and returns the updated `{engine, rule}`."
  def add_rule_with(engine, attrs \\ %{}) do
    {:ok, engine, rule} = Verdict.Engine.add_rule(engine, rule(attrs))
    {engine, rule}
  end

  @doc "Starts a counter Agent; pass the pid to a fact closure to count invocations."
  def start_counter do
    Agent.start(fn -> 0 end)
  end

  @doc "Increments a counter Agent."
  def inc({:ok, pid}) do
    Agent.update(pid, &(&1 + 1))
  end

  @doc "Reads a counter Agent."
  def count({:ok, pid}) do
    Agent.get(pid, & &1)
  end

  @doc "Starts a collector Agent; pass the pid to a callback to record its invocations."
  def start_collector do
    Agent.start(fn -> [] end)
  end

  @doc "Records an item in a collector Agent."
  def collect({:ok, pid}, item) do
    Agent.update(pid, fn list -> [item | list] end)
  end

  @doc "Reads all items from a collector Agent, in the order they were recorded."
  def collected({:ok, pid}) do
    Agent.get(pid, & &1) |> Enum.reverse()
  end
end

defmodule Verdict.LogCapture do
  @moduledoc false

  # Captures `Logger` output for the logging integration tests by registering a
  # temporary `:logger_handler` that forwards each event to a private Agent.
  #
  # Each `start/0` registers a uniquely-named handler, so captures do not collide
  # by id. The `:logger` handlers are node-global, however, so tests that capture
  # must not overlap in time (keep them in a non-async module and call `stop/1`).

  defmodule Handler do
    @moduledoc false
    @behaviour :logger_handler

    @impl true
    def log(event, config) do
      case config[:config] && config[:config][:collector] do
        collector when is_pid(collector) ->
          item = {event[:level], message(event[:msg])}
          Agent.update(collector, fn list -> [item | list] end)

        _ ->
          :ok
      end
    end

    defp message({:string, text}), do: text
    defp message(other), do: other
  end

  @doc "Starts capturing `Logger` output; returns a handle for `messages/1` and `stop/1`."
  def start do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    id = String.to_atom("jr_logcap_#{System.unique_integer([:positive])}")
    cfg = %{filter_default: :log, filters: [], config: %{collector: agent}}

    case :logger.add_handler(id, Handler, cfg) do
      :ok ->
        %{id: id, agent: agent}

      {:error, reason} ->
        Agent.stop(agent)
        raise "failed to add log capture handler: #{inspect(reason)}"
    end
  end

  @doc "Returns the captured `{level, message}` tuples, in emission order."
  def messages(%{agent: agent}), do: Agent.get(agent, &Enum.reverse/1)

  @doc "Removes the capture handler and stops the collector."
  def stop(%{id: id, agent: agent}) do
    :logger.remove_handler(id)
    Agent.stop(agent)
  end
end
