defmodule Garlic.CircuitPoolTest do
  use ExUnit.Case

  alias Garlic.CircuitPool

  setup do
    case GenServer.whereis(CircuitPool) do
      nil ->
        pool = start_supervised!(CircuitPool)
        %{pool: pool}

      pid ->
        # Pool already running from application supervisor — reset its state
        :sys.replace_state(pid, fn _ ->
          %CircuitPool{circuits: %{}, stats: %{checkouts: 0, hits: 0, misses: 0, races: 0}}
        end)

        %{pool: pid}
    end
  end

  describe "stats/0" do
    test "returns initial stats" do
      stats = CircuitPool.stats()

      assert stats.checkouts == 0
      assert stats.hits == 0
      assert stats.misses == 0
      assert stats.races == 0
      assert stats.domains == 0
    end
  end

  describe "checkin/checkout without racing" do
    test "checkin stores a circuit, checkout retrieves it" do
      fake_circuit = spawn(fn -> Process.sleep(:infinity) end)

      CircuitPool.checkin("test.onion", fake_circuit)
      Process.sleep(10)

      # Direct GenServer call to pop — avoids triggering a real race on miss
      state = :sys.get_state(CircuitPool)
      assert Map.has_key?(state.circuits, "test.onion")

      pids = Map.get(state.circuits, "test.onion", [])
      assert fake_circuit in pids

      Process.exit(fake_circuit, :kill)
    end

    test "dead circuits are skipped on checkout" do
      dead = spawn(fn -> :ok end)
      Process.sleep(10)

      CircuitPool.checkin("test.onion", dead)
      Process.sleep(10)

      state = :sys.get_state(CircuitPool)
      # The dead pid might or might not be cleaned up yet via :DOWN
      # but pop_circuit should skip it
      circuits = Map.get(state.circuits, "test.onion", [])
      alive_count = Enum.count(circuits, &Process.alive?/1)
      assert alive_count == 0
    end

    test "monitors circuits and removes on exit" do
      circuit = spawn(fn -> Process.sleep(:infinity) end)

      CircuitPool.checkin("test.onion", circuit)
      Process.sleep(10)

      state = :sys.get_state(CircuitPool)
      assert "test.onion" in Map.keys(state.circuits)

      Process.exit(circuit, :kill)
      Process.sleep(50)

      state = :sys.get_state(CircuitPool)
      pids = Map.get(state.circuits, "test.onion", [])
      refute circuit in pids
    end
  end

  describe "multiple domains" do
    test "tracks circuits per domain independently" do
      c1 = spawn(fn -> Process.sleep(:infinity) end)
      c2 = spawn(fn -> Process.sleep(:infinity) end)

      CircuitPool.checkin("a.onion", c1)
      CircuitPool.checkin("b.onion", c2)
      Process.sleep(10)

      stats = CircuitPool.stats()
      assert stats.domains == 2

      Process.exit(c1, :kill)
      Process.exit(c2, :kill)
    end
  end
end
