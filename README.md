# Garlic

![](https://github.com/abiko-search/garlic/workflows/Elixir%20CI/badge.svg)

Pure Elixir Tor client implementation

## Disclaimer

⚠️ This module was designed to crawl hidden services fast and doesn't provide the same level of anonymity as the reference Tor implementation! 

## Installation

```elixir
def deps do
  [
    {:garlic, "~> 0.1.0-dev", github: "abiko-search/garlic"}
  ]
end
```

## Usage

```elixir
alias Garlic.{CircuitManager, Mint.Client}

domain = "abikoifawyrftqivkhfxiwdjcdzybumpqrbowtudtwhrhpnykfonyzid.onion"
port = 80

with {:ok, pid} <- CircuitManager.get_circuit(domain) do
  for {url, i} <- Enum.with_index(~w(/ /robots.txt /sitemap.xml)) do
    Task.async fn ->
      pid
      |> Client.request(i + 1, domain, port, "GET", url, [], "")
      |> Enum.join()
      |> IO.inspect(label: url)
    end
  end
  |> Task.await_many(:infinity)
end
```

## License

[Apache 2.0] © [Danila Poyarkov]

[Apache 2.0]: LICENSE
[Danila Poyarkov]: http://dannote.net
