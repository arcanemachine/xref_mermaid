defmodule XrefMermaid.Edges do
  @moduledoc """
  Writes a selection as plain text, one line per call, for diffing rather than drawing.
  """

  @doc """
  One sorted line per call in `selection` (from `XrefMermaid.Selection.select/2`): `Mod.fun/arity -> Mod.fun/arity`,
  each function named by its lowest arity, or `~>` for a call through private functions
  (`XrefMermaid.Project.public_only/1`). For a selection between files (`XrefMermaid.Selection.by_file/3`), one
  line per pair of files, by their main modules, with the count of calls: `ModA -> ModB 3`.
  """
  def write(project, selection) do
    calls =
      Enum.map(selection.calls, fn {caller, callee} = call ->
        arrow = if call in project.through_private, do: "~>", else: "->"
        "#{name(caller)} #{arrow} #{name(callee)}\n"
      end)

    file_calls =
      Enum.map(selection.file_calls, fn {source, sink, count} ->
        "#{name(project, source)} -> #{name(project, sink)} #{count}\n"
      end)

    (calls ++ file_calls) |> Enum.sort() |> IO.iodata_to_binary()
  end

  defp name({:external, key}), do: name(key)
  defp name({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  defp name(_project, {:external_module, module}), do: inspect(module)

  defp name(project, {:file, file}) do
    case project.modules_in[file] do
      [main | _] -> inspect(main)
      _ -> file
    end
  end
end
