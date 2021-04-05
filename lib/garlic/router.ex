defmodule Garlic.Router do
  @moduledoc "Router in Tor circuit"

  defstruct [
    :nickname,
    :ipv4,
    :ipv6,
    :onion_port,
    :directory_port,
    :identity,
    :fingerprint,
    :digest,
    :ntor_onion_key,
    flags: MapSet.new(),
    bridge: false,
    bandwidth: %{}
  ]

  @type t() :: %__MODULE__{
          nickname: binary,
          ipv4: :inet.ip4_address(),
          ipv6: :inet.ip6_address(),
          onion_port: pos_integer,
          directory_port: pos_integer,
          identity: binary,
          fingerprint: binary,
          digest: binary,
          ntor_onion_key: binary,
          flags: MapSet.t(),
          bridge: boolean,
          bandwidth: map
        }

  @spec build_link_specifiers(__MODULE__.t()) :: iodata
  def build_link_specifiers(%__MODULE__{
        fingerprint: fingerprint,
        identity: identity,
        ipv4: addr,
        onion_port: onion_port
      }) do
    [
      <<3>>,
      <<0, 6>>,
      Tuple.to_list(addr),
      <<onion_port::16>>,
      <<2, 20, fingerprint::binary>>,
      <<3, 32, identity::binary>>
    ]
  end

  @spec parse_link_specifiers(binary) :: __MODULE__.t()
  def parse_link_specifiers(<<_, data::binary>>) do
    struct(
      %__MODULE__{},
      data
      |> parse_link_specifier()
      |> Enum.into(%{})
    )
  end

  defp parse_link_specifier(<<0, 6, a, b, c, d, port::16, tail::binary>>) do
    tail
    |> parse_link_specifier()
    |> Keyword.put(:ipv4, {a, b, c, d})
    |> Keyword.put(:onion_port, port)
  end

  defp parse_link_specifier(
         <<1, 18, a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, port::16, tail::binary>>
       ) do
    tail
    |> parse_link_specifier()
    |> Keyword.put(:ipv6, {a, b, c, d, e, f, g, h})
    |> Keyword.put(:onion_port, port)
  end

  defp parse_link_specifier(<<2, 20, fingerprint::binary-size(20), tail::binary>>) do
    tail
    |> parse_link_specifier()
    |> Keyword.put(:fingerprint, fingerprint)
  end

  defp parse_link_specifier(<<3, 32, identity::binary-size(32), tail::binary>>) do
    tail
    |> parse_link_specifier()
    |> Keyword.put(:identity, identity)
  end

  defp parse_link_specifier(<<>>), do: []
end
