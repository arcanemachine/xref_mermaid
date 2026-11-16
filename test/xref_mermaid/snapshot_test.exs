defmodule XrefMermaid.SnapshotTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Snapshot, TestProject}

  test "write/1 writes every file, function and call, which read/1 reads back" do
    project =
      TestProject.build([
        {Shop.Orders, "lib/shop/orders.ex", [{:place, [1, 2], :def, 2}, {:<~>, [2], :def, 4}],
         [{{:place, 2}, {Shop.Repo, :insert, 1}}, {{:place, 2}, {Enum, :map, 2}}]},
        {Shop.Repo, "lib/shop/repo.ex", [{:insert, [1], :def, 2, generated: true}], []},
        {Shop.Empty, "lib/shop/empty.ex", [], []}
      ])

    # The source files aren't there, so no function has a hash.
    text = Snapshot.write(project)

    assert text == """
           xref_mermaid snapshot 1
           call\tShop.Orders\tplace\t1\tShop.Repo\tinsert\t1
           external\tShop.Orders\tplace\t1\tEnum\tmap\t2
           file\tlib/shop/empty.ex
           file\tlib/shop/orders.ex
           file\tlib/shop/repo.ex
           function\tlib/shop/orders.ex\tShop.Orders\t<~>\t2\t-
           function\tlib/shop/orders.ex\tShop.Orders\tplace\t1,2\t-
           function\tlib/shop/repo.ex\tShop.Repo\tinsert\t1\tgenerated
           """

    assert {:ok, snapshot} = Snapshot.read(text)

    assert snapshot.files ==
             MapSet.new(["lib/shop/empty.ex", "lib/shop/orders.ex", "lib/shop/repo.ex"])

    assert %{arities: [1, 2], hash: nil, generated?: false} =
             Enum.find(snapshot.functions, &(&1.name == "place"))

    assert %{generated?: true} = Enum.find(snapshot.functions, &(&1.name == "insert"))

    assert snapshot.calls ==
             MapSet.new([{{"Shop.Orders", "place", 1}, {"Shop.Repo", "insert", 1}}])

    assert snapshot.externals == MapSet.new([{{"Shop.Orders", "place", 1}, {"Enum", "map", 2}}])
  end

  test "read/1 reads a snapshot with nothing in it" do
    assert {:ok, %{files: files, functions: []}} = Snapshot.read("xref_mermaid snapshot 1\n")
    assert MapSet.size(files) == 0
  end

  test "read/1 rejects another format version, another file and an unknown line" do
    assert {:error, "it was written by another version of xref_mermaid"} =
             Snapshot.read("xref_mermaid snapshot 2\n")

    assert {:error, "it isn't an xref_mermaid snapshot"} = Snapshot.read("flowchart LR\n")

    assert {:error, "can't read the line \"oops\""} =
             Snapshot.read("xref_mermaid snapshot 1\noops\n")
  end
end
