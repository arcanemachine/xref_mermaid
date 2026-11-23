defmodule XrefMermaid.Changes do
  @moduledoc """
  Compares a project with a snapshot of an earlier state (`XrefMermaid.Snapshot`): what is added, changed and
  removed since.

  A file is known by its path; a function by its module and name, and is the same function as an earlier one with
  an arity in common (adding a default argument to `place/2` makes `place/1..2`, not a new function); a call by the
  functions at its ends. So a module moved to another file makes the file new, not its functions, and a renamed
  function is a removed one and an added one.
  """

  alias XrefMermaid.{Project, Snapshot}

  defstruct added_files: MapSet.new(),
            added: MapSet.new(),
            changed: MapSet.new(),
            new_calls: MapSet.new(),
            removed: nil

  @doc """
  Compares `project` with `snapshot`. `hashes` are the project's source hashes (`XrefMermaid.Source.hashes/2`): a
  function is changed when it has one, the earlier function had one, and they differ.

  Options:

    * `:prefixes` - the path prefixes that removed things are counted in: `removed` is `%{files: [path], functions:
      [name], calls: [name]}` for the files whose paths start with one, their functions and the calls those made;
      `nil` without prefixes
    * `:external` - removed calls to modules outside the project count too, as `--external` draws them
    * `:excludes` - path prefixes left out of the project (`XrefMermaid.Project.exclude/2`), left out of the snapshot
      too
    * `:excluded_names` - functions left out of the project (`XrefMermaid.Project.exclude_names/2`), left out of the
      snapshot too, with every call to or from them
  """
  def compare(project, snapshot, hashes, opts \\ []) do
    excludes = Keyword.get(opts, :excludes, [])
    out? = fn file -> Enum.any?(excludes, &String.starts_with?(file, &1)) end
    names = Keyword.get(opts, :excluded_names, [])

    named_out =
      for function <- snapshot.functions,
          Project.name_out?(names, {function.module, function.name}, function.arities),
          into: MapSet.new(),
          do: before_key(function)

    # A callee in no file of the snapshot is external, matched by the arity it is called with.
    call_out? = fn {caller, {module, name, arity} = callee} ->
      caller in named_out or callee in named_out or
        Project.name_out?(names, {module, name}, [arity])
    end

    snapshot = %{
      snapshot
      | calls: Enum.reject(snapshot.calls, call_out?),
        externals: Enum.reject(snapshot.externals, call_out?)
    }

    before_functions =
      Enum.reject(snapshot.functions, &(out?.(&1.file) or before_key(&1) in named_out))

    # Every earlier function's file, excluded ones too, so a call into an excluded file is told from an external one.
    before_file = Map.new(snapshot.functions, &{before_key(&1), &1.file})
    before_by_name = Enum.group_by(before_functions, &{&1.module, &1.name})

    # Each project function's earlier functions: same module and name, an arity in common.
    earlier =
      Map.new(project.functions, fn {key, function} ->
        {module, name, _} = Snapshot.name(key)

        matches =
          Enum.filter(
            Map.get(before_by_name, {module, name}, []),
            &overlap?(&1.arities, function.arities)
          )

        {key, matches}
      end)

    earlier_keys =
      Map.new(earlier, fn {key, matches} -> {key, Enum.map(matches, &before_key/1)} end)

    changed =
      for {key, matches} <- earlier,
          hash = hashes[key],
          hash != nil,
          before_hashes = matches |> Enum.map(& &1.hash) |> Enum.reject(&is_nil/1),
          before_hashes != [] and hash not in before_hashes,
          into: MapSet.new(),
          do: key

    # The earlier calls each project call continues.
    continued =
      Map.new(
        for {caller, callees} <- project.forward, callee <- callees do
          before =
            case callee do
              {:external, key} ->
                for c <- earlier_keys[caller],
                    call = {c, Snapshot.name(key)},
                    call in snapshot.externals,
                    do: call

              _ ->
                for c <- earlier_keys[caller],
                    t <- earlier_keys[callee],
                    call = {c, t},
                    call in snapshot.calls,
                    do: call
            end

          {{caller, callee}, before}
        end
      )

    %__MODULE__{
      added_files:
        for(
          file <- Map.keys(project.file_edges),
          file not in snapshot.files,
          into: MapSet.new(),
          do: file
        ),
      added: for({key, []} <- earlier, into: MapSet.new(), do: key),
      changed: changed,
      new_calls: for({call, []} <- continued, into: MapSet.new(), do: call),
      removed:
        removed(
          project,
          snapshot,
          before_functions,
          before_file,
          continued,
          out?,
          Keyword.get(opts, :prefixes, []),
          opts[:external] == true
        )
    }
  end

  defp removed(_project, _snapshot, _functions, _file, _continued, _out?, [], _external), do: nil

  defp removed(
         project,
         snapshot,
         before_functions,
         before_file,
         continued,
         out?,
         prefixes,
         external
       ) do
    in_scope? = fn file -> Enum.any?(prefixes, &String.starts_with?(file, &1)) end

    # An external call counts only when the chart would draw it (`XrefMermaid.Selection.select/2`).
    external? = fn {module, name, arity} ->
      external and not String.starts_with?(module, ":") and
        module not in ["Kernel", "String.Chars"] and
        {name, arity} != {"exception", 1}
    end

    # Calls from generated functions aren't drawn, so their removal isn't counted.
    generated = for f <- before_functions, f.generated?, into: MapSet.new(), do: before_key(f)

    # A callee in no file of the snapshot is external.
    drawn_callee? = fn callee ->
      case before_file[callee] do
        nil -> external?.(callee)
        file -> not out?.(file)
      end
    end

    now_by_name =
      project.functions
      |> Map.values()
      |> Enum.group_by(&{inspect(&1.module), Atom.to_string(&1.name)})

    kept_calls = continued |> Map.values() |> List.flatten() |> MapSet.new()

    files =
      for file <- snapshot.files,
          in_scope?.(file) and not out?.(file),
          not Map.has_key?(project.file_edges, file),
          do: file

    functions =
      for function <- before_functions,
          in_scope?.(function.file) and not function.generated?,
          not Enum.any?(
            Map.get(now_by_name, {function.module, function.name}, []),
            &overlap?(&1.arities, function.arities)
          ),
          do: "#{function.module}.#{function.name}/#{arities(function.arities)}"

    calls =
      for {caller, callee} = call <- Enum.concat(snapshot.calls, snapshot.externals),
          caller_file = before_file[caller],
          caller_file != nil and in_scope?.(caller_file) and not out?.(caller_file),
          caller not in generated,
          drawn_callee?.(callee),
          call not in kept_calls,
          do: "#{text(caller)} -> #{text(callee)}"

    %{files: Enum.sort(files), functions: Enum.sort(functions), calls: Enum.sort(calls)}
  end

  @doc """
  The changes in a selection (`XrefMermaid.Selection.select/2`, before `by_file/3`) as text, one sorted line per item:
  `+` added, `~` changed, `-` removed, then the removed counts when there are path prefixes.
  """
  def list(project, selection, changes) do
    shown =
      selection.files
      |> Map.values()
      |> List.flatten()
      |> Enum.reject(&project.functions[&1].generated?)

    function_lines = fn keys, mark ->
      for key <- shown, key in keys do
        function = project.functions[key]

        "#{mark} function #{inspect(function.module)}.#{function.name}/#{arities(function.arities)}"
      end
    end

    removed = changes.removed

    lines =
      Enum.sort(
        for file <- Map.keys(selection.files), file in changes.added_files, do: "+ file #{file}"
      ) ++
        Enum.sort(function_lines.(changes.added, "+")) ++
        Enum.sort(function_lines.(changes.changed, "~")) ++
        Enum.sort(
          for {caller, callee} = call <- selection.calls,
              call in changes.new_calls,
              do: "+ call #{name(caller)} -> #{name(callee)}"
        ) ++
        if removed do
          Enum.map(removed.files, &"- file #{&1}") ++
            Enum.map(removed.functions, &"- function #{&1}") ++
            Enum.map(removed.calls, &"- call #{&1}") ++ [removed_count(removed)]
        else
          []
        end

    Enum.map_join(lines, &(&1 <> "\n"))
  end

  @doc "The removed counts as one line: `removed: 1 file, 2 functions, 0 calls`."
  def removed_count(removed) do
    counts =
      [{removed.files, "file"}, {removed.functions, "function"}, {removed.calls, "call"}]
      |> Enum.map_join(", ", fn {items, noun} ->
        "#{length(items)} #{noun}#{if length(items) == 1, do: "", else: "s"}"
      end)

    "removed: " <> counts
  end

  @doc "Warns when the snapshot has files and none of them is a file of the project."
  def warnings(project, snapshot) do
    if MapSet.size(snapshot.files) > 0 and
         not Enum.any?(Map.keys(project.file_edges), &(&1 in snapshot.files)),
       do: [
         "no file of the snapshot is a file of the project: was it taken in another directory (an umbrella app " <>
           "or its root)?"
       ],
       else: []
  end

  defp before_key(function), do: {function.module, function.name, hd(function.arities)}

  defp overlap?(a, b), do: Enum.any?(a, &(&1 in b))

  defp arities([arity]), do: "#{arity}"
  defp arities(arities), do: "#{List.first(arities)}..#{List.last(arities)}"

  defp text({module, name, arity}), do: "#{module}.#{name}/#{arity}"

  defp name({:external, key}), do: name(key)
  defp name({module, name, arity}), do: "#{inspect(module)}.#{name}/#{arity}"
end
