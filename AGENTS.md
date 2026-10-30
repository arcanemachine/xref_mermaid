# Agent Instructions — xref_mermaid

What the tool does and every option are in `README.md`. Read it first.

If there is a local agent file (`AGENTS.LOCAL.md`) next to this file, read it too. It adds to the rules in this
file, and where the two differ, the local file wins.

## Layout

- `lib/mix/tasks/xref.mermaid.ex`: the task; parses and checks options, then runs the three modules below.
- `lib/xref_mermaid/project.ex`: loads the project (`mix xref graph` through `dot_graph.ex`, functions and calls from
  `.beam` debug info through `beam.ex`) into one model, independent of any chart.
- `lib/xref_mermaid/selection.ex`: picks what to draw (path slices, `--from`/`--to` walks, the overview).
- `lib/xref_mermaid/mermaid.ex`: writes a selection as Mermaid text (ids, labels, classes, collapse lines, links).

## Rules

- The repository is public and generic: examples and fixtures use made-up names (`MyApp`, `Shop`, `Sample`), never
  code or names from a real project.
- The task runs as a Mix archive, loaded after Mix prunes the code path to compile the project. Keep the code free
  of anything compiled into the archive that breaks on another Elixir version (e.g. regex literals: compile them at
  run time).
- Supported Elixir versions: 1.15 and later. Run the tests on the oldest and newest you can before committing a
  code change.

## Tests

```bash
mix test                        # unit tests
mix test --include integration  # also builds the archive and runs the task on the projects in test/fixtures/
```

The integration tests run `mix` as a separate process, in a temporary directory, the way the task really runs.
