defmodule XrefMermaid do
  @moduledoc """
  Turns the file graph of `mix xref graph --format json` into a Mermaid flowchart.

  Slice files are the files whose paths start with one of the given prefixes. The chart shows them and the files
  they depend on (and the files that depend on them, with `incoming: true`), nested in one subgraph per directory.
  Each file is a subgraph of its public functions, collapsed unless `expanded: true`.
  """

  alias XrefMermaid.PublicFunctions

  @arrows %{"compile" => "==>", "export" => "-->", "runtime" => "-.->"}

  @doc """
  Renders `graph` (`%{source_file => %{sink_file => kind}}`) as Mermaid text.

  `read_source` takes a file path from the graph and returns that file's source.
  """
  def render(graph, prefixes, read_source, opts \\ []) do
    in_slice? = fn file -> Enum.any?(prefixes, &String.starts_with?(file, &1)) end

    edges =
      for {source, sinks} <- graph,
          {sink, kind} <- sinks,
          source != sink,
          in_slice?.(source) or (opts[:incoming] && in_slice?.(sink)),
          do: {source, sink, kind}

    files =
      (Enum.filter(Map.keys(graph), in_slice?) ++
         Enum.flat_map(edges, fn {source, sink, _} -> [source, sink] end))
      |> Enum.uniq()
      |> Enum.sort()

    dirs =
      files
      |> Enum.map(&Path.dirname/1)
      |> Enum.flat_map(fn dir -> dir |> Path.split() |> Enum.scan(&Path.join(&2, &1)) end)
      |> Enum.uniq()

    context = %{
      children: Enum.group_by(dirs, &Path.dirname/1),
      files_in: Enum.group_by(files, &Path.dirname/1),
      in_slice?: in_slice?,
      read_source: read_source,
      expanded?: opts[:expanded] == true
    }

    roots = dirs |> Enum.reject(&(Path.dirname(&1) in dirs)) |> Enum.sort()

    IO.iodata_to_binary([
      "flowchart LR\n",
      Enum.map(roots, &render_dir(&1, 1, context)),
      Enum.map(Enum.sort(edges), fn {source, sink, kind} ->
        "  #{id("f_", source)} #{@arrows[kind]} #{id("f_", sink)}\n"
      end),
      "  classDef slice fill:#ffe9a8,stroke:#b8860b\n"
    ])
  end

  defp render_dir(dir, indent, context) do
    pad = String.duplicate("  ", indent)
    files = context.files_in |> Map.get(dir, []) |> Enum.sort()
    subdirs = context.children |> Map.get(dir, []) |> Enum.sort()

    [
      ~s(#{pad}subgraph #{id("d_", dir)} ["#{Path.basename(dir)}/"]\n),
      Enum.map(files, &render_file(&1, pad <> "  ", context)),
      Enum.map(subdirs, &render_dir(&1, indent + 1, context)),
      "#{pad}end\n"
    ]
  end

  defp render_file(file, pad, context) do
    file_id = id("f_", file)
    functions = file |> context.read_source.() |> PublicFunctions.from_source()
    several_modules? = functions |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() > 1
    slice? = context.in_slice?.(file)

    # A file without public functions stays a plain node: Mermaid can't draw an empty subgraph.
    if functions == [] do
      ~s(#{pad}#{file_id}["#{Path.basename(file)}"]#{if slice?, do: ":::slice"}\n)
    else
      nodes =
        functions
        |> Enum.with_index()
        |> Enum.map(fn {{module, name, arity}, index} ->
          prefix = if several_modules?, do: "#{module |> String.split(".") |> List.last()}."
          ~s(#{pad}  #{file_id}__#{index}["#{prefix}#{name}/#{arity}"]\n)
        end)

      [
        ~s(#{pad}subgraph #{file_id} ["#{Path.basename(file)}"]\n),
        nodes,
        "#{pad}end\n",
        if(!context.expanded?, do: "#{pad}#{file_id}@{ view: collapsed }\n", else: ""),
        if(slice?, do: "#{pad}style #{file_id} fill:#ffe9a8,stroke:#b8860b\n", else: "")
      ]
    end
  end

  # Mermaid ids allow letters, digits and `_` only.
  defp id(prefix, path), do: prefix <> String.replace(path, ~r/[^A-Za-z0-9]/, "_")
end
