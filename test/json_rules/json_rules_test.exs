defmodule JsonRulesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias JsonRules.Engine

  test "JsonRules.new/1 is a convenience alias for Engine.new/1" do
    assert %Engine{} = JsonRules.new()
    assert JsonRules.new(schedule: :parallel).options[:schedule] == :parallel
  end
end
