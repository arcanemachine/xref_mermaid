defmodule XrefMermaid.Beam do
  @moduledoc """
  Reads a compiled module's functions and the calls each one makes from the Elixir debug info in its `.beam`
  file, which Mix keeps by default.
  """

  @doc """
  Returns `%{module: module, file: absolute_path, line: line, impl: impl, functions: functions, calls: calls}`, or
  `nil` when `binary` (a `.beam` file's content) has no Elixir debug info. With `details: true`, functions also get
  their docs and specs.

  `line` is the line of the module's `defmodule`. `impl` is `{protocol, for}` for a protocol implementation, and
  `nil` for any other module.

  `functions` holds `%{name: name, arities: [arity], kind: kind, line: line, generated?: boolean, doc: doc, specs:
  specs}`, one per definition in file order: a function with default arguments is one entry with several arities.
  `kind` is `:def`, `:defp`, `:defmacro` or `:defmacrop`. `generated?` marks functions that `use` or another macro
  has defined. `doc` is the `@doc` text (`nil` without one) and `specs` the `@spec`s as text, short for a label: without
  the function's name, and with module names cut to their last part (`(Order.t()) :: :ok`). Functions named like `__struct__` are left out.

  `calls` holds `{{name, arity}, {module, name, arity}}`: the caller in this module and the function called,
  once per pair, recursion left out. Calls through a variable (`apply/3`, `module.fun()`) can't be resolved.
  """
  def read(binary, opts \\ []) do
    with {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(binary, [:debug_info]),
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

      {docs, specs} = if opts[:details], do: {docs(binary), specs(binary)}, else: {%{}, %{}}

      functions =
        for {{name, arity}, kind, meta, _} <- definitions,
            not Map.has_key?(full_arity_of, {name, kind, arity}) do
          arities = Enum.to_list((arity - Keyword.get(meta, :defaults, 0))..arity)

          %{
            name: name,
            arities: arities,
            kind: kind,
            line: meta[:line],
            generated?: meta[:context] != nil,
            doc: docs[{name, arity}],
            # A function with default arguments may have a spec for each arity; the full arity's comes first.
            specs:
              arities
              |> Enum.reverse()
              |> Enum.flat_map(&Map.get(specs, {name, kind in [:defmacro, :defmacrop], &1}, []))
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

  # Returns `%{{name, arity} => text}` for the functions and macros with a `@doc` (not `@doc false`).
  defp docs(binary) do
    case :beam_lib.chunks(binary, [~c"Docs"]) do
      {:ok, {_, [{~c"Docs", chunk}]}} ->
        {:docs_v1, _, _, _, _, _, entries} = :erlang.binary_to_term(chunk)

        for {{kind, name, arity}, _, _, %{} = doc, _} <- entries,
            kind in [:function, :macro],
            text = doc["en"] || doc |> Map.values() |> List.first(),
            into: %{},
            do: {{name, arity}, text}

      _ ->
        %{}
    end
  end

  # Returns `%{{name, macro?, arity} => [spec text]}`.
  defp specs(binary) do
    case Code.Typespec.fetch_specs(binary) do
      {:ok, specs} ->
        for {{name, arity}, specs} <- specs, into: %{} do
          # A macro's spec is stored as `MACRO-name`, with the caller's environment as an extra first argument.
          case Atom.to_string(name) do
            "MACRO-" <> macro ->
              macro = String.to_atom(macro)
              {{macro, true, arity - 1}, Enum.map(specs, &spec_text(macro, &1, true))}

            _ ->
              {{name, false, arity}, Enum.map(specs, &spec_text(name, &1, false))}
          end
        end

      :error ->
        %{}
    end
  end

  defp spec_text(name, spec, macro?) do
    quoted = Code.Typespec.spec_to_quoted(name, spec)
    quoted = if macro?, do: drop_caller(quoted), else: quoted

    text =
      quoted
      |> Macro.prewalk(fn
        {:__aliases__, meta, parts} -> {:__aliases__, meta, [List.last(parts)]}
        module when is_atom(module) -> short_module(module)
        node -> node
      end)
      # On one line, however long.
      |> Code.quoted_to_algebra()
      |> Inspect.Algebra.format(:infinity)
      |> IO.iodata_to_binary()
      |> String.split()
      |> Enum.join(" ")

    # An operator's spec (`left <~> right :: ...`) keeps its name, which sits between the arguments.
    if String.starts_with?(text, "#{name}("),
      do: String.replace_prefix(text, Atom.to_string(name), ""),
      else: text
  end

  defp drop_caller({:when, meta, [spec, guards]}), do: {:when, meta, [drop_caller(spec), guards]}

  defp drop_caller({:"::", meta, [{name, head_meta, [_caller | args]}, result]}),
    do: {:"::", meta, [{name, head_meta, args}, result]}

  defp short_module(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ ->
        {:__aliases__, [], [atom |> Module.split() |> List.last() |> String.to_atom()]}

      _ ->
        atom
    end
  end

  defp special?(name) do
    name = Atom.to_string(name)
    String.starts_with?(name, "__") and String.ends_with?(name, "__")
  end

  # Calls are taken after their arguments, in the order the code runs them: `x |> f() |> g()`, compiled to
  # `g(f(x))`, calls `f/1` first.
  defp calls_in(ast, module, defined) do
    {_, calls} =
      Macro.traverse(
        ast,
        [],
        fn
          # A capture is replaced by `:ok`, so the capture's inner call node isn't read again as a call with no
          # arguments.
          {:&, _, [{:/, _, [{{:., _, [callee, name]}, _, []}, arity]}]}, calls
          when is_atom(callee) ->
            {:ok, [{callee, name, arity} | calls]}

          {:&, _, [{:/, _, [{name, _, context}, arity]}]}, calls when is_atom(context) ->
            {:ok, [{module, name, arity} | calls]}

          node, calls ->
            {node, calls}
        end,
        fn
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
        end
      )

    Enum.reverse(calls)
  end
end
