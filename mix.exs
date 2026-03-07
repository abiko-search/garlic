defmodule Garlic.MixProject do
  use Mix.Project

  def project do
    [
      app: :garlic,
      version: "0.2.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
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
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: ~w(dev test)a, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "cmd MIX_ENV=test mix test",
        "credo --strict --min-priority high",
        "dialyzer",
        "ex_dna"
      ]
    ]
  end

  defp description do
    "Pure Elixir Tor client implementation"
  end

  defp package do
    [
      name: :garlic,
      files: ~w(lib priv/auth_dirs.inc mix.exs README* LICENSE*),
      maintainers: ["Danila Poyarkov"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/abiko-search/garlic"}
    ]
  end
end
