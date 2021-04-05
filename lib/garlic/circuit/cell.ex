defmodule Garlic.Circuit.Cell do
  @moduledoc "Tor circuit cell"

  # tor-spec.txt 3. Cell Packet format

  # On a version 1 connection, each cell contains the following
  # fields:

  #     CircID                                [CIRCID_LEN bytes]
  #     Command                               [1 byte]
  #     Payload (padded with padding bytes)   [PAYLOAD_LEN bytes]

  # On a version 2 or higher connection, all cells are as in version 1
  # connections, except for variable-length cells, whose format is:

  #     CircID                                [CIRCID_LEN octets]
  #     Command                               [1 octet]
  #     Length                                [2 octets; big-endian integer]
  #     Payload (some commands MAY pad)       [Length bytes]

  alias Garlic.Circuit

  @type destroy_reason ::
          :none
          | :protocol
          | :internal
          | :requested
          | :hibernating
          | :resourcelimit
          | :connectfailed
          | :or_identity
          | :channel_closed
          | :finished
          | :timeout
          | :destroyed
          | :nosuchservice

  @spec decode(binary) ::
          {:error, atom}
          | {:more, binary}
          | {:ok, {0, :versions}, binary}
          | {:ok, {0, :certs, binary}, binary}
          | {:ok, {0, :auth_challenge}, binary}
          | {:ok, {Circuit.id(), :relay, inner_cell :: binary}, binary}
          | {:ok, {Circuit.id(), :destroy, destroy_reason}, binary}
          | {:ok,
             {0, :netinfo,
              {timestamp :: pos_integer, my_address :: tuple, their_address :: tuple}}, binary}
          | {:ok, {Circuit.id(), :created2, {server_public_key :: binary, auth :: binary}},
             binary}
  def decode(<<circuit_id::32, 3, inner_cell::binary-size(509), tail::binary>>) do
    {:ok, {circuit_id, :relay, inner_cell}, tail}
  end

  def decode(<<circuit_id::32, 4, reason, tail::binary>>) do
    reason =
      Enum.at(
        ~w(none protocol internal requested hibernating resourcelimit connectfailed or_identity
           channel_closed finished timeout destroyed nosuchservice)a,
        reason
      )

    {:ok, {circuit_id, :destroy, reason}, tail}
  end

  def decode(
        <<circuit_id::16, 7, payload_size::size(16), _::binary-size(payload_size), tail::binary>>
      ) do
    {:ok, {circuit_id, :versions}, tail}
  end

  def decode(<<circuit_id::32, 8, timestamp::32, tail::binary>>) do
    {[my_address], <<address_count, tail::binary>>} = parse_addresses(1, tail)

    {addresses, _} = parse_addresses(address_count, tail)

    {:ok, {circuit_id, :netinfo, {timestamp, my_address, addresses}}, ""}
  end

  def decode(
        <<circuit_id::32, 11, 64::16, server_public_key::binary-size(32), auth::binary-size(32),
          _::binary>>
      ) do
    {:ok, {circuit_id, :created2, {server_public_key, auth}}, ""}
  end

  def decode(
        <<circuit_id::32, 129, payload_size::size(16), payload::binary-size(payload_size),
          tail::binary>>
      ) do
    <<certs_count, data::binary>> = payload

    {certs, <<>>} = parse_certs(certs_count, data)

    {:ok, {circuit_id, :certs, Enum.into(certs, %{})}, tail}
  end

  def decode(
        <<circuit_id::32, 130, payload_size::size(16), _::binary-size(payload_size),
          tail::binary>>
      ) do
    {:ok, {circuit_id, :auth_challenge}, tail}
  end

  def decode(buffer) when byte_size(buffer) > 509, do: {:error, :unknown_cell}

  def decode(buffer), do: {:more, buffer}

  defp parse_addresses(0, tail), do: {[], tail}

  defp parse_addresses(
         count,
         <<type, address_length::size(8), addresses::binary-size(address_length), tail::binary>>
       ) do
    {other_addresses, tail} = parse_addresses(count - 1, tail)
    {[{type, addresses} | other_addresses], tail}
  end

  defp parse_certs(0, tail), do: {[], tail}

  defp parse_certs(
         count,
         <<type, cert_length::size(16), cert::binary-size(cert_length), tail::binary>>
       ) do
    {other_certs, tail} = parse_certs(count - 1, tail)
    {[{type, cert} | other_certs], tail}
  end
end
