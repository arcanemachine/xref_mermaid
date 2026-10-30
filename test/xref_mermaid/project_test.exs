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
