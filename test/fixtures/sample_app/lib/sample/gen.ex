defmodule Sample.Gen do
  defmacro __using__(_opts) do
    quote do
      def changeset(record), do: record
      def insert(record), do: {:ok, record}
    end
  end
end
