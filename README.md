# XrefMermaid

A Mix task that draws part of an Elixir project as a Mermaid flowchart: its files, their functions, and the calls
between them. Start from files, from a function (what it calls), or from callers (what calls it), or draw the
directories of the whole project.

It installs as a Mix archive, so it runs in any project without being one of its dependencies. It supports Elixir
1.15 and later. An archive is compiled by the Elixir that installs it, so install it once per Elixir version you use:

```bash
mix archive.install github <user>/xref_mermaid   # or, from a checkout: mix archive.build && mix archive.install
```

## Usage

From the project to draw (in an umbrella project, from the app's directory):

```bash
mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd   # these files
mix xref.mermaid --from MyApp.Orders.place/2 --depth 4 -o place.mmd     # what place/2 calls, 4 calls deep
mix xref.mermaid --to MyApp.Repo.insert -o inserts.mmd                  # what calls insert, at any arity
mix xref.mermaid --overview --level 3 -o overview.mmd                   # the project's directories
```

### What to draw

Path prefixes, `--from` and `--to` combine: the chart shows everything they reach.

- Path prefixes (arguments): every function in the files whose paths start with one (the slice), the calls they
  make, and the files the slice depends on. A prefix is relative to the app's directory (`./lib/...` and absolute
  paths work too); one that matches no file stops the task.
- `--from MOD.FUN/ARITY`: the calls the function makes, followed `--depth` calls deep (default 3). Leave out
  `/ARITY` for every arity. Repeatable.
- `--to MOD.FUN/ARITY`: the calls made to the function, followed `--depth` calls back. Repeatable.
- `--incoming`: also the calls into the slice, and the files that depend on it.
- `--overview`: instead, one node per directory `--level` deep (default 2: `lib/my_app/`), with an arrow per pair of
  directories labeled with the strongest dependency kind and the number of file dependencies. Files directly in a
  shallower directory form their own node: at level 2, `lib/my_app.ex` is in `lib/*`.

### How to draw it

- `-o`, `--output`: the file to write (required). Regenerating overwrites it.
- `--all-functions`: every function of every shown file, not only the ones calls reach. Files outside the slice then
  start collapsed.
- `--external`: also calls to Elixir modules outside the project (Ecto, Enum...), as leaves. Erlang modules, `Kernel`
  and `String.Chars` are left out: most of those calls are what Kernel's functions and string interpolation compile
  to.
- `--expanded` / `--collapsed`: opens or collapses every file (a file holding a `--from` or `--to` function always
  stays open).
- `--link TEMPLATE`: makes each function a link to its source; `{path}` is the absolute path and `{line}` the
  line, e.g. `vscode://file{path}:{line}`. Mermaid follows links only when the page renders with
  `securityLevel: "loose"` (its default, `"strict"`, turns them off, and a chart can't change it).
- `--legend`: adds a legend.

## Reading the chart

- Each directory is a subgraph; each file is a subgraph of its shown functions (a plain node when none is shown),
  and the slice files are yellow.
- A private function has a dashed border, a generated one (from `use` or another macro) is grey, and a `--from` or
  `--to` function has a red border.
- A function with default arguments is one node (`place/1..2`). In a file with several modules, functions outside
  the main one are labeled with their module (`Line.describe/1`) or protocol (`[impl String.Chars] to_string/1`).
- `-->` is a call. A file dependency with no call behind it (a struct, a compile-time use) is a labeled arrow
  between the files: `== compile ==>`, `-. export .->` or `-. runtime .->`.
- A collapsed file is a `<id>@{ view: collapsed }` line after its subgraph's `end` (Mermaid 12.2 supports it, though
  its docs don't mention it yet); delete the line to open it, add one to close it.

Mermaid draws at most 50,000 characters and 500 arrows by default; the task warns when a chart is over either.

## Where the data comes from

- Files and their dependency kinds: `mix xref graph --format dot`.
- Functions and calls: the Elixir debug info in the project's `.beam` files, which Mix keeps by default. The task
  warns about modules without it.

What it can't see:

- Calls through a variable (`apply/3`, `module.fun()`, a behaviour's or protocol's implementation called through the
  behaviour or protocol): the call stops at what the code names.
- `super(...)` calls in an overridden function.
- Macros: they are expanded before compiling, so a macro never has callers; its use shows as a compile dependency
  between files, and the code it expands to counts as the caller's.

## Development

```bash
mix test                        # unit tests
mix test --include integration  # also builds the archive and runs the task on test/fixtures/sample_app
```
