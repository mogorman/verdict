defmodule Verdict.Template.Engine do
  @moduledoc """
  A capturing EEx engine for rendering `t:Verdict.Template/0` `eex_string` markers.

  The default EEx engine returns only the *trailing* text of a template, so block
  control flow (`<% if %>…<% end %>`, `<% for %>…<% end %>`, …) renders to `""`. This
  engine instead accumulates every output segment — static text, `<%= expr %>`
  interpolations, and the result of each control-flow block — into a single iodata
  value, so the whole template becomes its rendered string. Plain `<% expr %>`
  statements still run for their side effects but contribute no output.
  """
  @behaviour EEx.Engine

  @impl true
  def init(_opts), do: %{side: [], emit: []}

  @impl true
  def handle_text(%{emit: emit} = state, _meta, text), do: %{state | emit: [text | emit]}

  @impl true
  def handle_expr(%{emit: emit} = state, "=", ast), do: %{state | emit: [stringify(ast) | emit]}

  def handle_expr(
        %{emit: emit} = state,
        "",
        ast = {name, _, _}
      )
      when name in [:if, :case, :cond, :for, :try, :receive] do
    %{state | emit: [ast | emit]}
  end

  def handle_expr(%{side: side} = state, "", ast), do: %{state | side: [ast | side]}

  def handle_expr(_state, marker, _ast) when marker in ["/", "|"] do
    raise EEx.SyntaxError, message: "unsupported EEx syntax <%#{marker}%>"
  end

  @impl true
  def handle_begin(_state), do: %{side: [], emit: []}

  @impl true
  def handle_end(state), do: compile(state)

  @impl true
  def handle_body(state), do: compile(state)

  # The rendered segments of a scope, in source order, as a single iodata list.
  # Side-effect statements (if any) run first; the list is the scope's output.
  defp compile(%{side: side, emit: emit}) do
    out = quote(do: [unquote_splicing(Enum.reverse(emit))])

    case Enum.reverse(side) do
      [] -> out
      side -> {:__block__, [], side ++ [out]}
    end
  end

  defp stringify(ast), do: quote(do: String.Chars.to_string(unquote(ast)))
end
