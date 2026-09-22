defmodule Verdict.EngineReportTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.{Engine, RunResult}

  # One rule that passes (x == 5) and one that fails (x == 5, but y == 99).
  defp engine do
    engine = Engine.new() |> Engine.add_fact("x", 5) |> Engine.add_fact("y", 10)

    {:ok, engine, _} =
      Engine.add_rule(engine, %{
        name: "passes",
        event: %{type: "ev"},
        conditions: %{all: [%{fact: "x", operator: "equal", value: 5}]}
      })

    {:ok, engine, _} =
      Engine.add_rule(engine, %{
        name: "fails",
        event: %{type: "ev"},
        conditions: %{
          all: [
            %{fact: "x", operator: "equal", value: 5},
            %{fact: "y", operator: "equal", value: 99}
          ]
        }
      })

    engine
  end

  defp valids(result) do
    result.results |> Enum.map(&{&1.rule.name, &1.valid?}) |> Enum.sort()
  end

  describe "default report mode" do
    test "is :full — builds changes and errors" do
      %RunResult{results: results} = Engine.run(engine(), %{})
      failing = Enum.find(results, &(&1.rule.name == "fails"))

      assert failing.valid? == false
      assert length(failing.changeset.changes) == 1
      assert length(failing.changeset.errors) == 1
    end
  end

  describe "report: :result_only" do
    test "matches :full on outcomes but carries no report" do
      full = Engine.run(engine(), %{})
      ro = Engine.run(engine(), %{}, report: :result_only)

      assert valids(ro) == valids(full)
      assert ro.events == full.events
      assert ro.failure_events == full.failure_events
      assert Enum.all?(ro.results, &is_nil(&1.changeset))
    end

    test "to_map reports nil conditions but keeps the outcome" do
      ro = Engine.run(engine(), %{}, report: :result_only)
      %{"results" => results} = RunResult.to_map(ro)

      assert Enum.all?(results, &(&1["conditions"] == nil))

      assert Map.new(results, &{&1["name"], &1["result"]}) == %{
               "passes" => true,
               "fails" => false
             }
    end
  end

  describe "report: :failures_only" do
    test "matches :full on outcomes; drops passing, keeps failing (with the same explanation)" do
      full = Engine.run(engine(), %{})
      fo = Engine.run(engine(), %{}, report: :failures_only)

      assert valids(fo) == valids(full)
      assert fo.events == full.events
      assert fo.failure_events == full.failure_events

      failing_fo = Enum.find(fo.results, &(&1.rule.name == "fails"))
      failing_full = Enum.find(full.results, &(&1.rule.name == "fails"))

      assert failing_fo.changeset.changes == []
      [{:y, {msg, _meta}}] = failing_fo.changeset.errors
      [{:y, {full_msg, _meta}}] = failing_full.changeset.errors
      assert msg == full_msg
    end
  end

  describe "report as an engine option" do
    test "is set on new/1 and overridable per run" do
      {:ok, base, _} =
        Engine.new(report: :result_only)
        |> Engine.add_fact("x", 5)
        |> Engine.add_rule(%{
          name: "p",
          event: %{type: "ev"},
          conditions: %{all: [%{fact: "x", operator: "equal", value: 5}]}
        })

      assert Enum.all?(Engine.run(base, %{}).results, &is_nil(&1.changeset))
      assert Enum.all?(Engine.run(base, %{}, report: :full).results, &is_map(&1.changeset))
    end
  end

  describe "invalid report" do
    test "raises on new/1 and on run/3" do
      assert_raise ArgumentError, ~r/invalid report/, fn -> Engine.new(report: :bogus) end

      assert_raise ArgumentError, ~r/invalid report/, fn ->
        Engine.run(engine(), %{}, report: :bogus)
      end
    end
  end
end
