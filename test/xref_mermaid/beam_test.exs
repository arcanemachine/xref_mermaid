defmodule XrefMermaid.BeamTest do
  # These tests change a global compiler option.
  use ExUnit.Case, async: false

  alias XrefMermaid.Beam

  setup do
    # `mix test` compiles without debug info, which `Beam.read/1` reads.
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    on_exit(fn -> Code.put_compiler_option(:debug_info, previous) end)
  end

  defp read(source) do
    source |> Code.compile_string() |> Enum.map(fn {_, binary} -> Beam.read(binary) end)
  end

  test "lists functions, merging default arities and keeping operators and delegates" do
    [module] =
      read("""
      defmodule BeamTest.Orders do
        defstruct [:id]

        def place(order, opts \\\\ []), do: {check(order), opts}
        def count([_ | rest]), do: 1 + count(rest)
        def count([]), do: 0
        def left <~> right, do: {left, right}
        defdelegate total(order), to: Enum, as: :sum
        defmacro twice(x), do: x
        defp check(order), do: order
      end
      """)

    assert module.module == BeamTest.Orders
    assert module.impl? == false

    assert Enum.map(module.functions, &{&1.name, &1.arities, &1.kind, &1.generated?}) == [
             {:place, [1, 2], :def, false},
             {:count, [1], :def, false},
             {:<~>, [2], :def, false},
             {:total, [1], :def, false},
             {:twice, [1], :defmacro, false},
             {:check, [1], :defp, false}
           ]
  end

  test "reads local, remote and captured calls, without recursion" do
    [module] =
      read("""
      defmodule BeamTest.Calls do
        def place(order) do
          order |> check() |> Enum.map(&String.upcase/1) |> Enum.map(&normalize/1)
        end

        def count([_ | rest]), do: count(rest)
        def count([]), do: 0

        defp check(order), do: order
        defp normalize(item), do: item
      end
      """)

    assert Enum.sort(module.calls) == [
             {{:place, 1}, {BeamTest.Calls, :check, 1}},
             {{:place, 1}, {BeamTest.Calls, :normalize, 1}},
             {{:place, 1}, {Enum, :map, 2}},
             {{:place, 1}, {String, :upcase, 1}}
           ]
  end

  test "marks generated functions, keeps local calls to them and leaves out `__name__` functions" do
    [_using, module] =
      read("""
      defmodule BeamTest.Gen do
        defmacro __using__(_opts) do
          quote do
            def changeset(record), do: record
          end
        end
      end

      defmodule BeamTest.Repo do
        use BeamTest.Gen
        defstruct [:id]

        def save(record), do: changeset(%__MODULE__{id: record})
      end
      """)

    assert Enum.map(module.functions, &{&1.name, &1.generated?}) == [
             {:changeset, true},
             {:save, false}
           ]

    assert module.calls == [{{:save, 1}, {BeamTest.Repo, :changeset, 1}}]
  end

  test "keeps generated functions of one name and line apart when their arities differ" do
    [_using, module] =
      read("""
      defmodule BeamTest.FetchGen do
        defmacro __using__(_opts) do
          quote do
            def fetch(a), do: a
            def fetch(a, b, c), do: {a, b, c}
          end
        end
      end

      defmodule BeamTest.Fetcher do
        use BeamTest.FetchGen
      end
      """)

    assert Enum.map(module.functions, &{&1.name, &1.arities}) == [{:fetch, [1]}, {:fetch, [3]}]
  end

  test "marks protocol implementations" do
    modules =
      read("""
      defmodule BeamTest.Thing do
        defstruct []
      end

      defprotocol BeamTest.Show do
        def show(thing)
      end

      defimpl BeamTest.Show, for: BeamTest.Thing do
        def show(_thing), do: "thing"
      end
      """)

    assert Enum.map(modules, &{&1.module, &1.impl?}) == [
             {BeamTest.Thing, false},
             {BeamTest.Show, false},
             {BeamTest.Show.BeamTest.Thing, true}
           ]
  end

  test "returns nil without debug info" do
    Code.put_compiler_option(:debug_info, false)
    assert read("defmodule BeamTest.Bare do\n  def a, do: 1\nend") == [nil]
  end
end
