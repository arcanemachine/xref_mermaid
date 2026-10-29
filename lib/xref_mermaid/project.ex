defmodule XrefMermaid.Project do
  @moduledoc """
  An Elixir project's files, functions and calls, independent of any chart.

  A function is known by its key, `{module, name, arity}` with the lowest arity of its definition, so a function with
  default arguments is one function. A call goes from a function key to a function key, or to
  `{:external, {module, name, arity}}` for a module outside the project.

  `modules_in` maps each file to its modules, the main one (the shortest name) first.
  """

  alias XrefMermaid.{Beam, DotGraph}

  defstruct root: nil,
            file_edges: %{},
            functions: %{},
            index: %{},
            modules: %{},
            modules_in: %{},
            forward: %{},
            backward: %{}

  @doc """
  Compiles the current Mix project and reads its file graph (`mix xref graph`) and its compiled modules.

  Returns `{project, warnings}`.
  """
  def load do
    if Mix.Project.umbrella?() do
      Mix.raise("Run this task from an app's directory, not from the umbrella root")
    end

    root = Path.dirname(Mix.Project.project_file())

    dot_path =
      Path.join(System.tmp_dir!(), "xref_mermaid_#{System.unique_integer([:positive])}.dot")

    # The project compiles first, with its messages shown; xref then runs quietly, as it would only print how to
    # render its dot file.
    Mix.Task.run("compile")
    shell = Mix.shell()

    file_edges =
      try do
        Mix.shell(Mix.Shell.Quiet)
        Mix.Task.rerun("xref", ~w(graph --format dot --output #{dot_path}))
        dot_path |> File.read!() |> DotGraph.parse()
      after
        Mix.shell(shell)
        File.rm(dot_path)
      end

    beams = Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam"))
    modules = beams |> Enum.map(&Beam.read(String.to_charlist(&1))) |> Enum.reject(&is_nil/1)
    project = new(file_edges, modules, root)
    {project, load_warnings(project, modules, length(beams))}
  end

  defp load_warnings(project, modules, beam_count) do
    without_debug_info = beam_count - length(modules)

    unmatched =
      Enum.count(
        modules,
        &(Path.relative_to(&1.file, project.root) not in Map.keys(project.file_edges))
      )

    [
      if(without_debug_info > 0,
        do:
          "#{without_debug_info} compiled modules have no debug info, so their functions are missing"
      ),
      if(unmatched > 0,
        do:
          "#{unmatched} modules come from files that `mix xref` doesn't list, so their functions are missing"
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
          {file, Enum.sort_by(names, &{String.length(inspect(&1)), &1})}
        end),
      forward: Enum.group_by(calls, &elem(&1, 0), &elem(&1, 1)),
      backward: Enum.group_by(calls, &elem(&1, 1), &elem(&1, 0))
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
