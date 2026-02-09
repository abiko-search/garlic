defmodule Garlic.CircuitPoolTest do
  use ExUnit.Case, async: true

  alias Garlic.CircuitPool

  defmodule FakeWorker do
    @behaviour NimblePool

    @impl NimblePool
    def init_pool(state), do: {:ok, state}

    @impl NimblePool
    def init_worker(pool_state) do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      worker = %{pid: pid, created_at: System.monotonic_time(:millisecond)}
      {:ok, worker, pool_state}
    end

    @impl NimblePool
    def handle_checkout(:checkout, _from, worker, pool_state) do
      {:ok, worker.pid, worker, pool_state}
    end

    @impl NimblePool
    def handle_checkin(_checkin_state, _from, worker, pool_state) do
      {:ok, worker, pool_state}
    end

    @impl NimblePool
    def terminate_worker(_reason, worker, pool_state) do
      if Process.alive?(worker.pid), do: Process.exit(worker.pid, :kill)
      {:ok, pool_state}
    end
  end

  describe "stats" do
    test "returns initial stats" do
      pool = start_pool!()
      stats = CircuitPool.stats(pool)

      assert stats.domains == 0
      assert stats.checkouts == 0
      assert stats.pool_starts == 0
      assert stats.evictions == 0
    end
  end

  describe "ensure_pool" do
    test "creates pool on first checkout for a domain" do
      pool = start_pool!()

      assert {:ok, pool_pid} = GenServer.call(pool, {:ensure_pool, "test.onion"})
      assert is_pid(pool_pid)
      assert Process.alive?(pool_pid)

      stats = CircuitPool.stats(pool)
      assert stats.domains == 1
      assert stats.pool_starts == 1
    end

    test "reuses pool on subsequent calls for same domain" do
      pool = start_pool!()

      {:ok, pid1} = GenServer.call(pool, {:ensure_pool, "test.onion"})
      {:ok, pid2} = GenServer.call(pool, {:ensure_pool, "test.onion"})

      assert pid1 == pid2

      stats = CircuitPool.stats(pool)
      assert stats.pool_starts == 1
    end

    test "creates separate pools for different domains" do
      pool = start_pool!()

      {:ok, pid1} = GenServer.call(pool, {:ensure_pool, "a.onion"})
      {:ok, pid2} = GenServer.call(pool, {:ensure_pool, "b.onion"})

      assert pid1 != pid2

      stats = CircuitPool.stats(pool)
      assert stats.domains == 2
      assert stats.pool_starts == 2
    end
  end

  describe "domain limit enforcement" do
    test "evicts LRU domain when max_domains reached" do
      pool = start_pool!(max_domains: 2)

      {:ok, _} = GenServer.call(pool, {:ensure_pool, "a.onion"})
      {:ok, _} = GenServer.call(pool, {:ensure_pool, "b.onion"})
      {:ok, _} = GenServer.call(pool, {:ensure_pool, "c.onion"})

      stats = CircuitPool.stats(pool)
      assert stats.domains == 2
      assert stats.evictions == 1
    end

    test "touching a domain moves it to front of LRU" do
      pool = start_pool!(max_domains: 2)

      {:ok, pid_a} = GenServer.call(pool, {:ensure_pool, "a.onion"})
      {:ok, _} = GenServer.call(pool, {:ensure_pool, "b.onion"})

      # Touch a.onion — moves it to front
      {:ok, ^pid_a} = GenServer.call(pool, {:ensure_pool, "a.onion"})

      # Adding c.onion should evict b.onion (LRU), not a.onion
      {:ok, _} = GenServer.call(pool, {:ensure_pool, "c.onion"})

      stats = CircuitPool.stats(pool)
      assert stats.domains == 2

      # a.onion should still have its pool alive
      {:ok, pid_a2} = GenServer.call(pool, {:ensure_pool, "a.onion"})
      assert pid_a == pid_a2
    end
  end

  describe "dead pool recovery" do
    test "restarts pool if it died" do
      pool = start_pool!()

      {:ok, pid1} = GenServer.call(pool, {:ensure_pool, "test.onion"})
      Process.exit(pid1, :kill)
      Process.sleep(50)

      {:ok, pid2} = GenServer.call(pool, {:ensure_pool, "test.onion"})
      assert pid1 != pid2
      assert Process.alive?(pid2)
    end
  end

  defp start_pool!(opts \\ []) do
    name = :"pool_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, pool_size: 1, max_domains: 25], opts)
    {:ok, pid} = CircuitPool.start_link(opts)
    pid
  end
end
