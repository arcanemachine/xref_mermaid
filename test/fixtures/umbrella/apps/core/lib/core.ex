defmodule Core do
  def hello, do: greet(:world)

  defp greet(name), do: {:hello, name}
end
