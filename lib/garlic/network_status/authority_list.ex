defmodule Garlic.NetworkStatus.AuthorityList do
  @moduledoc false

  defmacro default() do
    "./priv/auth_dirs.inc"
    |> File.read!()
    |> String.replace(~s("\n), ~s("<>))
    |> then(&"[#{&1}]")
    |> Code.eval_string()
    |> elem(0)
    |> Enum.map(&parse_authority_line/1)
    |> Macro.escape()
  end

  defp parse_authority_line(line) do
    {authority, properties} =
      line
      |> String.split(" ")
      |> Stream.map(fn
        "orport=" <> onion_port ->
          {[], [onion_port: String.to_integer(onion_port)]}

        "bridge" ->
          {[], [bridge: true]}

        "v3ident=" <> identity ->
          {[], [identity: Base.decode16!(identity)]}

        "ipv6=" <> ipv6 ->
          {[], [ipv6: Garlic.Util.parse_ip_address(ipv6)]}

        value ->
          {[value], []}
      end)
      |> Enum.unzip()

    [nickname, ipv4 | fingerprint] = List.flatten(authority)

    [ipv4, directory_port] = String.split(ipv4, ":")

    struct(
      Garlic.Router,
      properties
      |> List.flatten()
      |> Enum.into(%{
        nickname: nickname,
        ipv4: Garlic.Util.parse_ip_address(ipv4),
        directory_port: String.to_integer(directory_port),
        fingerprint:
          fingerprint
          |> Enum.join()
          |> Base.decode16!()
      })
    )
  end
end
