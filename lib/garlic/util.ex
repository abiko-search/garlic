defmodule Garlic.Util do
  @moduledoc false

  alias Garlic.Crypto.Ed25519

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

  @spec onion_address_valid?(binary) :: boolean
  def onion_address_valid?(<<address::binary-size(56), ".onion">>) do
    with {:ok, <<pubkey::binary-size(32), checksum::binary-size(2), 3>>} <-
           Base.decode32(String.upcase(address)),
        true <- Ed25519.on_curve?(pubkey),
         <<^checksum::binary-size(2), _::binary>> <-
           :crypto.hash(:sha3_256, [".onion checksum", pubkey, 3]) do
      true
    else
      _ -> false
    end
  end

  def onion_address_valid?(_), do: false
end
