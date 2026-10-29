defmodule Sample.Totals do
  def total(order), do: order.items |> Enum.map(&price/1) |> Enum.sum()

  defp price(_item), do: 1
end
