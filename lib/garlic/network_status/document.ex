defmodule Garlic.NetworkStatus.Document do
  @moduledoc "Network status document"

  @spec parse(binary) :: {:ok, Garlic.NetworkStatus.t()} | {:error, atom}
  def parse(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.split(&1, " "))
    |> parse_tokens(%Garlic.NetworkStatus{})
  end

  defp parse_tokens([["params" | params] | tail], network_status) do
    parse_tokens(tail, %{network_status | params: split_pairs(params)})
  end

  defp parse_tokens([["valid-after", date, time] | tail], network_status) do
    with {:ok, valid_after, _} <- DateTime.from_iso8601("#{date}T#{time}Z") do
      parse_tokens(tail, %{network_status | valid_after: DateTime.to_unix(valid_after)})
    end
  end

  defp parse_tokens([["valid-until", date, time] | tail], network_status) do
    with {:ok, valid_until, _} <- DateTime.from_iso8601("#{date}T#{time}Z") do
      parse_tokens(tail, %{network_status | valid_until: DateTime.to_unix(valid_until)})
    end
  end

  defp parse_tokens([["fresh-until", date, time] | tail], network_status) do
    with {:ok, fresh_until, _} <- DateTime.from_iso8601("#{date}T#{time}Z") do
      parse_tokens(tail, %{network_status | fresh_until: DateTime.to_unix(fresh_until)})
    end
  end

  defp parse_tokens([["shared-rand-previous-value", _, value] | tail], network_status) do
    parse_tokens(tail, %{network_status | previous_shared_random: Base.decode64!(value)})
  end

  defp parse_tokens([["shared-rand-current-value", _, value] | tail], network_status) do
    parse_tokens(tail, %{network_status | current_shared_random: Base.decode64!(value)})
  end

  defp parse_tokens([["r" | _] | _] = data, network_status) do
    {:ok, %{network_status | routers: parse_routers(data, network_status)}}
  end

  defp parse_tokens([_ | tail], network_status) do
    parse_tokens(tail, network_status)
  end

  defp parse_routers(
         [
           ["r", nickname, fingerprint, digest, _, _, ipv4, onion_port, directory_port] | tail
         ],
         network_status
       ) do
    %Garlic.Router{
      nickname: nickname,
      fingerprint: Base.decode64!(fingerprint, padding: false),
      digest: Base.decode64!(digest, padding: false),
      ipv4: Garlic.Util.parse_ip_address(ipv4),
      onion_port: String.to_integer(onion_port),
      directory_port: String.to_integer(directory_port)
    }
    |> parse_router_description(tail, network_status)
  end

  defp parse_routers([_ | tail], network_status) do
    parse_routers(tail, network_status)
  end

  defp parse_routers([], _), do: []

  defp parse_router_description(router, [["s" | flags] | tail], network_status) do
    router.flags
    |> put_in(MapSet.new(flags))
    |> parse_router_description(tail, network_status)
  end

  defp parse_router_description(router, [["w" | options] | tail], network_status) do
    router.bandwidth
    |> put_in(split_pairs(options))
    |> parse_router_description(tail, network_status)
  end

  defp parse_router_description(router, [["id", "ed25519", identity] | tail], network_status) do
    parse_router_description(
      %{router | identity: Base.decode64!(identity, padding: false)},
      tail,
      network_status
    )
  end

  defp parse_router_description(router, [[s | _] | tail], network_status)
       when s in ~w(a v pr p) do
    parse_router_description(router, tail, network_status)
  end

  defp parse_router_description(router, tail, network_status) do
    [router | parse_routers(tail, network_status)]
  end

  defp split_pairs([""]), do: %{}

  defp split_pairs(pairs) do
    for string <- pairs, into: %{} do
      [name, value] = String.split(string, "=")
      {name, String.to_integer(value)}
    end
  end
end
