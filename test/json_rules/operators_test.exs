defmodule JsonRules.OperatorsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias JsonRules.Operators

  test "equal / notEqual" do
    assert Operators.get("equal").(1, 1)
    refute Operators.get("equal").(1, 2)
    refute Operators.get("notEqual").(1, 1)
    assert Operators.get("notEqual").(1, 2)
  end

  test "ordering operators" do
    assert Operators.get("lessThan").(1, 2)
    refute Operators.get("lessThan").(2, 1)
    assert Operators.get("lessThanInclusive").(1, 1)
    assert Operators.get("greaterThan").(2, 1)
    refute Operators.get("greaterThan").(1, 2)
    assert Operators.get("greaterThanInclusive").(1, 1)
  end

  test "array operators" do
    assert Operators.get("in").(1, [1, 2, 3])
    refute Operators.get("in").(4, [1, 2, 3])
    assert Operators.get("notIn").(4, [1, 2, 3])
    refute Operators.get("notIn").(1, [1, 2, 3])
    assert Operators.get("contains").([1, 2, 3], 2)
    refute Operators.get("contains").([1, 2, 3], 4)
    assert Operators.get("doesNotContain").([1, 2, 3], 4)
    refute Operators.get("doesNotContain").([1, 2, 3], 2)
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
end
