defmodule Garlic.CircuitPool.Worker do
  @moduledoc """
  NimblePool worker that manages Tor circuit PIDs for a single .onion domain.

  Each worker holds a circuit PID plus health metadata (stream count, latencies,
  failure count). The pool lazily builds circuits via CircuitRacer on checkout
  and removes unhealthy ones on checkin or idle ping.
  """

  @behaviour NimblePool

  require Logger

  alias Garlic.CircuitRacer

  defstruct [:pid, :domain, :created_at, stream_count: 0, latencies: [], consecutive_failures: 0]

  @max_stream_count 100
  @max_circuit_age_ms 600_000
  @latency_threshold_ms 5_000
  @max_consecutive_failures 3

  @impl NimblePool
  def init_pool({domain, opts}) do
    state = %{
      domain: domain,
      race_opts: Keyword.take(opts, [:count, :hops, :timeout]),
      max_stream_count: Keyword.get(opts, :max_stream_count, @max_stream_count),
      max_circuit_age_ms: Keyword.get(opts, :max_circuit_age_ms, @max_circuit_age_ms),
      latency_threshold_ms: Keyword.get(opts, :latency_threshold_ms, @latency_threshold_ms),
      max_consecutive_failures: Keyword.get(opts, :max_consecutive_failures, @max_consecutive_failures)
    }

    {:ok, state}
  end

  @impl NimblePool
  def init_worker(pool_state) do
    async = fn ->
      case CircuitRacer.race(pool_state.domain, pool_state.race_opts) do
        {:ok, pid, _stats} ->
          %__MODULE__{
            pid: pid,
            domain: pool_state.domain,
            created_at: System.monotonic_time(:millisecond)
          }

        {:error, _reason} ->
          %__MODULE__{pid: nil, domain: pool_state.domain, created_at: 0}
      end
    end

    {:async, async, pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, %{pid: nil} = _worker, pool_state) do
    {:remove, :not_connected, pool_state}
  end

  def handle_checkout(:checkout, _from, worker, pool_state) do
    if Process.alive?(worker.pid) and healthy?(worker, pool_state) do
      worker = %{worker | stream_count: worker.stream_count + 1}
      report_worker_health(worker, pool_state)
      {:ok, worker.pid, worker, pool_state}
    else
      {:remove, :unhealthy, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin({:ok, latency_ms}, _from, worker, pool_state) do
    latencies = Enum.take([latency_ms | worker.latencies], 10)
    worker = %{worker | latencies: latencies, consecutive_failures: 0}
    report_worker_health(worker, pool_state)

    if healthy?(worker, pool_state) do
      {:ok, worker, pool_state}
    else
      {:remove, :degraded, pool_state}
    end
  end

  def handle_checkin(:error, _from, worker, pool_state) do
    worker = %{worker | consecutive_failures: worker.consecutive_failures + 1}
    report_worker_health(worker, pool_state)

    if worker.consecutive_failures >= pool_state.max_consecutive_failures do
      {:remove, :too_many_failures, pool_state}
    else
      {:ok, worker, pool_state}
    end
  end

  def handle_checkin(:ok, _from, worker, pool_state) do
    report_worker_health(worker, pool_state)

    if healthy?(worker, pool_state) do
      {:ok, worker, pool_state}
    else
      {:remove, :degraded, pool_state}
    end
  end

  @impl NimblePool
  def handle_ping(%{pid: nil} = worker, _pool_state), do: {:ok, worker}

  def handle_ping(worker, pool_state) do
    cond do
      not Process.alive?(worker.pid) ->
        {:remove, :dead}

      not healthy?(worker, pool_state) ->
        {:remove, :unhealthy}

      true ->
        {:ok, worker}
    end
  end

  @impl NimblePool
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{pid: pid}) do
    {:remove, :circuit_down}
  end

  def handle_info(_msg, worker), do: {:ok, worker}

  @impl NimblePool
  def terminate_worker(_reason, %{pid: nil}, pool_state), do: {:ok, pool_state}

  def terminate_worker(_reason, worker, pool_state) do
    cleanup_worker_health(worker)

    if Process.alive?(worker.pid) do
      try do
        Garlic.Circuit.close(worker.pid)
      catch
        :exit, _ ->
          Process.exit(worker.pid, :shutdown)
      end
    end

    {:ok, pool_state}
  end

  defp report_worker_health(worker, pool_state) do
    if :ets.whereis(:circuit_pool_workers) != :undefined do
      now = System.monotonic_time(:millisecond)

      avg_latency =
        case worker.latencies do
          [] -> nil
          latencies -> Enum.sum(latencies) / length(latencies)
        end

      entry = %{
        pid: worker.pid,
        stream_count: worker.stream_count,
        avg_latency_ms: avg_latency,
        consecutive_failures: worker.consecutive_failures,
        created_at: worker.created_at,
        age_ms: now - worker.created_at,
        healthy: healthy?(worker, pool_state)
      }

      existing =
        case :ets.lookup(:circuit_pool_workers, worker.domain) do
          [{_, list}] -> list
          [] -> []
        end

      updated =
        case Enum.find_index(existing, &(&1.pid == worker.pid)) do
          nil -> [entry | existing]
          idx -> List.replace_at(existing, idx, entry)
        end

      :ets.insert(:circuit_pool_workers, {worker.domain, updated})
    end
  end

  defp cleanup_worker_health(worker) do
    if :ets.whereis(:circuit_pool_workers) != :undefined do
      case :ets.lookup(:circuit_pool_workers, worker.domain) do
        [{_, list}] ->
          updated = Enum.reject(list, &(&1.pid == worker.pid))

          if updated == [] do
            :ets.delete(:circuit_pool_workers, worker.domain)
          else
            :ets.insert(:circuit_pool_workers, {worker.domain, updated})
          end

        [] ->
          :ok
      end
    end
  end

  defp healthy?(worker, config) do
    now = System.monotonic_time(:millisecond)

    worker.consecutive_failures < config.max_consecutive_failures and
      worker.stream_count < config.max_stream_count and
      now - worker.created_at < config.max_circuit_age_ms and
      not degraded?(worker, config)
  end

  defp degraded?(worker, config) do
    case worker.latencies do
      latencies when length(latencies) >= 3 ->
        Enum.sum(latencies) / length(latencies) > config.latency_threshold_ms

      _ ->
        false
    end
  end
end
