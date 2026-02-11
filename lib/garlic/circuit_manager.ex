defmodule Garlic.CircuitManager do
  @moduledoc false
  use GenServer

  alias Garlic.{Circuit, CircuitRegistry, CircuitSupervisor, NetworkStatus}

  defstruct last_id: 1

  @default_timeout 30_000

  @spec start_link(any) :: {:ok, pid} | {:error, any}
  def start_link(_config) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_config) do
    {:ok, %__MODULE__{}}
  end

  @doc """
  Get a circuit for the given domain (legacy single-circuit path).

  For racing/pooled circuits, use `Garlic.CircuitPool.checkout!/2` or
  `Garlic.CircuitRacer.race/2` directly.
  """
  @spec get_circuit(binary, keyword | pos_integer) :: {:ok, pid} | {:error, any}
  def get_circuit(domain, opts \\ [])

  def get_circuit(domain, opts) when is_list(opts) do
    hops = Keyword.get(opts, :hops, 2)
    get_circuit_legacy(domain, hops)
  end

  def get_circuit(domain, hops) when is_integer(hops) do
    get_circuit_legacy(domain, hops)
  end

  defp get_circuit_legacy(domain, hops) do
    case lookup_circuit(domain) do
      {pid, _} when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_circuit(domain, hops)
    end
  end

  defp lookup_circuit(domain) do
    case Registry.lookup(CircuitRegistry, domain) do
      [circuit] -> circuit
      _ -> nil
    end
  end

  defp start_circuit(domain, hops) do
    GenServer.call(__MODULE__, {:start_circuit, domain, hops}, @default_timeout)
  end

  @impl true
  def handle_call({:start_circuit, domain, hops}, _from, %__MODULE__{last_id: last_id} = state) do
    {reply, state} =
      case lookup_circuit(domain) do
        nil ->
          routers = NetworkStatus.pick_fast_routers(hops)

          with {:ok, pid} <- CircuitSupervisor.start_circuit(last_id, domain),
               :ok <- Circuit.build_rendezvous(pid, routers, domain) do
            {{:ok, pid}, %{state | last_id: last_id + 1}}
          else
            {:error, error} ->
              {{:error, error}, state}
          end

        circuit ->
          {{:ok, circuit}, state}
      end

    {:reply, reply, state}
  end
end
