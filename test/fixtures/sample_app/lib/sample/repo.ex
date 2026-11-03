defmodule Sample.Repo do
  use Sample.Gen

  @doc "Saves a record."
  @spec save(Sample.Orders.t()) :: {:ok, Sample.Orders.t()}
  def save(record), do: record |> changeset() |> insert()
end
