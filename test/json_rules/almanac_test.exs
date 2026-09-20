defmodule JsonRules.AlmanacTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias JsonRules.{Almanac, Fact, UndefinedFactError}

  test "add_runtime_fact makes a fact visible to later lookups" do
    almanac = Almanac.new(%{}, %{}, allow_undefined_facts: true)
    assert Almanac.fact_value(almanac, "x") == nil

    Almanac.add_runtime_fact(almanac, "x", 42)
    assert Almanac.fact_value(almanac, "x") == 42
  end

  test "stop marks the run stopped" do
    almanac = Almanac.new(%{})
    refute Almanac.stopped?(almanac)
    Almanac.stop(almanac)
    assert Almanac.stopped?(almanac)
  end

  test "facts/1 reports the values computed during the run" do
    almanac = Almanac.new(%{}, %{a: 1, b: 2})
    _ = Almanac.fact_value(almanac, "a")
    assert {"a", 1} in Almanac.facts(almanac)
  end

  describe "shared backend (used by :parallel)" do
    test "serves the per-run API across the state server" do
      almanac =
        Almanac.new(
          %{a: Fact.new("a", 1, priority: 5)},
          %{},
          backend: :shared,
          allow_undefined_facts: true
        )

      try do
        assert Almanac.fact_value(almanac, "a") == 1
        assert Almanac.fact_priority(almanac, "a") == 5
        assert Almanac.fact_priority(almanac, "missing") == 1

        Almanac.add_runtime_fact(almanac, "rt", 99)
        assert Almanac.fact_value(almanac, "rt") == 99
        assert Almanac.fact_value(almanac, "ghost") == nil
        assert {"rt", 99} in Almanac.facts(almanac)

        refute Almanac.stopped?(almanac)
        Almanac.stop(almanac)
        assert Almanac.stopped?(almanac)
      after
        Almanac.destroy(almanac)
      end
    end

    test "recomputes cache: false facts and raises for an undefined fact" do
      almanac =
        Almanac.new(
          %{f: Fact.new("f", fn _params, _almanac -> 7 end, cache: false)},
          %{},
          backend: :shared
        )

      try do
        assert Almanac.fact_value(almanac, "f") == 7
        assert_raise UndefinedFactError, fn -> Almanac.fact_value(almanac, "nope") end
      after
        Almanac.destroy(almanac)
      end
    end
  end
end
