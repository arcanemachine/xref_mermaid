defmodule XrefMermaid.Selection do
  @moduledoc """
  Picks the part of a `XrefMermaid.Project` to draw.

  A selection starts from seeds, which can be combined:

    * path prefixes: every function in the files under them (the slice files), the calls those functions make, and
      the file dependencies of the slice files that no call explains (a struct, a compile-time use);
    * `from:` function keys: the calls they make, followed outward up to `depth` hops;
    * `to:` function keys: the calls made to them, followed backward up to `depth` hops.

  Only the functions at either end of a drawn call are shown, plus every function of the slice files (or of every
  shown file, with `all_functions: true`). Generated functions are shown only at the end of a call.
  """

  @doc """
  Returns `%{files: %{file => [key]}, slice_files: MapSet, calls: [{caller, callee}], file_edges: [{source, sink,
  kind}], starts: MapSet, externals: %{module => [key]}}`.

  Options: `prefixes`, `from`, `to`, `depth` (default 3), `incoming` (also the calls into the slice files and the
  file dependencies on them), `all_functions`, `external` (also calls to Elixir modules outside the project, as
  leaves).
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

    # Erlang modules, `Kernel` and `String.Chars` are left out of external calls: most are what Kernel's functions
    # and string interpolation compile to.
    keep? = fn
      {:external, {module, _, _}} ->
        opts[:external] == true and String.starts_with?(Atom.to_string(module), "Elixir.") and
          module not in [Kernel, String.Chars]

      _ ->
        true
    end

    depth = Keyword.get(opts, :depth, 3)

    # The slice's own calls (and, with `incoming`, the calls into it) are one step from its functions.
    calls =
      (walk(project.forward, slice_functions, 1, keep?, :forward) ++
         if(incoming?, do: walk(project.backward, slice_functions, 1, keep?, :backward), else: []) ++
         walk(project.forward, Keyword.get(opts, :from, []), depth, keep?, :forward) ++
         walk(project.backward, Keyword.get(opts, :to, []), depth, keep?, :backward))
      |> Enum.uniq()
      |> Enum.sort()

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
      externals: externals
    }
  end

  # A shown file lists the functions at the end of a drawn call, and its other written functions when it is a slice
  # file or `all_functions?` is set; in file order.
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
  Groups the project's files into directories `level` deep (counted from the project root, so `lib/my_app/` is 2)
  and returns `%{dirs: [dir], edges: [{source_dir, sink_dir, kind, count}]}`: one edge per pair of directories,
  with the strongest kind among its file dependencies (compile, then export, then runtime) and their count.
  """
  def overview(project, level) do
    # Files in a directory shallower than `level` form their own group, `dir/*`, apart from its subdirectories;
    # files at the root are `./*`.
    dir_of = fn file ->
      parts = if Path.dirname(file) == ".", do: [], else: file |> Path.dirname() |> Path.split()
      name = if parts == [], do: ".", else: parts |> Enum.take(level) |> Path.join()
      name <> if(length(parts) < level, do: "/*", else: "/")
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
end
