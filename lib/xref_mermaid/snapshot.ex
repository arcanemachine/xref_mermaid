defmodule XrefMermaid.Snapshot do
  @moduledoc """
  A project's files, functions and calls as text, written at one state of the project and compared with another
  (`XrefMermaid.Changes`).

  One sorted, tab-separated line per item, after a header naming the format's version:

      xref_mermaid snapshot 1
      file	lib/my_app/orders.ex
      function	lib/my_app/orders.ex	MyApp.Orders	place	1,2	3f2a9c0d1e4b
      call	MyApp.Orders	place	1	MyApp.Repo	insert	1
      external	MyApp.Orders	place	1	Enum	map	2

  A function is its module, name and arities, with its source hash (`XrefMermaid.Source`), `generated` for a
  generated function, or `-` without one. A call names its caller and callee by their lowest arity; an `external`
  call names its callee as called. Modules and names stay text, so reading a snapshot creates no atoms.
  """

  alias XrefMermaid.Source

  @header "xref_mermaid snapshot 1"

  @doc "Writes the whole project as a snapshot."
  def write(project) do
    hashes = Source.hashes(project, Map.keys(project.file_edges))

    files = Enum.map(Map.keys(project.file_edges), &line(["file", &1]))

    functions =
      for {key, function} <- project.functions do
        line([
          "function",
          function.file,
          inspect(function.module),
          Atom.to_string(function.name),
          Enum.join(function.arities, ","),
          cond do
            function.generated? -> "generated"
            hash = hashes[key] -> hash
            true -> "-"
          end
        ])
      end

    calls =
      for {caller, callees} <- project.forward, callee <- callees do
        case callee do
          {:external, key} -> line(["external" | fields(caller) ++ fields(key)])
          key -> line(["call" | fields(caller) ++ fields(key)])
        end
      end

    IO.iodata_to_binary([@header, "\n", Enum.sort(files ++ functions ++ calls)])
  end

  @doc """
  Reads a snapshot. Returns `{:ok, snapshot}` or `{:error, message}`; `snapshot` holds `files` (a set of paths),
  `functions` (`%{file, module, name, arities, hash, generated?}`, `hash` `nil` without one), `calls` and
  `externals` (sets of `{caller, callee}`, each `{module, name, arity}` as text and integer).
  """
  def read(text) do
    case String.split(text, "\n", trim: true) do
      [@header | lines] ->
        parse(lines)

      ["xref_mermaid snapshot " <> _ | _] ->
        {:error, "it was written by another version of xref_mermaid"}

      _ ->
        {:error, "it isn't an xref_mermaid snapshot"}
    end
  end

  defp parse(lines) do
    empty = %{files: MapSet.new(), functions: [], calls: MapSet.new(), externals: MapSet.new()}

    Enum.reduce_while(lines, {:ok, empty}, fn line, {:ok, acc} ->
      case String.split(line, "\t") do
        ["file", file] ->
          {:cont, {:ok, %{acc | files: MapSet.put(acc.files, file)}}}

        ["function", file, module, name, arities, hash] ->
          function = %{
            file: file,
            module: module,
            name: name,
            arities: arities |> String.split(",") |> Enum.map(&String.to_integer/1),
            hash: if(hash in ["-", "generated"], do: nil, else: hash),
            generated?: hash == "generated"
          }

          {:cont, {:ok, %{acc | functions: [function | acc.functions]}}}

        ["call", m1, n1, a1, m2, n2, a2] ->
          call = {{m1, n1, String.to_integer(a1)}, {m2, n2, String.to_integer(a2)}}
          {:cont, {:ok, %{acc | calls: MapSet.put(acc.calls, call)}}}

        ["external", m1, n1, a1, m2, n2, a2] ->
          call = {{m1, n1, String.to_integer(a1)}, {m2, n2, String.to_integer(a2)}}
          {:cont, {:ok, %{acc | externals: MapSet.put(acc.externals, call)}}}

        _ ->
          {:halt, {:error, "can't read the line #{inspect(line)}"}}
      end
    end)
  end

  @doc "A function key as the snapshot's text: `{module, name, arity}`."
  def name({module, name, arity}), do: {inspect(module), Atom.to_string(name), arity}

  defp fields(key), do: key |> name() |> Tuple.to_list() |> Enum.map(&to_string/1)

  defp line(fields), do: Enum.join(fields, "\t") <> "\n"
end
