defmodule Garlic.Crypto do
  @moduledoc false
  alias Garlic.Circuit
  alias Garlic.Crypto.Ed25519

  @protoid "ntor-curve25519-sha256-1"

  @spec digest_relay_cell(binary, iodata, :crypto.hash_state()) ::
          {binary, :crypto.hash_state()}
  def digest_relay_cell(head, body, stream_digest) do
    stream_digest =
      stream_digest
      |> :crypto.hash_update(head)
      |> :crypto.hash_update(<<0::size(4)-unit(8)>>)
      |> :crypto.hash_update(body)

    digest =
      stream_digest
      |> :crypto.hash_final()
      |> binary_part(0, 4)

    {digest, stream_digest}
  end

  @spec complete_ntor_handshake(Circuit.t(), binary, binary) ::
          {:ok, Circuit.Hop.t()} | {:error, atom}
  def complete_ntor_handshake(
        %Garlic.Circuit{
          public_key: public_key,
          private_key: private_key,
          routers: [
            %Garlic.Router{
              fingerprint: fingerprint,
              ntor_onion_key: ntor_onion_key
            }
            | _
          ]
        },
        server_public_key,
        auth
      ) do
    secret_input = [
      :crypto.compute_key(:ecdh, server_public_key, private_key, :x25519),
      :crypto.compute_key(:ecdh, ntor_onion_key, private_key, :x25519),
      fingerprint,
      ntor_onion_key,
      public_key,
      server_public_key,
      @protoid
    ]

    key_seed = hmac(:key_extract, secret_input)
    verify = hmac(:verify, secret_input)

    auth_input = [
      verify,
      fingerprint,
      ntor_onion_key,
      server_public_key,
      public_key,
      @protoid,
      "Server"
    ]

    if hmac(:mac, auth_input) == auth do
      <<forward_digest_key::binary-size(20), backward_digest_key::binary-size(20),
        forward_cipher_key::binary-size(16),
        backward_cipher_key::binary-size(16)>> = hkdf_expand(key_seed, 20 * 2 + 16 * 2)

      hop = %Garlic.Circuit.Hop{
        forward_digest: digest_init(forward_digest_key),
        backward_digest: digest_init(backward_digest_key),
        forward_cipher: crypto_init(forward_cipher_key, true),
        backward_cipher: crypto_init(backward_cipher_key, false)
      }

      {:ok, hop}
    else
      {:error, :ntor_handshake}
    end
  end

  @spec blind_public_key(binary, pos_integer, pos_integer) :: binary
  def blind_public_key(public_key, time_period_length, time_period_num) do
    param =
      :crypto.hash(
        :sha3_256,
        [
          "Derive temporary signing key\0",
          public_key,
          Ed25519.base_string(),
          "key-blind",
          <<time_period_num::64, time_period_length::64>>
        ]
      )

    Ed25519.blind_public_key(public_key, param)
  end

  @spec build_subcredential(binary, binary) :: binary
  def build_subcredential(public_key, blinded_public_key) do
    credential = :crypto.hash(:sha3_256, ["credential", public_key])
    :crypto.hash(:sha3_256, ["subcredential", credential, blinded_public_key])
  end

  defp hmac(key, input) do
    :crypto.mac(:hmac, :sha256, "#{@protoid}:#{key}", input)
  end

  defp digest_init(key) do
    :sha
    |> :crypto.hash_init()
    |> :crypto.hash_update(key)
  end

  defp crypto_init(key, encrypt) do
    :crypto.crypto_init(:aes_128_ctr, key, List.duplicate(0, 16), encrypt)
  end

  defp hkdf_expand(key, len) do
    n = Float.ceil(len / 32)

    1..round(n)
    |> Enum.scan("", &:crypto.mac(:hmac, :sha256, key, &2 <> "#{@protoid}:key_expand" <> <<&1>>))
    |> :binary.list_to_bin()
    |> binary_part(0, len)
  end
end
