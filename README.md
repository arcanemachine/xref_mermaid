# XrefMermaid

A Mix task that draws part of an Elixir project's file dependency graph (from `mix xref graph`) as a Mermaid
flowchart: one subgraph per directory, one subgraph per file holding its public functions (collapsed by default),
and one arrow per dependency (`==>` compile, `-->` export, `-.->` runtime).

It installs as a Mix archive, so it runs in any project without being one of its dependencies:

```bash
mix archive.install github <user>/xref_mermaid   # or, from a checkout: mix archive.build && mix archive.install
```

## Usage

From the project to draw:

```bash
mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd
```

The arguments are path prefixes: the slice is every file whose path starts with one of them. The chart shows the
slice and the files it depends on.

- `-o`, `--output`: the file to write (required)
- `--incoming`: also shows the files that depend on the slice
- `--expanded`: draws each file's functions open instead of collapsed

A collapsed file is a `<id>@{ view: collapsed }` line after its subgraph's `end` (Mermaid 12.2 supports it, though its
docs don't mention it yet); delete the line to open it. Regenerating overwrites the output file.
