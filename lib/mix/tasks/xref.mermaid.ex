defmodule Mix.Tasks.Xref.Mermaid do
  @shortdoc "Writes the project's files and function calls as a Mermaid flowchart"

  @moduledoc """
  Writes a Mermaid flowchart of the files under the given path prefixes, the files they depend on, and the calls
  between their functions.

      mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd

  In an umbrella project, run it from the app's directory.

  ## Options

    * `-o`, `--output` - the file to write (required)
    * `--incoming` - also shows the files that depend on the slice, and their calls into it
    * `--expanded` - opens every file (by default, slice files are open and the others collapsed)
    * `--collapsed` - collapses every file

  Regenerating overwrites the output file.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, prefixes} =
      OptionParser.parse!(argv,
        strict: [output: :string, incoming: :boolean, expanded: :boolean, collapsed: :boolean],
        aliases: [o: :output]
      )

    output = opts[:output] || Mix.raise("Missing --output")
    if prefixes == [], do: Mix.raise("Give at least one path prefix")

    # Compiling the project prunes the code path, archives included, so this archive's modules load first.
    Code.ensure_all_loaded!([XrefMermaid, XrefMermaid.Beam, XrefMermaid.DotGraph])

    dot_path =
      Path.join(System.tmp_dir!(), "xref_mermaid_#{System.unique_integer([:positive])}.dot")

    graph =
      try do
        Mix.Task.run("xref", ~w(graph --format dot --output #{dot_path}))
        dot_path |> File.read!() |> XrefMermaid.DotGraph.parse()
      after
        File.rm(dot_path)
      end

    modules =
      for beam <- Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam")),
          module = XrefMermaid.Beam.read(beam),
          do: %{module | file: Path.relative_to(module.file, File.cwd!())}

    File.write!(output, XrefMermaid.render(graph, prefixes, modules, opts))
    Mix.shell().info("Wrote #{output}")
  end
end
