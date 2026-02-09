defmodule Garlic.MixProject do
  use Mix.Project

  def project do
    [
      app: :garlic,
      version: "0.1.0-dev",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Garlic",
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      mod: {Garlic, []},
      extra_applications: ~w(logger inets crypto ssl)a
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.6"},
      {:nimble_pool, "~> 1.1"},
      {:credo, "~> 1.7", only: ~w(dev test)a, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Pure Elixir Tor client implementation"
  end

  defp package do
    [
      name: :garlic,
      files: ~w(lib/garlic* lib/mint* priv mix.exs README* LICENSE*),
      maintainers: ["Danila Poyarkov"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/abiko-search/garlic"}
    ]
  end
end
