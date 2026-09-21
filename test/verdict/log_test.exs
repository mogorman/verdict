defmodule Verdict.LogTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Verdict.{Engine, Log}
  alias Verdict.LogCapture

  # --- unit: level gating -----------------------------------------------------

  describe "Log.emit?/2" do
    test "nil and :off emit nothing" do
      for level <- [nil, :off] do
        refute Log.emit?(level, :debug)
        refute Log.emit?(level, :info)
        refute Log.emit?(level, :warning)
        refute Log.emit?(level, :error)
      end
    end

    test "a level emits itself and every higher severity" do
      assert Log.emit?(:debug, :debug)
      assert Log.emit?(:debug, :info)
      assert Log.emit?(:debug, :warning)
      assert Log.emit?(:debug, :error)

      refute Log.emit?(:info, :debug)
      assert Log.emit?(:info, :info)
      assert Log.emit?(:info, :warning)
      assert Log.emit?(:info, :error)

      refute Log.emit?(:warning, :info)
      assert Log.emit?(:warning, :warning)
      assert Log.emit?(:warning, :error)

      refute Log.emit?(:error, :warning)
      assert Log.emit?(:error, :error)
    end
  end

  describe "predicates" do
    test "debug?/info?/warning?/error? mirror emit?/2" do
      assert Log.debug?(:debug)
      assert Log.info?(:debug)
      assert Log.warning?(:debug)
      assert Log.error?(:debug)

      refute Log.debug?(:info)
      assert Log.info?(:info)
      assert Log.warning?(:info)

      refute Log.info?(:warning)
      assert Log.warning?(:warning)

      refute Log.warning?(:error)
      assert Log.error?(:error)
    end
  end

  describe "Log.valid?/1 and validate!/1" do
    test "accepts every valid level" do
      for level <- [nil, :off, :debug, :info, :warning, :error] do
        assert Log.valid?(level)
        assert Log.validate!(level) == level
      end
    end

    test "rejects invalid levels" do
      refute Log.valid?(:loud)
      assert_raise ArgumentError, ~r/invalid log level/, fn -> Log.validate!(:loud) end
      assert_raise ArgumentError, ~r/invalid log level/, fn -> Log.validate!(:offf) end
    end
  end

  describe "Log.normalize/3" do
    test "resolves the first non-nil candidate, most-specific first" do
      assert Log.normalize(:debug, :info, :warning) == :debug
      assert Log.normalize(nil, :info, :warning) == :info
      assert Log.normalize(nil, nil, :warning) == :warning
      assert Log.normalize(nil, nil, nil) == nil
    end
  end

  describe "emitters" do
    test "always return :ok, for strings and lazy functions" do
      assert :ok = Log.debug(:off, "x")
      assert :ok = Log.info(:off, fn -> "x" end)
      assert :ok = Log.warning(:off, "y")
      assert :ok = Log.error(:off, fn -> "z" end)
    end

    test "a lazy message is only built when it will be emitted" do
      built? =
        Log.debug(:error, fn ->
          Process.put(:log_built, true)
          "should not run"
        end)

      assert built? == :ok
      refute Process.delete(:log_built)
    end
  end

  # --- integration: the engine emits through Logger ---------------------------

  describe "engine logging" do
    test "emits nothing when no :log is set" do
      cap = LogCapture.start()

      try do
        Engine.run(young_engine(), %{})
        assert LogCapture.messages(cap) == []
      after
        LogCapture.stop(cap)
      end
    end

    test "at :debug emits the full trace" do
      cap = LogCapture.start()

      try do
        Engine.run(young_engine(), %{}, log: :debug)
        msgs = LogCapture.messages(cap)

        assert has?(msgs, "run started")
        assert has?(msgs, ~s/leaf "age"/)
        assert has?(msgs, "all of 1: pass")
        assert has?(msgs, ~s/rule "young"/)
        assert has?(msgs, "run finished: 1 succeeded, 0 failed")
      after
        LogCapture.stop(cap)
      end
    end

    test "at :info emits info and above, but not debug" do
      cap = LogCapture.start()

      try do
        Engine.run(young_engine(), %{}, log: :info)
        msgs = LogCapture.messages(cap)

        assert has?(msgs, ~s/rule "young"/)
        assert has?(msgs, "run finished")
        refute has?(msgs, "run started")
        refute has?(msgs, "leaf")
        refute has?(msgs, "all of")
      after
        LogCapture.stop(cap)
      end
    end

    test "at :warning emits warnings but not info or debug" do
      cap = LogCapture.start()

      try do
        Engine.run(short_circuit_engine(), %{}, log: :warning)
        msgs = LogCapture.messages(cap)

        assert Enum.any?(msgs, fn {level, _} -> level == :warning end)
        assert has?(msgs, "short-circuit")
        refute has?(msgs, "run finished")
        refute has?(msgs, "run started")
      after
        LogCapture.stop(cap)
      end
    end
  end

  describe "log level precedence" do
    test "per-run :log overrides per-engine :log" do
      engine = young_engine(log: :debug)
      cap = LogCapture.start()

      try do
        Engine.run(engine, %{}, log: :info)
        msgs = LogCapture.messages(cap)

        assert has?(msgs, "run finished")
        refute has?(msgs, "run started")
      after
        LogCapture.stop(cap)
      end
    end

    test "per-engine :log overrides application config" do
      set_config(:warning)

      engine = young_engine(log: :debug)
      cap = LogCapture.start()

      try do
        Engine.run(engine, %{})
        assert has?(LogCapture.messages(cap), "run started")
      after
        LogCapture.stop(cap)
      end
    end

    test "application config is used when neither per-run nor per-engine sets :log" do
      set_config(:info)

      cap = LogCapture.start()

      try do
        Engine.run(young_engine(), %{})
        msgs = LogCapture.messages(cap)

        assert has?(msgs, "run finished")
        refute has?(msgs, "run started")
      after
        LogCapture.stop(cap)
      end
    end
  end

  # --- helpers ----------------------------------------------------------------

  # Builds a rule that fires for `age < 45`; `engine_opts` may include a
  # per-engine `:log`.
  defp young_engine(engine_opts \\ []) do
    engine = Engine.new(engine_opts) |> Engine.add_fact("age", 10)

    {:ok, engine, _rule} =
      Engine.add_rule(engine, %{
        name: "young",
        event: %{type: "youngEvent"},
        conditions: %{all: [%{fact: "age", operator: "lessThan", value: 45}]}
      })

    engine
  end

  # An `all` whose first (failing) child short-circuits the rest, producing a
  # short-circuit warning.
  defp short_circuit_engine do
    engine = Engine.new() |> Engine.add_fact("a", 1)

    {:ok, engine, _rule} =
      Engine.add_rule(engine, %{
        name: "warn",
        event: %{type: "warn"},
        conditions: %{
          all: [
            %{fact: "a", operator: "equal", value: 2},
            %{fact: "a", operator: "equal", value: 1}
          ]
        }
      })

    engine
  end

  defp set_config(level) do
    on_exit(fn -> Application.delete_env(:verdict, :log) end)
    Application.put_env(:verdict, :log, level)
  end

  defp has?(msgs, fragment) do
    Enum.any?(msgs, fn {_level, msg} ->
      is_binary(msg) and String.contains?(msg, fragment)
    end)
  end
end
