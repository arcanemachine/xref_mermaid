defmodule XrefMermaid.Project do
  @moduledoc """
  An Elixir project's files, functions and calls, independent of any chart.

  A function is known by its key, `{module, name, arity}` with the lowest arity of its definition, so a function with
  default arguments is one function. A call goes from a function key to a function key, or to
  `{:external, {module, name, arity}}` for a module outside the project.

  `modules_in` maps each file to its modules, the main one first: the one named after the file (`MyApp.Orders` in
  `lib/my_app/orders.ex`), or else the first one defined in it, a protocol implementation only when nothing else
  is there.

  `through_private` holds the calls that `public_only/1` made from calls through private functions.
  """

  alias XrefMermaid.{Beam, DotGraph}

  defstruct root: nil,
            file_edges: %{},
            functions: %{},
            index: %{},
            modules: %{},
            modules_in: %{},
            forward: %{},
            backward: %{},
            through_private: MapSet.new()

  @doc """
  Compiles the current Mix project and reads its file graph (`mix xref graph`) and its compiled modules. At an
  umbrella root, it reads every app, with paths relative to the root (`apps/my_app/lib/...`).

  With `details: true`, functions also get their docs and specs. Returns `{project, warnings}`.
  """
  def load(opts \\ []) do
    Mix.Project.get!()
    root = Path.dirname(Mix.Project.project_file())

    # The project compiles first, with its messages shown.
    Mix.Task.run("compile")

    # An umbrella's apps are read one by one: `mix xref graph` at the root would list every app's files without
    # their app's directory, so two apps' `lib/my_app.ex` would clash.
    {file_edges, beams} =
      if Mix.Project.umbrella?() do
        Mix.Project.apps_paths()
        |> Enum.sort()
        |> Enum.map(fn {app, path} ->
          Mix.Project.in_project(app, Path.join(root, path), fn _ ->
            {prefix_paths(file_graph(), path), beam_paths()}
          end)
        end)
        |> Enum.unzip()
        |> then(fn {graphs, beams} ->
          {Enum.reduce(graphs, %{}, &Map.merge/2), Enum.concat(beams)}
        end)
      else
        {file_graph(), beam_paths()}
      end

    modules = beams |> Enum.map(&Beam.read(File.read!(&1), opts)) |> Enum.reject(&is_nil/1)
    project = new(file_edges, modules, root)
    {project, load_warnings(project, modules, length(beams))}
  end

  # The current project's file graph, from `mix xref graph`, run quietly: it would only print how to render the dot
  # file.
  defp file_graph do
    dot_path =
      Path.join(System.tmp_dir!(), "xref_mermaid_#{System.unique_integer([:positive])}.dot")

    shell = Mix.shell()

    try do
      Mix.shell(Mix.Shell.Quiet)
      Mix.Task.rerun("xref", ["graph", "--format", "dot", "--output", dot_path])
      dot_path |> File.read!() |> DotGraph.parse()
    after
      Mix.shell(shell)
      File.rm(dot_path)
    end
  end

  # Erlang modules (from `src/`) are left out: they have no Elixir debug info to read.
  defp beam_paths, do: Path.wildcard(Path.join(Mix.Project.compile_path(), "Elixir.*.beam"))

  defp prefix_paths(file_edges, dir) do
    Map.new(file_edges, fn {source, sinks} ->
      {Path.join(dir, source),
       Map.new(sinks, fn {sink, kind} -> {Path.join(dir, sink), kind} end)}
    end)
  end

  @doc false
  # Public for its tests: `modules` are all the modules read, out of `beam_count` beam files.
  def load_warnings(project, modules, beam_count) do
    without_debug_info = beam_count - length(modules)

    unmatched =
      Enum.count(
        modules,
        &(Path.relative_to(&1.file, project.root) not in Map.keys(project.file_edges))
      )

    [
      if(without_debug_info > 0,
        do:
          "compiled modules without debug info, whose functions are missing: #{without_debug_info}"
      ),
      if(unmatched > 0,
        do:
          "modules from files that `mix xref` doesn't list, whose functions are missing: #{unmatched}"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Builds a project from `file_edges` (from `XrefMermaid.DotGraph.parse/1`, paths relative to `root`) and `modules`
  (from `XrefMermaid.Beam.read/1`, absolute paths).
  """
  def new(file_edges, modules, root) do
    # A module left out below (its file isn't in the file graph) is still the project's, not external.
    project_modules = MapSet.new(modules, & &1.module)

    modules =
      for module <- modules,
          file = Path.relative_to(module.file, root),
          Map.has_key?(file_edges, file),
          into: %{},
          do: {module.module, %{module | file: file}}

    functions =
      for {_, module} <- modules, function <- module.functions, into: %{} do
        key = {module.module, function.name, hd(function.arities)}
        {key, Map.merge(function, %{key: key, module: module.module, file: module.file})}
      end

    index =
      for {key, function} <- functions, arity <- function.arities, into: %{} do
        {{function.module, function.name, arity}, key}
      end

    # A call to a project module that resolves to no function (an unknown arity) is dropped.
    calls =
      for {_, module} <- modules,
          {{name, arity}, {callee_module, _, _} = callee} <- module.calls,
          target =
            index[callee] || if(callee_module not in project_modules, do: {:external, callee}),
          caller = index[{module.module, name, arity}],
          caller != target,
          uniq: true,
          do: {caller, target}

    %__MODULE__{
      root: root,
      file_edges: file_edges,
      functions: functions,
      index: index,
      modules: modules,
      modules_in:
        modules
        |> Map.values()
        |> Enum.group_by(& &1.file, & &1.module)
        |> Map.new(fn {file, names} ->
          {file, Enum.sort_by(names, &main_rank(modules[&1], file))}
        end),
      forward: Enum.group_by(calls, &elem(&1, 0), &elem(&1, 1)),
      backward: Enum.group_by(calls, &elem(&1, 1), &elem(&1, 0))
    }
  end

  # A module that isn't a protocol implementation comes first, then the one named after its file, then the first
  # one defined.
  defp main_rank(module, file) do
    path = Path.rootname(file)
    underscored = Macro.underscore(module.module)
    named_after_file? = path == underscored or String.ends_with?(path, "/" <> underscored)
    {module.impl != nil, not named_after_file?, module.line || 0, module.module}
  end

  @doc """
  Groups the files that call each other in a cycle: returns `%{file => group}` for each file on a cycle of calls
  between files, over the whole project. Two files are on one cycle when they share a group.
  """
  def cycle_groups(project) do
    graph = :digraph.new()

    try do
      for {caller, callees} <- project.forward,
          callee <- callees,
          not match?({:external, _}, callee),
          source = project.functions[caller].file,
          sink = project.functions[callee].file,
          source != sink do
        :digraph.add_vertex(graph, source)
        :digraph.add_vertex(graph, sink)
        :digraph.add_edge(graph, source, sink)
      end

      for {files, group} <- Enum.with_index(:digraph_utils.strong_components(graph)),
          length(files) > 1,
          file <- files,
          into: %{},
          do: {file, group}
    after
      :digraph.delete(graph)
    end
  end

  @doc """
  Drops the files whose paths start with one of `prefixes`: their file dependencies both ways, their modules and
  functions, and every call to or from them.
  """
  def exclude(project, []), do: project

  def exclude(project, prefixes) do
    out? = fn file -> Enum.any?(prefixes, &String.starts_with?(file, &1)) end

    functions = Map.reject(project.functions, fn {_, function} -> out?.(function.file) end)
    kept? = &(match?({:external, _}, &1) or Map.has_key?(functions, &1))

    keep_calls = fn edges ->
      for {key, others} <- edges,
          kept?.(key),
          others = Enum.filter(others, kept?),
          others != [],
          into: %{},
          do: {key, others}
    end

    %{
      project
      | file_edges:
          for(
            {source, sinks} <- project.file_edges,
            not out?.(source),
            into: %{},
            do: {source, Map.reject(sinks, fn {sink, _} -> out?.(sink) end)}
          ),
        functions: functions,
        index: Map.filter(project.index, fn {_, key} -> Map.has_key?(functions, key) end),
        modules: Map.reject(project.modules, fn {_, module} -> out?.(module.file) end),
        modules_in: Map.reject(project.modules_in, fn {file, _} -> out?.(file) end),
        forward: keep_calls.(project.forward),
        backward: keep_calls.(project.backward)
    }
  end

  @doc """
  Drops the functions `names` match (`name_out?/3`), project or external, and every call to or from them. `names`
  are `{module, name, arity}` as text (`XrefMermaid.Snapshot.name/1`), with `nil` for every arity, or `{:module,
  module}` for every function of a module and the modules nested in it.
  """
  def exclude_names(project, []), do: project

  def exclude_names(project, names) do
    out? = fn
      {:external, {module, name, arity}} ->
        name_out?(names, {inspect(module), Atom.to_string(name)}, [arity])

      {module, name, _} = key ->
        name_out?(names, {inspect(module), Atom.to_string(name)}, project.functions[key].arities)
    end

    functions = Map.reject(project.functions, fn {key, _} -> out?.(key) end)

    keep_calls = fn edges ->
      for {key, others} <- edges,
          not out?.(key),
          others = Enum.reject(others, out?),
          others != [],
          into: %{},
          do: {key, others}
    end

    %{
      project
      | functions: functions,
        index: Map.filter(project.index, fn {_, key} -> Map.has_key?(functions, key) end),
        forward: keep_calls.(project.forward),
        backward: keep_calls.(project.backward)
    }
  end

  @doc """
  Whether one of `names` (as in `exclude_names/2`) matches the function `{module, name}`, as text, with `arities`.
  """
  def name_out?(names, {module, name}, arities) do
    Enum.any?(names, fn
      {:module, out_module} ->
        module_in?(module, out_module)

      {out_module, out_name, arity} ->
        out_module == module and out_name == name and (arity == nil or arity in arities)
    end)
  end

  @doc """
  Whether `module` is `outer` or nested in it, by the parts of their names as text: `Ecto.Changeset` is in `Ecto`,
  `EctoEnum` isn't.
  """
  def module_in?(module, outer), do: module == outer or String.starts_with?(module, outer <> ".")

  @doc """
  Drops the private functions. A public function's calls through private ones become calls of its own, to the
  public functions and external ones they reach, listed in `through_private` unless it also makes them directly.
  Each function's calls keep the order its code first makes them.
  """
  def public_only(project) do
    private? = fn key ->
      function = project.functions[key]
      function != nil and function.kind in [:defp, :defmacrop]
    end

    functions = Map.reject(project.functions, fn {key, _} -> private?.(key) end)

    # `{callee, through_private?}` in the order the code first reaches each, depth first through private functions.
    reach = fn reach, callees, through?, seen ->
      Enum.flat_map_reduce(callees, seen, fn callee, seen ->
        cond do
          not private?.(callee) ->
            {[{callee, through?}], seen}

          callee in seen ->
            {[], seen}

          true ->
            reach.(reach, Map.get(project.forward, callee, []), true, MapSet.put(seen, callee))
        end
      end)
    end

    reached =
      for {caller, callees} <- project.forward, Map.has_key?(functions, caller), into: %{} do
        {pairs, _} = reach.(reach, callees, false, MapSet.new())
        {caller, Enum.reject(pairs, &(elem(&1, 0) == caller))}
      end

    calls =
      for {caller, pairs} <- reached,
          callee <- pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          do: {caller, callee}

    through_private =
      for {caller, pairs} <- reached,
          {callee, true} <- pairs,
          {callee, false} not in pairs,
          into: MapSet.new(),
          do: {caller, callee}

    %{
      project
      | functions: functions,
        index: Map.filter(project.index, fn {_, key} -> Map.has_key?(functions, key) end),
        forward: Enum.group_by(calls, &elem(&1, 0), &elem(&1, 1)),
        backward: Enum.group_by(calls, &elem(&1, 1), &elem(&1, 0)),
        through_private: through_private
    }
  end

  @doc """
  Finds the functions `spec` names: `{module, name, arity}`, or `{module, name, nil}` for every arity.

  Returns `{:ok, [key]}` or `{:error, message}` naming the closest matches.
  """
  def resolve(project, {module, name, arity}) do
    keys =
      if arity,
        do: List.wrap(project.index[{module, name, arity}]),
        else: for({key, f} <- project.functions, f.module == module and f.name == name, do: key)

    if keys != [] do
      {:ok, Enum.sort(keys)}
    else
      wanted = format_spec({module, name, arity})

      suggestions =
        project.functions
        |> Map.values()
        |> Enum.map(&format_spec({&1.module, &1.name, hd(&1.arities)}))
        |> Enum.sort_by(&(-String.jaro_distance(&1, wanted)))
        |> Enum.take(3)

      {:error, "No function #{wanted} in the project. Closest: #{Enum.join(suggestions, ", ")}"}
    end
  end

  @doc """
  Reads a function as written on the command line: `Mod.fun/arity`, or `Mod.fun` for every arity. Returns
  `{:ok, {module, name, arity_or_nil}}` or `:error`.
  """
  def parse_spec(spec) do
    # Read as a capture, so names like `valid?`, operators and nested modules read as Elixir reads them.
    case Code.string_to_quoted("&" <> spec) do
      {:ok, {:&, _, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]}}
      when is_integer(arity) ->
        with {:ok, module} <- module(module), do: {:ok, {module, name, arity}}

      {:ok, {:&, _, [{{:., _, [module, name]}, _, []}]}} ->
        with {:ok, module} <- module(module), do: {:ok, {module, name, nil}}

      _ ->
        :error
    end
  end

  defp module({:__aliases__, _, parts}) when is_list(parts), do: {:ok, Module.concat(parts)}
  defp module(module) when is_atom(module), do: {:ok, module}
  defp module(_), do: :error

  defp format_spec({module, name, arity}) do
    "#{inspect(module)}.#{name}" <> if(arity, do: "/#{arity}", else: "")
  end
end
