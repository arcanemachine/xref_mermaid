# XrefMermaid

A Mix task that draws part of an Elixir project as a Mermaid flowchart: its files, their functions, and the calls
between them. Start from files, from a function (what it calls), or from a function's callers (what calls it), or
draw the directories of the whole project.

It installs as a Mix archive, so it runs in any project without being one of its dependencies. It supports Elixir
1.15 and later. An archive is compiled by the Elixir that installs it, so install it once per Elixir version you use:

```bash
mix archive.install github arcanemachine/xref_mermaid   # or, from a checkout: mix archive.build && mix archive.install
mix archive.install hex xref_mermaid                    # once it's published on Hex
```

## Usage

From the project to draw. In an umbrella project, from the umbrella root to read every app (paths then start with
`apps/<app>/`), or from an app's directory to read only that app:

```bash
mix xref.mermaid lib/my_app/orders.ex lib/my_app/orders/ -o orders.mmd   # these files
mix xref.mermaid --from MyApp.Orders.place/2 --depth 4 -o place.mmd     # what place/2 calls, 4 hops deep
mix xref.mermaid --to MyApp.Repo.insert -o inserts.mmd                  # what calls insert, at any arity
mix xref.mermaid --overview --level 3 -o overview.mmd                   # the project's directories
```

### What to draw

Path prefixes, `--from` and `--to` combine: the chart shows everything they reach.

- Path prefixes (arguments): every non-generated function in the files whose paths start with one (the slice), the calls
  they make, and the files the slice depends on. A prefix is relative to the app's directory (`./lib/...` and absolute
  paths work too); one that matches no file stops the task. A prefix matches as text, so end a directory with `/`:
  `lib/my_app/orders` also matches `lib/my_app/orders_helpers.ex`.
- `--from MOD.FUN/ARITY`: the calls the function makes, followed up to `--depth` hops (default 3). Leave out
  `/ARITY` for every arity. Repeatable.
- `--to MOD.FUN/ARITY`: the calls made to the function, followed up to `--depth` hops back. Repeatable.
  `--from` and `--to` name functions of the project (not of its dependencies); an unknown one stops the task and
  names the closest matches.
- `--exclude PREFIX`: leaves out the files whose paths start with it (matched as text, like path prefixes), and every
  call to or from them, in every mode, `--overview` included. Repeatable. One that matches no file only warns.
- `--incoming`: also the calls into the slice, and the files that depend on it (needs path prefixes).
- `--overview`: instead, one node per directory `--level` deep (default 2: `lib/my_app/`), with an arrow per pair of
  directories labeled with the strongest dependency kind and the number of file dependencies. A file goes with the
  directory named after it, a module with its children: at level 2, `lib/my_app.ex` is in `lib/my_app/`; at level 4,
  `lib/my_app/orders.ex` is in `lib/my_app/orders/*`, with the files directly in `lib/my_app/orders/`. Other files
  directly in a shallower directory form their own node: at level 2, `lib/tools.ex` is in `lib/*`.

### How to draw it

- `-o`, `--output`: the file to write (required). Regenerating overwrites it.
- `--format edges`: instead of a chart, plain text with one sorted line per call (`MyApp.Orders.place/1 ->
  MyApp.Repo.insert/2`, each function named by its lowest arity), for comparing two runs, before and after a
  refactor, without drawing them. It takes what picks the calls (path prefixes, `--from`, `--to`, `--depth`,
  `--incoming`, `--exclude`, `--external`), and none of the drawing options below or `--overview`. The default is
  `--format mermaid`.
- `--modules`: one node per file instead of its functions, labeled with its main module, and one arrow per pair of
  files, labeled with the number of distinct function-to-function calls between them (calls within a file drop out).
  It draws what the selection reaches, so a slice of a few dozen files stays readable where its function chart is
  too big. With `--external`, one node per external module. It takes none of `--all-functions`, `--expanded`,
  `--collapsed`, `--link`, `--details` and `--call-order`. With `--format edges`, one line per pair:
  `MyApp.Orders -> MyApp.Repo 3`.
- `--all-functions`: every non-generated function of every shown file, not only the ones calls reach. With path
  prefixes, the files outside the slice then start collapsed.
- `--external`: also calls to Elixir modules outside the project (Ecto, Enum...), as leaves. Erlang modules,
  `Kernel`, `String.Chars` and `exception/1` are left out: most of those calls are what `Kernel`'s functions, string
  interpolation and `raise` compile to. Even so, a file's calls into libraries are many: `--external` reads best
  with `--from` and a small `--depth`.
- `--expanded` / `--collapsed`: opens or collapses every file (a file holding a `--from` or `--to` function always
  stays open).
- `--link TEMPLATE`: makes each function a link to its source; `{path}` is the URL-encoded absolute path and
  `{line}` the line, e.g. `vscode://file{path}:{line}`. Mermaid follows links only when the page renders with
  `securityLevel: "loose"` (Mermaid's default is `"strict"`, which turns them off, and a chart can't change it).
- `--legend`: adds a legend.
- `--details`: adds two lines under each function's name: its first `@spec` (with `(+N)` when it has more), without
  the name and with module names cut to their last part, and the first paragraph of its `@doc`, each cut to 80
  characters. Labels grow, so it reads best on a few files or a `--from` walk.
- `--call-order`: numbers each function's calls (`-->|1|`) in the order its code first makes them.
- `--direction DIR`: the chart's direction: `LR` (left to right, the default), `RL`, `TB` (top to bottom; `TD` is the
  same) or `BT`. It applies to every chart, `--modules` and `--overview` included.

### What changed

