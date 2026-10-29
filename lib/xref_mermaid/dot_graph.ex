defmodule XrefMermaid.DotGraph do
  @moduledoc """
  Reads the output of `mix xref graph --format dot`, which every supported Elixir version can write.
  """

  @doc """
  Returns `%{source_file => %{sink_file => kind}}`, where `kind` is `"compile"`, `"export"` or `"runtime"`.
  Files with no dependencies map to `%{}`.
  """
  def parse(dot) do
    dot
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, graph ->
      case Regex.run(~r/^\s*"([^"]+)"(?: -> "([^"]+)")?(?: \[label="\((\w+)\)"\])?/, line) do
        [_, file] ->
          Map.put_new(graph, file, %{})

        [_, source, sink | label] ->
          # An edge without a label is a runtime dependency.
          kind = List.first(label, "runtime")

          graph
          |> Map.update(source, %{sink => kind}, &Map.put(&1, sink, kind))
          |> Map.put_new(sink, %{})

        nil ->
          graph
      end
    end)
  end
end
