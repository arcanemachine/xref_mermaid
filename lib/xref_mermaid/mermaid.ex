defmodule XrefMermaid.Mermaid do
  @moduledoc """
  Writes a selection (`XrefMermaid.Selection`) or an overview as a Mermaid flowchart.

  Every id is prefixed (`d_` directory, `f_` file and its functions, `x_` external), which keeps ids clear of
  Mermaid's keywords (`end`, `graph`...), and is unique: a clash between two names that read the same once cleaned
  (`lib/a/b.ex` and `lib/a_b.ex`) gets a `_2` suffix.
  """

  @file_arrows %{"compile" => "==", "export" => "-.", "runtime" => "-."}
  @arrow_ends %{"compile" => "==>", "export" => ".->", "runtime" => ".->"}

  @doc """
  Options:

    * `:expanded` - opens every file
    * `:collapsed` - collapses every file
    * `:all_functions` - collapses the files outside the slice unless `:expanded` (their full function lists are
      long); otherwise every file is open
    * `:link` - a URL template for a `click` link on each function: `{path}` (absolute, URL-encoded) and `{line}`
    * `:legend` - adds a legend subgraph
  """
  def write(project, selection, opts \\ []) do
    files = selection.files |> Map.keys() |> Enum.sort()
    dirs = files |> Enum.map(&Path.dirname/1) |> Enum.flat_map(&ancestors/1) |> Enum.uniq()
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

    ids =
      unique_ids(
        Enum.flat_map(files, &function_ids(&1, selection.files[&1], project, container_ids)) ++
          for {module, keys} <- externals, {:external, {_, name, arity}} = key <- keys do
            {key, "#{container_ids[{:external_module, module}]}__#{clean(name)}_#{arity}"}
          end,
        container_ids
      )

    context = %{
      ids: ids,
      project: project,
      selection: selection,
      opts: opts,
      children: Enum.group_by(dirs, &Path.dirname/1),
      files_in: Enum.group_by(files, &Path.dirname/1)
    }

    roots = dirs |> Enum.reject(&(Path.dirname(&1) in dirs)) |> Enum.sort()
    shown_keys = selection.files |> Map.values() |> List.flatten()
    functions = Enum.map(shown_keys, &project.functions[&1])

    IO.iodata_to_binary([
      "flowchart LR\n",
      Enum.map(roots, &render_dir(&1, 1, context)),
      render_externals(externals, ids),
      Enum.map(selection.calls, fn {caller, callee} -> "  #{ids[caller]} --> #{ids[callee]}\n" end),
      Enum.map(selection.file_edges, fn {source, sink, kind} ->
        "  #{ids[{:file, source}]} #{@file_arrows[kind]} #{kind} #{@arrow_ends[kind]} #{ids[{:file, sink}]}\n"
      end),
      if(opts[:legend], do: legend(), else: ""),
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
  Writes an overview (`XrefMermaid.Selection.overview/2`): one node per directory, one labeled arrow per pair.
  """
  def write_overview(overview) do
    ids = unique_ids(Enum.map(overview.dirs, &{&1, "d_" <> clean(&1)}))

    IO.iodata_to_binary([
      "flowchart LR\n",
      Enum.map(overview.dirs, &~s(  #{ids[&1]}["#{escape(&1)}"]\n)),
      Enum.map(overview.edges, fn {source, sink, kind, count} ->
        "  #{ids[source]} #{@file_arrows[kind]} #{kind} ×#{count} #{@arrow_ends[kind]} #{ids[sink]}\n"
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
    prefixes = module_prefixes(file, context.project)

    collapsed? =
      cond do
        opts[:expanded] -> false
        opts[:collapsed] -> true
        opts[:all_functions] -> not slice?
        true -> false
      end

    # A file without shown functions stays a plain node: Mermaid can't draw an empty subgraph.
    if keys == [] do
      ~s(#{pad}#{file_id}["#{escape(Path.basename(file))}"]#{if slice?, do: ":::slice"}\n)
    else
      [
        ~s(#{pad}subgraph #{file_id} ["#{escape(Path.basename(file))}"]\n),
        Enum.map(keys, fn key ->
          function = context.project.functions[key]
          label = "#{prefixes[function.module]}#{function.name}/#{arities(function)}"
          ~s(#{pad}  #{ids[key]}["#{escape(label)}"]\n)
        end),
        "#{pad}end\n",
        if(collapsed?, do: "#{pad}#{file_id}@{ view: collapsed }\n", else: ""),
        if(slice?, do: "#{pad}style #{file_id} fill:#ffe9a8,stroke:#b8860b\n", else: "")
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

  defp function_ids(file, keys, project, container_ids) do
    prefixes = module_prefixes(file, project)

    for key <- keys do
      function = project.functions[key]

      # `[impl String.Chars] ` becomes `impl_String_Chars__`, `Line.` becomes `Line__`.
      module_part =
        case prefixes[function.module] do
          "" ->
            ""

          prefix ->
            (prefix
             |> String.replace(["[", "]"], "")
             |> String.trim()
             |> String.trim_trailing(".")
             |> clean()) <> "__"
        end

      {key,
       "#{container_ids[{:file, file}]}__#{module_part}#{clean(function.name)}_#{hd(function.arities)}"}
    end
  end

  # In a file with several modules, functions outside the file's main module (the one with the shortest name) are
  # labeled with their module relative to it, or as the protocol implementation they are.
  defp module_prefixes(file, project) do
    modules = for {name, module} <- project.modules, module.file == file, do: {name, module}

    case Enum.min_by(modules, fn {name, _} -> String.length(inspect(name)) end, fn -> nil end) do
      {main, _} when length(modules) > 1 ->
        main_name = inspect(main)

        Map.new(modules, fn {name, module} ->
          name_string = inspect(name)

          prefix =
            cond do
              name == main ->
                ""

              module.impl? ->
                "[impl #{String.replace_suffix(name_string, "." <> main_name, "")}] "

              String.starts_with?(name_string, main_name <> ".") ->
                String.replace_prefix(name_string, main_name <> ".", "") <> "."

              true ->
                name_string <> "."
            end

          {name, prefix}
        end)

      _ ->
        Map.new(modules, fn {name, _} -> {name, ""} end)
    end
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
    url =
      template
      |> String.replace("{path}", URI.encode(Path.join(project.root, function.file)))
      |> String.replace("{line}", to_string(function.line))

    ~s(  click #{ids[function.key]} href "#{String.replace(url, "\"", "%22")}"\n)
  end

  defp legend do
    """
      subgraph legend_ ["Legend"]
        legend_public["public function"]
        legend_private["private function"]:::private
        legend_generated["generated function"]:::generated
        legend_start["start function"]:::start
        legend_caller["caller"] --> legend_called["called"]
        legend_file["file"] -. runtime .-> legend_dependency["file it depends on with no call"]
      end
    """
  end

  defp ancestors(dir), do: dir |> Path.split() |> Enum.scan(&Path.join(&2, &1))

  # The directory every file shares (e.g. `lib/my_app`), left out of ids to keep the chart under Mermaid's text
  # size limit.
  defp shared_dir([]), do: []

  defp shared_dir(files) do
    files
    |> Enum.map(&(&1 |> Path.dirname() |> Path.split()))
    |> Enum.reduce(fn parts, shared ->
      parts
      |> Enum.zip(shared)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(&elem(&1, 0))
    end)
  end

  defp strip(path, shared) do
    case Path.split(path) |> Enum.drop(length(shared)) do
      [] -> "root"
      parts -> Path.join(parts)
    end
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

  # Mermaid ids allow letters, digits and `_`; `?` and `!` keep their own spellings so `valid?/1` and `valid!/1`
  # stay apart.
  defp clean(term) do
    term
    |> to_string()
    |> String.replace("?", "_q")
    |> String.replace("!", "_b")
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
  end

  # Mermaid reads `#name;` entities in labels, and `"` would end the label.
  defp escape(text) do
    text
    |> String.replace("#", "#35;")
    |> String.replace("\"", "#quot;")
    |> String.replace("&", "#amp;")
    |> String.replace("<", "#lt;")
    |> String.replace(">", "#gt;")
  end
end
