defmodule XrefMermaid.PublicFunctions do
  @moduledoc """
  Reads the public functions of an Elixir source file from its code, without compiling it.
  """

  @doc """
  Returns `[{module, name, arity}]` for the `def`, `defmacro` and `defdelegate` heads in `source`,
  one per name and arity, in file order.
  """
  def from_source(source) do
    source |> Code.string_to_quoted!() |> walk(nil, []) |> Enum.reverse() |> Enum.uniq()
  end

  defp walk({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, outer, acc) do
    walk(body, Enum.join(List.wrap(outer) ++ Enum.map(parts, &to_string/1), "."), acc)
  end

  # Code inside `quote` defines functions in other modules (e.g. `__using__/1`).
  defp walk({:quote, _, _}, _module, acc), do: acc

  defp walk({kind, _, [head | _]}, module, acc) when kind in [:def, :defmacro, :defdelegate] do
    case head_name_arity(head) do
      {name, arity} -> [{module, name, arity} | acc]
      nil -> acc
    end
  end

  defp walk({_, _, args}, module, acc) when is_list(args), do: walk(args, module, acc)

  defp walk(list, module, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, module, &2))

  defp walk({left, right}, module, acc), do: walk(right, module, walk(left, module, acc))
  defp walk(_, _module, acc), do: acc

  defp head_name_arity({:when, _, [call | _]}), do: head_name_arity(call)

  defp head_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp head_name_arity({name, _, context}) when is_atom(name) and is_atom(context), do: {name, 0}
  defp head_name_arity(_), do: nil
end
