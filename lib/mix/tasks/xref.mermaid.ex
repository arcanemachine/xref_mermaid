defmodule Mix.Tasks.Xref.Mermaid do
  @shortdoc "Writes a Mermaid flowchart of the project's files, functions and calls"

  @moduledoc """
  Writes a Mermaid flowchart of part of the project: files, their functions, and the calls between them, or an
  overview of the whole project.

      mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd
      mix xref.mermaid --from MyApp.Orders.place/2 --depth 4 -o place.mmd
      mix xref.mermaid --to MyApp.Repo.insert -o who_inserts.mmd
      mix xref.mermaid --overview --level 3 -o overview.mmd
      mix xref.mermaid --snapshot -o before.snapshot
      mix xref.mermaid lib/my_app/orders/ --since before.snapshot -o orders.mmd

  In an umbrella project, run it from the umbrella root to read every app (paths start with `apps/<app>/`), or from
  an app's directory to read only that app.

  ## What to draw

  Path prefixes, `--from` and `--to` can be combined; the chart shows everything they reach.

    * path prefixes (arguments, relative to the app's directory) - every non-generated function in the files whose
      paths start with one, the calls those make, and the files they depend on; a prefix matches as text, so end a
      directory with `/` (`lib/my_app/orders` also matches `lib/my_app/orders_helpers.ex`)
    * `--from MOD.FUN/ARITY` - the calls the function makes, followed up to `--depth` hops (repeatable; leave out
      `/ARITY` for every arity)
    * `--to MOD.FUN/ARITY` - the calls made to the function, followed up to `--depth` hops back (repeatable)
    * `--depth N` - hops for `--from` and `--to` (default 3)
    * `--incoming` - also the calls into the path slice and the files that depend on it (with path prefixes)
    * `--exclude PREFIX` - leaves out the files whose paths start with it, and every call to or from them, in
      every mode (repeatable)
    * `--modules` - one node per file instead of its functions, labeled with its main module, and one arrow per
      pair of files, labeled with the number of distinct function-to-function calls between them
    * `--overview` - instead of all the above; takes only `--level` (default 2) and `--exclude`: one node per
      directory `--level` deep, arrows between them

  ## How to draw it

    * `-o`, `--output` - the file to write (required)
    * `--format FORMAT` - `mermaid` (the default) or `edges`: plain text, one sorted line per call
      (`Mod.fun/arity -> Mod.fun/arity`), for diffing; it takes none of the options below but `--external`
    * `--all-functions` - every non-generated function of every shown file, not just the ones calls reach
      (with path prefixes, files outside the slice start collapsed)
    * `--external` - also calls to Elixir modules outside the project, as leaves; Erlang modules, `Kernel`,
      `String.Chars` and `exception/1` are left out, as their calls mostly come from `Kernel`'s functions, string
      interpolation and `raise`. Best with `--from` and a small `--depth`
    * `--expanded` / `--collapsed` - opens or collapses every file, not both (a file holding a `--from` or `--to`
      function stays open)
    * `--link TEMPLATE` - makes each function a link: `{path}` (absolute, URL-encoded) and `{line}`, e.g.
      `vscode://file{path}:{line}`
    * `--legend` - adds a legend
    * `--details` - adds each function's first `@spec` and the first paragraph of its `@doc`, cut short
    * `--call-order` - numbers each function's calls in the order its code makes them

  Regenerating overwrites the output file.

  ## What changed

    * `--snapshot` - instead of a chart, writes the whole project as text to compare with later; takes only `-o`
    * `--since SNAPSHOT` - marks what is added (green), changed (blue) and new calls (green arrows) since the
      snapshot; not with `--overview` or `--format edges`
    * `--changes FILE` - with `--since`, also writes the changes as text, one line each, and the removed counts
    * `--marks MARKS` - with `--since`: `colors` (the default), `labels` (`+` and `~` before names, no colors) or
      `both`

  ## Version check

  A development feature, which may be removed: with `XREF_MERMAID_VERSION_CHECK=1` set, the task warns when GitHub
  has a newer commit than the one the archive was built from.
  """

  use Mix.Task

  alias XrefMermaid.{Changes, Edges, Mermaid, Project, Selection, Snapshot, Source, VersionCheck}

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
          legend: :boolean,
          details: :boolean,
          call_order: :boolean,
          exclude: :keep,
          format: :string,
          modules: :boolean,
          snapshot: :boolean,
          since: :string,
          changes: :string,
          marks: :string
        ],
        aliases: [o: :output]
      )

    check_options!(opts, prefixes)
    output = opts[:output]

    # Compiling the project prunes the code path, archives included, so this archive's modules load first.
    Application.load(:xref_mermaid)
    Code.ensure_all_loaded!(Application.spec(:xref_mermaid, :modules))

    # The check runs before compiling, which prunes the code path of the applications the check uses.
    version_warnings = VersionCheck.warnings()
    {full_project, warnings} = Project.load(details: opts[:details] == true)
    {excludes, exclude_warnings} = excludes(full_project, opts)
    project = Project.exclude(full_project, excludes)

    {text, chart_warnings} =
      cond do
        opts[:snapshot] -> {Snapshot.write(project), []}
        opts[:overview] -> {overview(project, opts), []}
        true -> chart(project, full_project, prefixes, excludes, opts)
      end

    write!(output, text)

    warnings =
      warnings ++
        exclude_warnings ++
        chart_warnings ++
        umbrella_warnings(project, opts) ++
        if(opts[:format] == "edges" or opts[:snapshot],
          do: [],
          else: Mermaid.limit_warnings(text)
        ) ++
        version_warnings

    Enum.each(warnings, &Mix.shell().error("warning: " <> &1))
    Mix.shell().info("Wrote #{output}")
  end

  # An umbrella's apps share its lockfile. Run in an app, only that app is read, so callers in the other apps are
  # missing.
  defp umbrella_warnings(project, opts) do
    in_umbrella? =
      Path.dirname(Path.expand(Mix.Project.config()[:lockfile], project.root)) != project.root

    if in_umbrella? and (opts[:incoming] || Keyword.has_key?(opts, :to)) do
      [
        "this app is part of an umbrella; calls from its other apps aren't read, so their callers are missing " <>
          "(run from the umbrella root to read them)"
      ]
    else
      []
    end
  end

  defp check_options!(opts, prefixes) do
    from_or_to? = Keyword.has_key?(opts, :from) or Keyword.has_key?(opts, :to)

    cond do
      opts[:snapshot] && (prefixes != [] or Keyword.keys(opts) -- [:snapshot, :output] != []) ->
        Mix.raise("--snapshot writes the whole project; it takes only --output")

      opts[:snapshot] ->
        if !opts[:output], do: Mix.raise("Missing --output"), else: :ok

      opts[:since] && (opts[:overview] || opts[:format] == "edges") ->
        Mix.raise("--since goes with a chart, not --overview or --format edges")

      Keyword.has_key?(opts, :changes) and !opts[:since] ->
        Mix.raise("--changes goes with --since")

      Keyword.has_key?(opts, :marks) and !opts[:since] ->
        Mix.raise("--marks goes with --since")

      opts[:marks] not in [nil, "colors", "labels", "both"] ->
        Mix.raise("--marks is colors, labels or both")

      opts[:format] not in [nil, "mermaid", "edges"] ->
        Mix.raise("--format is mermaid or edges")

      opts[:format] == "edges" && opts[:overview] ->
        Mix.raise("--format edges doesn't go with --overview")

      opts[:format] == "edges" &&
          Enum.any?(
            [:all_functions, :expanded, :collapsed, :link, :legend, :details, :call_order],
            &Keyword.has_key?(opts, &1)
          ) ->
        Mix.raise(
          "--format edges takes no drawing options (--all-functions, --expanded, --collapsed, --link, --legend, " <>
            "--details, --call-order)"
        )

      opts[:modules] && opts[:overview] ->
        Mix.raise("--modules doesn't go with --overview")

      opts[:modules] &&
          Enum.any?(
            [:all_functions, :expanded, :collapsed, :link, :details, :call_order],
            &Keyword.has_key?(opts, &1)
          ) ->
        Mix.raise(
          "--modules draws no functions; leave out --all-functions, --expanded, --collapsed, --link, --details " <>
            "and --call-order"
        )

      opts[:expanded] && opts[:collapsed] ->
        Mix.raise("Give --expanded or --collapsed, not both")

      opts[:overview] && (prefixes != [] or from_or_to?) ->
        Mix.raise("--overview draws the whole project; leave out path prefixes, --from and --to")

      opts[:overview] &&
          Enum.any?(
            [
              :depth,
              :incoming,
              :all_functions,
              :external,
              :expanded,
              :collapsed,
              :link,
              :legend,
              :details,
              :call_order
            ],
            &Keyword.has_key?(opts, &1)
          ) ->
        Mix.raise("--overview takes only --level, --exclude and --output")

      !opts[:overview] and prefixes == [] and not from_or_to? ->
        Mix.raise("Give path prefixes, --from, --to or --overview")

      !opts[:output] ->
        Mix.raise("Missing --output")

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

  # An exclusion that matches no file only warns: the same exclusions are often reused across runs.
  defp excludes(project, opts) do
    opts
    |> Keyword.get_values(:exclude)
    |> Enum.map(fn prefix ->
      relative = relative_prefix(prefix, project)

      if matches_file?(project, relative),
        do: {relative, nil},
        else: {relative, "--exclude #{prefix} matches no file of the project"}
    end)
    |> Enum.unzip()
    |> then(fn {excludes, warnings} -> {excludes, Enum.reject(warnings, &is_nil/1)} end)
  end

  defp chart(project, full_project, prefixes, excludes, opts) do
    snapshot = opts[:since] && read_snapshot!(opts[:since])
    prefixes = Enum.map(prefixes, &relative_prefix!(&1, project, snapshot))
    resolve = &resolve!(project, full_project, &1)

    selection_opts =
      [
        prefixes: prefixes,
        from: opts |> Keyword.get_values(:from) |> Enum.flat_map(resolve),
        to: opts |> Keyword.get_values(:to) |> Enum.flat_map(resolve)
      ] ++ Keyword.take(opts, [:depth, :incoming, :all_functions, :external])

    selection = Selection.select(project, selection_opts)

    changes =
      snapshot &&
        Changes.compare(project, snapshot, Source.hashes(project, Map.keys(selection.files)),
          prefixes: prefixes,
          excludes: excludes,
          external: opts[:external] == true
        )

    if path = opts[:changes] do
      write!(path, Changes.list(project, selection, changes))
    end

    selection =
      if opts[:modules],
        do:
          Selection.by_file(
            project,
            selection,
            if(changes, do: changes.new_calls, else: MapSet.new())
          ),
        else: selection

    text =
      if opts[:format] == "edges",
        do: Edges.write(project, selection),
        else:
          Mermaid.write(
            project,
            selection,
            Keyword.drop(opts, [:changes]) ++ [changes: changes]
          )

    {text, if(snapshot, do: Changes.warnings(project, snapshot), else: [])}
  end

  defp read_snapshot!(path) do
    with {:ok, text} <- File.read(path),
         {:ok, snapshot} <- Snapshot.read(text) do
      snapshot
    else
      {:error, reason} when is_atom(reason) ->
        Mix.raise("Can't read #{path}: #{:file.format_error(reason)}")

      {:error, message} ->
        Mix.raise("Can't read #{path} as a snapshot: #{message}")
    end
  end

  defp write!(path, text) do
    with {:error, reason} <- File.write(path, text) do
      Mix.raise("Can't write #{path}: #{:file.format_error(reason)}")
    end
  end

  # With `--since`, a prefix may match only files of the snapshot: a slice the change removed.
  defp relative_prefix!(prefix, project, snapshot) do
    relative = relative_prefix(prefix, project)

    if not matches_file?(project, relative) and
         !(snapshot && Enum.any?(snapshot.files, &String.starts_with?(&1, relative))) do
      Mix.raise("No file of the project starts with #{prefix}")
    end

    relative
  end

  # Prefixes are compared with the paths `mix xref` gives, which are relative to the app's directory.
  defp relative_prefix(prefix, project) do
    # The app's directory itself (`.`) is the empty prefix, which every file starts with.
    case Path.relative_to(Path.expand(prefix), project.root) do
      "." -> ""
      relative -> if String.ends_with?(prefix, "/"), do: relative <> "/", else: relative
    end
  end

  defp matches_file?(project, prefix),
    do: Enum.any?(Map.keys(project.file_edges), &String.starts_with?(&1, prefix))

  # `full_project` is the project before `--exclude`, to say when a function is missing because it was excluded.
  defp resolve!(project, full_project, spec) do
    with {:ok, parsed} <- Project.parse_spec(spec),
         {:ok, keys} <- Project.resolve(project, parsed) do
      keys
    else
      :error ->
        Mix.raise("Can't read #{inspect(spec)}: give MOD.FUN/ARITY or MOD.FUN")

      {:error, message} ->
        with {:ok, parsed} <- Project.parse_spec(spec),
             {:ok, _} <- Project.resolve(full_project, parsed) do
          Mix.raise("#{spec} is in a file left out by --exclude")
        end

        Mix.raise(message)
    end
  end
end
