defmodule JsonRules.FactTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Almanac, Fact}

  test "new/3 builds a constant fact with default options" do
    fact = Fact.new("age", 22)
    refute Fact.is_dynamic?(fact)
    assert fact.value == 22
    assert fact.calculation_method == nil
    assert fact.cache == true
    assert fact.priority == 1
  end

  test "new/3 builds a dynamic fact" do
    fact = Fact.new("age", fn p, _a -> p["x"] end)
    assert Fact.is_dynamic?(fact)
    assert fact.value == nil
  end

  test "new/3 honours the cache and priority options" do
    fact = Fact.new("age", fn _p, _a -> 1 end, cache: false, priority: 7)
    refute fact.cache
    assert fact.priority == 7
  end

  test "new/3 parses a numeric-string priority" do
    assert Fact.new("age", 1, priority: "5").priority == 5
  end

  test "calculate/3 returns a constant fact's value" do
    assert Fact.calculate(Fact.new("age", 22), %{}, Almanac.new(%{})) == 22
  end

  test "calculate/3 calls a (params, almanac) function" do
    assert Fact.calculate(
             Fact.new("age", fn p, _a -> p["n"] + 1 end),
             %{"n" => 41},
             Almanac.new(%{})
           ) ==
             42
  end

  test "calculate/3 calls a (params) function" do
    assert Fact.calculate(Fact.new("age", fn p -> p["n"] end), %{"n" => 3}, Almanac.new(%{})) == 3
  end
end
