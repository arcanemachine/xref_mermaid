defmodule XrefMermaid.SelectionTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Selection, TestProject}

  # `Orders.place/1` -> `Orders.check/1` -> `Rules.allowed?/1` -> `Rules.limit/0`; `place/1` -> `Repo.insert/1`;
  # `Admin.retry/1` -> `place/1`; `Rules.allowed?/1` and `Rules.again/1` call each other.
  setup do
    project =
      TestProject.build(
        [
          {Shop.Orders, "lib/shop/orders.ex",
           [{:place, [1], :def, 2}, {:check, [1], :defp, 5}, {:unused, [0], :def, 8}],
           [
             {{:place, 1}, {Shop.Orders, :check, 1}},
             {{:place, 1}, {Shop.Repo, :insert, 1}},
             {{:place, 1}, {Enum, :map, 2}},
             {{:place, 1}, {:erlang, :length, 1}},
             {{:check, 1}, {Shop.Rules, :allowed?, 1}}
           ]},
          {Shop.Rules, "lib/shop/rules.ex",
           [{:allowed?, [1], :def, 2}, {:again, [1], :def, 4}, {:limit, [0], :def, 6}],
           [
             {{:allowed?, 1}, {Shop.Rules, :limit, 0}},
             {{:allowed?, 1}, {Shop.Rules, :again, 1}},
             {{:again, 1}, {Shop.Rules, :allowed?, 1}}
           ]},
          {Shop.Repo, "lib/shop/repo.ex",
           [{:insert, [1], :def, 2, generated: true}, {:all, [0], :def, 2, generated: true}], []},
          {Shop.Admin, "lib/shop/admin.ex", [{:retry, [1], :def, 2}],
           [{{:retry, 1}, {Shop.Orders, :place, 1}}]},
          {Shop.Order, "lib/shop/order.ex", [], []}
        ],
        %{
          "lib/shop/orders.ex" => %{
            "lib/shop/order.ex" => "export",
            "lib/shop/repo.ex" => "runtime",
            "lib/shop/rules.ex" => "runtime"
          },
          "lib/shop/admin.ex" => %{"lib/shop/orders.ex" => "runtime"}
        }
      )

    %{project: project}
  end

  test "a path slice shows its functions, their calls, the called functions and unexplained file dependencies",
       %{project: project} do
    selection = Selection.select(project, prefixes: ["lib/shop/orders.ex"])

    assert selection.files == %{
             "lib/shop/orders.ex" => [
               {Shop.Orders, :place, 1},
               {Shop.Orders, :check, 1},
               {Shop.Orders, :unused, 0}
             ],
             "lib/shop/rules.ex" => [{Shop.Rules, :allowed?, 1}],
             "lib/shop/repo.ex" => [{Shop.Repo, :insert, 1}],
             "lib/shop/order.ex" => []
           }

    assert selection.calls == [
             {{Shop.Orders, :check, 1}, {Shop.Rules, :allowed?, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Orders, :check, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Repo, :insert, 1}}
           ]

    assert selection.file_edges == [{"lib/shop/orders.ex", "lib/shop/order.ex", "export"}]
    assert selection.slice_files == MapSet.new(["lib/shop/orders.ex"])
    assert selection.externals == %{}
  end

  test "`all_functions` shows every written function of the shown files", %{project: project} do
    selection = Selection.select(project, prefixes: ["lib/shop/orders.ex"], all_functions: true)

    assert selection.files["lib/shop/rules.ex"] == [
             {Shop.Rules, :allowed?, 1},
             {Shop.Rules, :again, 1},
             {Shop.Rules, :limit, 0}
           ]

    # Generated functions stay limited to the called ones.
    assert selection.files["lib/shop/repo.ex"] == [{Shop.Repo, :insert, 1}]
  end

  test "`incoming` adds the calls into the slice and the files that depend on it", %{
    project: project
  } do
    selection = Selection.select(project, prefixes: ["lib/shop/orders.ex"], incoming: true)

    assert {{Shop.Admin, :retry, 1}, {Shop.Orders, :place, 1}} in selection.calls
    assert selection.files["lib/shop/admin.ex"] == [{Shop.Admin, :retry, 1}]
  end

  test "`from` follows calls outward up to `depth` hops, through cycles", %{project: project} do
    two = Selection.select(project, from: [{Shop.Orders, :place, 1}], depth: 2)

    assert two.calls == [
             {{Shop.Orders, :check, 1}, {Shop.Rules, :allowed?, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Orders, :check, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Repo, :insert, 1}}
           ]

    assert two.starts == MapSet.new([{Shop.Orders, :place, 1}])
    assert two.slice_files == MapSet.new()
    assert two.file_edges == []
    refute Map.has_key?(two.files, "lib/shop/order.ex")

    all = Selection.select(project, from: [{Shop.Orders, :place, 1}], depth: 10)

    assert all.calls == [
             {{Shop.Orders, :check, 1}, {Shop.Rules, :allowed?, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Orders, :check, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Repo, :insert, 1}},
             {{Shop.Rules, :again, 1}, {Shop.Rules, :allowed?, 1}},
             {{Shop.Rules, :allowed?, 1}, {Shop.Rules, :again, 1}},
             {{Shop.Rules, :allowed?, 1}, {Shop.Rules, :limit, 0}}
           ]
  end

  test "`to` follows calls backward", %{project: project} do
    selection = Selection.select(project, to: [{Shop.Rules, :limit, 0}], depth: 3)

    assert selection.calls == [
             {{Shop.Orders, :check, 1}, {Shop.Rules, :allowed?, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Orders, :check, 1}},
             {{Shop.Rules, :again, 1}, {Shop.Rules, :allowed?, 1}},
             # The cycle's other half is a call into a function already reached.
             {{Shop.Rules, :allowed?, 1}, {Shop.Rules, :again, 1}},
             {{Shop.Rules, :allowed?, 1}, {Shop.Rules, :limit, 0}}
           ]
  end

  test "path prefixes, `from` and `to` combine", %{project: project} do
    selection =
      Selection.select(project,
        prefixes: ["lib/shop/admin.ex"],
        from: [{Shop.Rules, :allowed?, 1}],
        to: [{Shop.Orders, :check, 1}],
        depth: 1
      )

    assert selection.calls == [
             {{Shop.Admin, :retry, 1}, {Shop.Orders, :place, 1}},
             {{Shop.Orders, :place, 1}, {Shop.Orders, :check, 1}},
             {{Shop.Rules, :allowed?, 1}, {Shop.Rules, :again, 1}},
             {{Shop.Rules, :allowed?, 1}, {Shop.Rules, :limit, 0}}
           ]

    assert selection.slice_files == MapSet.new(["lib/shop/admin.ex"])
    assert selection.starts == MapSet.new([{Shop.Rules, :allowed?, 1}, {Shop.Orders, :check, 1}])
  end

  test "a start function is shown even without drawn calls", %{project: project} do
    zero = Selection.select(project, from: [{Shop.Orders, :place, 1}], depth: 0)
    assert zero.calls == []
    assert zero.files == %{"lib/shop/orders.ex" => [{Shop.Orders, :place, 1}]}

    leaf = Selection.select(project, from: [{Shop.Rules, :limit, 0}])
    assert leaf.files == %{"lib/shop/rules.ex" => [{Shop.Rules, :limit, 0}]}
  end

  test "`external` adds Elixir modules outside the project, but not Erlang modules", %{
    project: project
  } do
    selection = Selection.select(project, prefixes: ["lib/shop/orders.ex"], external: true)

    assert selection.externals == %{Enum => [{:external, {Enum, :map, 2}}]}
    assert {{Shop.Orders, :place, 1}, {:external, {Enum, :map, 2}}} in selection.calls
    refute Enum.any?(selection.calls, &match?({_, {:external, {:erlang, _, _}}}, &1))
  end

  test "overview/2 groups files at the root as `./*`" do
    project =
      TestProject.build([{A, "a.ex", [], []}, {B, "lib/b.ex", [], []}], %{
        "a.ex" => %{"lib/b.ex" => "export"}
      })

    assert Selection.overview(project, 2) == %{
             dirs: ["./*", "lib/*"],
             edges: [{"./*", "lib/*", "export", 1}]
           }
  end

  test "overview/2 groups files into directories and sums their dependencies" do
    project =
      TestProject.build(
        [
          {A, "lib/app.ex", [], []},
          {B, "lib/app/orders/a.ex", [], []},
          {C, "lib/app/orders/b.ex", [], []},
          {D, "lib/app/rules/c.ex", [], []}
        ],
        %{
          "lib/app.ex" => %{"lib/app/orders/a.ex" => "runtime"},
          "lib/app/orders/a.ex" => %{
            "lib/app/rules/c.ex" => "runtime",
            "lib/app/orders/b.ex" => "compile"
          },
          "lib/app/orders/b.ex" => %{"lib/app/rules/c.ex" => "compile"}
        }
      )

    assert Selection.overview(project, 1) == %{
             dirs: ["lib/"],
             edges: []
           }

    assert Selection.overview(project, 5).dirs == ["lib/*", "lib/app/orders/*", "lib/app/rules/*"]

    assert Selection.overview(project, 3) == %{
             dirs: ["lib/*", "lib/app/orders/", "lib/app/rules/"],
             edges: [
               {"lib/*", "lib/app/orders/", "runtime", 1},
               {"lib/app/orders/", "lib/app/rules/", "compile", 2}
             ]
           }
  end
end
