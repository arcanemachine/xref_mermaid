defmodule XrefMermaid.Source do
  @moduledoc """
  Fingerprints functions by their source code, to tell whether a function changed between two states of a project.

  The source is used rather than the compiled code: a compiled function also changes when a struct it builds gains a
  field, or a macro or attribute it uses changes, though the function itself was not edited.
  """

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  @doc """
  Returns `%{key => hash}` for the functions of `project` in `files` whose `def`s are found in their source file:
  a hash of those `def`s (heads, guards, defaults and bodies) without line numbers, so a function edited elsewhere in
  the file, a comment or a blank line leaves it as it was. A function's `def`s are the ones on its definition's or
  clauses' lines with its name and full arity. Generated functions and functions with no such `def` (a
  `defdelegate`, a `def` written by a macro) get none.
  """
  def hashes(project, files) do
    functions_in = project.functions |> Map.values() |> Enum.group_by(& &1.file)

    for file <- files,
        functions = Map.get(functions_in, file, []),
        functions != [],
        defs = defs(Path.join(project.root, file)),
        function <- functions,
        not function.generated?,
        nodes =
          for(
            {line, name, arity, node} <- defs,
            line in Map.get(function, :lines, [function.line]),
            name == function.name and arity == List.last(function.arities),
            do: node
          ),
        nodes != [],
        into: %{},
        do: {function.key, hash(nodes)}
  end

  # The file's `def`s as `{line, name, arity, node}`, the node without metadata; none when the file can't be read.
  defp defs(path) do
    with {:ok, text} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(text, file: path) do
      {_, defs} =
        Macro.prewalk(ast, [], fn
          {kind, meta, [head | _]} = node, defs when kind in @def_kinds ->
            case name_arity(head) do
              {name, arity} -> {node, [{meta[:line], name, arity, strip(node)} | defs]}
              nil -> {node, defs}
            end

          node, defs ->
            {node, defs}
        end)

      defs
    else
      _ -> []
    end
  end

  defp name_arity({:when, _, [head | _]}), do: name_arity(head)
  defp name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp name_arity({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp name_arity(_), do: nil

  defp strip(node) do
    Macro.prewalk(node, fn
      {form, meta, args} when is_list(meta) -> {form, [], args}
      other -> other
    end)
  end

  defp hash(nodes) do
    :erlang.md5(:erlang.term_to_binary(nodes, minor_version: 2))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
