defmodule JsonRules.UnsupportedError do
  @moduledoc """
  Raised when a rule uses a feature that is not yet implemented (Phase 2),
  such as condition `path` resolution or named condition references.
  """
  defexception [:feature]

  @impl true
  def message(%{feature: feature}) do
    "#{feature} is not supported yet (Phase 2)"
  end
end
