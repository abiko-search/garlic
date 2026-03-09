defmodule Garlic.DescriptorPrefetcher do
  @moduledoc """
  Background prefetcher for hidden service descriptors.

  Accepts domain names and fetches their HS descriptors in parallel,
  populating the `:introduction_points` ETS cache. When the crawler
  later builds a circuit via `CircuitRacer.race/2`, the descriptor
  lookup is an instant ETS hit instead of a 3-4s network roundtrip.

  Domains that fail descriptor fetch are reported via an optional
  callback, allowing the caller to mark them as dead immediately
  without wasting a circuit race attempt.

  ## Usage

      Garlic.DescriptorPrefetcher.prefetch(["abc...xyz.onion", ...])

      # With failure callback
      Garlic.DescriptorPrefetcher.prefetch(domains,
        on_failure: fn domain, reason -> Queue.backoff(domain) end)
  """

  use GenServer

  require Logger

  @max_concurrency 20
  @fetch_timeout 15_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Prefetch descriptors for a list of domains.

  Already-cached domains are skipped. Fetches run concurrently up to
  `@max_concurrency` in parallel.

  ## Options

    * `:on_failure` - `fn domain, reason -> ... end` called for each failed fetch
  """
  @spec prefetch([String.t()], keyword()) :: %{cached: non_neg_integer(), fetched: non_neg_integer(), failed: non_neg_integer()}
  def prefetch(domains, opts \\ []) do
    GenServer.call(__MODULE__, {:prefetch, domains, opts}, 120_000)
  end

  @doc "Prefetch asynchronously — fire and forget."
  @spec prefetch_async([String.t()], keyword()) :: :ok
  def prefetch_async(domains, opts \\ []) do
    GenServer.cast(__MODULE__, {:prefetch, domains, opts})
  end

  @doc "Number of cached descriptors."
  @spec cached_count() :: non_neg_integer()
  def cached_count do
    :ets.info(:introduction_points, :size)
  end

  @impl true
  def init(_opts) do
    {:ok, %{in_flight: MapSet.new()}}
  end

  @impl true
  def handle_call({:prefetch, domains, opts}, _from, state) do
    {result, state} = do_prefetch(domains, opts, state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:prefetch, domains, opts}, state) do
    {_result, state} = do_prefetch(domains, opts, state)
    {:noreply, state}
  end

  defp do_prefetch(domains, opts, state) do
    on_failure = Keyword.get(opts, :on_failure)

    uncached =
      domains
      |> Enum.uniq()
      |> Enum.reject(&descriptor_cached?/1)
      |> Enum.reject(&MapSet.member?(state.in_flight, &1))

    state = %{state | in_flight: Enum.reduce(uncached, state.in_flight, &MapSet.put(&2, &1))}
    cached = length(domains) - length(uncached)

    results =
      uncached
      |> Task.async_stream(
        fn domain ->
          result =
            try do
              Garlic.NetworkStatus.fetch_intoduction_points(domain, @fetch_timeout)
            catch
              :exit, reason -> {:error, {:exit, reason}}
            end

          {domain, result}
        end,
        max_concurrency: @max_concurrency,
        timeout: @fetch_timeout + 5_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{fetched: 0, failed: 0}, fn
        {:ok, {domain, {:ok, _intro_points}}}, acc ->
          Logger.debug("Prefetched descriptor for #{String.slice(domain, 0, 16)}...")
          %{acc | fetched: acc.fetched + 1}

        {:ok, {domain, {:error, reason}}}, acc ->
          if on_failure, do: on_failure.(domain, reason)
          %{acc | failed: acc.failed + 1}

        {:exit, _reason}, acc ->
          %{acc | failed: acc.failed + 1}
      end)

    state = %{state | in_flight: Enum.reduce(uncached, state.in_flight, &MapSet.delete(&2, &1))}

    result = Map.put(results, :cached, cached)
    {result, state}
  end

  defp descriptor_cached?(domain) do
    case :ets.lookup(:introduction_points, domain) do
      [{_, _intro_points, _expire_at}] -> true
      _ -> false
    end
  end
end
