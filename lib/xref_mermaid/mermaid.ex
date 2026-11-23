defmodule XrefMermaid.Mermaid do
  @moduledoc """
  Writes a selection (`XrefMermaid.Selection`) or an overview as a Mermaid flowchart.

  Every id is prefixed (`d_` directory, `f_` file and its functions, `x_` external), which keeps ids clear of
  Mermaid's keywords (`end`, `graph`...), and is unique: a clash between two names that read the same once cleaned
  (`lib/a/b.ex` and `lib/a_b.ex`) gets a `_2`, `_3`... suffix.
  """

  alias XrefMermaid.{Changes, Project}

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
    * `:link` - a URL template for a `click` link on each function: `{path}` (absolute), `{relpath}` (relative to
      the project root), both URL-encoded, and `{line}`
    * `:legend` - adds a legend subgraph
    * `:details` - adds each function's first `@spec` and the start of its `@doc` to its label
    * `:call_order` - numbers each function's calls in the order its code makes them
    * `:direction` - the chart's direction (default `"LR"`)
    * `:modules` - the selection is one between files (`XrefMermaid.Selection.by_file/3`): each file is a node
      labeled with its main module, and its calls to another file are one arrow labeled with their count

  A file holding a start function (`from`/`to`) is never collapsed.

  Two kinds of call arrow are marked: a call on a cycle of calls between files, over the whole project (red), and a
  call to a parent module, by each file's main module (`MyApp.Orders.Line` to `MyApp.Orders` or `MyApp`; thick).
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

    marks = marks(project, selection, opts)

    context = %{
      ids: ids,
      project: project,
      selection: selection,
      opts: opts,
      marks: marks,
      module_parts: module_parts,
      children: Enum.group_by(dirs, &Path.dirname/1),
      files_in: Enum.group_by(files, &Path.dirname/1)
    }

    roots = dirs |> Enum.reject(&(Path.dirname(&1) in dirs)) |> Enum.sort()
    shown_keys = selection.files |> Map.values() |> List.flatten()
    functions = Enum.map(shown_keys, &project.functions[&1])

    # The order of a function's first call to each callee, among the calls drawn.
    call_numbers =
      if opts[:call_order] do
        for {caller, calls} <- Enum.group_by(selection.calls, &elem(&1, 0)),
            order = project.forward |> Map.get(caller, []) |> Enum.with_index() |> Map.new(),
            {call, number} <- calls |> Enum.sort_by(&order[elem(&1, 1)]) |> Enum.with_index(1),
            into: %{},
            do: {call, number}
      else
        %{}
      end

    changes = opts[:changes]
    colors? = changes != nil and opts[:marks] in [nil, "colors", "both"]
    labels? = changes != nil and opts[:marks] in ["labels", "both"]
    groups = Project.cycle_groups(project)
    new? = &(changes != nil and &1 in changes.new_calls)

    # A new call is green; with labels, or on a cycle (red), it gets a `+`.
    call_label = fn call, number ->
      plus = new?.(call) and (labels? or cycle_call?(project, groups, call))

      case {plus, number} do
        {false, nil} -> nil
        {false, number} -> "#{number}"
        {true, nil} -> "+"
        {true, number} -> "+ #{number}"
      end
    end

    removed = changes && changes.removed

    IO.iodata_to_binary([
      "flowchart #{Keyword.get(opts, :direction, "LR")}\n",
      if(removed, do: "  %% #{Changes.removed_count(removed)}\n", else: ""),
      Enum.map(cut_texts(selection, opts), &"  %% #{&1}\n"),
      # Files at the project root sit at the top level, outside any directory.
      Enum.map(Enum.sort(Map.get(context.files_in, ".", [])), &render_file(&1, "  ", context)),
      Enum.map(roots, &render_dir(&1, 1, context)),
      render_externals(externals, ids),
      Enum.map(selection.calls, fn {caller, callee} = call ->
        case call_label.(call, call_numbers[call]) do
          nil -> "  #{ids[caller]} --> #{ids[callee]}\n"
          label -> "  #{ids[caller]} -->|#{label}| #{ids[callee]}\n"
        end
      end),
      Enum.map(selection.file_calls, fn {source, sink, count} ->
        label =
          case Map.get(selection.new_file_calls, {source, sink}, 0) do
            0 -> "#{count}"
            # Quoted: Mermaid reads a bare `(` in a label as a node shape.
            new -> "\"#{count} (+#{new})\""
          end

        "  #{ids[source]} -->|#{label}| #{ids[sink]}\n"
      end),
      Enum.map(selection.file_edges, fn {source, sink, kind} ->
        {open, close} = @file_arrows[kind]
        "  #{ids[{:file, source}]} #{open} #{kind} #{close} #{ids[{:file, sink}]}\n"
      end),
      cond do
        !opts[:legend] ->
          ""

        opts[:modules] ->
          module_legend(change_legend(opts, colors?, labels?, removed))

        true ->
          legend([cut_legend(selection, opts), change_legend(opts, colors?, labels?, removed)])
      end,
      # A node has one fill: a file's added or changed mark replaces the slice's.
      case Enum.filter(
             files,
             &(&1 in selection.slice_files and not (colors? and Map.has_key?(marks, {:file, &1})))
           ) do
        [] -> ""
        slice_files -> "  class #{Enum.map_join(slice_files, ",", &ids[{:file, &1}])} slice\n"
      end,
      "  classDef slice fill:#ffe9a8,stroke:#b8860b\n",
      if(colors?, do: mark_classes(marks, ids), else: ""),
      class_line(functions, &(&1.kind in [:defp, :defmacrop]), "private", ids),
      class_line(functions, & &1.generated?, "generated", ids),
      class_line(functions, &(&1.key in selection.starts), "start", ids),
      case Enum.filter(files, &(&1 in selection.start_files)) do
        [] -> ""
        start_files -> "  class #{Enum.map_join(start_files, ",", &ids[{:file, &1}])} start\n"
      end,
      "  classDef private stroke-dasharray:4 3\n",
      "  classDef generated fill:#eeeeee,stroke:#999999,color:#555555\n",
      "  classDef start stroke:#cc3333,stroke-width:3px\n",
      if(opts[:link],
        do: Enum.map(functions, &link_line(&1, ids, project, opts[:link])),
        else: ""
      ),
      mark_lines(project, selection, opts, groups, new?, colors?)
    ])
  end

  @added_fill "#c7e9c0"
  @changed_fill "#c6dbef"
  @new_style "stroke:#2ca02c"

  # `%{{:file, file} | key => :added | :changed}` for the shown files and functions with a mark. A function in an
  # added file, or a generated one, has none: the file's mark says it all, and the change didn't write a generated
  # one. With `:modules`, a file that isn't added but holds an added or changed function is changed.
  defp marks(project, selection, opts) do
    case opts[:changes] do
      nil ->
        %{}

      changes ->
        file_marks =
          for file <- Map.keys(selection.files),
              mark = file_mark(project, file, changes, opts[:modules]),
              into: %{},
              do: {{:file, file}, mark}

        function_marks =
          for {file, keys} <- selection.files,
              file not in changes.added_files,
              key <- keys,
              not project.functions[key].generated?,
              mark = function_mark(key, changes),
              into: %{},
              do: {key, mark}

        Map.merge(file_marks, function_marks)
    end
  end

  defp file_mark(project, file, changes, modules?) do
    cond do
      file in changes.added_files ->
        :added

      modules? &&
          Enum.any?(
            project.functions,
            fn {key, function} ->
              function.file == file and not function.generated? and
                  function_mark(key, changes) != nil
            end
          ) ->
        :changed

      true ->
        nil
    end
  end

  defp function_mark(key, changes) do
    cond do
      key in changes.added -> :added
      key in changes.changed -> :changed
      true -> nil
    end
  end

  defp mark_classes(marks, ids) do
    for mark <- [:added, :changed] do
      case for({owner, ^mark} <- marks, do: ids[owner]) |> Enum.sort() do
        [] -> ""
        matching -> "  class #{Enum.join(matching, ",")} #{mark}\n"
      end
    end ++
      ["  classDef added fill:#{@added_fill}\n", "  classDef changed fill:#{@changed_fill}\n"]
  end

  defp mark_label(context, owner) do
    if context.opts[:changes] && context.opts[:marks] in ["labels", "both"] do
      case context.marks[owner] do
        :added -> "+ "
        :changed -> "~ "
        nil -> ""
      end
    else
      ""
    end
  end

  defp cycle_call?(_project, _groups, {_, {:external, _}}), do: false

  defp cycle_call?(project, groups, {caller, callee}) do
    source = project.functions[caller].file
    sink = project.functions[callee].file
    source != sink and groups[source] != nil and groups[source] == groups[sink]
  end

  @cycle_style "stroke:#d62728"
  @parent_style "stroke-width:4px"

  # `linkStyle` lines for the marked call arrows, which Mermaid finds by their place among all the arrows: the calls
  # come first, then the file dependencies, then the legend's. Mermaid keeps only the last `linkStyle` naming an
  # arrow, so an arrow with both marks gets one line with both styles.
  defp mark_lines(project, selection, opts, groups, new?, colors?) do
    file_of = fn key -> project.functions[key].file end

    # Each arrow's files (`nil` for an external end) and whether it carries a new call.
    ends =
      Enum.map(selection.calls, fn
        {_, {:external, _}} = call -> {nil, new?.(call)}
        {caller, callee} = call -> {{file_of.(caller), file_of.(callee)}, new?.(call)}
      end) ++
        Enum.map(selection.file_calls, fn
          {{:file, source}, {:file, sink} = to, _} ->
            {{source, sink}, Map.get(selection.new_file_calls, {{:file, source}, to}, 0) > 0}

          {source, sink, _} ->
            {nil, Map.get(selection.new_file_calls, {source, sink}, 0) > 0}
        end)

    styles =
      for {{files, new}, index} <- Enum.with_index(ends),
          style = style(project, groups, files, colors? and new),
          style != "",
          do: {index, style}

    # The legend's arrows after the first two show the marks.
    styles =
      if opts[:legend] do
        legend_start = length(ends) + length(selection.file_edges)

        styles ++
          [{legend_start + 2, @parent_style}, {legend_start + 3, @cycle_style}] ++
          if(colors?, do: [{legend_start + 4, @new_style}], else: [])
      else
        styles
      end

    styles
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.sort()
    |> Enum.map(fn {style, indexes} -> "  linkStyle #{Enum.join(indexes, ",")} #{style}\n" end)
  end

  # The style of a call arrow between files (`nil` with an external end), or "" when it isn't marked. A new call on
  # a cycle stays red; its label says it is new.
  defp style(_project, _groups, nil, new?), do: if(new?, do: @new_style, else: "")

  defp style(project, groups, {source, sink}, new?) do
    cycle? = source != sink and groups[source] != nil and groups[source] == groups[sink]
    parent? = parent?(main_module(project, sink), main_module(project, source))

    [
      cond do
        cycle? -> @cycle_style
        new? -> @new_style
        true -> nil
      end,
      if(parent?, do: @parent_style)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(",")
  end

  defp main_module(project, file), do: project.modules_in |> Map.get(file, []) |> List.first()

  # `MyApp.Orders` is a parent of `MyApp.Orders.Line`, and so is `MyApp`.
  defp parent?(parent, child)
       when is_atom(parent) and is_atom(child) and not is_nil(parent) and not is_nil(child) do
    parent_parts = Module.split(parent)
    child_parts = Module.split(child)
    length(parent_parts) < length(child_parts) and List.starts_with?(child_parts, parent_parts)
  end

  defp parent?(_, _), do: false

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
  Takes the `:direction` option of `write/3`.
  """
  def write_overview(overview, opts \\ []) do
    ids = unique_ids(Enum.map(overview.dirs, &{&1, "d_" <> clean(&1)}))

    IO.iodata_to_binary([
      "flowchart #{Keyword.get(opts, :direction, "LR")}\n",
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
      label =
        case {opts[:modules], context.project.modules_in[file]} do
          {true, [main | _]} -> inspect(main)
          _ -> Path.basename(file)
        end

      ~s(#{pad}#{file_id}["#{escape(mark_label(context, {:file, file}) <> label)}"]\n)
    else
      [
        ~s(#{pad}subgraph #{file_id} ["#{escape(mark_label(context, {:file, file}) <> Path.basename(file))}"]\n),
        Enum.map(keys, fn key ->
          function = context.project.functions[key]
          {label_prefix, _} = parts[function.module]

          label =
            "#{if key in selection.more_callers, do: "… "}#{mark_label(context, key)}" <>
              "#{label_prefix}#{function.name}/#{arities(function)}" <>
              "#{if key in selection.more_callees, do: " …"}"

          ~s(#{pad}  #{ids[key]}["#{details(label, function, opts)}"]\n)
        end),
        "#{pad}end\n",
        if(collapsed?, do: "#{pad}#{file_id}@{ view: collapsed }\n", else: "")
      ]
    end
  end

  # With `:details`, the label gains the function's first spec and its doc's first paragraph, each on a line of its
  # own and cut short.
  defp details(label, function, opts) do
    lines =
      if opts[:details] do
        spec =
          case function.specs do
            [] -> nil
            [spec] -> cut(spec)
            [spec | more] -> cut(spec) <> " (+#{length(more)})"
          end

        doc =
          function.doc && function.doc |> String.trim() |> String.split("\n\n") |> hd() |> cut()

        [label, spec, doc]
      else
        [label]
      end

    lines |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map_join("<br>", &escape/1)
  end

  # The text goes on one line, at most 80 characters.
  defp cut(text) do
    text = text |> String.split() |> Enum.join(" ")
    if String.length(text) > 80, do: String.slice(text, 0, 79) <> "…", else: text
  end

  defp render_externals([], _ids), do: ""

  defp render_externals(externals, ids) do
    [
      ~s(  subgraph x_ ["external"]\n),
      Enum.map(externals, fn
        {module, []} ->
          ~s(    #{ids[{:external_module, module}]}["#{escape(inspect(module))}"]\n)

        {module, keys} ->
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
    encode = &URI.encode(&1, fn char -> URI.char_unreserved?(char) or char == ?/ end)

    url =
      template
      |> String.replace("{path}", encode.(Path.join(project.root, function.file)))
      |> String.replace("{relpath}", encode.(function.file))
      |> String.replace("{line}", to_string(function.line))

    ~s(  click #{ids[function.key]} href "#{url}"\n)
  end

  # What the marks of the functions the depth cut off mean, for the functions that have them: `… ` before a name, or
  # ` …` after it.
  defp cut_texts(selection, opts) do
    depth = Keyword.get(opts, :depth, 3)

    [
      if(MapSet.size(selection.more_callees) > 0,
        do: "name …: it makes calls past --depth #{depth}, not drawn"
      ),
      if(MapSet.size(selection.more_callers) > 0,
        do: "… name: it gets calls past --depth #{depth}, not drawn"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp cut_legend(selection, opts) do
    selection
    |> cut_texts(opts)
    |> Enum.with_index(1)
    |> Enum.map(fn {text, index} -> ~s(    legend_cut_#{index}["#{escape(text)}"]\n) end)
  end

  # The legend reads left to right in every chart direction: in a top-to-bottom chart it sits beside the chart, and
  # left to right it stays a narrow column. Its nodes link only to each other, so Mermaid keeps its direction.
  defp legend(extra) do
    [
      """
        subgraph legend_ ["Legend"]
          direction LR
          legend_public["public function"]
          legend_private["private function"]:::private
          legend_generated["generated function"]:::generated
          legend_start["start function"]:::start
          legend_slice["file of the slice"]:::slice
          legend_caller["caller"] --> legend_called["called"]
          legend_file["file"] -. runtime .-> legend_dependency["file it depends on with no call"]
          legend_child["caller"] --> legend_parent["its parent module"]
          legend_cycle["caller"] --> legend_cycle_called["called, on a cycle of calls between files"]
      """,
      extra,
      "  end\n"
    ]
  end

  # The legend's lines for the marks of `:changes`, after its other lines; its arrow comes after theirs.
  defp change_legend(opts, colors?, labels?, removed) do
    if opts[:changes] do
      {plus, tilde} = if labels?, do: {"+ ", "~ "}, else: {"", ""}
      {added, changed} = if colors?, do: {":::added", ":::changed"}, else: {"", ""}

      {added_text, changed_text, arrow} =
        if opts[:modules],
          do:
            {"added file", "file with added or changed functions",
             ~s{legend_new_caller["calling file"] -->|"3 (+1)"| legend_new_called["3 calls, 1 of them new"]}},
          else:
            {"added function, or file", "changed function",
             ~s(legend_new_caller["caller"] #{if labels?, do: "-->|+|", else: "-->"} legend_new_called["called, a new call"])}

      [
        ~s(    legend_added["#{plus}#{added_text}"]#{added}\n),
        ~s(    legend_changed["#{tilde}#{changed_text}"]#{changed}\n),
        "    #{arrow}\n",
        if(removed, do: ~s(    legend_removed["#{Changes.removed_count(removed)}"]\n), else: "")
      ]
    else
      ""
    end
  end

  defp module_legend(extra) do
    [
      """
        subgraph legend_ ["Legend"]
          direction LR
          legend_module["file, by its main module"]
          legend_start["file of a start function"]:::start
          legend_slice["file of the slice"]:::slice
          legend_caller["calling file"] -->|3| legend_called["called file: 3 distinct function calls"]
          legend_file["file"] -. runtime .-> legend_dependency["file it depends on with no call"]
          legend_child["calling file"] --> legend_parent["its parent module"]
          legend_cycle["calling file"] --> legend_cycle_called["called file, on a cycle of calls between files"]
      """,
      extra,
      "  end\n"
    ]
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
