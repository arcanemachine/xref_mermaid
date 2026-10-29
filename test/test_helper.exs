# The integration test builds and installs the archive and compiles a fixture project: `mix test --include
# integration`.
ExUnit.start(exclude: [:integration])

defmodule XrefMermaid.TestProject do
  @moduledoc false

  alias XrefMermaid.Project

  @root "/project"

  @doc """
  Builds a project from `modules`: `{module, file, functions, calls}` or `{module, file, functions, calls, opts}`,
  where `functions` are `{name, arities, kind, line}` (add `generated: true` in a fifth element) and `file` is
  relative. Every file is in the file graph; `file_edges` adds dependencies.
  """
  def build(modules, file_edges \\ %{}) do
    modules =
      Enum.map(modules, fn
        {module, file, functions, calls} -> beam(module, file, functions, calls, [])
        {module, file, functions, calls, opts} -> beam(module, file, functions, calls, opts)
      end)

    files = Map.new(modules, &{Path.relative_to(&1.file, @root), %{}})
    Project.new(Map.merge(files, file_edges, fn _, a, b -> Map.merge(a, b) end), modules, @root)
  end

  defp beam(module, file, functions, calls, opts) do
    %{
      module: module,
      file: Path.join(@root, file),
      impl?: Keyword.get(opts, :impl?, false),
      functions:
        Enum.map(functions, fn
          {name, arities, kind, line} -> function(name, arities, kind, line, false)
          {name, arities, kind, line, generated} -> function(name, arities, kind, line, generated)
        end),
      calls: calls
    }
  end

  defp function(name, arities, kind, line, generated) do
    %{
      name: name,
      arities: arities,
      kind: kind,
      line: line,
      generated?: generated == [generated: true]
    }
  end
end
