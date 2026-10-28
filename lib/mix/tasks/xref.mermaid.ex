defmodule Mix.Tasks.Xref.Mermaid do
  @shortdoc "Writes the project's xref file graph as a Mermaid flowchart"

  @moduledoc """
  Writes a Mermaid flowchart of the files under the given path prefixes and their dependencies.

      mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd

  ## Options

    * `-o`, `--output` - the file to write (required)
    * `--incoming` - also shows the files that depend on the slice
    * `--expanded` - draws each file's functions open instead of collapsed

  Regenerating overwrites the output file.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, prefixes} =
      OptionParser.parse!(argv,
        strict: [output: :string, incoming: :boolean, expanded: :boolean],
        aliases: [o: :output]
      )

    output = opts[:output] || Mix.raise("Missing --output")
    if prefixes == [], do: Mix.raise("Give at least one path prefix")

    # Compiling the project prunes the code path, archives included, so this archive's modules load first.
    Code.ensure_all_loaded!([XrefMermaid, XrefMermaid.PublicFunctions])

    json_path =
      Path.join(System.tmp_dir!(), "xref_mermaid_#{System.unique_integer([:positive])}.json")

    graph =
      try do
        Mix.Task.run("xref", ~w(graph --format json --output #{json_path}))
        json_path |> File.read!() |> JSON.decode!()
      after
        File.rm(json_path)
      end

    File.write!(output, XrefMermaid.render(graph, prefixes, &File.read!/1, opts))
    Mix.shell().info("Wrote #{output}")
  end
end
