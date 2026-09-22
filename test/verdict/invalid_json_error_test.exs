defmodule Verdict.InvalidJSONErrorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Verdict.InvalidJSONError

  test "message with no input" do
    assert Exception.message(%InvalidJSONError{reason: "trailing garbage"}) ==
             "Invalid JSON: trailing garbage"
  end

  test "message appends the offending input when provided" do
    msg = Exception.message(%InvalidJSONError{reason: "bad", input: "{not json"})
    assert msg == "Invalid JSON: bad\n\ninput: {not json"
  end

  test "message truncates input longer than 200 bytes" do
    input = String.duplicate("x", 300)

    msg = Exception.message(%InvalidJSONError{reason: "bad", input: input})
    assert msg == "Invalid JSON: bad\n\ninput: " <> String.duplicate("x", 200) <> "…"
  end
end
