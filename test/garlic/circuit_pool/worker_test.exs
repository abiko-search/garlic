defmodule Garlic.CircuitPool.WorkerTest do
  use ExUnit.Case, async: true

  alias Garlic.CircuitPool.Worker

  describe "health checking" do
    test "healthy circuit passes checkout" do
      worker = build_worker()
      config = build_config()

      assert {:ok, _pid, _worker, _state} = Worker.handle_checkout(:checkout, self_from(), worker, config)
    end

    test "uninitialized worker (pid: nil) returns :remove on failed race" do
      worker = %Worker{pid: nil, domain: "nonexistent.onion", created_at: 0}
      config = build_config()

      assert {:remove, _, _state} = Worker.handle_checkout(:checkout, self_from(), worker, config)
    end

    test "dead circuit removed on checkout" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      worker = build_worker(pid: pid)
      config = build_config()

      assert {:remove, :unhealthy, _state} = Worker.handle_checkout(:checkout, self_from(), worker, config)
    end

    test "success checkin resets failure count" do
      worker = build_worker(consecutive_failures: 2)
      config = build_config()

      assert {:ok, updated, _state} = Worker.handle_checkin({:ok, 50}, self_from(), worker, config)
      assert updated.consecutive_failures == 0
      assert updated.latencies == [50]
    end

    test "success checkin tracks latency history (max 10)" do
      worker = build_worker(latencies: Enum.to_list(1..10))
      config = build_config()

      assert {:ok, updated, _state} = Worker.handle_checkin({:ok, 999}, self_from(), worker, config)
      assert length(updated.latencies) == 10
      assert hd(updated.latencies) == 999
    end

    test "error checkin increments failure count" do
      worker = build_worker(consecutive_failures: 0)
      config = build_config()

      assert {:ok, updated, _state} = Worker.handle_checkin(:error, self_from(), worker, config)
      assert updated.consecutive_failures == 1
    end

    test "too many failures triggers removal" do
      worker = build_worker(consecutive_failures: 2)
      config = build_config(max_consecutive_failures: 3)

      assert {:remove, :too_many_failures, _state} = Worker.handle_checkin(:error, self_from(), worker, config)
    end

    test "aged circuit removed on checkin" do
      worker = build_worker(created_at: System.monotonic_time(:millisecond) - 700_000)
      config = build_config(max_circuit_age_ms: 600_000)

      assert {:remove, :degraded, _state} = Worker.handle_checkin(:ok, self_from(), worker, config)
    end

    test "exhausted stream count removed on checkin" do
      worker = build_worker(stream_count: 100)
      config = build_config(max_stream_count: 100)

      assert {:remove, :degraded, _state} = Worker.handle_checkin(:ok, self_from(), worker, config)
    end

    test "high latency circuit removed on checkin" do
      worker = build_worker(latencies: [6000, 6000, 6000])
      config = build_config(latency_threshold_ms: 5_000)

      assert {:remove, :degraded, _state} = Worker.handle_checkin(:ok, self_from(), worker, config)
    end

    test "latency degradation needs at least 3 samples" do
      worker = build_worker(latencies: [10_000, 10_000])
      config = build_config(latency_threshold_ms: 5_000)

      assert {:ok, _worker, _state} = Worker.handle_checkin(:ok, self_from(), worker, config)
    end
  end

  describe "handle_ping" do
    test "healthy idle circuit stays" do
      worker = build_worker()
      config = build_config()

      assert {:ok, ^worker} = Worker.handle_ping(worker, config)
    end

    test "dead circuit removed on ping" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      worker = build_worker(pid: pid)
      config = build_config()

      assert {:remove, :dead} = Worker.handle_ping(worker, config)
    end

    test "aged circuit removed on ping" do
      worker = build_worker(created_at: System.monotonic_time(:millisecond) - 700_000)
      config = build_config(max_circuit_age_ms: 600_000)

      assert {:remove, :unhealthy} = Worker.handle_ping(worker, config)
    end
  end

  describe "terminate_worker" do
    test "closes alive circuit" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      worker = build_worker(pid: pid)
      config = build_config()

      assert {:ok, ^config} = Worker.terminate_worker(:normal, worker, config)
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "handles already dead circuit" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      worker = build_worker(pid: pid)
      config = build_config()

      assert {:ok, ^config} = Worker.terminate_worker(:normal, worker, config)
    end
  end

  # -- Helpers --

  defp build_worker(overrides \\ []) do
    pid = Keyword.get_lazy(overrides, :pid, fn -> spawn(fn -> Process.sleep(:infinity) end) end)

    %Worker{
      pid: pid,
      domain: "test.onion",
      created_at: Keyword.get(overrides, :created_at, System.monotonic_time(:millisecond)),
      stream_count: Keyword.get(overrides, :stream_count, 0),
      latencies: Keyword.get(overrides, :latencies, []),
      consecutive_failures: Keyword.get(overrides, :consecutive_failures, 0)
    }
  end

  defp build_config(overrides \\ []) do
    %{
      domain: "test.onion",
      race_opts: [],
      max_stream_count: Keyword.get(overrides, :max_stream_count, 100),
      max_circuit_age_ms: Keyword.get(overrides, :max_circuit_age_ms, 600_000),
      latency_threshold_ms: Keyword.get(overrides, :latency_threshold_ms, 5_000),
      max_consecutive_failures: Keyword.get(overrides, :max_consecutive_failures, 3)
    }
  end

  defp self_from, do: {self(), make_ref()}
end
