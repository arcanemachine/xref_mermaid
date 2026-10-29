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
  file dependencies on them), `all_functions`, `external` (also calls to modules outside the project, as leaves).
  """
  def select(project, opts) do
    prefixes = Keyword.get(opts, :prefixes, [])
    depth = Keyword.get(opts, :depth, 3)
    in_slice? = fn file -> Enum.any?(prefixes, &String.starts_with?(file, &1)) end

    slice_files = project.file_edges |> Map.keys() |> Enum.filter(in_slice?) |> MapSet.new()

    slice_functions =
      for {key, function} <- project.functions,
          function.file in slice_files and not function.generated?,
          do: key

    # Erlang modules and `Kernel` are left out of external calls: most are what Kernel's functions compile to.
    keep? = fn
      {:external, {module, _, _}} ->
        opts[:external] == true and String.starts_with?(Atom.to_string(module), "Elixir.") and
          module != Kernel

      _ ->
        true
    end

    calls =
      Enum.uniq(
        for(
          caller <- slice_functions,
          callee <- Map.get(project.forward, caller, []),
          keep?.(callee),
          do: {caller, callee}
        ) ++
          if(opts[:incoming],
            do:
              for(
                callee <- slice_functions,
                caller <- Map.get(project.backward, callee, []),
                do: {caller, callee}
              ),
            else: []
          ) ++
          walk(project.forward, Keyword.get(opts, :from, []), depth, keep?) ++
          (project.backward
           |> walk(Keyword.get(opts, :to, []), depth, fn _ -> true end)
           |> Enum.map(fn {callee, caller} -> {caller, callee} end))
      )

    file_of = fn key -> project.functions[key].file end
    project_calls = Enum.reject(calls, &match?({_, {:external, _}}, &1))

    called_files =
      MapSet.new(project_calls, fn {caller, callee} -> {file_of.(caller), file_of.(callee)} end)

    file_edges =
      for {source, sinks} <- project.file_edges,
          {sink, kind} <- sinks,
          source != sink,
          source in slice_files or (opts[:incoming] == true and sink in slice_files),
          {source, sink} not in called_files,
          do: {source, sink, kind}

    endpoints = calls |> Enum.flat_map(&Tuple.to_list/1) |> MapSet.new()

    shown_files =
      Enum.uniq(
        Enum.to_list(slice_files) ++
          for(key <- endpoints, not match?({:external, _}, key), do: file_of.(key)) ++
          Enum.flat_map(file_edges, fn {source, sink, _} -> [source, sink] end)
      )

    functions_in = project.functions |> Map.values() |> Enum.group_by(& &1.file)

    files =
      for file <- shown_files, into: %{} do
        keys =
          for function <- Map.get(functions_in, file, []),
              function.key in endpoints or
                (not function.generated? and (file in slice_files or opts[:all_functions] == true)),
              do: function.key

        {file, Enum.sort_by(keys, &{project.functions[&1].line, &1})}
      end

    externals =
      for {:external, {module, _, _}} = key <- endpoints, reduce: %{} do
        acc -> Map.update(acc, module, [key], &Enum.sort([key | &1]))
      end

    %{
      files: files,
      slice_files: slice_files,
      calls: Enum.sort(calls),
      file_edges: Enum.sort(file_edges),
      starts: MapSet.new(Keyword.get(opts, :from, []) ++ Keyword.get(opts, :to, [])),
      externals: externals
    }
  end

  # Breadth-first from `seeds` over `edges` (a map from a key to the keys it leads to); returns the edges taken.
  defp walk(edges, seeds, depth, keep?) do
    {taken, _seen, _frontier} =
      Enum.reduce(1..depth//1, {[], MapSet.new(seeds), seeds}, fn _, {taken, seen, frontier} ->
        step = for from <- frontier, to <- Map.get(edges, from, []), keep?.(to), do: {from, to}
        next = step |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 in seen)) |> Enum.uniq()
        {taken ++ step, MapSet.union(seen, MapSet.new(next)), next}
      end)

    taken
  end

  @doc """
  Groups the project's files into directories `level` deep (counted from the project root, so `lib/my_app/` is 2)
  and returns `%{dirs: [dir], edges: [{source_dir, sink_dir, kind, count}]}`: one edge per pair of directories,
  with the strongest kind among its file dependencies (compile, then export, then runtime) and their count.
  """
  def overview(project, level) do
    # Files in a directory shallower than `level` form their own group, `dir/*`, apart from its subdirectories.
    dir_of = fn file ->
      parts = file |> Path.dirname() |> Path.split()
      Path.join(Enum.take(parts, level)) <> if(length(parts) < level, do: "/*", else: "/")
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
