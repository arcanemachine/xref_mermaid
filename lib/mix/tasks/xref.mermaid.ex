defmodule Mix.Tasks.Xref.Mermaid do
  @shortdoc "Writes a Mermaid flowchart of the project's files, functions and calls"

  @moduledoc """
  Writes a Mermaid flowchart of part of the project: files, their functions, and the calls between them.

      mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd
      mix xref.mermaid --from MyApp.Orders.place/2 --depth 4 -o place.mmd
      mix xref.mermaid --to MyApp.Repo.insert -o who_inserts.mmd
      mix xref.mermaid --overview --level 3 -o overview.mmd

  Run it from an app's directory (in an umbrella project, not from the umbrella root).

  ## What to draw

  These can be combined; the chart shows everything they reach.

    * path prefixes (arguments) - every function in the files under them, the calls those make, and the files they
      depend on
    * `--from MOD.FUN/ARITY` - the calls the function makes, followed `--depth` hops (repeatable; leave out
      `/ARITY` for every arity)
    * `--to MOD.FUN/ARITY` - the calls made to the function, followed `--depth` hops back (repeatable)
    * `--depth N` - hops for `--from` and `--to` (default 3)
    * `--incoming` - also the calls into the path slice and the files that depend on it
    * `--overview` - instead of all the above: one node per directory `--level` deep (default 2), arrows between
      them

  ## How to draw it

    * `-o`, `--output` - the file to write (required)
    * `--all-functions` - every function of every shown file, not just the ones calls reach (files outside the
      slice start collapsed)
    * `--external` - also calls to modules outside the project, as leaves
    * `--expanded` / `--collapsed` - opens or collapses every file
    * `--link TEMPLATE` - makes each function a link: `{path}` (absolute) and `{line}`, e.g.
      `vscode://file{path}:{line}`
    * `--legend` - adds a legend

  Regenerating overwrites the output file.
  """

  use Mix.Task

  alias XrefMermaid.{Mermaid, Project, Selection}

  @switches [
    output: :string,
    from: :keep,
    to: :keep,
    depth: :integer,
    incoming: :boolean,
    overview: :boolean,
    level: :integer,
    all_functions: :boolean,
    external: :boolean,
    expanded: :boolean,
    collapsed: :boolean,
    link: :string,
    legend: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, prefixes} = OptionParser.parse!(argv, strict: @switches, aliases: [o: :output])
    output = opts[:output] || Mix.raise("Missing --output")
    from = Keyword.get_values(opts, :from)
    to = Keyword.get_values(opts, :to)

    if opts[:expanded] && opts[:collapsed],
      do: Mix.raise("Give --expanded or --collapsed, not both")

    if !opts[:overview] and prefixes == [] and from == [] and to == [] do
      Mix.raise("Give path prefixes, --from, --to or --overview")
    end

    # Compiling the project prunes the code path, archives included, so this archive's modules load first.
    Application.load(:xref_mermaid)
    Code.ensure_all_loaded!(Application.spec(:xref_mermaid, :modules))

    {project, warnings} = Project.load()

    text =
      if opts[:overview] do
        project |> Selection.overview(Keyword.get(opts, :level, 2)) |> Mermaid.write_overview()
      else
        selection =
          Selection.select(project,
            prefixes: prefixes,
            from: Enum.flat_map(from, &resolve!(project, &1)),
            to: Enum.flat_map(to, &resolve!(project, &1)),
            depth: Keyword.get(opts, :depth, 3),
            incoming: opts[:incoming],
            all_functions: opts[:all_functions],
            external: opts[:external]
          )

        Mermaid.write(project, selection, opts)
      end

    File.write!(output, text)
    Enum.each(warnings ++ size_warnings(text), &Mix.shell().error("warning: " <> &1))
    Mix.shell().info("Wrote #{output}")
  end

  defp resolve!(project, spec) do
    case Project.resolve(project, parse_spec!(spec)) do
      {:ok, keys} -> keys
      {:error, message} -> Mix.raise(message)
    end
  end

  # Parsed as a capture so names like `valid?`, operators and nested modules read as Elixir reads them.
  defp parse_spec!(spec) do
    case Code.string_to_quoted("&" <> spec) do
      {:ok, {:&, _, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]}}
      when is_integer(arity) ->
        {module!(module, spec), name, arity}

      {:ok, {:&, _, [{{:., _, [module, name]}, _, []}]}} ->
        {module!(module, spec), name, nil}

      _ ->
        Mix.raise("Can't read #{inspect(spec)}: give MOD.FUN/ARITY or MOD.FUN")
    end
  end

  defp module!({:__aliases__, _, parts}, _spec), do: Module.concat(parts)
  defp module!(module, _spec) when is_atom(module), do: module
  defp module!(_, spec), do: Mix.raise("Can't read the module in #{inspect(spec)}")

  # Mermaid 12 refuses to draw a chart over these limits (`maxTextSize`, `maxEdges`), and a chart can't raise them.
  defp size_warnings(text) do
    edges = text |> String.split("\n") |> Enum.count(&String.contains?(&1, ["-->", ".->", "==>"]))

    [
      if(byte_size(text) > 50_000,
        do: "the chart is #{byte_size(text)} characters; Mermaid draws at most 50000 by default"
      ),
      if(edges > 500, do: "the chart has #{edges} arrows; Mermaid draws at most 500 by default")
    ]
    |> Enum.reject(&is_nil/1)
  end
end
