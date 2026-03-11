defmodule Garlic.ORConnPool do
  @moduledoc """
  Pool of OR connections keyed by relay fingerprint.

  Ensures at most one TLS connection per relay. When a circuit needs to
  connect to a relay, it calls `get_or_connect/1` which returns an existing
  ORConnection or creates a new one.

  This is the core of connection multiplexing — C Tor's equivalent of the
  `connection_or.c` layer.
  """

  use GenServer

  require Logger

  alias Garlic.{ORConnection, Router}

  @ets_table :or_conn_pool

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get an existing OR connection to a relay, or create one.

  Returns `{:ok, or_conn_pid}` on success. The connection is fully
  handshaked and ready for circuit cells.
  """
  @spec get_or_connect(Router.t()) :: {:ok, pid()} | {:error, term()}
  def get_or_connect(%Router{fingerprint: fp} = router) do
    case lookup(fp) do
      {:ok, pid} ->
        if Process.alive?(pid) and ORConnection.connected?(pid) do
          {:ok, pid}
        else
          remove(fp)
          do_connect(router)
        end

      :miss ->
        do_connect(router)
    end
  end

  @doc "Stats for observability."
  @spec stats() :: %{connections: non_neg_integer(), total_circuits: non_neg_integer()}
  def stats do
    conns =
      :ets.tab2list(@ets_table)
      |> Enum.filter(fn {_fp, pid} -> Process.alive?(pid) end)

    total_circuits =
      Enum.reduce(conns, 0, fn {_fp, pid}, acc ->
        try do
          acc + ORConnection.circuit_count(pid)
        catch
          :exit, _ -> acc
        end
      end)

    %{connections: length(conns), total_circuits: total_circuits}
  end

  # -- Internal --

  defp do_connect(%Router{fingerprint: fp} = router) do
    GenServer.call(__MODULE__, {:connect, fp, router}, 20_000)
  end

  defp lookup(fingerprint) do
    case :ets.lookup(@ets_table, fingerprint) do
      [{_, pid}] -> {:ok, pid}
      [] -> :miss
    end
  end

  defp remove(fingerprint) do
    :ets.delete(@ets_table, fingerprint)
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:connect, fp, router}, _from, state) do
    case :ets.lookup(@ets_table, fp) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          :ets.delete(@ets_table, fp)
          start_and_connect(fp, router, state)
        end

      [] ->
        start_and_connect(fp, router, state)
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up any entry pointing to this dead pid
    :ets.match_delete(@ets_table, {:_, pid})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_and_connect(fp, router, state) do
    case ORConnection.start_link(router) do
      {:ok, pid} ->
        Process.monitor(pid)

        case ORConnection.connect(pid) do
          :ok ->
            :ets.insert(@ets_table, {fp, pid})
            {:reply, {:ok, pid}, state}

          {:error, reason} ->
            GenServer.stop(pid, :normal)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
