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
          %{module: A, file: "/p/lib/a.ex", impl?: false, functions: [], calls: []},
          %{module: B, file: "/p/elsewhere/b.ex", impl?: false, functions: [], calls: []}
        ],
        "/p"
      )

    assert Map.keys(project.modules) == [A]
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
