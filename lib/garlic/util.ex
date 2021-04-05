defmodule Garlic.Util do
  @moduledoc false

  @spec parse_ip_address(binary) :: :inet.ip_address()
  def parse_ip_address(binary) do
    binary
    |> String.to_charlist()
    |> :inet.parse_address()
    |> elem(1)
  end

  @spec parse_pem(list(list(binary))) :: {binary, list(list(binary))}
  def parse_pem([["-----BEGIN" | _] | tail]) do
    {data, tail} =
      Enum.split_while(
        tail,
        fn
          ["-----END" | _] -> false
          _ -> true
        end
      )

    data =
      data
      |> IO.iodata_to_binary()
      |> Base.decode64!()

    {data, tl(tail)}
  end
end
