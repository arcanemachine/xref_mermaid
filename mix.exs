defmodule XrefMermaid.MixProject do
  use Mix.Project

  @source_url "https://github.com/arcanemachine/xref_mermaid"

  def project do
    [
      app: :xref_mermaid,
      version: "0.1.0",
      elixir: "~> 1.15",
      description: "Draws an Elixir project's files, functions and calls as a Mermaid flowchart.",
      source_url: @source_url,
      package: [licenses: ["MIT"], links: %{"GitHub" => @source_url}],
      # The fixture projects are compiled by the integration test, not loaded as tests.
      test_ignore_filters: [~r{^test/fixtures/}],
      deps: []
    ]
  end

  def application, do: []
end
