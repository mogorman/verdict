defmodule JsonRules.UndefinedFactError do
  @moduledoc """
  Raised when a rule references a fact that has not been defined and
  `allow_undefined_facts` is not enabled.
  """
  defexception [:fact]

  @impl true
  def message(%{fact: fact}) do
    "Undefined fact: #{fact}"
  end
end