Mark what a commit or a branch added, changed and removed: take a snapshot of the project before, then draw it after
with `--since`. The task doesn't run `git`; check out and compile each state yourself, for example in a throwaway
copy:

```bash
git checkout HEAD~1                                  # the state before (or main, for a whole branch)
mix xref.mermaid --snapshot -o before.snapshot      # the whole project, as it was
git checkout -                                       # back to the change
mix xref.mermaid lib/my_app/orders/ --since before.snapshot --changes changes.txt -o orders.mmd
```

- `--snapshot`: instead of a chart, writes the whole project (files, functions, calls) as text, to compare with
  later. It takes only `-o`.
- `--since SNAPSHOT`: marks what is new since the snapshot: added files and functions (green), changed functions
  (blue) and new calls (green arrows). A function in an added file has no mark of its own; its file has it. With
  `--modules`, a file holding an added or changed function is blue, and an arrow carrying new calls is green and
  counts them (`5 (+2)`: 5 calls, 2 of them new). A new call on a cycle stays red, labeled `+`. A path prefix may
  match only files of the snapshot (a slice the change removed). Not with `--overview` or `--format edges`.
- `--changes FILE`: also writes the changes as text, one sorted line each: `+ file lib/my_app/orders/line.ex`,
  `+ function MyApp.Orders.place/1..2`, `~ function ...` (changed), `+ call MyApp.Orders.place/1 ->
  MyApp.Repo.insert/1`, then what is removed (`- file`, `- function`, `- call`) and a line counting it.
- `--marks colors|labels|both`: how marks show. `colors` (the default) as above; `labels` puts `+` (added) or `~`
  (changed) before a name and `+` on a new call's arrow, with no colors; `both` does both.

What counts:

- A file is known by its path; a function by its module and name, and is the same function as before when it
  shares an arity (adding a default argument to `place/2` doesn't make `place/1..2` new); a call by its two ends. So
  a module moved to another file makes the file new, not its functions, and a renamed function is removed and added.
- A function is changed when its source changed: its `def`s, heads, guards and bodies, not comments, blank lines or
  line numbers. A struct gaining a field, or a macro or attribute it uses changing, doesn't change it. A function
  with no `def` of its own in the source (`defdelegate`, one a macro writes) is never changed, and generated
  functions get no marks.
- Removed files, functions and calls are counted in the files the path prefixes match (a `%%` comment in the chart,
  and a line in the legend); without path prefixes, nothing is counted. They can't be drawn in a chart of the
  change.
- Run both states from the same directory (both at an umbrella root, or both in the same app); the task warns when
  no file of the snapshot is a file of the project.

### Version check

A development feature, which may be removed: with `XREF_MERMAID_VERSION_CHECK=1` set, the task asks GitHub whether
`main` has commits the installed archive wasn't built from, and if so warns and gives the command to reinstall. It
gives up silently on any error (no network, an archive built from a commit GitHub doesn't have, an archive built
without `git`).

## Reading the chart

- Each directory is a subgraph; each file is a subgraph of its shown functions (a plain node when none is shown),
  and the slice files are yellow.
- A private function has a dashed border, a generated one (from `use` or another macro) is grey, and a `--from` or
  `--to` function has a red border.
- A function with default arguments is one node (`place/1..2`). In a file with several modules, the main one is the
  module named after the file, or else the first one defined; functions of the others are labeled with their module
  (`Line.describe/1`), and functions of a protocol implementation with the protocol and type
  (`[impl Inspect for Line] inspect/2`, or `[impl String.Chars] to_string/1` for the main module's own).
- `-->` is a call. A red one is on a cycle of calls between files (over the whole project, not only the part
  drawn), and a thick one goes to a parent module (`MyApp.Orders.Line` to `MyApp.Orders` or `MyApp`, by each file's
  main module): the calls worth a second look. With `--modules`, the same marks are on the arrows between files.
- A file dependency with no call behind it (a struct, a compile-time use) is a labeled arrow between the files:
  `== compile ==>`, `-. export .->` or `-. runtime .->`.
- Node ids are internal: the same file or function can get a different id in another chart (they leave out the
  directory every shown file shares, and a clash adds a `_2`). To compare runs, use `--format edges`.
- A collapsed file is a `<id>@{ view: collapsed }` line after its subgraph's `end` (Mermaid 12.2 supports it, though
  its docs don't mention it yet); delete the line to open it, add one to close it.

Mermaid draws at most 50,000 characters and 500 arrows by default; the task warns when a chart is over either.

## Where the data comes from

- Files and their dependency kinds: `mix xref graph --format dot`.
- Functions and calls: the Elixir debug info in the project's `.beam` files, which Mix keeps by default. The task
  warns about modules without it.
- Docs and specs (`--details`): the `.beam` files' docs chunk and debug info.
- Changed functions (`--since`): the project's source files, parsed.

What it can't see:

- Calls through a variable (`apply/3`, `module.fun()`, a behaviour's or protocol's implementation called through the
  behaviour or protocol): the call stops at what the code names.
- `super(...)` calls in an overridden function.
- In an umbrella project run from an app's directory, the other apps: only that app is read, so callers in the other
  apps are missing (the task warns when `--incoming` or `--to` runs there), and the other apps' functions show only
  as external, with `--external`. Run from the umbrella root, every app is read, and calls between apps show.
- From the umbrella root, file dependencies between apps with no call behind them (a struct, a compile-time use):
  `mix xref graph` lists each app's files on their own. So `--overview` there draws no arrows between apps.
- Macros: they are expanded before compiling, so a macro never has callers; its use shows as a compile dependency
  between files, and the code it expands to counts as the caller's.

## Development

```bash
mix test                        # unit tests
mix test --include integration  # also builds the archive and runs the task on the projects in test/fixtures/
```
