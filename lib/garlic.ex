defmodule Garlic do
  use Application

  require Logger

  def start(_type, _args) do
    children = [
      Garlic.NetworkStatus
    ]

    opts = [strategy: :one_for_one]

    Supervisor.start_link(children, opts)
  end
end
