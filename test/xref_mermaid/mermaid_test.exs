defmodule XrefMermaid.MermaidTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Mermaid, Selection, TestProject}

  setup do
    project =
      TestProject.build(
        [
          {Shop.Orders, "lib/shop/orders.ex",
           [{:place, [1, 2], :def, 2}, {:valid?, [1], :defp, 5}, {:<~>, [2], :def, 7}],
           [
             {{:place, 1}, {Shop.Orders, :valid?, 1}},
             {{:place, 1}, {Shop.Repo, :insert, 1}},
             {{:place, 1}, {Shop.A.B, :run, 0}},
             {{:place, 1}, {Shop.AB, :run, 0}}
           ]},
          {Shop.Orders.Line, "lib/shop/orders.ex", [{:describe, [1], :def, 12}], []},
          {String.Chars.Shop.Orders, "lib/shop/orders.ex", [{:to_string, [1], :def, 16}], [],
           impl?: true},
          {Shop.Repo, "lib/shop/repo.ex", [{:insert, [1], :def, 2, generated: true}], []},
          {Shop.A.B, "lib/shop/a/b.ex", [{:run, [0], :def, 2}], []},
          {Shop.AB, "lib/shop/a_b.ex", [{:run, [0], :def, 2}], []},
          {Shop.Order, "lib/shop/order.ex", [], []}
        ],
        %{"lib/shop/orders.ex" => %{"lib/shop/order.ex" => "export"}}
      )

    %{project: project}
  end

  test "write/3 draws directories, files, functions, calls and file dependencies", %{
    project: project
  } do
    selection = Selection.select(project, prefixes: ["lib/shop/orders.ex"])

    assert Mermaid.write(project, selection) == ~S"""
           flowchart LR
             subgraph d_lib ["lib/"]
               subgraph d_lib_shop ["shop/"]
                 subgraph f_a_b_2 ["a_b.ex"]
                   f_a_b_2__run_0["run/0"]
                 end
                 f_order["order.ex"]
                 subgraph f_orders ["orders.ex"]
                   f_orders__place_1["place/1..2"]
                   f_orders__valid_q_1["valid?/1"]
                   f_orders______2["#lt;~#gt;/2"]
                   f_orders__Line__describe_1["Line.describe/1"]
                   f_orders__impl_String_Chars__to_string_1["[impl String.Chars] to_string/1"]
                 end
                 subgraph f_repo ["repo.ex"]
                   f_repo__insert_1["insert/1"]
                 end
                 subgraph d_lib_shop_a ["a/"]
                   subgraph f_a_b ["b.ex"]
                     f_a_b__run_0["run/0"]
                   end
                 end
               end
             end
             f_orders__place_1 --> f_a_b__run_0
             f_orders__place_1 --> f_a_b_2__run_0
             f_orders__place_1 --> f_orders__valid_q_1
             f_orders__place_1 --> f_repo__insert_1
             f_orders -. export .-> f_order
             class f_orders slice
             classDef slice fill:#ffe9a8,stroke:#b8860b
             class f_orders__valid_q_1 private
             class f_repo__insert_1 generated
             classDef private stroke-dasharray:4 3
             classDef generated fill:#eeeeee,stroke:#999999,color:#555555
             classDef start stroke:#cc3333,stroke-width:3px
           """
  end

  test "write/3 collapses files on request, except a start function's, and adds links and a legend",
       %{project: project} do
    selection = Selection.select(project, from: [{Shop.Orders, :place, 1}], depth: 1)

    text =
      Mermaid.write(project, selection,
        collapsed: true,
        link: "editor://open?file={path}&line={line}",
        legend: true
      )

    # The file holding the start function stays open.
    refute text =~ "f_orders@{ view: collapsed }"
    assert text =~ "  f_repo@{ view: collapsed }\n"
    assert text =~ "  class f_orders__place_1 start\n"

    assert text =~
             ~s(  click f_orders__place_1 href "editor://open?file=/project/lib/shop/orders.ex&line=2"\n)

    assert text =~ ~s(  subgraph legend_ ["Legend"]\n)
  end

  test "write/3 opens every file by default, and collapses the files outside the slice with `all_functions`",
       %{project: project} do
    default = Mermaid.write(project, Selection.select(project, prefixes: ["lib/shop/orders.ex"]))
    refute default =~ "view: collapsed"

    all_opts = [prefixes: ["lib/shop/orders.ex"], all_functions: true]
    all = Mermaid.write(project, Selection.select(project, all_opts), all_functions: true)
    assert all =~ "f_repo@{ view: collapsed }"
    refute all =~ "f_orders@{ view: collapsed }"
  end

  test "write/3 escapes what Mermaid reads in labels" do
    project = TestProject.build([{Odd, "lib/odd \"#1\".ex", [{:&&&, [2], :def, 1}], []}])
    text = Mermaid.write(project, Selection.select(project, prefixes: ["lib/"]))

    assert text =~ ~s(["odd #quot;#35;1#quot;.ex"])
    assert text =~ ~s(["#amp;#amp;#amp;/2"])
  end

  test "write/3 draws external calls in their own subgraph" do
    project =
      TestProject.build([
        {Shop.Orders, "lib/shop/orders.ex", [{:place, [1], :def, 2}],
         [{{:place, 1}, {Enum, :map, 2}}]}
      ])

    text = Mermaid.write(project, Selection.select(project, prefixes: ["lib/"], external: true))

    assert text =~ """
             subgraph x_ ["external"]
               subgraph x_Enum ["Enum"]
                 x_Enum__map_2["map/2"]
               end
             end
             f_orders__place_1 --> x_Enum__map_2
           """
  end

  test "write/3 gives clashing ids a suffix, and colors a slice file drawn as a plain node" do
    project =
      TestProject.build([
        {A, "lib/a-b/x.ex", [{:valid?, [1], :def, 1}, {:valid_q, [1], :def, 2}], []},
        {B, "lib/a_b/x.ex", [], []}
      ])

    text = Mermaid.write(project, Selection.select(project, prefixes: ["lib/"]))

    assert text =~ ~s(subgraph d_lib_a_b ["a-b/"])
    assert text =~ ~s(subgraph d_lib_a_b_2 ["a_b/"])
    assert text =~ ~s(subgraph f_a_b_x ["x.ex"])
    assert text =~ ~s(f_a_b_x__valid_q_1["valid?/1"])
    assert text =~ ~s(f_a_b_x__valid_q_1_2["valid_q/1"])
    assert text =~ ~s(  f_a_b_x_2["x.ex"]\n)
    assert text =~ "class f_a_b_x,f_a_b_x_2 slice"
  end

  test "write/3 encodes reserved characters of a path in links" do
    project = TestProject.build([{A, "lib/my #1 dir/a?b.ex", [{:run, [0], :def, 3}], []}])

    text =
      Mermaid.write(project, Selection.select(project, prefixes: ["lib/"]),
        link: "x://{path}:{line}"
      )

    assert text =~ ~s(href "x:///project/lib/my%20%231%20dir/a%3Fb.ex:3")
  end

  test "limit_warnings/1 warns over Mermaid's default limits, not counting the legend" do
    assert Mermaid.limit_warnings("flowchart LR\n  a --> b\n") == []
    assert [size] = Mermaid.limit_warnings(String.duplicate("x", 50_001))
    assert size =~ "50001 characters"

    arrows = String.duplicate("  a --> b\n", 501)
    assert [count] = Mermaid.limit_warnings(arrows <> "    legend_caller --> legend_called\n")
    assert count =~ "501 arrows"
  end

  test "write_overview/1 draws one node per directory and labeled arrows" do
    overview = %{
      dirs: ["lib/*", "lib/app/orders/"],
      edges: [{"lib/*", "lib/app/orders/", "compile", 2}]
    }

    assert Mermaid.write_overview(overview) == """
           flowchart LR
             d_lib__["lib/*"]
             d_lib_app_orders_["lib/app/orders/"]
             d_lib__ == compile ×2 ==> d_lib_app_orders_
           """
  end
end
