defmodule XrefMermaid.Beam do
  @moduledoc """
  Reads a compiled module's functions and the calls each one makes from the Elixir debug info in its `.beam`
  file, which Mix keeps by default.
  """

  @doc """
  Returns `%{module: module, file: absolute_path, line: line, impl: impl, functions: functions, calls: calls}`, or
  `nil` when `beam` (a charlist path or the module's binary) has no Elixir debug info.

  `line` is the line of the module's `defmodule`. `impl` is `{protocol, for}` for a protocol implementation, and
  `nil` for any other module.

  `functions` holds `%{name: name, arities: [arity], kind: kind, line: line, generated?: boolean}`, one per
  definition in file order: a function with default arguments is one entry with several arities. `kind` is `:def`,
  `:defp`, `:defmacro` or `:defmacrop`. `generated?` marks functions that `use` or another macro has defined.
  Functions named like `__struct__` are left out.

  `calls` holds `{{name, arity}, {module, name, arity}}`: the caller in this module and the function called,
  once per pair, recursion left out. Calls through a variable (`apply/3`, `module.fun()`) can't be resolved.
  """
  def read(beam) do
    with {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam, [:debug_info]),
         {:ok, info} <- backend.debug_info(:elixir_v1, module, data, []) do
      # A protocol implementation answers `__impl__(:protocol)` and `__impl__(:for)`.
      impl =
        for {{:__impl__, 1}, _, _, clauses} <- info.definitions,
            {_, [key], _, value} <- clauses,
            key in [:protocol, :for],
            into: %{},
            do: {key, value}

      # Elixir 1.20 gives the module's line as `anno` (`{line, column}`), earlier versions as `line`.
      line =
        case Map.get(info, :anno, Map.get(info, :line)) do
          {line, _column} -> line
          line -> line
        end

      definitions = Enum.reject(info.definitions, fn {{name, _}, _, _, _} -> special?(name) end)
      defined = MapSet.new(definitions, &elem(&1, 0))

      # The definition with all the arguments carries `defaults: n`; the n lower arities belong to the definition.
      # Elixir 1.20 marks those lower arities as generated; the mark is ignored, as the lower arities come from the
      # written function.
      full_arity_of =
        for {{name, arity}, kind, meta, _} <- definitions,
            defaults = meta[:defaults],
            lower <- (arity - defaults)..(arity - 1)//1,
            into: %{},
            do: {{name, kind, lower}, arity}

      functions =
        for {{name, arity}, kind, meta, _} <- definitions,
            not Map.has_key?(full_arity_of, {name, kind, arity}) do
          %{
            name: name,
            arities: Enum.to_list((arity - Keyword.get(meta, :defaults, 0))..arity),
            kind: kind,
            line: meta[:line],
            generated?: meta[:context] != nil
          }
        end
        |> Enum.sort_by(&{&1.line, &1.arities})

      calls =
        for {{name, arity}, _, _, clauses} <- definitions,
            {_meta, args, guards, body} <- clauses,
            {_, callee_name, _} = callee <- calls_in([args, guards, body], module, defined),
            callee != {module, name, arity},
            not special?(callee_name),
            uniq: true,
            do: {{name, arity}, callee}

      %{
        module: module,
        file: info.file,
        line: line,
        impl: if(map_size(impl) == 2, do: {impl.protocol, impl.for}),
        functions: functions,
        calls: calls
      }
    else
      _ -> nil
    end
  end

  defp special?(name) do
    name = Atom.to_string(name)
    String.starts_with?(name, "__") and String.ends_with?(name, "__")
  end

  defp calls_in(ast, module, defined) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        # A capture is replaced by `:ok`, so the capture's inner call node isn't read again as a call with no
        # arguments.
        {:&, _, [{:/, _, [{{:., _, [callee, name]}, _, []}, arity]}]}, calls when is_atom(callee) ->
          {:ok, [{callee, name, arity} | calls]}

        {:&, _, [{:/, _, [{name, _, context}, arity]}]}, calls when is_atom(context) ->
          {:ok, [{module, name, arity} | calls]}

        {{:., _, [callee, name]}, _, args} = node, calls
        when is_atom(callee) and is_atom(name) and is_list(args) ->
          {node, [{callee, name, length(args)} | calls]}

        # A local call; special forms (`case`, `=`, ...) share this shape and aren't among the module's functions.
        {name, _, args} = node, calls when is_atom(name) and is_list(args) ->
          if {name, length(args)} in defined,
            do: {node, [{module, name, length(args)} | calls]},
            else: {node, calls}

        node, calls ->
          {node, calls}
      end)

    Enum.reverse(calls)
  end
end
