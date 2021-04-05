defmodule Garlic.Circuit.RelayCell do
  # tor-spec.txt 6.1. Relay cells

  # The payload of each unencrypted RELAY cell consists of:

  #   Relay command           [1 byte]
  #   'Recognized'            [2 bytes]
  #   StreamID                [2 bytes]
  #   Digest                  [4 bytes]
  #   Length                  [2 bytes]
  #   Data                    [Length bytes]
  #   Padding                 [PAYLOAD_LEN - 11 - Length bytes]

  def decode(
        <<2, _::16, stream_id::16, _::binary-size(4), data_length::16,
          data::binary-size(data_length), _::binary>>
      ) do
    {:ok, {stream_id, :data, data}}
  end

  def decode(<<3, _::16, stream_id::16, _::binary-size(4), _::16, reason, _::binary>>) do
    reason =
      Enum.at(
        ~w(misc resolvefailed connectrefused exitpolicy destroy done timeout noroute
         hibernating internal resourcelimit connreset torprotocol notdirectory)a,
        reason - 1
      )

    {:ok, {stream_id, :end, reason}}
  end

  def decode(
        <<4, _::16, stream_id::16, _::binary-size(4), addr::binary-size(4), ttl::32, _::binary>>
      ) do
    {:ok, {stream_id, :connected, 4, addr, ttl}}
  end

  def decode(
        <<4, _::16, stream_id::16, _::binary-size(4), 0::size(4)-unit(4), 6,
          addr::binary-size(16), ttl::32, _::binary>>
      ) do
    {:ok, {stream_id, :connected, 6, addr, ttl}}
  end

  def decode(<<5, _::16, stream_id::16, _::binary>>) do
    {:ok, {stream_id, :sendme}}
  end

  def decode(<<9, _::16, stream_id::16, _::binary-size(4), _::16, reason, _::binary>>) do
    reason =
      Enum.at(
        ~w(none protocol internal requested hibernating resourcelimit connectfailed or_identity
           channel_closed finished timeout destroyed nosuchservice)a,
        reason
      )

    {:ok, {stream_id, :truncated, reason}}
  end

  def decode(
        <<15, _::16, 0::16, _::binary-size(4), 66::16, 64::16, server_public_key::binary-size(32),
          auth::binary-size(32), _::binary>>
      ) do
    {:ok, {0, :extended2, {server_public_key, auth}}}
  end

  def decode(
        <<37, _::16, stream_id::16, _::binary-size(4), _::16, server_public_key::binary-size(32),
          auth::binary-size(32), _::binary>>
      ) do
    {:ok, {stream_id, :rendezvous2, {server_public_key, auth}}}
  end

  def decode(<<39, _::16, stream_id::16, _::binary>>) do
    {:ok, {stream_id, :rendezvous_established}}
  end

  def decode(<<40, _::16, stream_id::16, _::binary-size(4), 3::16, reason::16, _::binary>>) do
    reason = Enum.at(~w(success failure bad_message cannot_relay)a, reason)
    {:ok, {stream_id, :introduce_ack, reason}}
  end

  def decode(<<42, _::16, stream_id::16, _::binary>>) do
    {:ok, {stream_id, :padding_negotiated}}
  end

  def decode(_), do: {:error, :unknown_relay_cell}
end
