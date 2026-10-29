defmodule XrefMermaid do
  @moduledoc """
  Draws part of an Elixir project as a Mermaid flowchart: its files (from `mix xref graph`) and the calls between
  their functions (from the compiled modules).

  Slice files are the files whose paths start with one of the given prefixes. The chart shows them and the files
  they depend on (and the files that depend on them, with `incoming: true`), nested in one subgraph per directory.
  Each file is a subgraph of its functions. An arrow is drawn for each call a slice function makes; a file
  dependency with no call behind it (a struct, a compile-time use) is drawn as a labeled arrow between files.
  """

  @file_arrows %{
    "compile" => "== compile ==>",
    "export" => "-. export .->",
    "runtime" => "-. runtime .->"
  }

  @doc """
  Renders `graph` (`%{source_file => %{sink_file => kind}}`) and `modules` (from `XrefMermaid.Beam.read/1`, with
  `:file` relative to the graph's paths) as Mermaid text.

  Options:

    * `:incoming` - also shows the files that depend on the slice, and their calls into it
    * `:expanded` - opens every file (by default, slice files are open and the others collapsed)
    * `:collapsed` - collapses every file
  """
  def render(graph, prefixes, modules, opts \\ []) do
    in_slice? = fn file -> Enum.any?(prefixes, &String.starts_with?(file, &1)) end

    shown_edge? = fn source, sink ->
      in_slice?.(source) or (opts[:incoming] == true and in_slice?.(sink))
    end

    file_edges =
      for {source, sinks} <- graph,
          {sink, kind} <- sinks,
          source != sink,
          shown_edge?.(source, sink),
          do: {source, sink, kind}

    files =
      (Enum.filter(Map.keys(graph), in_slice?) ++
         Enum.flat_map(file_edges, fn {source, sink, _} -> [source, sink] end))
      |> Enum.uniq()
      |> Enum.sort()

    modules_in = modules |> Enum.filter(&(&1.file in files)) |> Enum.group_by(& &1.file)

    # Each `{module, name, arity}` points at its function's node, so calls to any arity of a function with
    # default arguments land on one node.
    node_of =
      for {file, file_modules} <- modules_in,
          module <- file_modules,
          function <- module.functions,
          arity <- function.arities,
          into: %{},
          do:
            {{module.module, function.name, arity},
             {file, function_id(file, file_modules, module, function)}}

    calls =
      for {file, file_modules} <- modules_in,
          module <- file_modules,
          {{name, arity}, callee} <- module.calls,
          {^file, caller_id} <- List.wrap(node_of[{module.module, name, arity}]),
          {callee_file, callee_id} <- List.wrap(node_of[callee]),
          shown_edge?.(file, callee_file),
          # A function with default arguments calls its own other arity, which is the same node.
          callee_id != caller_id,
          uniq: true,
          do: {file, caller_id, callee_file, callee_id}

    called_files = MapSet.new(calls, fn {file, _, callee_file, _} -> {file, callee_file} end)

    dirs =
      files
      |> Enum.map(&Path.dirname/1)
      |> Enum.flat_map(fn dir -> dir |> Path.split() |> Enum.scan(&Path.join(&2, &1)) end)
      |> Enum.uniq()

    context = %{
      children: Enum.group_by(dirs, &Path.dirname/1),
      files_in: Enum.group_by(files, &Path.dirname/1),
      modules_in: modules_in,
      in_slice?: in_slice?,
      opts: opts
    }

    roots = dirs |> Enum.reject(&(Path.dirname(&1) in dirs)) |> Enum.sort()

    IO.iodata_to_binary([
      "flowchart LR\n",
      Enum.map(roots, &render_dir(&1, 1, context)),
      Enum.map(Enum.sort(calls), fn {_, caller_id, _, callee_id} ->
        "  #{caller_id} --> #{callee_id}\n"
      end),
      file_edges
      |> Enum.reject(fn {source, sink, _} -> {source, sink} in called_files end)
      |> Enum.sort()
      |> Enum.map(fn {source, sink, kind} ->
        "  #{file_id(source)} #{@file_arrows[kind]} #{file_id(sink)}\n"
      end),
      "  classDef slice fill:#ffe9a8,stroke:#b8860b\n",
      "  classDef private stroke-dasharray:4 3\n"
    ])
  end

  defp render_dir(dir, indent, context) do
    pad = String.duplicate("  ", indent)
    files = context.files_in |> Map.get(dir, []) |> Enum.sort()
    subdirs = context.children |> Map.get(dir, []) |> Enum.sort()

    [
      ~s(#{pad}subgraph d_#{id(dir)} ["#{Path.basename(dir)}/"]\n),
      Enum.map(files, &render_file(&1, pad <> "  ", context)),
      Enum.map(subdirs, &render_dir(&1, indent + 1, context)),
      "#{pad}end\n"
    ]
  end

  defp render_file(file, pad, context) do
    file_modules = Map.get(context.modules_in, file, [])
    several_modules? = length(file_modules) > 1
    slice? = context.in_slice?.(file)

    nodes =
      for module <- file_modules, function <- module.functions do
        prefix = if several_modules?, do: "#{module.module |> Module.split() |> List.last()}."

        arities =
          Enum.join(Enum.uniq([List.first(function.arities), List.last(function.arities)]), "..")

        class = if function.kind in [:defp, :defmacrop], do: ":::private"

        ~s(#{pad}  #{function_id(file, file_modules, module, function)}["#{prefix}#{function.name}/#{arities}"]#{class}\n)
      end

    collapsed? =
      cond do
        context.opts[:expanded] -> false
        context.opts[:collapsed] -> true
        true -> not slice?
      end

    # A file without functions stays a plain node: Mermaid can't draw an empty subgraph.
    if nodes == [] do
      ~s(#{pad}#{file_id(file)}["#{Path.basename(file)}"]#{if slice?, do: ":::slice"}\n)
    else
      [
        ~s(#{pad}subgraph #{file_id(file)} ["#{Path.basename(file)}"]\n),
        nodes,
        "#{pad}end\n",
        if(collapsed?, do: "#{pad}#{file_id(file)}@{ view: collapsed }\n", else: ""),
        if(slice?, do: "#{pad}style #{file_id(file)} fill:#ffe9a8,stroke:#b8860b\n", else: "")
      ]
    end
  end

  defp file_id(file), do: "f_" <> id(file)

  # The module is in the id only when the file holds several, so ids stay short and survive regeneration.
  defp function_id(file, file_modules, module, function) do
    module_part =
      if length(file_modules) > 1, do: id(module.module |> Module.split() |> List.last()) <> "__"

    "#{file_id(file)}__#{module_part}#{id(function.name)}_#{List.first(function.arities)}"
  end

  # Mermaid ids allow letters, digits and `_` only; `?` and `!` keep their own spellings so `valid?/1` and
  # `valid!/1` stay apart.
  defp id(term) do
    term
    |> to_string()
    |> String.replace("?", "_q")
    |> String.replace("!", "_b")
    |> String.replace(~r/[^A-Za-z0-9]/, "_")
  end
end
