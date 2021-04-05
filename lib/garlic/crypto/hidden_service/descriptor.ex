defmodule Garlic.Crypto.HiddenService.Descriptor do
  @moduledoc """
  Parses hidden service descriptor 
  """

  alias Garlic.{Crypto, IntroductionPoint, Router}

  def decode(data, public_key, blinded_public_key) do
    case parse_superencrypted(data) do
      %{"superencrypted" => superencrypted, "revision-counter" => revision_counter} ->
        subcredential = Crypto.build_subcredential(public_key, blinded_public_key)

        secret_input = [
          blinded_public_key,
          subcredential,
          <<revision_counter::64>>
        ]

        try do
          introduction_points =
            superencrypted
            |> decrypt_layer("hsdir-superencrypted-data", secret_input)
            |> String.split("\n")
            |> Enum.map(&String.split(&1, " "))
            |> parse_descriptor()
            |> Enum.into(%{})
            |> Map.get("encrypted")
            |> decrypt_layer("hsdir-encrypted-data", secret_input)
            |> String.split("\n")
            |> Enum.map(&String.split(&1, " "))
            |> parse_plaintext()
            |> Enum.map(&Map.put(&1, :subcredential, subcredential))

          {:ok, introduction_points}
        rescue
          _ -> {:error, :descriptor_format}
        end

      _ ->
        {:error, :descriptor_format}
    end
  end

  defp parse_encrypted(encrypted) do
    encrypted_size = byte_size(encrypted) - 16 - 32

    <<salt::binary-size(16), encrypted::binary-size(encrypted_size), mac::binary-size(32)>> =
      encrypted

    {salt, encrypted, mac}
  end

  defp derive_keys(string_constant, secret_input, salt) do
    <<secret_key::binary-size(32), secret_iv::binary-size(16), mac_key::binary-size(32)>> =
      [secret_input, salt, string_constant]
      |> IO.iodata_to_binary()
      |> Crypto.Keccak.shake256(32 + 16 + 32)

    {secret_key, secret_iv, mac_key}
  end

  defp decrypt_layer(encrypted, string_constant, secret_input) do
    {salt, encrypted, _} = parse_encrypted(encrypted)
    {secret_key, secret_iv, _} = derive_keys(string_constant, secret_input, salt)
    :crypto.crypto_one_time(:aes_256_ctr, secret_key, secret_iv, encrypted, false)
  end

  defp parse_descriptor([[item] | tail])
       when item in ~w(descriptor-signing-key-cert superencrypted encrypted) do
    {data, tail} = Garlic.Util.parse_pem(tail)
    [{item, data} | parse_descriptor(tail)]
  end

  defp parse_descriptor([[item, data] | tail])
       when item in ~w(hs-descriptor descriptor-lifetime revision-counter) do
    [{item, String.to_integer(data)} | parse_descriptor(tail)]
  end

  defp parse_descriptor([_ | tail]), do: parse_descriptor(tail)

  defp parse_descriptor([]), do: []

  defp parse_superencrypted(data) do
    data
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.map(&String.split(&1, " "))
    |> parse_descriptor()
    |> Enum.into(%{})
  end

  defp parse_plaintext([["introduction-point", data] | tail]) do
    router =
      data
      |> Base.decode64!()
      |> Router.parse_link_specifiers()

    parse_introduction_point(%IntroductionPoint{router: router}, tail)
  end

  defp parse_plaintext([_ | tail]), do: parse_plaintext(tail)

  defp parse_plaintext([]), do: []

  defp parse_introduction_point(introduction_point, [["enc-key", "ntor", data] | tail]) do
    introduction_point
    |> Map.put(:encryption_key, Base.decode64!(data))
    |> parse_introduction_point(tail)
  end

  defp parse_introduction_point(introduction_point, [["onion-key", "ntor", data] | tail]) do
    introduction_point
    |> Map.put(:onion_key, Base.decode64!(data))
    |> parse_introduction_point(tail)
  end

  defp parse_introduction_point(introduction_point, [["auth-key"] | tail]) do
    {data, tail} = Garlic.Util.parse_pem(tail)

    introduction_point
    |> Map.put(:authentication_key, Crypto.Certificate.parse(data).certified_key)
    |> parse_introduction_point(tail)
  end

  defp parse_introduction_point(introduction_point, tail) do
    [introduction_point | parse_plaintext(tail)]
  end
end
