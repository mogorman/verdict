defmodule JsonRules.TestSupport do
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
        )
    }
  end

  @doc "Adds a rule and returns the updated engine."
  def add_rule(engine, attrs \\ %{}) do
    {:ok, engine, _rule} = JsonRules.Engine.add_rule(engine, rule(attrs))
    engine
  end

  @doc "Adds a rule and returns the updated `{engine, rule}`."
  def add_rule_with(engine, attrs \\ %{}) do
    {:ok, engine, rule} = JsonRules.Engine.add_rule(engine, rule(attrs))
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
end
