defmodule XrefMermaidTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.PublicFunctions

  test "from_source/1 lists public functions with arity and skips private and quoted ones" do
    source = """
    defmodule Shop.Orders do
      defmacro __using__(_opts), do: quote(do: def(injected, do: 1))
      def place(order, opts) when is_list(opts), do: {order, opts}
      def place(order, _opts), do: order
      def count, do: 0
      defp helper(x), do: x
      defdelegate total(order), to: Shop.Totals
    end
    """

    assert PublicFunctions.from_source(source) == [
             {"Shop.Orders", :__using__, 1},
             {"Shop.Orders", :place, 2},
             {"Shop.Orders", :count, 0},
             {"Shop.Orders", :total, 1}
           ]
  end

  test "render/4 nests files in directory subgraphs and draws the slice's dependencies" do
    graph = %{
      "lib/shop/orders.ex" => %{"lib/shop/repo.ex" => "runtime", "lib/shop/order.ex" => "export"},
      "lib/shop/repo.ex" => %{},
      "lib/shop/order.ex" => %{},
      "lib/shop/unrelated.ex" => %{}
    }

    sources = %{
      "lib/shop/orders.ex" => "defmodule Shop.Orders do\n  def place(order), do: order\nend\n",
      "lib/shop/repo.ex" => "defmodule Shop.Repo do\n  def get(id), do: id\nend\n",
      "lib/shop/order.ex" => "defmodule Shop.Order do\n  defstruct [:id]\nend\n"
    }

    assert XrefMermaid.render(graph, ["lib/shop/orders.ex"], &Map.fetch!(sources, &1)) == """
           flowchart LR
             subgraph d_lib ["lib/"]
               subgraph d_lib_shop ["shop/"]
                 f_lib_shop_order_ex["order.ex"]
                 subgraph f_lib_shop_orders_ex ["orders.ex"]
                   f_lib_shop_orders_ex__0["place/1"]
                 end
                 f_lib_shop_orders_ex@{ view: collapsed }
                 style f_lib_shop_orders_ex fill:#ffe9a8,stroke:#b8860b
                 subgraph f_lib_shop_repo_ex ["repo.ex"]
                   f_lib_shop_repo_ex__0["get/1"]
                 end
                 f_lib_shop_repo_ex@{ view: collapsed }
               end
             end
             f_lib_shop_orders_ex --> f_lib_shop_order_ex
             f_lib_shop_orders_ex -.-> f_lib_shop_repo_ex
             classDef slice fill:#ffe9a8,stroke:#b8860b
           """
  end
end
