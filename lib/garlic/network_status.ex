defmodule Garlic.NetworkStatus do
  @moduledoc "Tor network status"

  # TODO: make autoupdate

  require Logger
  alias Garlic.NetworkStatus.AuthorityList
  require AuthorityList

  use GenServer

  alias Garlic.{Circuit, Crypto, Mint.Client, NetworkStatus.Document}

  defstruct [
    :previous_shared_random,
    :current_shared_random,
    :valid_after,
    :valid_until,
    :fresh_until,
    routers: [],
    params: %{},
    time_period_length: 1440,
    default_voting_interval: 3600
  ]

  @type timestamp :: non_neg_integer

  @type t() :: %__MODULE__{
          previous_shared_random: binary,
          current_shared_random: binary,
          valid_after: timestamp,
          valid_until: timestamp,
          fresh_until: timestamp,
          routers: [Garlic.Router.t()],
          params: map,
          time_period_length: pos_integer,
          default_voting_interval: pos_integer
        }

  @directory_timeout 5_000
  @default_timeout 20_000
  @router_pool_size 50

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: Garlic.NetworkStatus)
  end

  def default_authorities, do: AuthorityList.default()

  @doc """
  Returns the active authority list.

  Checks `Application.get_env(:garlic, :authorities)` first.
  Accepts a list of `%Garlic.Router{}` structs or DirAuthority strings.
  Falls back to the compiled-in Tor directory authorities.
  """
  def authorities do
    case Application.get_env(:garlic, :authorities) do
      nil ->
        default_authorities()

      authorities when is_list(authorities) ->
        Enum.map(authorities, fn
          %Garlic.Router{} = r -> r
          line when is_binary(line) -> AuthorityList.parse(line)
        end)
    end
  end

  @spec pick_fast_routers(pos_integer) :: list(Garlic.Router.t())
  def pick_fast_routers(count) do
    GenServer.call(__MODULE__, {:pick_fast_routers, count})
  end

  def fetch_intoduction_points(public_key, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:fetch_intoduction_points, public_key}, timeout)
  end

  def invalidate_introduction_points(domain) do
    :ets.delete(:introduction_points, domain)
  end

  def fetch_router_descriptors(routers, timeout \\ @default_timeout) do
    GenServer.call(__MODULE__, {:fetch_router_descriptors, routers}, timeout)
  end

  @impl true
  def init(_) do
    :ets.new(:hidden_service_directory, ~w(ordered_set named_table)a)
    :ets.new(:introduction_points, ~w(ordered_set named_table public)a)
    :ets.new(:routers, ~w(ordered_set named_table public)a)

    {:ok, nil, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, _state) do
    network_status =
      (with nil <- read_cached(), do: download())
      |> detect_testing_network()

    network_status.routers
    |> Stream.filter(&(not is_nil(&1.ntor_onion_key)))
    |> Enum.each(&:ets.insert(:routers, {&1.fingerprint, &1}))

    for router <- Stream.filter(network_status.routers, &("HSDir" in &1.flags)) do
      directory_index =
        Crypto.HiddenService.build_directory_index(
          router.identity,
          get_shared_random(network_status),
          network_status.time_period_length,
          get_time_period_num(network_status)
        )

      :ets.insert(:hidden_service_directory, {directory_index, router})
    end

    {:noreply, network_status}
  end

  @impl true
  def handle_call({:pick_fast_routers, count}, _from, network_status) do
    routers =
      network_status
      |> get_fast_routers()
      |> Enum.take_random(count)

    {:reply, routers, network_status}
  end

  def handle_call(
        {:fetch_intoduction_points, domain},
        from,
        %__MODULE__{time_period_length: time_period_length} = network_status
      ) do
    public_key =
      domain
      |> String.replace_trailing(".onion", "")
      |> String.upcase()
      |> Base.decode32!()
      |> binary_part(0, 32)

    spread_store = Map.get(network_status.params, "hsdir_spread_store", 4)
    n_replicas = Map.get(network_status.params, "hsdir_n_replicas", 2)
    time_period_num = get_time_period_num(network_status)
    blinded_public_key = Crypto.blind_public_key(public_key, time_period_length, time_period_num)

    responsible_directories =
      Enum.flat_map(
        1..n_replicas,
        fn replica ->
          index =
            Crypto.HiddenService.build_index(
              blinded_public_key,
              replica,
              time_period_length,
              time_period_num
            )

          case :ets.select(
                 :hidden_service_directory,
                 [{{:"$1", :"$2"}, [{:>=, :"$1", index}], [:"$2"]}],
                 spread_store
               ) do
            {results, _} -> results
            :"$end_of_table" -> []
          end
        end
      )

    case :ets.lookup(:introduction_points, domain) do
      [{_, introduction_points, expire_at}] when network_status.valid_after < expire_at ->
        {:reply, {:ok, introduction_points}, network_status}

      _ ->
        expire_at = get_start_time_of_next_time_period(network_status)

        spawn fn ->
          response =
            responsible_directories
            |> Enum.shuffle()
            |> request_from_next_directory(public_key, blinded_public_key)

          with {:ok, introduction_points} <- response do
            :ets.insert(:introduction_points, {domain, introduction_points, expire_at})
          end

          GenServer.reply(from, response)
        end

        {:noreply, network_status}
    end
  end

  def handle_call({:fetch_router_descriptors, routers}, from, network_status) do
    spawn fn ->
      routers =
        for router <- routers do
          case :ets.lookup(:routers, router.fingerprint) do
            [{_, router}] ->
              router

            _ ->
              router
          end
        end

      fingerprints =
        routers
        |> Stream.filter(&is_nil(&1.ntor_onion_key))
        |> Enum.map(&Base.encode16(&1.fingerprint))

      fast_directories = get_fast_directories(network_status)

      response =
        if fingerprints != [] do
          with {:ok, descriptors} <- do_fetch_router_descriptors(fast_directories, fingerprints) do
            descriptors_map = for d <- descriptors, into: %{}, do: {d.fingerprint, d}

            routers =
              Enum.map(routers, &struct(&1, Map.get(descriptors_map, &1.fingerprint, %{})))

            Enum.each(routers, &:ets.insert(:routers, {&1.fingerprint, &1}))

            {:ok, routers}
          end
        else
          {:ok, routers}
        end

      GenServer.reply(from, response)
    end

    {:noreply, network_status}
  end

  defp prefetch_router_descriptors(network_status) do
    routers =
      network_status.routers
      |> Stream.chunk_every(512)
      |> Enum.flat_map(fn routers ->
        fingerprints = Enum.map(routers, &Base.encode16(&1.fingerprint))

        fast_directories = get_fast_directories(network_status)

        case do_fetch_router_descriptors(fast_directories, fingerprints) do
          {:ok, descriptors} ->
            descriptors_map = for d <- descriptors, into: %{}, do: {d.fingerprint, d}
            Enum.map(routers, &struct(&1, Map.get(descriptors_map, &1.fingerprint, %{})))

          _ ->
            routers
        end
      end)

    %{network_status | routers: routers}
  end

  defp get_fast_routers(network_status) do
    network_status.routers
    |> Enum.sort_by(&Map.get(&1.bandwidth, "Bandwidth"))
    |> Enum.reverse()
    |> Enum.take(@router_pool_size)
  end

  defp get_fast_directories(network_status) do
    network_status.routers
    |> Enum.filter(&(&1.directory_port > 0))
    |> Enum.sort_by(&Map.get(&1.bandwidth, "Bandwidth"))
    |> Enum.reverse()
    |> Enum.take(@router_pool_size)
  end

  defp do_fetch_router_descriptors(directories, fingerprints, retries \\ 3)

  defp do_fetch_router_descriptors(_directories, _fingerprints, 0),
    do: {:error, :directory_unavailable}

  defp do_fetch_router_descriptors(directories, fingerprints, retries) do
    directory = Enum.random(directories)

    Logger.debug(
      "Fetching router descriptors for #{Enum.join(fingerprints, ", ")} " <>
        "from #{directory.nickname} #{:inet.ntoa(directory.ipv4)}:#{directory.directory_port}"
    )

    with {:ok, response} <-
           do_directory_request(directory, "/tor/server/fp/#{Enum.join(fingerprints, "+")}.z"),
         {:ok, [_ | _] = descriptors} <- Garlic.Router.Descriptor.parse(response) do
      {:ok, descriptors}
    else
      _ -> do_fetch_router_descriptors(directories, fingerprints, retries - 1)
    end
  end

  defp download do
    directory = Enum.random(authorities())

    Logger.info(
      "Connecting to directory authority #{directory.nickname} at #{:inet.ntoa(directory.ipv4)}"
    )

    network_status =
      with {:ok, response} <-
             do_directory_request(directory, "/tor/status-vote/current/authority.z"),
           {:ok, network_status} <- Document.parse(response) do
        if Application.get_env(:garlic, :prefetch_router_descriptors, false) do
          prefetch_router_descriptors(network_status)
        else
          network_status
        end
      else
        _ -> download()
      end

    File.mkdir_p(cache_directory())
    File.write(cache_path(), :erlang.term_to_binary(network_status))

    network_status
  end

  defp read_cached do
    now = System.system_time(:second)

    with {:ok, file} <- File.read(cache_path()),
         %__MODULE__{fresh_until: fresh_until} = network_status
         when now < fresh_until <- :erlang.binary_to_term(file) do
      network_status
    else
      _ -> nil
    end
  end

  defp cache_path do
    suffix =
      case Application.get_env(:garlic, :authorities) do
        nil -> ""
        auths -> "_" <> (:erlang.phash2(auths) |> Integer.to_string(16))
      end

    Path.join(cache_directory(), "network_status#{suffix}")
  end

  defp cache_directory do
    Application.get_env(:garlic, :cache_path, Path.join(System.tmp_dir!(), "garlic"))
  end

  def get_time_period_num(
        %__MODULE__{time_period_length: time_period_length, valid_after: valid_after} =
          network_status,
        unix_time \\ nil
      ) do
    t = unix_time || valid_after || System.system_time(:second)

    div(
      div(t, 60) - 12 * div(get_voting_interval(network_status), 60),
      time_period_length
    )
  end

  def get_voting_interval(%__MODULE__{
        valid_after: valid_after,
        fresh_until: fresh_until
      })
      when not is_nil(valid_after) and not is_nil(fresh_until),
      do: fresh_until - valid_after

  def get_voting_interval(network_status) when is_struct(network_status, __MODULE__),
    do: network_status.default_voting_interval

  def get_start_time_of_next_time_period(
        %__MODULE__{time_period_length: time_period_length} = network_status,
        unix_time \\ System.system_time(:second)
      ) do
    time_period_num = get_time_period_num(network_status, unix_time)
    (time_period_num + 1) * time_period_length * 60 + 12 * get_voting_interval(network_status)
  end

  def get_shared_random_start_time(%__MODULE__{valid_after: valid_after} = network_status) do
    voting_interval = get_voting_interval(network_status)
    current_round_slot = Integer.mod(div(valid_after, voting_interval), 12 * 2)
    valid_after - current_round_slot * voting_interval
  end

  def get_shared_random(
        %__MODULE__{current_shared_random: nil, time_period_length: time_period_length} =
          network_status
      ) do
    network_status
    |> get_time_period_num()
    |> Crypto.HiddenService.build_disaster_shared_random(time_period_length)
  end

  def get_shared_random(
        %__MODULE__{
          current_shared_random: current_shared_random,
          previous_shared_random: previous_shared_random,
          valid_after: valid_after,
          time_period_length: time_period_length
        } = network_status
      ) do
    shared_random_start_time = get_shared_random_start_time(network_status)

    start_time_of_next_time_period =
      get_start_time_of_next_time_period(network_status, shared_random_start_time)

    if valid_after >= shared_random_start_time and valid_after < start_time_of_next_time_period do
      previous_shared_random || current_shared_random ||
        network_status
        |> get_time_period_num()
        |> Crypto.HiddenService.build_disaster_shared_random(time_period_length)
    else
      current_shared_random ||
        network_status
        |> get_time_period_num()
        |> Crypto.HiddenService.build_disaster_shared_random(time_period_length)
    end
  end

  defp do_directory_request(directory, path) do
    {ip, port} = Garlic.resolve_address(directory.ipv4, directory.directory_port)
    host = :inet.ntoa(ip)
    url = ~c"http://#{host}:#{port}#{path}"

    opts = [timeout: @directory_timeout]

    case :httpc.request(:get, {url, []}, opts, []) do
      {:ok, {{_, 200, _}, _, body}} ->
        try do
          {:ok, :zlib.uncompress(body)}
        catch
          :error, :data_error -> {:error, :compression}
        end

      {:ok, _} ->
        {:error, :bad_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_from_next_directory([directory | tail], public_key, blinded_public_key) do
    [router] =
      pick_fast_routers(1)
      |> Enum.reject(&(&1.fingerprint == directory.fingerprint))
      |> case do
        [] -> pick_fast_routers(2) |> Enum.reject(&(&1.fingerprint == directory.fingerprint))
        routers -> routers
      end
      |> Enum.take(1)

    path = "/tor/hs/3/#{Base.encode64(blinded_public_key, padding: false)}"

    result =
      with {:ok, pid} <- Circuit.start(),
           :ok <- Circuit.build_circuit(pid, [router, directory]) do
        response =
          pid
          |> Client.request(1, "directory", 0, "GET", path, [], "")
          |> Enum.join()

        Logger.debug(
          "HSDir #{directory.nickname} response for #{Base.encode16(blinded_public_key, case: :lower)}: #{byte_size(response)} bytes"
        )

        Crypto.HiddenService.Descriptor.decode(response, public_key, blinded_public_key)
      end

    with {:error, reason} <- result do
      Logger.debug("HSDir #{directory.nickname} failed: #{inspect(reason)}")
      request_from_next_directory(tail, public_key, blinded_public_key)
    end
  end

  defp request_from_next_directory([], _, _), do: {:error, :introduction_points}

  defp detect_testing_network(%__MODULE__{} = ns) do
    voting_interval = get_voting_interval(ns)

    if voting_interval < 3600 do
      # SRV protocol run = 24 rounds × voting_interval
      %{ns | time_period_length: div(24 * voting_interval, 60)}
    else
      ns
    end
  end
end
