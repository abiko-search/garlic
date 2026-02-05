defmodule Garlic.CircuitPool do
  @moduledoc """
  Pool of pre-raced circuits keyed by .onion domain.

  Provides checkout/checkin semantics for the crawler pipeline.
  Circuits are built via `CircuitRacer` and cached for reuse.
  """

  use GenServer

  require Logger

  alias Garlic.CircuitRacer

  defstruct circuits: %{},
            stats: %{checkouts: 0, hits: 0, misses: 0, races: 0}

  @type pool_stats :: %{
          checkouts: non_neg_integer(),
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          races: non_neg_integer(),
          domains: non_neg_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a circuit for the given domain.

  Returns a cached circuit if available, otherwise races new ones.
  """
  @spec checkout(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def checkout(domain, opts \\ []) do
    GenServer.call(__MODULE__, {:checkout, domain, opts}, 60_000)
  end

  @doc """
  Return a circuit to the pool for reuse.
  Only accepts circuits that are still alive.
  """
  @spec checkin(binary(), pid()) :: :ok
  def checkin(domain, circuit_pid) do
    GenServer.cast(__MODULE__, {:checkin, domain, circuit_pid})
  end

  @doc """
  Pre-build circuits for a domain using racing.
  """
  @spec warm_up(binary(), keyword()) :: :ok | {:error, term()}
  def warm_up(domain, opts \\ []) do
    GenServer.call(__MODULE__, {:warm_up, domain, opts}, 60_000)
  end

  @doc """
  Pool statistics.
  """
  @spec stats() :: pool_stats()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:checkout, domain, opts}, _from, state) do
    state = update_in(state.stats.checkouts, &(&1 + 1))

    case pop_circuit(state, domain) do
      {pid, state} when is_pid(pid) ->
        state = update_in(state.stats.hits, &(&1 + 1))
        {:reply, {:ok, pid}, state}

      {nil, state} ->
        state = update_in(state.stats.misses, &(&1 + 1))
        state = update_in(state.stats.races, &(&1 + 1))

        case CircuitRacer.race(domain, opts) do
          {:ok, pid, _stats} ->
            {:reply, {:ok, pid}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:warm_up, domain, opts}, _from, state) do
    state = update_in(state.stats.races, &(&1 + 1))

    case CircuitRacer.race(domain, opts) do
      {:ok, pid, _stats} ->
        state = put_circuit(state, domain, pid)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = Map.put(state.stats, :domains, map_size(state.circuits))
    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:checkin, domain, pid}, state) do
    if Process.alive?(pid) do
      {:noreply, put_circuit(state, domain, pid)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = remove_circuit_by_pid(state, pid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp pop_circuit(state, domain) do
    case Map.get(state.circuits, domain, []) do
      [pid | rest] ->
        if Process.alive?(pid) do
          state = put_in(state.circuits[domain], rest)
          {pid, state}
        else
          state = put_in(state.circuits[domain], rest)
          pop_circuit(state, domain)
        end

      [] ->
        {nil, state}
    end
  end

  defp put_circuit(state, domain, pid) do
    Process.monitor(pid)
    existing = Map.get(state.circuits, domain, [])
    put_in(state.circuits[domain], [pid | existing])
  end

  defp remove_circuit_by_pid(state, pid) do
    circuits =
      Map.new(state.circuits, fn {domain, pids} ->
        {domain, Enum.reject(pids, &(&1 == pid))}
      end)
      |> Enum.reject(fn {_, pids} -> pids == [] end)
      |> Map.new()

    %{state | circuits: circuits}
  end
end
