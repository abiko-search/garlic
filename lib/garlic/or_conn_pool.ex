defmodule Garlic.ORConnPool do
  @moduledoc """
  Pool of OR connections keyed by relay fingerprint.

  Ensures at most one TLS connection per relay. When a circuit needs to
  connect to a relay, it calls `get_or_connect/1` which returns an existing
  ORConnection or creates a new one.

  Connection establishment is non-blocking for the GenServer — the actual
  TCP+TLS+handshake runs in a spawned task. Multiple callers requesting
  the same relay will all wait on the same in-flight task.
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

  Returns `{:ok, or_conn_pid}` on success. Non-blocking for the pool —
  if a connection is being established, callers wait on the task ref.
  """
  @spec get_or_connect(Router.t()) :: {:ok, pid()} | {:error, term()}
  def get_or_connect(%Router{fingerprint: fp} = router) do
    case lookup(fp) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :ets.delete(@ets_table, fp)
          request_connection(fp, router)
        end

      :miss ->
        request_connection(fp, router)
    end
  end

  @doc "Stats for observability."
  @spec stats() :: %{connections: non_neg_integer(), total_circuits: non_neg_integer()}
  def stats do
    conns =
      :ets.tab2list(@ets_table)
      |> Enum.filter(fn
        {_fp, pid} when is_pid(pid) -> Process.alive?(pid)
        _ -> false
      end)

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

  defp lookup(fingerprint) do
    case :ets.lookup(@ets_table, fingerprint) do
      [{_, pid}] when is_pid(pid) -> {:ok, pid}
      _ -> :miss
    end
  end

  defp request_connection(fp, router) do
    case GenServer.call(__MODULE__, {:get_or_start, fp, router}, 30_000) do
      {:ok, pid} -> {:ok, pid}
      {:pending, ref} -> await_connection(ref)
      {:error, _} = err -> err
    end
  end

  defp await_connection(ref) do
    receive do
      {:or_conn_ready, ^ref, {:ok, pid}} -> {:ok, pid}
      {:or_conn_ready, ^ref, {:error, reason}} -> {:error, reason}
    after
      20_000 -> {:error, :connect_timeout}
    end
  end

  # -- GenServer --

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{pending: %{}}}
  end

  @impl true
  def handle_call({:get_or_start, fp, router}, {caller_pid, _} = _from, state) do
    case :ets.lookup(@ets_table, fp) do
      [{_, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          :ets.delete(@ets_table, fp)
          start_or_join(fp, router, caller_pid, state)
        end

      _ ->
        start_or_join(fp, router, caller_pid, state)
    end
  end

  @impl true
  def handle_info({:connect_result, fp, result}, state) do
    case Map.pop(state.pending, fp) do
      {nil, _} ->
        {:noreply, state}

      {{_task_ref, ref, waiters}, remaining_pending} ->
        case result do
          {:ok, pid} ->
            :ets.insert(@ets_table, {fp, pid})
            Process.monitor(pid)
            Enum.each(waiters, &send(&1, {:or_conn_ready, ref, {:ok, pid}}))

          {:error, _} = err ->
            Enum.each(waiters, &send(&1, {:or_conn_ready, ref, err}))
        end

        {:noreply, %{state | pending: remaining_pending}}
    end
  end

  def handle_info({:DOWN, _mref, :process, pid, _reason}, state) do
    :ets.match_delete(@ets_table, {:_, pid})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_or_join(fp, router, caller_pid, state) do
    case Map.get(state.pending, fp) do
      {task_ref, ref, waiters} ->
        state = put_in(state.pending[fp], {task_ref, ref, [caller_pid | waiters]})
        {:reply, {:pending, ref}, state}

      nil ->
        ref = make_ref()
        pool_pid = self()

        task_ref =
          Task.start(fn ->
            result = do_connect(router)
            send(pool_pid, {:connect_result, fp, result})
          end)

        state = put_in(state.pending[fp], {task_ref, ref, [caller_pid]})
        {:reply, {:pending, ref}, state}
    end
  end

  defp do_connect(router) do
    case GenServer.start(ORConnection, router) do
      {:ok, pid} ->
        case ORConnection.connect(pid) do
          :ok -> {:ok, pid}
          {:error, reason} ->
            GenServer.stop(pid, :normal)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
