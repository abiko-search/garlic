defmodule Garlic do
  use Application

  require Logger

  def start(_type, _args) do
    children = [
      Garlic.NetworkStatus,
      {Registry, name: Garlic.CircuitRegistry, keys: :unique},
      {Garlic.CircuitSupervisor, []},
      {Garlic.CircuitManager, []},
      {Garlic.CircuitPool, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
