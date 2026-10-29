# XrefMermaid

A Mix task that draws part of an Elixir project as a Mermaid flowchart: its files (from `mix xref graph`), their
functions, and the calls between those functions (from the compiled modules).

It installs as a Mix archive, so it runs in any project without being one of its dependencies. It supports Elixir
1.15 and later. An archive is compiled by the Elixir that installs it, so install it once per Elixir version you use:

```bash
mix archive.install github <user>/xref_mermaid   # or, from a checkout: mix archive.build && mix archive.install
```

## Usage

From the project to draw (in an umbrella project, from the app's directory):

```bash
mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd
```

The arguments are path prefixes: the slice is every file whose path starts with one of them. The chart shows the
slice and the files it depends on:

- Each directory is a subgraph, and each file a subgraph of its functions (private ones with a dashed border).
  A function with default arguments is one node (`place/1..2`). Functions that `use` generates are left out.
- Each call a slice function makes to a function on the chart is an arrow (`-->`).
- A file dependency with no call behind it (a struct, a compile-time use, a call to a generated function) is a
  labeled arrow between the files: `== compile ==>`, `-. export .->` or `-. runtime .->`.

Options:

- `-o`, `--output`: the file to write (required)
- `--incoming`: also shows the files that depend on the slice, and their calls into it
- `--expanded`: opens every file (by default, slice files are open and the others collapsed)
- `--collapsed`: collapses every file

A collapsed file is a `<id>@{ view: collapsed }` line after its subgraph's `end` (Mermaid 12.2 supports it, though its
docs don't mention it yet); delete the line to open it, add one to close it. Regenerating overwrites the output file.

## Where the data comes from

- Files and their dependency kinds: `mix xref graph --format dot`.
- Functions and calls: the Elixir debug info in the project's `.beam` files, which Mix keeps by default. Calls
  through a variable (`apply/3`, `module.fun()`) can't be resolved, and code a macro expands to counts as the
  caller's.
