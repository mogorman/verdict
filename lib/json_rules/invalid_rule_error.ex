defmodule JsonRules.InvalidRuleError do
  @moduledoc """
  Raised by `JsonRules.run!/3` when a rule fails validation.

  The failing rule's `Ecto.Changeset` is carried as `changeset`; its `errors`
  describe exactly what was invalid.
  """
  defexception [:changeset]

  @impl true
  def message(%{changeset: changeset}) do
    "Invalid rule: " <> format_errors(changeset)
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} -> Keyword.get(opts, :default, msg) end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end
end
