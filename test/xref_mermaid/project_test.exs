defmodule XrefMermaid.ProjectTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Project, TestProject}

  setup do
    project =
      TestProject.build([
        {Shop.Orders, "lib/shop/orders.ex", [{:place, [1, 2], :def, 2}, {:check, [1], :defp, 6}],
         [
           {{:place, 1}, {Shop.Orders, :place, 2}},
           {{:place, 2}, {Shop.Orders, :check, 1}},
           {{:place, 2}, {Shop.Repo, :insert, 2}},
           {{:place, 2}, {Shop.Repo, :missing, 1}},
           {{:place, 2}, {Enum, :map, 2}}
         ]},
        {Shop.Repo, "lib/shop/repo.ex", [{:insert, [1, 2], :def, 2}], []}
      ])

    %{project: project}
  end

  test "new/3 resolves calls to function keys, merges default arities and marks external calls",
       %{project: project} do
    assert project.forward == %{
             {Shop.Orders, :place, 1} => [
               {Shop.Orders, :check, 1},
               {Shop.Repo, :insert, 1},
               {:external, {Enum, :map, 2}}
             ]
           }

    assert project.backward[{Shop.Repo, :insert, 1}] == [{Shop.Orders, :place, 1}]
    assert project.functions[{Shop.Orders, :place, 1}].file == "lib/shop/orders.ex"
  end

  test "new/3 leaves out modules whose files aren't in the file graph" do
    project =
      Project.new(
        %{"lib/a.ex" => %{}},
        [
          %{module: A, file: "/p/lib/a.ex", line: 1, impl: nil, functions: [], calls: []},
          %{module: B, file: "/p/elsewhere/b.ex", line: 1, impl: nil, functions: [], calls: []}
        ],
        "/p"
      )

    assert Map.keys(project.modules) == [A]
  end

  test "new/3 doesn't count a project module it leaves out as external" do
    project =
      Project.new(
        %{"lib/a.ex" => %{}},
        [
          %{
            module: A,
            file: "/p/lib/a.ex",
            line: 1,
            impl: nil,
            functions: [%{name: :run, arities: [0], kind: :def, line: 1, generated?: false}],
            calls: [{{:run, 0}, {B, :go, 0}}, {{:run, 0}, {Enum, :map, 2}}]
          },
          %{module: B, file: "/p/elsewhere/b.ex", line: 1, impl: nil, functions: [], calls: []}
        ],
        "/p"
      )

    assert project.forward == %{{A, :run, 0} => [{:external, {Enum, :map, 2}}]}
  end

  test "new/3 lists each file's modules, the main one first" do
    project =
      TestProject.build([
        {String.Chars.Shop.Orders, "lib/shop/orders.ex", [], [],
         impl: {String.Chars, Shop.Orders}},
        {Shop.Orders.Line, "lib/shop/orders.ex", [], []},
        {Shop.Orders, "lib/shop/orders.ex", [], []}
      ])

    assert project.modules_in == %{
             "lib/shop/orders.ex" => [Shop.Orders, Shop.Orders.Line, String.Chars.Shop.Orders]
           }
  end

  test "exclude/2 drops the files, their functions and every call to or from them" do
    project =
      TestProject.build(
        [
          {Shop.Orders, "lib/shop/orders.ex", [{:place, [1], :def, 2}],
           [{{:place, 1}, {Shop.Repo, :insert, 1}}, {{:place, 1}, {Enum, :map, 2}}]},
          {Shop.Repo, "lib/shop/repo.ex", [{:insert, [1], :def, 2}], []},
          {Shop.Audit, "lib/shop/audit.ex", [{:log, [1], :def, 2}],
           [{{:log, 1}, {Shop.Orders, :place, 1}}]}
        ],
        %{"lib/shop/orders.ex" => %{"lib/shop/repo.ex" => "runtime"}}
      )

    project = Project.exclude(project, ["lib/shop/repo", "lib/shop/audit.ex"])

    assert project.file_edges == %{"lib/shop/orders.ex" => %{}}
    assert Map.keys(project.functions) == [{Shop.Orders, :place, 1}]
    assert Map.keys(project.modules) == [Shop.Orders]
    assert Map.keys(project.modules_in) == ["lib/shop/orders.ex"]
    assert project.forward == %{{Shop.Orders, :place, 1} => [{:external, {Enum, :map, 2}}]}
    assert project.backward == %{{:external, {Enum, :map, 2}} => [{Shop.Orders, :place, 1}]}
    assert {:error, _} = Project.resolve(project, {Shop.Repo, :insert, 1})
  end

  test "public_only/1 drops private functions, and turns calls through them into calls of their own" do
    place = {Shop.Orders, :place, 1}
    allowed? = {Shop.Rules, :allowed?, 1}
    insert = {Shop.Repo, :insert, 1}
    map = {:external, {Enum, :map, 2}}

    project =
      TestProject.build([
        {Shop.Orders, "lib/shop/orders.ex",
         [{:place, [1], :def, 2}, {:check, [1], :defp, 5}, {:log, [1], :defp, 8}],
         [
           {{:place, 1}, {Shop.Orders, :check, 1}},
           {{:place, 1}, {Shop.Repo, :insert, 1}},
           {{:place, 1}, {Shop.Orders, :log, 1}},
           {{:check, 1}, {Shop.Rules, :allowed?, 1}},
           {{:check, 1}, {Shop.Orders, :log, 1}},
           {{:check, 1}, {Enum, :map, 2}},
           {{:log, 1}, {Shop.Orders, :check, 1}},
           {{:log, 1}, {Shop.Repo, :insert, 1}},
           {{:log, 1}, {Shop.Orders, :place, 1}}
         ]},
        {Shop.Rules, "lib/shop/rules.ex", [{:allowed?, [1], :def, 2}], []},
        {Shop.Repo, "lib/shop/repo.ex", [{:insert, [1], :def, 2}], []}
      ])
      |> Project.public_only()

    assert Map.keys(project.functions) |> Enum.sort() == Enum.sort([place, allowed?, insert])
    assert {:error, _} = Project.resolve(project, {Shop.Orders, :check, 1})

    # In the order the code first reaches each, round the `check/1`-`log/1` cycle once: `allowed?/1`, then `log/1`'s
    # `insert/1`, then `map/2`. `log/1`'s call back to `place/1` is a call to itself, dropped; `insert/1` is also a
    # direct call, so not through a private one.
    assert project.forward == %{place => [allowed?, insert, map]}
    assert project.backward == %{allowed? => [place], map => [place], insert => [place]}
    assert project.through_private == MapSet.new([{place, allowed?}, {place, map}])
  end

  test "cycle_groups/1 groups the files on a cycle of calls between files" do
    project =
      TestProject.build([
        {A, "lib/a.ex", [{:run, [0], :def, 2}, {:back, [0], :def, 3}],
         [{{:run, 0}, {B, :run, 0}}, {{:run, 0}, {A, :back, 0}}]},
        {B, "lib/b.ex", [{:run, [0], :def, 2}], [{{:run, 0}, {C, :run, 0}}]},
        {C, "lib/c.ex", [{:run, [0], :def, 2}], [{{:run, 0}, {A, :back, 0}}]},
        {D, "lib/d.ex", [{:run, [0], :def, 2}], [{{:run, 0}, {A, :run, 0}}]}
      ])

    groups = Project.cycle_groups(project)
    assert Map.keys(groups) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
    assert groups |> Map.values() |> Enum.uniq() |> length() == 1
  end

  test "load_warnings/3 counts modules without debug info and modules whose files xref doesn't list" do
    project = TestProject.build([{A, "lib/a.ex", [], []}])

    unlisted = %{
      module: B,
      file: "/project/elsewhere/b.ex",
      line: 1,
      impl: nil,
      functions: [],
      calls: []
    }

    listed = %{module: A, file: "/project/lib/a.ex", line: 1, impl: nil, functions: [], calls: []}

    assert Project.load_warnings(project, [listed], 1) == []

    assert Project.load_warnings(project, [listed, unlisted], 4) == [
             "compiled modules without debug info, whose functions are missing: 2",
             "modules from files that `mix xref` doesn't list, whose functions are missing: 1"
           ]
  end

  test "parse_spec/1 reads functions as Elixir reads them" do
    assert Project.parse_spec("Shop.Orders.place/2") == {:ok, {Shop.Orders, :place, 2}}
    assert Project.parse_spec("Shop.Orders.valid?/1") == {:ok, {Shop.Orders, :valid?, 1}}
    assert Project.parse_spec("Shop.Orders.place") == {:ok, {Shop.Orders, :place, nil}}
    assert Project.parse_spec("Shop.Ops.<~>/2") == {:ok, {Shop.Ops, :<~>, 2}}
    assert Project.parse_spec("Elixir.Shop.Orders.place/1") == {:ok, {Shop.Orders, :place, 1}}
    assert Project.parse_spec(":ets.insert/2") == {:ok, {:ets, :insert, 2}}
    assert Project.parse_spec("Shop.Orders") == :error
    assert Project.parse_spec("place/1") == :error
    assert Project.parse_spec("not valid (") == :error
  end

  test "resolve/2 finds a function by any of its arities, or every arity", %{project: project} do
    assert Project.resolve(project, {Shop.Orders, :place, 2}) == {:ok, [{Shop.Orders, :place, 1}]}

    assert Project.resolve(project, {Shop.Orders, :place, nil}) ==
             {:ok, [{Shop.Orders, :place, 1}]}
  end

  test "resolve/2 names the closest functions when none matches", %{project: project} do
    assert {:error, message} = Project.resolve(project, {Shop.Orders, :plaec, 1})
    assert message =~ "No function Shop.Orders.plaec/1"
    assert message =~ "Shop.Orders.place/1"
  end
end
