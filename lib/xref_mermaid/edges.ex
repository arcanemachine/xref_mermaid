defmodule XrefMermaid.Edges do
  @moduledoc """
  Writes a selection as plain text, one line per call, for diffing rather than drawing.
  """

  @doc """
  One sorted line per call in `selection` (from `XrefMermaid.Selection.select/2`): `Mod.fun/arity -> Mod.fun/arity`,
  each function named by its lowest arity.
  """
  def write(selection) do
    selection.calls
    |> Enum.map(fn {caller, callee} -> "#{name(caller)} -> #{name(callee)}\n" end)
    |> Enum.sort()
    |> IO.iodata_to_binary()
  end

  defp name({:external, key}), do: name(key)
  defp name({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"
end
