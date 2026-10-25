defmodule Verdict.TemplateTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Verdict.{Almanac, Template}

  defp almanac(facts) do
    a = Almanac.new(nil, facts, [])
    on_exit(fn -> Almanac.destroy(a) end)
    a
  end

  defp bnd, do: Template.binding(almanac(%{"bar" => "x", "count" => 5}))

  test "renders an eex_string marker against the binding" do
    assert Template.render(%{eex_string: "foo <%= bar %>"}, bnd(), false) == "foo x"
  end

  test "a plain string is left untouched" do
    assert Template.render("just a string", bnd(), false) == "just a string"
  end

  test "a non-marker map is recursed, not rendered" do
    assert Template.render(%{other: %{eex_string: "<%= bar %>"}}, bnd(), false) == %{
             other: "x"
           }
  end

  test "recurses into nested maps and lists" do
    value = %{
      top: %{eex_string: "<%= bar %>"},
      list: [%{eex_string: "<%= count %>"}, 7]
    }

    assert Template.render(value, bnd(), false) == %{top: "x", list: ["5", 7]}
  end

  test "uses the facts map for non-identifier fact names" do
    a = almanac(%{"game-duration" => 9})
    b = Template.binding(a)

    assert Template.render(%{eex_string: "<%= facts[\"game-duration\"] %>"}, b, false) == "9"
  end

  test "a control-flow template raises when allow_unsafe is false" do
    assert_raise ArgumentError, ~r/control flow/, fn ->
      Template.render(%{eex_string: "<% if true %>yes<% end %>"}, bnd(), false)
    end
  end

  test "a control-flow template renders when allow_unsafe is true" do
    assert Template.render(%{eex_string: "<%= if bar do %>y<% end %>"}, bnd(), true) == "y"
  end

  test "validate returns :ok for well-formed templates" do
    assert :ok = Template.validate(%{a: %{eex_string: "<%= bar %>"}, b: [%{eex_string: "x"}]})
  end

  test "validate reports ill-formed templates" do
    assert {:error, [message]} = Template.validate(%{a: %{eex_string: "<%= unclosed"}})
    assert message =~ "not valid EEx"
  end
end
