defmodule XrefMermaidTest do
  # The `Beam.read/1` test changes a global compiler option.
  use ExUnit.Case, async: false

  alias XrefMermaid.{Beam, DotGraph}

  test "DotGraph.parse/1 reads files, edges and their kinds" do
    dot = """
    digraph "xref graph" {
      "lib/shop/orders.ex"
      "lib/shop/orders.ex" -> "lib/shop/repo.ex"
      "lib/shop/orders.ex" -> "lib/shop/order.ex" [label="(export)"]
      "lib/shop/order.ex" -> "lib/shop/schema.ex" [label="(compile)"]
      "lib/shop/lonely.ex"
    }
    """

    assert DotGraph.parse(dot) == %{
             "lib/shop/orders.ex" => %{
               "lib/shop/repo.ex" => "runtime",
               "lib/shop/order.ex" => "export"
             },
             "lib/shop/order.ex" => %{"lib/shop/schema.ex" => "compile"},
             "lib/shop/repo.ex" => %{},
             "lib/shop/schema.ex" => %{},
             "lib/shop/lonely.ex" => %{}
           }
  end

  test "Beam.read/1 lists functions and their local, remote and captured calls" do
    # `mix test` compiles without debug info, which `Beam.read/1` reads.
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    on_exit(fn -> Code.put_compiler_option(:debug_info, previous) end)

    [{XrefMermaidTest.Orders, binary}] =
      Code.compile_string("""
      defmodule XrefMermaidTest.Orders do
        defstruct [:id]

        def place(order, opts \\\\ []) do
          order |> check() |> Enum.map(&String.upcase/1) |> save(opts)
        end

        def count([_ | rest]), do: 1 + count(rest)
        def count([]), do: 0

        defp check(order), do: Enum.map(order, &normalize/1)
        defp normalize(item), do: item
        defp save(order, _opts), do: order
      end
      """)

    module = Beam.read(binary)

    assert module.module == XrefMermaidTest.Orders
    assert module.file == "nofile"

    assert Enum.map(module.functions, &{&1.name, &1.arities, &1.kind}) == [
             {:place, [1, 2], :def},
             {:count, [1], :def},
             {:check, [1], :defp},
             {:normalize, [1], :defp},
             {:save, [2], :defp}
           ]

    assert Enum.sort(module.calls) ==
             Enum.sort([
               {{:place, 2}, {XrefMermaidTest.Orders, :check, 1}},
               {{:place, 2}, {Enum, :map, 2}},
               {{:place, 2}, {String, :upcase, 1}},
               {{:place, 2}, {XrefMermaidTest.Orders, :save, 2}},
               {{:count, 1}, {:erlang, :+, 2}},
               {{:check, 1}, {Enum, :map, 2}},
               {{:check, 1}, {XrefMermaidTest.Orders, :normalize, 1}}
             ])
  end

  test "render/4 draws calls between functions and file dependencies with no call behind them" do
    graph = %{
      "lib/shop/orders.ex" => %{"lib/shop/repo.ex" => "runtime", "lib/shop/order.ex" => "export"},
      "lib/shop/repo.ex" => %{},
      "lib/shop/order.ex" => %{},
      "lib/shop/unrelated.ex" => %{}
    }

    modules = [
      %{
        module: Shop.Orders,
        file: "lib/shop/orders.ex",
        functions: [
          %{name: :place, arities: [1], kind: :def, line: 2},
          %{name: :valid?, arities: [1], kind: :defp, line: 6}
        ],
        calls: [
          {{:place, 1}, {Shop.Orders, :valid?, 1}},
          {{:place, 1}, {Shop.Repo, :insert, 1}},
          {{:place, 1}, {Enum, :map, 2}}
        ]
      },
      %{
        module: Shop.Repo,
        file: "lib/shop/repo.ex",
        functions: [%{name: :insert, arities: [1, 2], kind: :def, line: 2}],
        calls: []
      },
      %{module: Shop.Order, file: "lib/shop/order.ex", functions: [], calls: []}
    ]

    assert XrefMermaid.render(graph, ["lib/shop/orders.ex"], modules) == """
           flowchart LR
             subgraph d_lib ["lib/"]
               subgraph d_lib_shop ["shop/"]
                 f_lib_shop_order_ex["order.ex"]
                 subgraph f_lib_shop_orders_ex ["orders.ex"]
                   f_lib_shop_orders_ex__place_1["place/1"]
                   f_lib_shop_orders_ex__valid_q_1["valid?/1"]:::private
                 end
                 style f_lib_shop_orders_ex fill:#ffe9a8,stroke:#b8860b
                 subgraph f_lib_shop_repo_ex ["repo.ex"]
                   f_lib_shop_repo_ex__insert_1["insert/1..2"]
                 end
                 f_lib_shop_repo_ex@{ view: collapsed }
               end
             end
             f_lib_shop_orders_ex__place_1 --> f_lib_shop_orders_ex__valid_q_1
             f_lib_shop_orders_ex__place_1 --> f_lib_shop_repo_ex__insert_1
             f_lib_shop_orders_ex -. export .-> f_lib_shop_order_ex
             classDef slice fill:#ffe9a8,stroke:#b8860b
             classDef private stroke-dasharray:4 3
           """
  end
end
