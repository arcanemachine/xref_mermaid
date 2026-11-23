defmodule XrefMermaid.Selection do
  @moduledoc """
  Picks the part of an `XrefMermaid.Project` to draw.

  A selection starts from seeds, which can be combined:

    * path prefixes: every non-generated function in the files whose paths start with one (the slice files), the
      calls those functions make, and the file dependencies of the slice files that no call explains (a struct, a
      compile-time use);
    * `from:` function keys: the calls they make, followed outward up to `depth` hops;
    * `to:` function keys: the calls made to them, followed backward up to `depth` hops.

  Only the functions at either end of a drawn call, and the start functions, are shown, plus every non-generated
  function of the slice files (or of every shown file, with `all_functions: true`). Generated functions are shown
  only at the end of a call, or as a start function.
  """

  alias XrefMermaid.Project

  @doc """
  Returns `%{files: %{file => [key]}, slice_files: MapSet, calls: [{caller, callee}], file_edges: [{source, sink,
  kind}], starts: MapSet, more_callees: MapSet, more_callers: MapSet, externals: %{module => [key]}, file_calls: [],
  new_file_calls: %{}, start_files: MapSet}`; `file_calls`, `new_file_calls` and `start_files` are filled by
  `by_file/3`. `more_callees` holds the functions a `from:` walk reached that make a call not drawn (the depth cut
  it off), and `more_callers` those a `to:` walk reached that get one.

  Options: `prefixes`, `from`, `to`, `depth` (default 3), `call_paths` (only the calls on a walk from a `from` key
  to a `to` key, at most `depth` calls long, or any length without `depth`; nothing is cut off), `incoming` (also
  the calls into the slice files and the file dependencies on them), `all_functions`, `external` (also calls to
  Elixir modules outside the project, as leaves), `external_only` (with `external`, only those to the modules named,
  as text, matched by `XrefMermaid.Project.module_in?/2`).
  """
  def select(project, opts) do
    prefixes = Keyword.get(opts, :prefixes, [])
    starts = Keyword.get(opts, :from, []) ++ Keyword.get(opts, :to, [])
    incoming? = opts[:incoming] == true

    ## Seeds

    slice_files =
      for file <- Map.keys(project.file_edges),
          Enum.any?(prefixes, &String.starts_with?(file, &1)),
          into: MapSet.new(),
          do: file

    slice_functions =
      for {key, function} <- project.functions,
          function.file in slice_files and not function.generated?,
          do: key

    ## Calls

    external_only = Keyword.get(opts, :external_only, [])

    # Erlang modules, `Kernel`, `String.Chars` and `exception/1` are left out of external calls: most are what
    # `Kernel`'s functions, string interpolation and `raise` compile to.
    keep? = fn
      {:external, {module, name, arity}} ->
        opts[:external] == true and String.starts_with?(Atom.to_string(module), "Elixir.") and
          module not in [Kernel, String.Chars] and {name, arity} != {:exception, 1} and
          (external_only == [] or
             Enum.any?(external_only, &Project.module_in?(inspect(module), &1)))

      _ ->
        true
    end

    from = Keyword.get(opts, :from, [])
    to = Keyword.get(opts, :to, [])
    call_paths? = opts[:call_paths] == true

    {from_calls, to_calls} =
      if call_paths? do
        {call_paths(project, from, to, opts[:depth]), []}
      else
        depth = Keyword.get(opts, :depth, 3)

        {walk(project.forward, from, depth, keep?, :forward),
         walk(project.backward, to, depth, keep?, :backward)}
      end

    # The slice's own calls (and, with `incoming`, the calls into the slice) are one step from its functions.
    calls =
      (walk(project.forward, slice_functions, 1, keep?, :forward) ++
         if(incoming?, do: walk(project.backward, slice_functions, 1, keep?, :backward), else: []) ++
         from_calls ++ to_calls)
      |> Enum.uniq()
      |> Enum.sort()

    # The functions a walk reached that make (or get) a call the chart doesn't draw: those the depth cut off.
    drawn = MapSet.new(calls)

    # Off a call path, a call not drawn isn't cut off by the depth.
    more_callees =
      for key <- MapSet.new(from ++ Enum.map(from_calls, &elem(&1, 1))),
          not call_paths?,
          not match?({:external, _}, key),
          Enum.any?(Map.get(project.forward, key, []), &(keep?.(&1) and {key, &1} not in drawn)),
          into: MapSet.new(),
          do: key

    more_callers =
      for key <- MapSet.new(to ++ Enum.map(to_calls, &elem(&1, 0))),
          not call_paths?,
          Enum.any?(Map.get(project.backward, key, []), &({&1, key} not in drawn)),
          into: MapSet.new(),
          do: key

    ## File dependencies that no drawn call explains

    file_of = fn key -> project.functions[key].file end

    called_files =
      for {caller, callee} <- calls,
          not match?({:external, _}, callee),
          into: MapSet.new(),
          do: {file_of.(caller), file_of.(callee)}

    file_edges =
      for {source, sinks} <- project.file_edges,
          {sink, kind} <- sinks,
          source != sink,
          source in slice_files or (incoming? and sink in slice_files),
          {source, sink} not in called_files,
          do: {source, sink, kind}

    ## Shown functions

    # The start functions are shown even when they make or get no drawn call.
    endpoints =
      calls |> Enum.flat_map(&Tuple.to_list/1) |> MapSet.new() |> MapSet.union(MapSet.new(starts))

    project_endpoints = Enum.reject(endpoints, &match?({:external, _}, &1))

    shown_files =
      Enum.uniq(
        Enum.to_list(slice_files) ++
          Enum.map(project_endpoints, file_of) ++
          Enum.flat_map(file_edges, fn {source, sink, _} -> [source, sink] end)
      )

    files =
      shown_functions(project, shown_files, endpoints, slice_files, opts[:all_functions] == true)

    externals =
      for {:external, {module, _, _}} = key <- endpoints, reduce: %{} do
        acc -> Map.update(acc, module, [key], &Enum.sort([key | &1]))
      end

    %{
      files: files,
      slice_files: slice_files,
      calls: calls,
      file_edges: Enum.sort(file_edges),
      starts: MapSet.new(starts),
      more_callees: more_callees,
      more_callers: more_callers,
      externals: externals,
      file_calls: [],
      new_file_calls: %{},
      start_files: MapSet.new()
    }
  end

  # A shown file lists the functions at the end of a drawn call or the start functions, and its other non-generated
  # functions when the file is a slice file or `all_functions?` is set; in file order.
  defp shown_functions(project, shown_files, endpoints, slice_files, all_functions?) do
    functions_in = project.functions |> Map.values() |> Enum.group_by(& &1.file)

    for file <- shown_files, into: %{} do
      keys =
        for function <- Map.get(functions_in, file, []),
            function.key in endpoints or
              (not function.generated? and (file in slice_files or all_functions?)),
            do: function.key

      {file, Enum.sort_by(keys, &{project.functions[&1].line, &1})}
    end
  end

  # The calls on a walk from a `from` key to a `to` key, at most `depth` calls long (any length when `nil`): a call
  # `{a, b}` is on one when the distance from the `from` keys to `a`, plus one, plus the distance from `b` to the `to`
  # keys is within `depth`.
  defp call_paths(project, from, to, depth) do
    from_distance = distances(project.forward, from)
    to_distance = distances(project.backward, to)

    for {caller, caller_distance} <- from_distance,
        callee <- Map.get(project.forward, caller, []),
        callee_distance = to_distance[callee],
        callee_distance != nil,
        depth == nil or caller_distance + 1 + callee_distance <= depth,
        do: {caller, callee}
  end

  # The fewest steps over `edges` from any of `seeds` to each key reached.
  defp distances(edges, seeds) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while({Map.new(seeds, &{&1, 0}), seeds}, fn distance, {reached, frontier} ->
      next =
        for(
          from <- frontier,
          to <- Map.get(edges, from, []),
          not Map.has_key?(reached, to),
          do: to
        )
        |> Enum.uniq()

      if next == [],
        do: {:halt, reached},
        else: {:cont, {Map.merge(reached, Map.new(next, &{&1, distance})), next}}
    end)
  end

  # Breadth-first from `seeds`, `depth` steps, over `edges`: a map from a key to its callees (`:forward`) or callers
  # (`:backward`). Returns the calls taken as `{caller, callee}`, including those into keys already reached.
  defp walk(edges, seeds, depth, keep?, direction) do
    {taken, _seen, _frontier} =
      Enum.reduce(1..depth//1, {[], MapSet.new(seeds), seeds}, fn _, {taken, seen, frontier} ->
        step = for from <- frontier, to <- Map.get(edges, from, []), keep?.(to), do: {from, to}
        next = step |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 in seen)) |> Enum.uniq()
        {taken ++ step, MapSet.union(seen, MapSet.new(next)), next}
      end)

    if direction == :forward,
      do: taken,
      else: Enum.map(taken, fn {callee, caller} -> {caller, callee} end)
  end

  @doc """
  Turns a selection (from `select/2`) into one between files, for a chart of one node per file: its calls become
  `file_calls`, `[{source, sink, count}]`, where `source` and `sink` are `{:file, file}` or `{:external_module,
  module}` and `count` is the number of distinct function-to-function calls between them; calls within a file drop
  out. Its files and external modules list no functions, `more_callees` and `more_callers` are empty, and
  `start_files` holds the files of the start functions.
  `new_file_calls` counts, per `{source, sink}`, those of its calls in `new_calls` (`XrefMermaid.Changes`).
  """
  def by_file(project, selection, new_calls \\ MapSet.new()) do
    end_of = fn
      {:external, {module, _, _}} -> {:external_module, module}
      key -> {:file, project.functions[key].file}
    end

    pairs =
      selection.calls
      |> Enum.map(fn {caller, callee} = call -> {{end_of.(caller), end_of.(callee)}, call} end)
      |> Enum.reject(fn {{source, sink}, _} -> source == sink end)

    file_calls =
      pairs
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.map(fn {{source, sink}, count} -> {source, sink, count} end)
      |> Enum.sort()

    new_file_calls =
      for({pair, call} <- pairs, call in new_calls, do: pair) |> Enum.frequencies()

    %{
      selection
      | files: Map.new(selection.files, fn {file, _} -> {file, []} end),
        externals: Map.new(selection.externals, fn {module, _} -> {module, []} end),
        calls: [],
        more_callees: MapSet.new(),
        more_callers: MapSet.new(),
        file_calls: file_calls,
        new_file_calls: new_file_calls,
        start_files: MapSet.new(selection.starts, &project.functions[&1].file)
    }
  end

  @doc """
  Groups the project's files into directories `level` deep (counted from the project root, so `lib/my_app/` is 2)
  and returns `%{dirs: [dir], edges: [{source_dir, sink_dir, kind, count}]}`: one edge per pair of directories,
  with the strongest kind among its file dependencies (compile, then export, then runtime) and their count. A file
  goes with the directory named after it when there is one (`lib/my_app/orders.ex` with `lib/my_app/orders/`).
  """
  def overview(project, level) do
    # Files in a directory shallower than `level` form their own group, `dir/*`, apart from its subdirectories;
    # files at the root are `./*`.
    group_of = fn file ->
      parts = if Path.dirname(file) == ".", do: [], else: file |> Path.dirname() |> Path.split()
      name = if parts == [], do: ".", else: parts |> Enum.take(level) |> Path.join()
      name <> if(length(parts) < level, do: "/*", else: "/")
    end

    dirs =
      for file <- Map.keys(project.file_edges),
          dir <- file |> Path.dirname() |> ancestors(),
          into: MapSet.new(),
          do: dir

    # A file goes with the directory named after it (`orders.ex` with `orders/`): a module and its children.
    dir_of = fn file ->
      named_dir = Path.rootname(file)
      if named_dir in dirs, do: group_of.(Path.join(named_dir, "_")), else: group_of.(file)
    end

    rank = %{"compile" => 3, "export" => 2, "runtime" => 1}

    edges =
      for {source, sinks} <- project.file_edges,
          {sink, kind} <- sinks,
          dir_of.(source) != dir_of.(sink) do
        {{dir_of.(source), dir_of.(sink)}, kind}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {{source, sink}, kinds} ->
        {source, sink, Enum.max_by(kinds, &rank[&1]), length(kinds)}
      end)
      |> Enum.sort()

    %{
      dirs: project.file_edges |> Map.keys() |> Enum.map(dir_of) |> Enum.uniq() |> Enum.sort(),
      edges: edges
    }
  end

  # `lib/a/b` -> ["lib/a/b", "lib/a", "lib"]
  defp ancestors("."), do: []
  defp ancestors(dir), do: [dir | ancestors(Path.dirname(dir))]
end
