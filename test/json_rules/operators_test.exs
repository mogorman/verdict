defmodule JsonRules.OperatorsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias JsonRules.Operators

  test "equal / notEqual" do
    assert {true, msg} = Operators.get("equal").(1, 1)
    assert is_binary(msg) and msg != ""
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
end
