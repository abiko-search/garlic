defmodule Garlic.Router.Descriptor do
  def parse(text) do
    routers =
      text
      |> String.split("\n")
      |> Enum.map(&String.split(&1, " "))
      |> parse_tokens()

    {:ok, routers}
  end

  defp parse_tokens([["router", nickname | _] | tail]) do
    {router, tail} = parse_router(%{nickname: nickname}, tail)

    [router | parse_tokens(tail)]
  end

  defp parse_tokens([]), do: []

  defp parse_router(router, [[item] | tail])
       when item in ~w(identity-ed25519 onion-key signing-key onion-key-crosscert router-signature) do
    {data, tail} = Garlic.Util.parse_pem(tail)

    router
    |> Map.put(to_atom(item), data)
    |> parse_router(tail)
  end

  defp parse_router(router, [[item, data] | tail])
       when item in ~w(master-key-ed25519 ntor-onion-key router-sig-ed25519) do
    router
    |> Map.put(to_atom(item), Base.decode64!(data, padding: false))
    |> parse_router(tail)
  end

  defp parse_router(router, [["fingerprint" | fingerprint] | tail]) do
    fingerprint =
      fingerprint
      |> Enum.join()
      |> Base.decode16!()

    router
    |> Map.put(:fingerprint, fingerprint)
    |> parse_router(tail)
  end

  defp parse_router(router, [["router" | _] | _] = tail), do: {router, tail}

  defp parse_router(router, [_ | tail]), do: parse_router(router, tail)

  defp parse_router(router, []), do: {router, []}

  defp to_atom(item) do
    item
    |> String.replace("-", "_")
    |> String.to_atom()
  end
end
