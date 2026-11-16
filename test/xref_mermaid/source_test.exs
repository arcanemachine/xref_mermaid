defmodule XrefMermaid.SourceTest do
  use ExUnit.Case, async: true

  alias XrefMermaid.{Source, TestProject}

  @moduletag :tmp_dir

  # Hashes the functions of `source`, written as `lib/shop/orders.ex`, given as `{name, arities, kind, lines}`.
  defp hashes(dir, source, functions) do
    path = Path.join(dir, "lib/shop/orders.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)

    functions =
      for {name, arities, kind, [line | _] = lines} <- functions,
          do: {name, arities, kind, line, lines: lines}

    project = TestProject.build([{Shop.Orders, "lib/shop/orders.ex", functions, []}])
    Source.hashes(%{project | root: dir}, ["lib/shop/orders.ex"])
  end

  test "hashes/2 keeps a function's hash when other lines move or change", %{tmp_dir: dir} do
    before =
      hashes(
        dir,
        """
        defmodule Shop.Orders do
          def place(order), do: order
        end
        """,
        [{:place, [1], :def, [2]}]
      )

    # A comment and another function above shift the line.
    after_edit =
      hashes(
        dir,
        """
        defmodule Shop.Orders do
          # Orders.
          def count(orders), do: for(o <- orders, do: o) |> length()

          def place(order),   do: order
        end
        """,
        [{:count, [1], :def, [3]}, {:place, [1], :def, [5]}]
      )

    assert after_edit[{Shop.Orders, :place, 1}] == before[{Shop.Orders, :place, 1}]
  end

  test "hashes/2 changes with a function's body, its default values or its kind", %{tmp_dir: dir} do
    hash = fn source, kind ->
      hashes(dir, "defmodule Shop.Orders do\n#{source}\nend\n", [{:place, [1, 2], kind, [2]}])[
        {Shop.Orders, :place, 1}
      ]
    end

    base = hash.("def place(order, opts \\\\ []), do: {order, opts}", :def)

    # Sanity check: the function was found.
    assert is_binary(base)

    assert hash.("def place(order, opts \\\\ []), do: {opts, order}", :def) != base
    assert hash.("def place(order, opts \\\\ [a: 1]), do: {order, opts}", :def) != base
    assert hash.("defp place(order, opts \\\\ []), do: {order, opts}", :defp) != base
  end

  test "hashes/2 covers every clause of a function", %{tmp_dir: dir} do
    source = fn second ->
      """
      defmodule Shop.Orders do
        def count([]), do: 0
        def count([_ | rest]), do: #{second}
      end
      """
    end

    functions = [{:count, [1], :def, [2, 3]}]
    one = hashes(dir, source.("1 + count(rest)"), functions)
    two = hashes(dir, source.("2 + count(rest)"), functions)

    assert one[{Shop.Orders, :count, 1}] != two[{Shop.Orders, :count, 1}]
  end

  test "hashes/2 gives none to a delegate, a generated function or a function of an unreadable file",
       %{
         tmp_dir: dir
       } do
    hashes =
      hashes(
        dir,
        """
        defmodule Shop.Orders do
          defdelegate total(order), to: Shop.Totals
        end
        """,
        [{:total, [1], :def, [2]}]
      )

    assert hashes == %{}

    project =
      TestProject.build([
        {Shop.Gen, "lib/shop/gen.ex", [{:run, [0], :def, 2, generated: true}], []},
        {Shop.Gone, "lib/shop/gone.ex", [{:run, [0], :def, 1}], []}
      ])

    File.write!(Path.join(dir, "lib/shop/gen.ex"), "defmodule Shop.Gen do\ndef run, do: 1\nend\n")
    assert Source.hashes(%{project | root: dir}, ["lib/shop/gen.ex", "lib/shop/gone.ex"]) == %{}
  end
end
