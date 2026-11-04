defmodule XrefMermaid.EdgesTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.Edges

  test "write/1 writes one sorted line per call, externals included" do
    selection = %{
      calls: [
        {{Shop.Orders, :place, 1}, {Shop.Repo, :insert, 1}},
        {{Shop.Orders, :place, 1}, {:external, {Enum, :map, 2}}},
        {{Shop.Orders, :valid?, 1}, {Shop.Orders, :<~>, 2}}
      ]
    }

    assert Edges.write(selection) == """
           Shop.Orders.place/1 -> Enum.map/2
           Shop.Orders.place/1 -> Shop.Repo.insert/1
           Shop.Orders.valid?/1 -> Shop.Orders.<~>/2
           """
  end

  test "write/1 writes nothing for no calls" do
    assert Edges.write(%{calls: []}) == ""
  end
end
