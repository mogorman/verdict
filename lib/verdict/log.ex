defmodule Verdict.Log do
  @moduledoc """
  Optional, level-gated logging for the engine.

  By default the engine is silent. Set a log level with the `:log` option on
  `c:Verdict.Engine.new/1` (per engine) or `c:Verdict.Engine.run/3` (per
  run), or globally with application config:

  ```elixir
  config :verdict, :log, :info
  ```

  The effective level is resolved per run: a per-run `:log` wins over a
  per-engine `:log`, which wins over the application config, which defaults to
  off. `nil` means "off" (and, at the engine/run option, "fall through to the
  next tier").

  The levels are cumulative — a run at `:info` emits `:info`, `:warning` and
  `:error` messages but not `:debug`. See `docs/phase_6.md` for which engine
  step emits at which level.

  Each message is emitted through `Logger` using a zero-arity function, so when
  a level is off no message is built and no `Logger` call is made. The host
  application's own `:logger` configuration (console level, formatters,
  backends) still applies on top: this module only decides *whether* the engine
  asks `Logger` to emit.
  """

  @valid [nil, :off, :debug, :info, :warning, :error]
  @rank %{debug: 0, info: 1, warning: 2, error: 3}

  require Logger

  # A log threshold. `nil`/`:off` are silent; the rest are cumulative.
  @type level() :: nil | :off | :debug | :info | :warning | :error

  @doc "Returns `true` when `level` is a valid log threshold."
  @spec valid?(term()) :: boolean()
  def valid?(level), do: level in @valid

  @doc """
  Raises `ArgumentError` when `level` is not a valid log threshold.

  Returns the level unchanged when it is valid, so it can be used in a
  `validate!` then bind style.
  """
  @spec validate!(term()) :: level()
  def validate!(level) do
    unless valid?(level) do
      raise ArgumentError,
            "invalid log level #{inspect(level)}; expected nil, :off, :debug, :info, :warning or :error"
    end

    level
  end

  @doc """
  Resolves a log level from up to three candidates, most-specific first.

  The first non-`nil` candidate wins:
  `normalize(run_level, engine_level, app_config_level)`. Returns `nil` (off)
  when none is set.
  """
  @spec normalize(term(), term(), term()) :: level()
  def normalize(a, b, c) do
    cond do
      a != nil -> a
      b != nil -> b
      true -> c
    end
  end

  @doc "Returns `true` when `level` emits messages at `severity` or higher."
  @spec emit?(level(), level()) :: boolean()
  def emit?(level, severity), do: rank(level) != nil and rank(level) <= rank(severity)

  @spec debug?(level()) :: boolean()
  def debug?(level), do: emit?(level, :debug)

  @spec info?(level()) :: boolean()
  def info?(level), do: emit?(level, :info)

  @spec warning?(level()) :: boolean()
  def warning?(level), do: emit?(level, :warning)

  @spec error?(level()) :: boolean()
  def error?(level), do: emit?(level, :error)

  @doc """
  Emits `msg` at `:debug` when `level` allows it, and always returns `:ok`.

  `msg` may be a plain string or a zero-arity function; the function form is
  only invoked (and only then) when the message will actually be emitted, so an
  off level costs nothing.
  """
  @spec debug(level(), String.t() | (-> String.t())) :: :ok
  def debug(level, msg), do: emit(level, :debug, msg)

  @doc "Emits `msg` at `:info` when `level` allows it."
  @spec info(level(), String.t() | (-> String.t())) :: :ok
  def info(level, msg), do: emit(level, :info, msg)

  @doc "Emits `msg` at `:warning` when `level` allows it."
  @spec warning(level(), String.t() | (-> String.t())) :: :ok
  def warning(level, msg), do: emit(level, :warning, msg)

  @doc "Emits `msg` at `:error` when `level` allows it."
  @spec error(level(), String.t() | (-> String.t())) :: :ok
  def error(level, msg), do: emit(level, :error, msg)

  defp emit(level, severity, msg) do
    if emit?(level, severity) do
      Logger.log(severity, resolve_msg(msg))
    end

    :ok
  end

  defp resolve_msg(msg) when is_function(msg, 0), do: msg.()
  defp resolve_msg(msg), do: msg

  defp rank(nil), do: nil
  defp rank(:off), do: nil
  defp rank(level), do: @rank[level]
end
