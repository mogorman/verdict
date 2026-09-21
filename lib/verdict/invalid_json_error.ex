defmodule Verdict.InvalidJSONError do
  @moduledoc """
  Raised by `Verdict.run!/3` when a JSON string cannot be decoded.

  `reason` is the decoder's message and `input` is the offending JSON string.
  """
  defexception [:reason, input: nil]

  @impl true
  def message(%{reason: reason, input: input}) do
    "Invalid JSON: #{reason}" <> input_suffix(input)
  end

  defp input_suffix(nil), do: ""
  defp input_suffix(input) when is_binary(input), do: "\n\ninput: #{truncate(input)}"

  defp truncate(input) do
    if byte_size(input) > 200 do
      String.slice(input, 0, 200) <> "…"
    else
      input
    end
  end
end
