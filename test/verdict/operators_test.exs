defmodule Verdict.OperatorsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.Operators

  test "equal / notEqual" do
    assert {true, msg} = Operators.get("equal").(1, 1)
    assert msg != ""
    assert {false, _} = Operators.get("equal").(1, 2)
    assert {false, _} = Operators.get("notEqual").(1, 1)
    assert {true, _} = Operators.get("notEqual").(1, 2)
  end

  test "ordering operators" do
    assert {true, _} = Operators.get("lessThan").(1, 2)
    assert {false, _} = Operators.get("lessThan").(2, 1)
    assert {true, _} = Operators.get("lessThanInclusive").(1, 1)
    assert {true, _} = Operators.get("greaterThan").(2, 1)
    assert {false, _} = Operators.get("greaterThan").(1, 2)
    assert {true, _} = Operators.get("greaterThanInclusive").(1, 1)
  end

  test "array operators" do
    assert {true, _} = Operators.get("in").(1, [1, 2, 3])
    assert {false, _} = Operators.get("in").(4, [1, 2, 3])
    assert {true, _} = Operators.get("notIn").(4, [1, 2, 3])
    assert {false, _} = Operators.get("notIn").(1, [1, 2, 3])
    assert {true, _} = Operators.get("contains").([1, 2, 3], 2)
    assert {false, _} = Operators.get("contains").([1, 2, 3], 4)
    assert {true, _} = Operators.get("doesNotContain").([1, 2, 3], 4)
    assert {false, _} = Operators.get("doesNotContain").([1, 2, 3], 2)
  end

  test "explanations describe the comparison" do
    assert {false, msg} = Operators.get("greaterThanInclusive").(500, 1000)
    assert msg =~ "500"
    assert msg =~ "1000"
  end

  test "known/0 lists the ten built-in operators" do
    assert "equal" in Operators.known()
    assert "doesNotContain" in Operators.known()
    assert length(Operators.known()) == 10
  end

  test "get/1 raises on an unknown operator" do
    assert_raise ArgumentError, "unknown operator: \"nope\"", fn ->
      Operators.get("nope")
    end
  end

  describe "bool/4 (the :result_only operator)" do
    @ops ~w(equal notEqual lessThan lessThanInclusive greaterThan greaterThanInclusive in notIn contains doesNotContain)

    test "returns a pure boolean fn for every built-in operator" do
      for op <- @ops do
        assert is_function(Operators.bool(%{}, %{}, op, %{}), 2)
      end
    end

    test "falls back to resolve/4 for a custom operator" do
      f = Operators.bool(%{"isA" => fn a, b -> a == b end}, %{}, "isA", %{})
      assert f.(1, 1)
      refute f.(1, 2)
    end
  end

  describe "lazy/4 (the :failures_only operator)" do
    @passing %{
      "equal" => {1, 1},
      "notEqual" => {1, 2},
      "lessThan" => {1, 2},
      "lessThanInclusive" => {1, 2},
      "greaterThan" => {2, 1},
      "greaterThanInclusive" => {2, 1},
      "in" => {1, [1, 2]},
      "notIn" => {3, [1, 2]},
      "contains" => {[1, 2], 1},
      "doesNotContain" => {[1, 2], 9}
    }

    @failing %{
      "equal" => {1, 2},
      "notEqual" => {1, 1},
      "lessThan" => {2, 1},
      "lessThanInclusive" => {2, 1},
      "greaterThan" => {1, 2},
      "greaterThanInclusive" => {1, 2},
      "in" => {9, [1, 2]},
      "notIn" => {1, [1, 2]},
      "contains" => {[1, 2], 9},
      "doesNotContain" => {[1, 2], 1}
    }

    test "a passing comparison returns {true, nil} (no explanation built)" do
      for {op, {a, b}} <- Map.to_list(@passing) do
        f = Operators.lazy(%{}, %{}, op, %{})
        assert {true, nil} = f.(a, b)
      end
    end

    test "a failing comparison builds the same explanation as the full operator" do
      for {op, {a, b}} <- Map.to_list(@failing) do
        lazy_msg = elem(Operators.lazy(%{}, %{}, op, %{}).(a, b), 1)
        full_msg = elem(Operators.get(op).(a, b), 1)
        assert {false, ^lazy_msg} = Operators.lazy(%{}, %{}, op, %{}).(a, b)
        assert lazy_msg == full_msg
      end
    end

    test "falls back to resolve/4 for a custom operator" do
      f = Operators.lazy(%{"isA" => fn a, b -> a == b end}, %{}, "isA", %{})
      assert {true, _} = f.(1, 1)
      assert {false, _} = f.(1, 2)
    end
  end

  describe "resolve/4 composites" do
    test "built-in list decorators (someFact / everyValue) compose over the base" do
      assert {true, _} = Operators.resolve(%{}, %{}, "someFact:equal", %{}).([1, 2, 3], 2)
      assert {true, _} = Operators.resolve(%{}, %{}, "everyValue:equal", %{}).(5, [5, 5])
    end

    test "as_bool/1 unwraps a custom base operator (tuple and bare boolean)" do
      tuple_base = %{"range" => fn a, b, _p -> {a < b, "range"} end}
      assert {false, _} = Operators.resolve(tuple_base, %{}, "not:range", %{}).(1, 5)

      bool_base = %{"isA" => fn a, b -> a == b end}
      assert {false, _} = Operators.resolve(bool_base, %{}, "not:isA", %{}).(1, 1)
    end
  end
end
