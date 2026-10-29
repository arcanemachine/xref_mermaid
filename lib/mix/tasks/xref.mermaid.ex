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

    * path prefixes (arguments, relative to the app's directory) - every function in the files under them, the
      calls those make, and the files they depend on
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
    * `--external` - also calls to Elixir modules outside the project, as leaves (not Erlang modules, `Kernel` or
      `String.Chars`, which are mostly what Kernel's functions and string interpolation compile to)
    * `--expanded` / `--collapsed` - opens or collapses every file
    * `--link TEMPLATE` - makes each function a link: `{path}` (absolute) and `{line}`, e.g.
      `vscode://file{path}:{line}`
    * `--legend` - adds a legend

  Regenerating overwrites the output file.
  """

  use Mix.Task

  alias XrefMermaid.{Mermaid, Project, Selection}

  @impl true
  def run(argv) do
    {opts, prefixes} =
      OptionParser.parse!(argv,
        strict: [
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
        ],
        aliases: [o: :output]
      )

    output = opts[:output] || Mix.raise("Missing --output")
    check_options!(opts, prefixes)

    # Compiling the project prunes the code path, archives included, so this archive's modules load first.
    Application.load(:xref_mermaid)
    Code.ensure_all_loaded!(Application.spec(:xref_mermaid, :modules))

    {project, warnings} = Project.load()
    text = if opts[:overview], do: overview(project, opts), else: chart(project, prefixes, opts)

    File.write!(output, text)
    Enum.each(warnings ++ Mermaid.limit_warnings(text), &Mix.shell().error("warning: " <> &1))
    Mix.shell().info("Wrote #{output}")
  end

  defp check_options!(opts, prefixes) do
    from_or_to? = Keyword.has_key?(opts, :from) or Keyword.has_key?(opts, :to)

    cond do
      opts[:expanded] && opts[:collapsed] ->
        Mix.raise("Give --expanded or --collapsed, not both")

      opts[:overview] && (prefixes != [] or from_or_to?) ->
        Mix.raise("--overview draws the whole project; leave out path prefixes, --from and --to")

      opts[:overview] &&
          Enum.any?(
            [:depth, :incoming, :all_functions, :external, :expanded, :collapsed, :link, :legend],
            &Keyword.has_key?(opts, &1)
          ) ->
        Mix.raise("--overview takes only --level and --output")

      !opts[:overview] and prefixes == [] and not from_or_to? ->
        Mix.raise("Give path prefixes, --from, --to or --overview")

      Keyword.has_key?(opts, :level) and !opts[:overview] ->
        Mix.raise("--level goes with --overview")

      Keyword.get(opts, :level, 1) < 1 ->
        Mix.raise("--level must be 1 or more")

      Keyword.has_key?(opts, :depth) and not from_or_to? ->
        Mix.raise("--depth goes with --from or --to")

      Keyword.get(opts, :depth, 0) < 0 ->
        Mix.raise("--depth must be 0 or more")

      opts[:incoming] && prefixes == [] ->
        Mix.raise("--incoming goes with path prefixes")

      true ->
        :ok
    end
  end

  defp overview(project, opts) do
    project |> Selection.overview(Keyword.get(opts, :level, 2)) |> Mermaid.write_overview()
  end

  defp chart(project, prefixes, opts) do
    prefixes = Enum.map(prefixes, &relative_prefix!(&1, project))

    selection_opts =
      [
        prefixes: prefixes,
        from: opts |> Keyword.get_values(:from) |> Enum.flat_map(&resolve!(project, &1)),
        to: opts |> Keyword.get_values(:to) |> Enum.flat_map(&resolve!(project, &1))
      ] ++ Keyword.take(opts, [:depth, :incoming, :all_functions, :external])

    Mermaid.write(project, Selection.select(project, selection_opts), opts)
  end

  # Prefixes are compared with the paths `mix xref` gives, which are relative to the app's directory.
  defp relative_prefix!(prefix, project) do
    # The app's directory itself (`.`) is the empty prefix, which every file starts with.
    relative =
      case Path.relative_to(Path.expand(prefix), project.root) do
        "." -> ""
        relative -> if String.ends_with?(prefix, "/"), do: relative <> "/", else: relative
      end

    if not Enum.any?(Map.keys(project.file_edges), &String.starts_with?(&1, relative)) do
      Mix.raise("No file of the project starts with #{prefix}")
    end

    relative
  end

  defp resolve!(project, spec) do
    with {:ok, parsed} <- Project.parse_spec(spec),
         {:ok, keys} <- Project.resolve(project, parsed) do
      keys
    else
      :error -> Mix.raise("Can't read #{inspect(spec)}: give MOD.FUN/ARITY or MOD.FUN")
      {:error, message} -> Mix.raise(message)
    end
  end
end
