defmodule VerdictTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.Engine

  test "Verdict.new/1 is a convenience alias for Engine.new/1" do
    assert %Engine{} = Verdict.new()
    assert Verdict.new(schedule: :parallel).options[:schedule] == :parallel
  end
end
