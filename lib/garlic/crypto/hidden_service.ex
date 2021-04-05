defmodule Garlic.Crypto.HiddenService do
  alias Garlic.{Crypto, Circuit, Router, IntroductionPoint, RendezvousPoint}

  @protoid "tor-hs-ntor-curve25519-sha3-256-1"

  def complete_ntor_handshake(
        %Circuit{
          rendezvous_point: %RendezvousPoint{
            public_key: public_key,
            private_key: private_key,
            introduction_point: %IntroductionPoint{
              authentication_key: authentication_key,
              encryption_key: encryption_key
            }
          }
        },
        server_public_key,
        auth
      ) do
    secret_input = [
      :crypto.compute_key(:ecdh, server_public_key, private_key, :x25519),
      :crypto.compute_key(:ecdh, encryption_key, private_key, :x25519),
      authentication_key,
      encryption_key,
      public_key,
      server_public_key,
      @protoid
    ]

    key_seed = hmac(secret_input, :hs_key_extract)
    verify = hmac(secret_input, :hs_verify)

    auth_input = [
      verify,
      authentication_key,
      encryption_key,
      server_public_key,
      public_key,
      @protoid,
      "Server"
    ]

    if hmac(auth_input, :hs_mac) == auth do
      keys =
        [key_seed, "#{@protoid}:hs_key_expand"]
        |> IO.iodata_to_binary()
        |> Crypto.Keccak.shake256(32 * 2 + 32 * 2)

      <<forward_digest_key::binary-size(32), backward_digest_key::binary-size(32),
        forward_cipher_key::binary-size(32), backward_cipher_key::binary-size(32)>> = keys

      hop = %Circuit.Hop{
        forward_digest: digest_init(forward_digest_key),
        backward_digest: digest_init(backward_digest_key),
        forward_cipher: crypto_init(forward_cipher_key, true),
        backward_cipher: crypto_init(backward_cipher_key, false)
      }

      {:ok, hop}
    else
      {:error, :hs_ntor_handshake}
    end
  end

  def build_introduction(%RendezvousPoint{
        cookie: rendezvous_cookie,
        public_key: public_key,
        private_key: private_key,
        introduction_point: %IntroductionPoint{
          authentication_key: authentication_key,
          encryption_key: encryption_key,
          subcredential: subcredential
        },
        router: %Router{ntor_onion_key: ntor_onion_key} = router
      }) do
    secret_input = [
      :crypto.compute_key(:ecdh, encryption_key, private_key, :x25519),
      authentication_key,
      public_key,
      encryption_key,
      @protoid
    ]

    info = ["#{@protoid}:hs_key_expand", subcredential]

    <<secret_key::binary-size(32), mac_key::binary-size(32)>> =
      [secret_input, "#{@protoid}:hs_key_extract", info]
      |> IO.iodata_to_binary()
      |> Crypto.Keccak.shake256(32 + 32)

    encrypted =
      :crypto.crypto_one_time(
        :aes_256_ctr,
        secret_key,
        <<0::size(16)-unit(8)>>,
        [
          rendezvous_cookie,
          <<0>>,
          <<1, byte_size(ntor_onion_key)::16, ntor_onion_key::binary>>,
          Router.build_link_specifiers(router)
        ],
        true
      )

    payload = [
      <<0::size(20)-unit(8)>>,
      <<2, byte_size(authentication_key)::16, authentication_key::binary>>,
      <<0>>,
      public_key,
      encrypted
    ]

    [payload, hmac(mac_key, payload)]
  end

  def build_index(blinded_public_key, replica, time_period_length, time_period_num) do
    :crypto.hash(
      :sha3_256,
      [
        "store-at-idx",
        blinded_public_key,
        <<replica::64, time_period_length::64, time_period_num::64>>
      ]
    )
  end

  def build_directory_index(identity, shared_random, time_period_length, time_period_num) do
    :crypto.hash(
      :sha3_256,
      [
        "node-idx",
        identity,
        shared_random,
        <<time_period_num::64, time_period_length::64>>
      ]
    )
  end

  def build_disaster_shared_random(time_period_length, time_period_num) do
    :crypto.hash(
      :sha3_256,
      [
        "shared-random-disaster",
        <<time_period_length::64, time_period_num::64>>
      ]
    )
  end

  defp hmac(key, input) when is_atom(input) do
    hmac(key, "#{@protoid}:#{input}")
  end

  defp hmac(key, input) do
    :crypto.hash(:sha3_256, [<<IO.iodata_length(key)::64>>, key, input])
  end

  defp digest_init(key) do
    :sha3_256
    |> :crypto.hash_init()
    |> :crypto.hash_update(key)
  end

  defp crypto_init(key, encrypt) do
    :crypto.crypto_init(:aes_256_ctr, key, List.duplicate(0, 16), encrypt)
  end
end
