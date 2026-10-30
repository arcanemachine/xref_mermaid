defmodule XrefMermaid.Mermaid do
  @moduledoc """
  Writes a selection (`XrefMermaid.Selection`) or an overview as a Mermaid flowchart.

  Every id is prefixed (`d_` directory, `f_` file and its functions, `x_` external), which keeps ids clear of
  Mermaid's keywords (`end`, `graph`...), and is unique: a clash between two names that read the same once cleaned
  (`lib/a/b.ex` and `lib/a_b.ex`) gets a `_2`, `_3`... suffix.
  """

  # A labeled file dependency is written `a <open> kind <close> b`.
  @file_arrows %{
    "compile" => {"==", "==>"},
    "export" => {"-.", ".->"},
    "runtime" => {"-.", ".->"}
  }

  @doc """
  Options:

    * `:expanded` - opens every file
    * `:collapsed` - collapses every file
    * `:all_functions` - collapses the files outside the slice unless `:expanded` (their full function lists are
      long); otherwise every file is open
    * `:link` - a URL template for a `click` link on each function: `{path}` (absolute, URL-encoded) and `{line}`
    * `:legend` - adds a legend subgraph

  A file holding a start function (`from`/`to`) is never collapsed.
  """
  def write(project, selection, opts \\ []) do
    ## Ids

    files = selection.files |> Map.keys() |> Enum.sort()
    dirs = files |> Enum.flat_map(&(&1 |> dir_parts() |> ancestors())) |> Enum.uniq()
    shared = shared_dir(files)
    externals = selection.externals |> Enum.sort()

    # Containers get their ids first, so each function's id builds on its file's final (unique) id.
    container_ids =
      unique_ids(
        Enum.map(dirs, &{{:dir, &1}, "d_" <> clean(&1)}) ++
          Enum.map(files, &{{:file, &1}, "f_" <> clean(&1 |> strip(shared) |> Path.rootname())}) ++
          Enum.map(externals, fn {module, _} ->
            {{:external_module, module}, "x_" <> clean(inspect(module))}
          end)
      )

    module_parts = Map.new(files, &{&1, module_parts(&1, project)})

    ids =
      unique_ids(
        Enum.flat_map(
          files,
          &function_ids(&1, selection.files[&1], project, module_parts[&1], container_ids)
        ) ++
          for {module, keys} <- externals, {:external, {_, name, arity}} = key <- keys do
            {key, "#{container_ids[{:external_module, module}]}__#{clean_name(name)}_#{arity}"}
          end,
        container_ids
      )

    ## Text: the directory and file tree, the external modules, the arrows, then the styles and links

    context = %{
      ids: ids,
      project: project,
      selection: selection,
      opts: opts,
      module_parts: module_parts,
      children: Enum.group_by(dirs, &Path.dirname/1),
      files_in: Enum.group_by(files, &Path.dirname/1)
    }

    roots = dirs |> Enum.reject(&(Path.dirname(&1) in dirs)) |> Enum.sort()
    shown_keys = selection.files |> Map.values() |> List.flatten()
    functions = Enum.map(shown_keys, &project.functions[&1])

    IO.iodata_to_binary([
      "flowchart LR\n",
      # Files at the project root sit at the top level, outside any directory.
      Enum.map(Enum.sort(Map.get(context.files_in, ".", [])), &render_file(&1, "  ", context)),
      Enum.map(roots, &render_dir(&1, 1, context)),
      render_externals(externals, ids),
      Enum.map(selection.calls, fn {caller, callee} -> "  #{ids[caller]} --> #{ids[callee]}\n" end),
      Enum.map(selection.file_edges, fn {source, sink, kind} ->
        {open, close} = @file_arrows[kind]
        "  #{ids[{:file, source}]} #{open} #{kind} #{close} #{ids[{:file, sink}]}\n"
      end),
      if(opts[:legend], do: legend(), else: ""),
      case Enum.filter(files, &(&1 in selection.slice_files)) do
        [] -> ""
        slice_files -> "  class #{Enum.map_join(slice_files, ",", &ids[{:file, &1}])} slice\n"
      end,
      "  classDef slice fill:#ffe9a8,stroke:#b8860b\n",
      class_line(functions, &(&1.kind in [:defp, :defmacrop]), "private", ids),
      class_line(functions, & &1.generated?, "generated", ids),
      class_line(functions, &(&1.key in selection.starts), "start", ids),
      "  classDef private stroke-dasharray:4 3\n",
      "  classDef generated fill:#eeeeee,stroke:#999999,color:#555555\n",
      "  classDef start stroke:#cc3333,stroke-width:3px\n",
      if(opts[:link],
        do: Enum.map(functions, &link_line(&1, ids, project, opts[:link])),
        else: ""
      )
    ])
  end

  @doc """
  Returns warnings for a chart over Mermaid 12's default limits (`maxTextSize`, `maxEdges`), which make it refuse to
  draw the chart; a chart can't raise them.
  """
  def limit_warnings(text) do
    edges =
      text
      |> String.split("\n")
      |> Enum.count(&String.contains?(&1, ["-->", ".->", "==>"]))

    [
      if(String.length(text) > 50_000,
        do:
          "the chart is #{String.length(text)} characters; Mermaid draws at most 50000 by default"
      ),
      if(edges > 500, do: "the chart has #{edges} arrows; Mermaid draws at most 500 by default")
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Writes an overview (`XrefMermaid.Selection.overview/2`): one node per directory, one labeled arrow per pair.
  """
  def write_overview(overview) do
    ids = unique_ids(Enum.map(overview.dirs, &{&1, "d_" <> clean(&1)}))

    IO.iodata_to_binary([
      "flowchart LR\n",
      Enum.map(overview.dirs, &~s(  #{ids[&1]}["#{escape(&1)}"]\n)),
      Enum.map(overview.edges, fn {source, sink, kind, count} ->
        {open, close} = @file_arrows[kind]
        "  #{ids[source]} #{open} #{kind} ×#{count} #{close} #{ids[sink]}\n"
      end)
    ])
  end

  defp render_dir(dir, indent, context) do
    pad = String.duplicate("  ", indent)

    [
      ~s(#{pad}subgraph #{context.ids[{:dir, dir}]} ["#{escape(Path.basename(dir))}/"]\n),
      Enum.map(
        Enum.sort(Map.get(context.files_in, dir, [])),
        &render_file(&1, pad <> "  ", context)
      ),
      Enum.map(
        Enum.sort(Map.get(context.children, dir, [])),
        &render_dir(&1, indent + 1, context)
      ),
      "#{pad}end\n"
    ]
  end

  defp render_file(file, pad, context) do
    %{ids: ids, selection: selection, opts: opts} = context
    file_id = ids[{:file, file}]
    slice? = file in selection.slice_files
    keys = selection.files[file]
    parts = context.module_parts[file]

    collapsed? =
      cond do
        opts[:expanded] -> false
        Enum.any?(keys, &(&1 in selection.starts)) -> false
        opts[:collapsed] -> true
        # Without a slice, every file is outside it, including the call path asked for.
        opts[:all_functions] -> MapSet.size(selection.slice_files) > 0 and not slice?
        true -> false
      end

    # A file without shown functions stays a plain node: Mermaid can't draw an empty subgraph.
    if keys == [] do
      ~s(#{pad}#{file_id}["#{escape(Path.basename(file))}"]\n)
    else
      [
        ~s(#{pad}subgraph #{file_id} ["#{escape(Path.basename(file))}"]\n),
        Enum.map(keys, fn key ->
          function = context.project.functions[key]
          {label_prefix, _} = parts[function.module]
          label = "#{label_prefix}#{function.name}/#{arities(function)}"
          ~s(#{pad}  #{ids[key]}["#{escape(label)}"]\n)
        end),
        "#{pad}end\n",
        if(collapsed?, do: "#{pad}#{file_id}@{ view: collapsed }\n", else: "")
      ]
    end
  end

  defp render_externals([], _ids), do: ""

  defp render_externals(externals, ids) do
    [
      ~s(  subgraph x_ ["external"]\n),
      Enum.map(externals, fn {module, keys} ->
        [
          ~s(    subgraph #{ids[{:external_module, module}]} ["#{escape(inspect(module))}"]\n),
          for(
            {:external, {_, name, arity}} = key <- keys,
            do: ~s(      #{ids[key]}["#{escape("#{name}/#{arity}")}"]\n)
          ),
          "    end\n"
        ]
      end),
      "  end\n"
    ]
  end

  defp function_ids(file, keys, project, parts, container_ids) do
    for key <- keys do
      function = project.functions[key]
      {_, id_part} = parts[function.module]

      {key,
       "#{container_ids[{:file, file}]}__#{id_part}#{clean_name(function.name)}_#{hd(function.arities)}"}
    end
  end

  # Returns `%{module => {label_prefix, id_part}}` for a file's modules. The main module's functions have no prefix;
  # another module's are labeled with its name after the part it shares with the main module (`Line.`), and a
  # protocol implementation's with the protocol and, unless it is the main module, the type
  # (`[impl String.Chars] `, `[impl Inspect for Line] `).
  defp module_parts(file, project) do
    case Map.get(project.modules_in, file, []) do
      [] ->
        %{}

      [main | _] = modules ->
        Map.new(modules, fn module ->
          parts =
            case project.modules[module].impl do
              {protocol, for} ->
                for_part = if for == main, do: "", else: relative_name(for, main)
                label = "[impl #{inspect(protocol)}#{if for_part != "", do: " for #{for_part}"}] "

                id =
                  "impl_#{clean(inspect(protocol))}#{if for_part != "", do: "_for_#{clean(for_part)}"}__"

                {label, id}

              nil when module == main ->
                {"", ""}

              nil ->
                {relative_name(module, main) <> ".", clean(relative_name(module, main)) <> "__"}
            end

          {module, parts}
        end)
    end
  end

  # `MyApp.Orders.Line` relative to `MyApp.Orders` is `Line`; `MyApp.Order` relative to `MyApp.Orders` is `Order`.
  defp relative_name(module, main) do
    parts = Module.split(module)

    shared =
      parts
      |> Enum.zip(Module.split(main))
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

    parts |> Enum.drop(min(shared, length(parts) - 1)) |> Enum.join(".")
  end

  defp arities(%{arities: [arity]}), do: "#{arity}"
  defp arities(%{arities: arities}), do: "#{List.first(arities)}..#{List.last(arities)}"

  defp class_line(functions, filter, class, ids) do
    case for(function <- functions, filter.(function), do: ids[function.key]) do
      [] -> ""
      matching -> "  class #{Enum.join(matching, ",")} #{class}\n"
    end
  end

  defp link_line(function, ids, project, template) do
    # Every character but `/` and unreserved ones is encoded, so a `#` or `?` in a path is not a fragment or query.
    path =
      URI.encode(Path.join(project.root, function.file), &(URI.char_unreserved?(&1) or &1 == ?/))

    url =
      template
      |> String.replace("{path}", path)
      |> String.replace("{line}", to_string(function.line))

    ~s(  click #{ids[function.key]} href "#{url}"\n)
  end

  defp legend do
    """
      subgraph legend_ ["Legend"]
        legend_public["public function"]
        legend_private["private function"]:::private
        legend_generated["generated function"]:::generated
        legend_start["start function"]:::start
        legend_slice["file of the slice"]:::slice
        legend_caller["caller"] --> legend_called["called"]
        legend_file["file"] -. runtime .-> legend_dependency["file it depends on with no call"]
      end
    """
  end

  # A file's directory as path parts; `[]` for a file at the project root.
  defp dir_parts(file) do
    case Path.dirname(file) do
      "." -> []
      dir -> Path.split(dir)
    end
  end

  defp ancestors(parts), do: Enum.scan(parts, &Path.join(&2, &1))

  # The directory every file shares (e.g. `lib/my_app`), left out of file ids to keep the chart under Mermaid's text
  # size limit.
  defp shared_dir([]), do: []

  defp shared_dir(files) do
    files
    |> Enum.map(&dir_parts/1)
    |> Enum.reduce(fn parts, shared ->
      parts
      |> Enum.zip(shared)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(&elem(&1, 0))
    end)
  end

  defp strip(path, shared) do
    parts = Path.split(path)
    parts |> Enum.drop(min(length(shared), length(parts) - 1)) |> Path.join()
  end

  # Assigns each owner its base id, or the base with `_2`, `_3`... when another owner (here or in `ids`) has it.
  defp unique_ids(pairs, ids \\ %{}) do
    {ids, _taken} =
      Enum.reduce(pairs, {ids, MapSet.new(Map.values(ids))}, fn {owner, base}, {ids, taken} ->
        id =
          if base in taken,
            do:
              Stream.iterate(2, &(&1 + 1))
              |> Stream.map(&"#{base}_#{&1}")
              |> Enum.find(&(&1 not in taken)),
            else: base

        {Map.put(ids, owner, id), MapSet.put(taken, id)}
      end)

    ids
  end

  # Mermaid ids allow letters, digits and `_`; in a path or module name, any other character becomes `_`. (No
  # regex here or in `clean_name/1`: a regex compiled into an archive breaks on another Elixir version.)
  defp clean(term) do
    for <<char <- to_string(term)>>, into: "", do: if(id_char?(char), do: <<char>>, else: "_")
  end

  # In a function name, operator characters get names, so `<~>` becomes `_lt_tilde_gt`, and `valid?/1` and
  # `valid!/1` stay apart as `valid_q` and `valid_b`.
  defp clean_name(name) do
    names = %{
      ?? => "q",
      ?! => "b",
      ?< => "lt",
      ?> => "gt",
      ?~ => "tilde",
      ?| => "pipe",
      ?= => "eq",
      ?& => "amp",
      ?+ => "plus",
      ?- => "minus",
      ?* => "star",
      ?/ => "slash",
      ?^ => "caret",
      ?@ => "at",
      ?\\ => "backslash",
      ?. => "dot",
      ?: => "colon"
    }

    for <<char <- Atom.to_string(name)>>, into: "" do
      cond do
        id_char?(char) -> <<char>>
        Map.has_key?(names, char) -> "_" <> names[char]
        true -> "_"
      end
    end
  end

  defp id_char?(char), do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char == ?_

  # Mermaid reads `#name;` entities and HTML in labels, and `"` would end the label.
  defp escape(text) do
    text
    |> String.replace("#", "#35;")
    |> String.replace("\"", "#quot;")
    |> String.replace("&", "#amp;")
    |> String.replace("<", "#lt;")
    |> String.replace(">", "#gt;")
  end
end
