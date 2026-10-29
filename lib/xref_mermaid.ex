defmodule XrefMermaid do
  @moduledoc """
  Draws part of an Elixir project as a Mermaid flowchart: its files, their functions and the calls between them.

    * `XrefMermaid.Project` loads the project: files from `mix xref graph` (`XrefMermaid.DotGraph`), functions and
      calls from the compiled modules (`XrefMermaid.Beam`).
    * `XrefMermaid.Selection` picks what to draw.
    * `XrefMermaid.Mermaid` writes it.

  `mix xref.mermaid` runs the three.
  """
end
