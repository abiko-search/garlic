defmodule Garlic.MixProject do
  use Mix.Project

  def project do
    [
      app: :garlic,
      version: "0.1.0-dev",
      elixir: "~> 1.12",
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
      applications: ~w(mint)a,
      extra_applications: ~w(logger inets crypto ssl)a
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.3"},
      {:credo, "~> 1.5", only: ~w(dev test)a, runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false}
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
