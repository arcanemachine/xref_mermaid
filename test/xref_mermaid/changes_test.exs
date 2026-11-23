defmodule XrefMermaid.ChangesTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Changes, Selection, Snapshot, TestProject}

  # The earlier state: `gone/0` and `lib/shop/old.ex` are removed since, `place/2` gains a default argument, `valid?/1`
  # is edited, and `total/1` (a delegate) has no hash.
  @before """
  xref_mermaid snapshot 1
  call\tShop.Orders\tgone\t0\tShop.Old\trun\t0
  call\tShop.Orders\tplace\t2\tShop.Orders\tvalid?\t1
  call\tShop.Orders\tplace\t2\tShop.Repo\tinsert\t1
  external\tShop.Orders\tgone\t0\t:erlang\tfoo\t0
  external\tShop.Orders\tgone\t0\tEnum\tmap\t2
  file\tlib/shop/old.ex
  file\tlib/shop/orders.ex
  file\tlib/shop/repo.ex
  function\tlib/shop/old.ex\tShop.Old\trun\t0\tr1
  function\tlib/shop/orders.ex\tShop.Orders\tgone\t0\tg1
  function\tlib/shop/orders.ex\tShop.Orders\tplace\t2\tp1
  function\tlib/shop/orders.ex\tShop.Orders\ttotal\t1\t-
  function\tlib/shop/orders.ex\tShop.Orders\tvalid?\t1\tv1
  function\tlib/shop/repo.ex\tShop.Repo\tinsert\t1\tgenerated
  """

  setup do
    project =
      TestProject.build([
        {Shop.Orders, "lib/shop/orders.ex",
         [
           {:place, [1, 2], :def, 2},
           {:valid?, [1], :defp, 5},
           {:total, [1], :def, 7},
           {:count, [1], :def, 9}
         ],
         [
           {{:place, 2}, {Shop.Orders, :valid?, 1}},
           {{:place, 2}, {Shop.Repo, :insert, 1}},
           {{:place, 2}, {Shop.Notes, :note, 1}}
         ]},
        {Shop.Repo, "lib/shop/repo.ex", [{:insert, [1], :def, 2, generated: true}], []},
        {Shop.Notes, "lib/shop/notes.ex", [{:note, [1], :def, 2}], []}
      ])

    {:ok, snapshot} = Snapshot.read(@before)

    hashes = %{
      {Shop.Orders, :place, 1} => "p1",
      {Shop.Orders, :valid?, 1} => "v2",
      {Shop.Orders, :count, 1} => "c1",
      {Shop.Notes, :note, 1} => "n1"
    }

    %{project: project, snapshot: snapshot, hashes: hashes}
  end

  test "compare/4 finds the added files, functions and calls, matching functions by any arity",
       context do
    changes = Changes.compare(context.project, context.snapshot, context.hashes)

    assert changes.added_files == MapSet.new(["lib/shop/notes.ex"])
    assert changes.added == MapSet.new([{Shop.Orders, :count, 1}, {Shop.Notes, :note, 1}])

    assert changes.new_calls ==
             MapSet.new([{{Shop.Orders, :place, 1}, {Shop.Notes, :note, 1}}])
  end

  test "compare/4 finds a function changed only when both states have a hash and they differ",
       context do
    changes = Changes.compare(context.project, context.snapshot, context.hashes)
    assert changes.changed == MapSet.new([{Shop.Orders, :valid?, 1}])

    # Without hashes now, nothing is changed.
    assert Changes.compare(context.project, context.snapshot, %{}).changed == MapSet.new()
  end

  test "compare/4 counts what is removed in the files of the prefixes only", context do
    changes =
      Changes.compare(context.project, context.snapshot, context.hashes, prefixes: ["lib/shop/"])

    assert changes.removed == %{
             files: ["lib/shop/old.ex"],
             functions: ["Shop.Old.run/0", "Shop.Orders.gone/0"],
             calls: ["Shop.Orders.gone/0 -> Shop.Old.run/0"]
           }

    assert Changes.compare(context.project, context.snapshot, context.hashes,
             prefixes: ["lib/shop/repo.ex"]
           ).removed == %{files: [], functions: [], calls: []}

    assert Changes.compare(context.project, context.snapshot, context.hashes).removed == nil
  end

  test "compare/4 counts removed external calls with `external`, as the chart would draw them",
       context do
    changes =
      Changes.compare(context.project, context.snapshot, context.hashes,
        prefixes: ["lib/shop/orders.ex"],
        external: true
      )

    assert changes.removed.calls == [
             "Shop.Orders.gone/0 -> Enum.map/2",
             "Shop.Orders.gone/0 -> Shop.Old.run/0"
           ]
  end

  test "compare/4 leaves out of the snapshot what `excludes` leaves out of the project",
       context do
    changes =
      Changes.compare(context.project, context.snapshot, context.hashes,
        prefixes: ["lib/shop/"],
        excludes: ["lib/shop/old.ex"]
      )

    assert changes.removed == %{files: [], functions: ["Shop.Orders.gone/0"], calls: []}
  end

  test "compare/4 leaves out of the snapshot the functions `excluded_names` leaves out, and their calls",
       context do
    compare = fn names ->
      Changes.compare(context.project, context.snapshot, context.hashes,
        prefixes: ["lib/shop/"],
        external: true,
        excluded_names: names
      ).removed
    end

    assert compare.([{"Shop.Orders", "gone", nil}]) ==
             %{files: ["lib/shop/old.ex"], functions: ["Shop.Old.run/0"], calls: []}

    # An external function is matched by the arity it is called with; a project one by any of its arities.
    assert compare.([{"Enum", "map", 2}, {"Shop.Old", "run", 0}]).calls == []

    assert compare.([{"Enum", "map", 3}]).calls == [
             "Shop.Orders.gone/0 -> Enum.map/2",
             "Shop.Orders.gone/0 -> Shop.Old.run/0"
           ]
  end

  test "compare/4 doesn't read a call into an excluded file as a removed external call",
       context do
    # The project as the task gives it, with the excluded file left out.
    project = XrefMermaid.Project.exclude(context.project, ["lib/shop/repo.ex"])

    changes =
      Changes.compare(project, context.snapshot, context.hashes,
        prefixes: ["lib/shop/orders.ex"],
        excludes: ["lib/shop/repo.ex"],
        external: true
      )

    assert changes.removed.calls == [
             "Shop.Orders.gone/0 -> Enum.map/2",
             "Shop.Orders.gone/0 -> Shop.Old.run/0"
           ]
  end

  test "compare/4 doesn't count the removed calls of a generated function", context do
    {:ok, snapshot} =
      Snapshot.read(
        @before <>
          "function\tlib/shop/orders.ex\tShop.Orders\tchild_spec\t1\tgenerated\n" <>
          "call\tShop.Orders\tchild_spec\t1\tShop.Repo\tinsert\t1\n"
      )

    changes =
      Changes.compare(context.project, snapshot, context.hashes, prefixes: ["lib/shop/orders.ex"])

    assert changes.removed.calls == ["Shop.Orders.gone/0 -> Shop.Old.run/0"]
  end

  test "list/3 lists the selection's changes, then the removed ones and their counts", context do
    changes =
      Changes.compare(context.project, context.snapshot, context.hashes, prefixes: ["lib/shop/"])

    selection = Selection.select(context.project, prefixes: ["lib/shop/"])

    assert Changes.list(context.project, selection, changes) == """
           + file lib/shop/notes.ex
           + function Shop.Notes.note/1
           + function Shop.Orders.count/1
           ~ function Shop.Orders.valid?/1
           + call Shop.Orders.place/1 -> Shop.Notes.note/1
           - file lib/shop/old.ex
           - function Shop.Old.run/0
           - function Shop.Orders.gone/0
           - call Shop.Orders.gone/0 -> Shop.Old.run/0
           removed: 1 file, 2 functions, 1 call
           """
  end

  test "warnings/2 warns when no file of a snapshot with files is in the project", context do
    assert Changes.warnings(context.project, context.snapshot) == []

    {:ok, elsewhere} =
      Snapshot.read("xref_mermaid snapshot 1\nfile\tapps/shop/lib/shop/orders.ex\n")

    assert [warning] = Changes.warnings(context.project, elsewhere)
    assert warning =~ "no file of the snapshot is a file of the project"

    {:ok, empty} = Snapshot.read("xref_mermaid snapshot 1\n")
    assert Changes.warnings(context.project, empty) == []
  end
end
