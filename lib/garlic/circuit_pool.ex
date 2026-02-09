defmodule Garlic.CircuitPool do
  @moduledoc """
  Domain-keyed circuit pool manager.

  Lazily creates one NimblePool per .onion domain via DynamicSupervisor.
  Enforces global circuit limits by evicting LRU domain pools when capacity
  is reached.

  ## Usage

      Garlic.CircuitPool.checkout!("abc...xyz.onion", fn circuit_pid ->
        # use circuit_pid for HTTP requests
        start = System.monotonic_time(:millisecond)
        result = do_work(circuit_pid)
        latency = System.monotonic_time(:millisecond) - start
        {result, {:ok, latency}}
      end)

  The callback must return `{result, checkin_state}` where checkin_state is:
  - `{:ok, latency_ms}` — success with latency for health tracking
  - `:ok` — success without latency info
  - `:error` — failure, increments the circuit's failure counter

  ## Configuration

      Garlic.CircuitPool.start_link(
        pool_size: 2,           # circuits per domain (default: 2)
        max_domains: 25,        # global domain limit (default: 25)
        race_opts: [count: 2, hops: 1]
      )
  """

  use GenServer

  require Logger

  @default_pool_size 2
  @default_max_domains 25
  @pool_timeout 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Check out a circuit, run the callback, and check it back in.

  The callback receives the circuit PID and must return
  `{result, checkin_state}`. The `result` is returned to the caller.
  """
  @spec checkout!(String.t(), (pid() -> {term(), term()})) :: term()
  @spec checkout!(String.t(), keyword(), (pid() -> {term(), term()})) :: term()
  def checkout!(domain, opts_or_fun, fun_or_nil \\ nil)

  def checkout!(domain, fun, nil) when is_function(fun, 1) do
    checkout!(domain, [], fun)
  end

  def checkout!(domain, opts, fun) when is_list(opts) and is_function(fun, 1) do
    name = Keyword.get(opts, :pool, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @pool_timeout)

    pool_pid = GenServer.call(name, {:ensure_pool, domain}, timeout)

    case pool_pid do
      {:ok, pid} ->
        NimblePool.checkout!(pid, :checkout, fn _from, circuit_pid ->
          fun.(circuit_pid)
        end, timeout)

      {:error, reason} ->
        raise "Failed to get pool for #{domain}: #{inspect(reason)}"
    end
  end

  @doc "Pool statistics."
  @spec stats(GenServer.server()) :: map()
  def stats(name \\ __MODULE__) do
    GenServer.call(name, :stats)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      supervisor: sup,
      pools: %{},
      domain_order: [],
      pool_size: Keyword.get(opts, :pool_size, @default_pool_size),
      max_domains: Keyword.get(opts, :max_domains, @default_max_domains),
      race_opts: Keyword.get(opts, :race_opts, []),
      worker_opts: Keyword.take(opts, [:max_stream_count, :max_circuit_age_ms, :latency_threshold_ms, :max_consecutive_failures]),
      stats: %{checkouts: 0, pool_starts: 0, evictions: 0}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_pool, domain}, _from, state) do
    case Map.get(state.pools, domain) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          state = touch_domain(state, domain)
          state = update_in(state.stats.checkouts, &(&1 + 1))
          {:reply, {:ok, pid}, state}
        else
          state = remove_pool(state, domain)
          start_pool_and_reply(state, domain)
        end

      nil ->
        start_pool_and_reply(state, domain)
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      state.stats
      |> Map.put(:domains, map_size(state.pools))
      |> Map.put(:pool_size, state.pool_size)

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.pools, fn {_domain, pool_pid} -> pool_pid == pid end) do
      {domain, _} ->
        Logger.debug("CircuitPool: pool for #{domain} exited")
        {:noreply, remove_pool(state, domain)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internal --

  defp start_pool_and_reply(state, domain) do
    state = enforce_domain_limit(state)

    worker_opts = Keyword.merge(state.worker_opts, state.race_opts)

    pool_opts = [
      worker: {Garlic.CircuitPool.Worker, {domain, worker_opts}},
      pool_size: state.pool_size,
      lazy: true,
      worker_idle_timeout: 30_000
    ]

    case DynamicSupervisor.start_child(state.supervisor, {NimblePool, pool_opts}) do
      {:ok, pid} ->
        Process.monitor(pid)
        state = put_in(state.pools[domain], pid)
        state = %{state | domain_order: [domain | state.domain_order -- [domain]]}
        state = update_in(state.stats.pool_starts, &(&1 + 1))
        state = update_in(state.stats.checkouts, &(&1 + 1))
        {:reply, {:ok, pid}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp enforce_domain_limit(state) do
    if map_size(state.pools) >= state.max_domains do
      case List.last(state.domain_order) do
        nil ->
          state

        lru_domain ->
          Logger.debug("CircuitPool: evicting LRU pool for #{lru_domain}")
          state = update_in(state.stats.evictions, &(&1 + 1))
          evict_pool(state, lru_domain)
      end
    else
      state
    end
  end

  defp evict_pool(state, domain) do
    case Map.get(state.pools, domain) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(state.supervisor, pid)
        remove_pool(state, domain)

      nil ->
        state
    end
  end

  defp remove_pool(state, domain) do
    %{state |
      pools: Map.delete(state.pools, domain),
      domain_order: state.domain_order -- [domain]
    }
  end

  defp touch_domain(state, domain) do
    %{state | domain_order: [domain | state.domain_order -- [domain]]}
  end
end
