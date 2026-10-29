defmodule XrefMermaid.DotGraphTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.DotGraph

  test "reads files, edges and their kinds" do
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
end
