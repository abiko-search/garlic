defmodule Garlic do
  @moduledoc false
  use Application

  require Logger

  def start(_type, _args) do
    children = [
      Garlic.NetworkStatus,
      {Registry, name: Garlic.CircuitRegistry, keys: :unique},
      {Garlic.CircuitSupervisor, []},
      {Garlic.CircuitManager, []},
      {Garlic.CircuitPool, Application.get_env(:garlic, :circuit_pool, [])}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  @doc """
  Resolve a relay address through the configured address map.

  When `:address_map` is set in application config, rewrites
  `{container_ip, container_port}` to `{host_ip, host_port}`.
  Used to reach Docker container ORPorts from macOS hosts.

  The map keys are `{ip_tuple, port}` tuples.
  """
  @spec resolve_address(:inet.ip_address(), :inet.port_number()) ::
          {:inet.ip_address(), :inet.port_number()}
  def resolve_address(ip, port) do
    case Application.get_env(:garlic, :address_map) do
      nil -> {ip, port}
      map when is_map(map) -> Map.get(map, {ip, port}, {ip, port})
      fun when is_function(fun, 2) -> fun.(ip, port)
    end
  end
end
