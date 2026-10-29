defmodule Sample.Repo do
  use Sample.Gen

  def save(record), do: record |> changeset() |> insert()
end
