defmodule XrefMermaid.Beam do
  @moduledoc """
  Reads a compiled module's functions and the calls each one makes from the Elixir debug info in its `.beam`
  file, which Mix keeps by default.
  """

  @doc """
  Returns `%{module: module, file: absolute_path, impl?: boolean, functions: functions, calls: calls}`, or `nil`
  when `beam` (a charlist path or the module's binary) has no Elixir debug info.

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
      impl? = Enum.any?(info.definitions, &match?({{:__impl__, 1}, _, _, _}, &1))
      definitions = Enum.reject(info.definitions, fn {{name, _}, _, _, _} -> special?(name) end)
      defined = MapSet.new(definitions, &elem(&1, 0))

      # The definition with all the arguments carries `defaults: n`; the n lower arities belong to it. (Elixir 1.20
      # also marks those lower arities as generated, which they aren't: they come from the written function.)
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

      %{module: module, file: info.file, impl?: impl?, functions: functions, calls: calls}
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
        # A capture is replaced by `:ok` so its inner call node isn't read again as a call with no arguments.
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
