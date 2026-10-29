defmodule Sample.Orders do
  defstruct [:items]

  def place(order, opts \\ []) do
    if valid?(order), do: order |> Sample.Repo.save() |> finish(opts), else: valid!(order)
  end

  def valid?(order), do: order.items != []
  def valid!(order), do: raise(ArgumentError, inspect(order))

  def left <~> right, do: {left, right}

  def receipt(order), do: %Sample.Receipt{total: total(order)}

  def paths, do: {Sample.A.B.run(), Sample.AB.run()}

  def label(order), do: Enum.map(order.items, &Sample.Orders.Line.describe/1)

  defdelegate total(order), to: Sample.Totals

  defp finish(order, _opts), do: order

  defmodule Line do
    def describe(item), do: to_string(item)
  end
end

defimpl String.Chars, for: Sample.Orders do
  def to_string(order), do: "order #{length(order.items)}"
end
