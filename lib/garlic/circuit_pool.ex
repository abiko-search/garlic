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
        max_domains: 1000,      # global domain limit (default: 1000)
        race_opts: [count: 2, hops: 2]
      )
  """

  use GenServer

  require Logger

  @default_pool_size 2
  @default_max_domains 5000
  @pool_timeout 60_000
  @domain_health_table :circuit_pool_domain_health
  @base_backoff_ms 60_000
  @max_backoff_ms 3_600_000
  @max_domain_failures 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Check out a circuit, run the callback, and check it back in.

  Returns `{:error, :domain_backed_off}` immediately if the domain has
  too many consecutive failures and is still in its backoff window.

  The callback receives the circuit PID and must return
  `{result, checkin_state}`. The `result` is returned to the caller.
  """
  @spec checkout!(String.t(), (pid() -> {term(), term()})) :: term()
  def checkout!(domain, fun) when is_function(fun, 1) do
    checkout!(domain, [], fun)
  end

  @spec checkout!(String.t(), keyword(), (pid() -> {term(), term()})) :: term()
  def checkout!(domain, opts, fun) when is_list(opts) and is_function(fun, 1) do
    case domain_available?(domain) do
      false ->
        raise "Domain #{domain} is backed off"

      true ->
        name = Keyword.get(opts, :pool, __MODULE__)
        timeout = Keyword.get(opts, :timeout, @pool_timeout)

        pool_pid = GenServer.call(name, {:ensure_pool, domain}, timeout)

        case pool_pid do
          {:ok, pid} ->
            try do
              result =
                NimblePool.checkout!(pid, :checkout, fn _from, circuit_pid ->
                  fun.(circuit_pid)
                end, timeout)

              record_domain_success(domain)
              result
            rescue
              e ->
                record_domain_failure(domain)
                reraise e, __STACKTRACE__
            catch
              :exit, reason ->
                record_domain_failure(domain)
                exit(reason)
            end

          {:error, reason} ->
            record_domain_failure(domain)
            raise "Failed to get pool for #{domain}: #{inspect(reason)}"
        end
    end
  end

  @doc "Check if a domain is available (not in backoff)."
  @spec domain_available?(String.t()) :: boolean()
  def domain_available?(domain) do
    case :ets.lookup(@domain_health_table, domain) do
      [{_, failures, last_failure_at}] when failures > 0 ->
        backoff_ms = min(@base_backoff_ms * :math.pow(2, failures - 1), @max_backoff_ms) |> trunc()
        now = System.monotonic_time(:millisecond)
        now - last_failure_at > backoff_ms

      _ ->
        true
    end
  end

  @doc "Record a successful connection to a domain, resetting its failure count."
  def record_domain_success(domain) do
    :ets.insert(@domain_health_table, {domain, 0, 0})
  end

  @doc "Record a failed connection to a domain."
  def record_domain_failure(domain) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@domain_health_table, domain) do
      [{_, failures, _}] ->
        new_failures = min(failures + 1, @max_domain_failures)
        :ets.insert(@domain_health_table, {domain, new_failures, now})

      [] ->
        :ets.insert(@domain_health_table, {domain, 1, now})
    end
  end

  @doc "Domain health stats for observability."
  @spec domain_health_stats() :: %{backed_off: non_neg_integer(), healthy: non_neg_integer(), total: non_neg_integer()}
  def domain_health_stats do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {_domain, failures, last_at}, acc ->
        backoff_ms = min(@base_backoff_ms * :math.pow(2, max(failures - 1, 0)), @max_backoff_ms) |> trunc()

        if failures > 0 and now - last_at <= backoff_ms do
          %{acc | backed_off: acc.backed_off + 1, total: acc.total + 1}
        else
          %{acc | healthy: acc.healthy + 1, total: acc.total + 1}
        end
      end,
      %{backed_off: 0, healthy: 0, total: 0},
      @domain_health_table
    )
  end

  @doc "Pool statistics."
  @spec stats(GenServer.server()) :: map()
  def stats(name \\ __MODULE__) do
    GenServer.call(name, :stats)
  end

  @doc "Per-domain pool info for observability."
  @spec pool_info(GenServer.server()) :: [map()]
  def pool_info(name \\ __MODULE__) do
    GenServer.call(name, :pool_info)
  end

  # -- GenServer --

  @impl true
  def init(opts) do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    if :ets.whereis(:circuit_pool_workers) == :undefined do
      :ets.new(:circuit_pool_workers, [:named_table, :public, :set])
    end

    if :ets.whereis(@domain_health_table) == :undefined do
      :ets.new(@domain_health_table, [:named_table, :public, :set])
    end

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

    schedule_ssl_reaper()
    {:ok, state}
  end

  @reaper_interval_ms 30_000

  @impl true
  def handle_call({:ensure_pool, domain}, _from, state) do
    case Map.get(state.pools, domain) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          state = touch_domain(state, domain)
          state = update_in(state.stats.checkouts, &(&1 + 1))
          :telemetry.execute([:garlic, :pool, :checkout], %{count: 1}, %{domain: domain})
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
      |> Map.put(:max_domains, state.max_domains)

    {:reply, stats, state}
  end

  def handle_call(:pool_info, _from, state) do
    info =
      Enum.map(state.pools, fn {domain, pid} ->
        workers =
          case :ets.lookup(:circuit_pool_workers, domain) do
            [{_, worker_list}] -> worker_list
            [] -> []
          end

        lru_position = Enum.find_index(state.domain_order, &(&1 == domain))

        %{
          domain: domain,
          pool_pid: pid,
          alive: Process.alive?(pid),
          workers: workers,
          lru_position: lru_position
        }
      end)

    {:reply, info, state}
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

  def handle_info(:reap_ssl, state) do
    reaped_ssl = reap_orphaned_ssl_processes()
    reaped_gs = reap_orphaned_genservers()
    total = reaped_ssl + reaped_gs

    if total > 0,
      do: Logger.info("Reaped #{reaped_ssl} orphaned circuits, #{reaped_gs} empty gen_servers")

    schedule_ssl_reaper()
    {:noreply, state}
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
      worker_idle_timeout: 60_000
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
          :telemetry.execute([:garlic, :pool, :eviction], %{count: 1}, %{domain: lru_domain})
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

  defp reap_orphaned_genservers do
    Process.list()
    |> Enum.reduce(0, fn pid, count ->
      with {:current_function, {:gen_server, :loop, 7}} <- Process.info(pid, :current_function),
           {:links, []} <- Process.info(pid, :links),
           %Garlic.Circuit{} <- safe_get_state(pid) do
        Process.exit(pid, :kill)
        count + 1
      else
        _ -> count
      end
    end)
  end

  defp safe_get_state(pid) do
    :sys.get_state(pid, 50)
  catch
    _, _ -> nil
  end

  defp schedule_ssl_reaper do
    Process.send_after(self(), :reap_ssl, @reaper_interval_ms)
  end

  defp reap_orphaned_ssl_processes do
    # Collect all circuit PIDs that NimblePool is actively managing
    managed_pids =
      if :ets.whereis(:circuit_pool_workers) != :undefined do
        :ets.foldl(fn {_domain, workers}, acc ->
          pids = Enum.map(workers, & &1.pid) |> Enum.reject(&is_nil/1)
          pids ++ acc
        end, [], :circuit_pool_workers)
        |> MapSet.new()
      else
        MapSet.new()
      end

    # Find gen_server processes linked to SSL statemachines but not in the pool
    Process.list()
    |> Enum.reduce(0, fn pid, count ->
      with {:current_function, {:gen_server, :loop, 7}} <- Process.info(pid, :current_function),
           false <- MapSet.member?(managed_pids, pid),
           {:links, links} <- Process.info(pid, :links) do
        has_ssl_link = Enum.any?(links, fn l ->
          is_pid(l) and
            (case Process.info(l, :current_function) do
              {:current_function, {:gen_statem, :loop_receive, 3}} -> true
              _ -> false
            end)
        end)

        has_non_ssl_link = Enum.any?(links, fn l ->
          is_pid(l) and
            not (case Process.info(l, :current_function) do
              {:current_function, {:gen_statem, :loop_receive, 3}} -> true
              {:current_function, {:gen_server, :loop, 7}} -> true
              _ -> false
            end)
        end)

        if has_ssl_link and not has_non_ssl_link do
          GenServer.stop(pid, :normal)
          count + 1
        else
          count
        end
      else
        _ -> count
      end
    end)
  end
end
