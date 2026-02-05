defmodule Garlic.CircuitRacer do
  @moduledoc """
  Builds N parallel hidden service connections and returns the fastest.

  Each lane uses a different rendezvous point and (where possible) a
  different introduction point. The first circuit to complete the full
  rendezvous handshake wins; losers are torn down.

  This is the "Happy Eyeballs" approach applied to Tor HS circuits.
  See CIRCUIT_RACING.md for spec grounding.
  """

  require Logger

  alias Garlic.{Circuit, NetworkStatus, PathSelector, RendezvousPoint}

  @default_count 4
  @default_timeout 30_000

  @type race_result :: {:ok, pid(), race_stats()} | {:error, term()}
  @type race_stats :: %{
          winner_index: non_neg_integer(),
          build_time_ms: non_neg_integer(),
          lanes_attempted: pos_integer(),
          lanes_failed: non_neg_integer()
        }

  @doc """
  Race `count` parallel circuits to a hidden service domain.

  Returns `{:ok, circuit_pid, stats}` for the first circuit that
  completes the rendezvous, or `{:error, reason}` if all fail.

  ## Options
    * `:count` - number of parallel lanes (default: #{@default_count})
    * `:timeout` - per-lane timeout in ms (default: #{@default_timeout})
    * `:hops` - hops on client side to RP, 1 for speed (default: 1)
  """
  @spec race(binary(), keyword()) :: race_result()
  def race(domain, opts \\ []) do
    count = Keyword.get(opts, :count, @default_count)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    hops = Keyword.get(opts, :hops, 1)

    start_time = System.monotonic_time(:millisecond)

    with {:ok, intro_points} <- fetch_intro_points(domain) do
      rp_relays = PathSelector.select_rendezvous_relays(count)
      intro_selected = PathSelector.select_intro_points(intro_points, count)
      pairs = PathSelector.build_race_paths(rp_relays, intro_selected, count)

      lanes =
        pairs
        |> Enum.with_index()
        |> Enum.map(fn {{rp_relay, intro_point}, index} ->
          task =
            Task.async(fn ->
              build_lane(domain, rp_relay, intro_point, hops, index)
            end)

          {task, index}
        end)

      result = await_first_winner(lanes, timeout)

      elapsed = System.monotonic_time(:millisecond) - start_time

      case result do
        {:ok, pid, winner_index, failed_count} ->
          teardown_losers(lanes, winner_index)

          stats = %{
            winner_index: winner_index,
            build_time_ms: elapsed,
            lanes_attempted: length(lanes),
            lanes_failed: failed_count
          }

          Logger.info("Circuit race won by lane #{winner_index} in #{elapsed}ms")
          {:ok, pid, stats}

        {:error, reason} ->
          Logger.warning("All #{length(lanes)} race lanes failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Build a single lane: 1-hop (or N-hop) circuit to RP, establish
  rendezvous, introduce, await service connection.
  """
  @spec build_lane(binary(), Garlic.Router.t(), Garlic.IntroductionPoint.t(), pos_integer(), non_neg_integer()) ::
          {:ok, pid(), non_neg_integer()} | {:error, term()}
  def build_lane(_domain, rp_relay, intro_point, hops, index) do
    Logger.debug("Lane #{index}: building #{hops}-hop circuit to RP #{rp_relay.nickname}")

    with {:ok, routers} <- build_path_to_rp(rp_relay, hops),
         {:ok, routers} <- NetworkStatus.fetch_router_descriptors(routers),
         rendezvous_point <- RendezvousPoint.build(intro_point, rp_relay),
         {:ok, pid} <- Circuit.start(),
         :ok <- do_build_circuit(pid, routers),
         :ok <- Circuit.establish_rendezvous(pid, 1, rendezvous_point) do
      spawn_introduction(rendezvous_point)

      case Circuit.await_rendezvous(pid, 1) do
        :ok -> {:ok, pid, index}
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :exit, reason -> {:error, {:lane_crashed, reason}}
  end

  defp build_path_to_rp(rp_relay, 1), do: {:ok, [rp_relay]}

  defp build_path_to_rp(rp_relay, hops) when hops > 1 do
    extra = NetworkStatus.pick_fast_routers(hops - 1)
    {:ok, extra ++ [rp_relay]}
  end

  defp do_build_circuit(pid, [head | tail]) do
    with :ok <- Circuit.connect(pid, head) do
      Enum.reduce_while(tail, :ok, fn router, _ ->
        case Circuit.extend(pid, router) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp spawn_introduction(rendezvous_point) do
    spawn(fn ->
      with [router] <- NetworkStatus.pick_fast_routers(1),
           {:ok, pid} <- Circuit.start(),
           :ok <-
             Circuit.build_circuit(pid, [
               router,
               rendezvous_point.introduction_point.router
             ]) do
        Circuit.introduce(pid, 1, rendezvous_point)
      end
    end)
  end

  defp await_first_winner(lanes, timeout) do
    tasks = Enum.map(lanes, &elem(&1, 0))
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await(lanes, tasks, deadline, 0)
  end

  defp do_await([], _tasks, _deadline, _failed) do
    {:error, :all_lanes_failed}
  end

  defp do_await(lanes, tasks, deadline, failed) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield_many(tasks, remaining) do
      results ->
        winner =
          Enum.find_value(results, fn
            {task, {:ok, {:ok, pid, index}}} when is_pid(pid) ->
              {task, pid, index}

            _ ->
              nil
          end)

        case winner do
          {_task, pid, index} ->
            {:ok, pid, index, failed}

          nil ->
            new_failed =
              Enum.count(results, fn
                {_, {:ok, {:error, _}}} -> true
                {_, {:exit, _}} -> true
                _ -> false
              end)

            still_pending =
              Enum.filter(lanes, fn {task, _} ->
                Enum.any?(results, fn
                  {^task, nil} -> true
                  _ -> false
                end)
              end)

            if still_pending == [] do
              {:error, :all_lanes_failed}
            else
              pending_tasks = Enum.map(still_pending, &elem(&1, 0))
              do_await(still_pending, pending_tasks, deadline, failed + new_failed)
            end
        end
    end
  end

  defp teardown_losers(lanes, winner_index) do
    Enum.each(lanes, fn {task, index} ->
      if index != winner_index do
        Task.shutdown(task, :brutal_kill)
      end
    end)
  end

  defp fetch_intro_points(domain) do
    NetworkStatus.fetch_intoduction_points(domain)
  catch
    :exit, reason -> {:error, {:intro_fetch_failed, reason}}
  end
end
