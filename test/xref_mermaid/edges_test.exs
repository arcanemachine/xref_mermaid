defmodule XrefMermaid.EdgesTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Edges, Project}

  test "write/2 writes one sorted line per call, externals included, `~>` through private functions" do
    selection = %{
      calls: [
        {{Shop.Orders, :place, 1}, {Shop.Repo, :insert, 1}},
        {{Shop.Orders, :place, 1}, {:external, {Enum, :map, 2}}},
        {{Shop.Orders, :valid?, 1}, {Shop.Orders, :<~>, 2}}
      ],
      file_calls: []
    }

    project = %Project{
      through_private: MapSet.new([{{Shop.Orders, :place, 1}, {Shop.Repo, :insert, 1}}])
    }

    assert Edges.write(project, selection) == """
           Shop.Orders.place/1 -> Enum.map/2
           Shop.Orders.place/1 ~> Shop.Repo.insert/1
           Shop.Orders.valid?/1 -> Shop.Orders.<~>/2
           """
  end

  test "write/2 writes nothing for no calls" do
    assert Edges.write(%Project{}, %{calls: [], file_calls: []}) == ""
  end
end
