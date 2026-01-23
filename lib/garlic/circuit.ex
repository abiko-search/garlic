defmodule Garlic.Circuit do
  @moduledoc "Tor circuit"

  import Bitwise
  use GenServer

  require Logger

  alias Garlic.{Crypto, Circuit, Router, IntroductionPoint, RendezvousPoint, NetworkStatus}

  defstruct [
    :socket,
    :id,
    :public_key,
    :private_key,
    :rendezvous_point,
    routers: [],
    hops: [],
    buffer: "",
    window: 1000,
    streams: %{}
  ]

  @type id :: pos_integer

  @type t() :: %__MODULE__{
          socket: :ssl.socket(),
          id: id,
          public_key: binary,
          private_key: binary,
          rendezvous_point: RendezvousPoint.t(),
          routers: list(Router.t()),
          hops: list(Circuit.Hop.t()),
          buffer: binary,
          window: integer,
          streams: %{Circuit.Stream.id() => Circuit.Stream.t()}
        }

  @default_timeout 10_000

  @spec start(id) :: {:ok, pid} | {:error, any}
  def start(id \\ :rand.uniform(0x0FFFFFFF)) do
    GenServer.start(__MODULE__, id)
  end

  @spec start_link(id, binary) :: {:ok, pid} | {:error, any}
  def start_link(id, domain) do
    GenServer.start_link(__MODULE__, id, name: {:via, Registry, {Garlic.CircuitRegistry, domain}})
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, opts}
    }
  end

  @spec connect(pid, Router.t(), timeout) :: :ok | {:error, atom}
  def connect(pid, router, timeout \\ @default_timeout) do
    GenServer.call(pid, {:connect, router}, timeout)
  end

  @spec extend(pid, Router.t(), timeout) :: :ok | {:error, atom}
  def extend(pid, router, timeout \\ @default_timeout) do
    GenServer.call(pid, {:extend, router}, timeout)
  end

  @spec begin(pid, Circuit.Stream.id(), binary, non_neg_integer, timeout) ::
          :ok | {:error, atom}
  def begin(pid, stream_id, domain, port, timeout \\ @default_timeout)

  def begin(pid, stream_id, "directory", _, timeout) do
    GenServer.call(pid, {:relay_begin_dir, stream_id}, timeout)
  end

  def begin(pid, stream_id, domain, port, timeout) do
    GenServer.call(pid, {:relay_begin, stream_id, domain, port}, timeout)
  end

  @spec establish_rendezvous(pid, Circuit.Stream.id(), RendezvousPoint.t(), timeout) ::
          :ok | {:error, atom}
  def establish_rendezvous(pid, stream_id, rendezvous_point, timeout \\ @default_timeout) do
    GenServer.call(pid, {:relay_establish_rendezvous, stream_id, rendezvous_point}, timeout)
  end

  @spec await_rendezvous(pid, Circuit.Stream.id(), timeout) :: :ok | {:error, atom}
  def await_rendezvous(pid, stream_id, timeout \\ @default_timeout) do
    GenServer.call(pid, {:await_rendezvous, stream_id}, timeout)
  end

  @spec introduce(pid, Circuit.Stream.id(), RendezvousPoint.t(), timeout) ::
          :ok | {:error, atom}
  def introduce(pid, stream_id, rendezvous_point, timeout \\ @default_timeout) do
    GenServer.call(pid, {:relay_introduce, stream_id, rendezvous_point}, timeout)
  end

  @spec send(pid, Circuit.Stream.id(), iodata, timeout) :: :ok | {:error, atom}
  def send(pid, stream_id, data, timeout \\ @default_timeout) do
    GenServer.call(pid, {:send, stream_id, data}, timeout)
  end

  @spec getopts(pid, Keyword.t()) :: {:ok, [:gen_tcp.option()]} | {:error, any}
  def getopts(pid, opts) do
    GenServer.call(pid, {:getopts, opts})
  end

  @spec setopts(pid, Keyword.t()) :: {:ok, [:gen_tcp.option()]} | {:error, any}
  def setopts(pid, opts) do
    GenServer.call(pid, {:setopts, opts})
  end

  @spec close(pid) :: :ok | {:error, atom}
  def close(pid) do
    GenServer.call(pid, :close)
  end

  @spec close(pid, Circuit.Stream.id(), atom, timeout) :: :ok | {:error, atom}
  def close(pid, stream_id, reason, timeout \\ @default_timeout) do
    GenServer.call(pid, {:relay_end, stream_id, reason}, timeout)
  end

  @spec build_circuit(pid, nonempty_list(Router.t())) :: :ok | {:error, atom}
  def build_circuit(pid, routers) do
    with {:ok, routers} <- NetworkStatus.fetch_router_descriptors(routers) do
      do_build_circuit(pid, routers)
    end
  end

  @spec build_rendezvous(pid, nonempty_list(Router.t()), binary) :: :ok | {:error, atom}
  def build_rendezvous(pid, routers, domain) do
    with {:ok, routers} <- NetworkStatus.fetch_router_descriptors(routers),
         {:ok, introduction_points} <- NetworkStatus.fetch_intoduction_points(domain),
         introduction_point <- Enum.random(introduction_points),
         rendezvous_point <- RendezvousPoint.build(introduction_point, List.last(routers)),
         :ok <- do_build_circuit(pid, routers),
         :ok <- establish_rendezvous(pid, 1, rendezvous_point) do
      spawn_link(fn -> do_introduction(rendezvous_point) end)
      await_rendezvous(pid, 1)
    end
  end

  defp do_build_circuit(pid, [head | tail]) do
    with :ok <- connect(pid, head) do
      Enum.reduce_while(tail, :ok, fn router, _ ->
        case extend(pid, router) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp do_introduction(
         %RendezvousPoint{
           introduction_point: %IntroductionPoint{
             router: introduction_router
           }
         } = rendezvous_point
       ) do
    with [router] <- NetworkStatus.pick_fast_routers(1),
         {:ok, pid} <- start(),
         :ok <- build_circuit(pid, [router, introduction_router]) do
      introduce(pid, 1, rendezvous_point)
    end
  end

  @impl true
  def init(id) do
    {:ok, %Circuit{id: id ||| 0x80000000}}
  end

  @impl true
  def handle_call(
        {:connect, %Router{ipv4: address, onion_port: port, nickname: nickname} = router},
        _from,
        circuit
      ) do
    Logger.metadata(circuit_id: circuit.id &&& 0x0FFFFFFF)
    Logger.debug("Connecting to #{nickname} #{:inet.ntoa(address)}:#{port}")

    tcp_options = [:binary, send_timeout: @default_timeout, active: false]
    ssl_options = [verify: :verify_peer, verify_fun: {&verify_certificate/3, nil}]

    with {:ok, socket} <- :gen_tcp.connect(address, port, tcp_options),
         {:ok, socket} <- :ssl.connect(socket, ssl_options),
         {:ok, circuit} <- send_versions(%{circuit | socket: socket, routers: [router]}),
         {:ok, circuit} <- receive_versions(circuit),
         {:ok, circuit} <- receive_certs(circuit),
         {:ok, circuit} <- receive_auth_challenge(circuit),
         {:ok, {their_address, my_address}, circuit} <- receive_netinfo(circuit),
         {:ok, circuit} <- send_netinfo(circuit, their_address, my_address),
         {:ok, circuit} <- send_create2(generate_keypair(circuit)),
         {:ok, circuit} <- receive_created2(circuit) do
      {:reply, :ok, circuit}
    else
      {:ok, _, _} ->
        {:stop, :protocol, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call(
        {:extend,
         %Router{
           fingerprint: fingerprint,
           ntor_onion_key: ntor_onion_key,
           ipv4: addr,
           onion_port: port,
           nickname: nickname
         } = router},
        _from,
        %Circuit{public_key: public_key} = circuit
      ) do
    Logger.debug("Extending to #{nickname} #{:inet.ntoa(addr)}:#{port}")

    payload = [
      Router.build_link_specifiers(router),
      <<2::16, 84::16>>,
      fingerprint,
      ntor_onion_key,
      public_key
    ]

    with {:ok, circuit} <- send_relay(circuit, 0, 14, payload),
         circuit <- put_in(circuit.routers, [router | circuit.routers]),
         {:ok, circuit} <- receive_relay_extended2(circuit) do
      {:reply, :ok, circuit}
    else
      {:ok, _, _} ->
        {:stop, :protocol, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call({:relay_begin, stream_id, domain, port}, from, circuit) do
    Logger.debug("Sending RELAY_BEGIN")

    payload = <<"#{domain}:#{port}\0", 0::32>>

    with {:ok, circuit} <- send_relay(circuit, stream_id, 1, payload),
         :ok <- :ssl.setopts(circuit.socket, active: :once) do
      {:noreply, put_in(circuit.streams[stream_id], %Circuit.Stream{from: from})}
    else
      {:error, reason} -> {:stop, reason, circuit}
    end
  end

  def handle_call({:relay_begin_dir, stream_id}, from, circuit) do
    Logger.debug("Sending RELAY_BEGIN_DIR")

    with {:ok, circuit} <- send_relay(circuit, stream_id, 13, <<>>),
         :ok <- :ssl.setopts(circuit.socket, active: :once) do
      {:noreply, put_in(circuit.streams[stream_id], %Circuit.Stream{from: from})}
    else
      {:error, reason} -> {:stop, reason, circuit}
    end
  end

  def handle_call({:relay_end, stream_id, reason}, _from, circuit) do
    Logger.debug("Sending RELAY_END")

    reason =
      Enum.find_index(
        ~w(misc resolvefailed connectrefused exitpolicy destroy done timeout noroute
           hibernating internal resourcelimit connreset torprotocol notdirectory)a,
        &(&1 == reason)
      ) + 1

    case send_relay(circuit, stream_id, 3, <<reason>>) do
      {:ok, circuit} ->
        {:reply, :ok, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call({:relay_establish_rendezvous, stream_id, rendezvous_point}, _from, circuit) do
    Logger.debug("Sending RELAY_ESTABLISH_RENDEZVOUS")

    with {:ok, circuit} <- send_relay(circuit, stream_id, 33, rendezvous_point.cookie),
         {:ok, circuit} <- receive_relay_rendezvous_established(circuit) do
      {:reply, :ok, %{circuit | rendezvous_point: rendezvous_point}}
    else
      {:ok, _, _} ->
        {:stop, :protocol, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call({:await_rendezvous, _stream_id}, _from, circuit) do
    Logger.debug("Sending RELAY_ESTABLISH_RENDEZVOUS")

    case receive_relay_rendezvous2(circuit) do
      {:ok, circuit} ->
        {:reply, :ok, circuit}

      {:ok, _, _} ->
        {:stop, :protocol, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call({:relay_introduce, stream_id, rendezvous_point}, _from, circuit) do
    Logger.debug("Sending RELAY_INTRODUCE1")

    payload = Crypto.HiddenService.build_introduction(rendezvous_point)

    with {:ok, circuit} <- send_relay(circuit, stream_id, 34, payload),
         {:ok, circuit} <- receive_relay_introduce_ack(circuit) do
      {:reply, :ok, circuit}
    else
      {:ok, _, _} ->
        {:stop, :protocol, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call({:send, stream_id, data}, from, circuit) do
    Logger.debug("Sending RELAY_DATA ##{stream_id}")

    case send_relay(circuit, stream_id, 2, data) do
      {:ok, circuit} ->
        {:reply, :ok, put_in(circuit.streams[stream_id].from, from)}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_call(:close, _from, circuit) do
    {:reply, :ssl.close(circuit.socket), circuit}
  end

  def handle_call({:getopts, opts}, _from, circuit) do
    {:reply, :ssl.getopts(circuit.socket, opts), circuit}
  end

  def handle_call({:setopts, opts}, _from, circuit) do
    {:reply, :ssl.setopts(circuit.socket, opts), circuit}
  end

  # Handle terminate and report circuit

  @impl true
  def handle_info({:ssl, _, data}, circuit) do
    case handle_data(circuit, data) do
      {:ok, circuit} ->
        {:noreply, circuit}

      {:error, reason} ->
        {:stop, reason, circuit}
    end
  end

  def handle_info({:ssl_closed, _}, _) do
    Logger.debug("Connection closed")

    {:stop, :normal, :closed, nil}
  end

  defp verify_certificate(_certificate, _event, _state), do: {:valid, nil}

  defp receive_versions(circuit) do
    with {:ok, {0, :versions}, circuit} <- recv_next_cell(circuit, "") do
      Logger.debug("Received VERSIONS")

      {:ok, circuit}
    end
  end

  defp receive_certs(circuit) do
    with {:ok, {0, :certs, _}, circuit} <- recv_next_cell(circuit, "") do
      Logger.debug("Received CERTS")

      {:ok, circuit}
    end
  end

  defp receive_auth_challenge(circuit) do
    with {:ok, {0, :auth_challenge}, circuit} <- recv_next_cell(circuit, "") do
      Logger.debug("Received AUTH_CHALLENGE")

      {:ok, circuit}
    end
  end

  defp receive_netinfo(circuit) do
    with {:ok, {0, :netinfo, {_, my_address, [their_address | _]}}, circuit} <-
           recv_next_cell(circuit, "") do
      Logger.debug("Received NETINFO")

      {:ok, {their_address, my_address}, circuit}
    end
  end

  defp receive_created2(%Circuit{id: circuit_id} = circuit) do
    with {:ok, {^circuit_id, :created2, {server_public_key, auth}}, circuit} <-
           recv_next_cell(circuit, "") do
      Logger.debug("Received CREATED2")

      with {:ok, hop} <- Crypto.complete_ntor_handshake(circuit, server_public_key, auth) do
        {:ok, %{circuit | hops: [hop | circuit.hops]}}
      end
    end
  end

  defp receive_relay(%Circuit{id: circuit_id} = circuit) do
    with {:ok, {^circuit_id, :relay, relay_cell}, circuit} <- recv_next_cell(circuit, "") do
      decode_relay_cell(circuit, relay_cell)
    end
  end

  defp receive_relay_extended2(%Circuit{hops: hops} = circuit) do
    with {:ok, {_, :extended2, {server_public_key, auth}}, circuit} <-
           receive_relay(circuit) do
      Logger.debug("Received RELAY_EXTENDED2")

      with {:ok, hop} <- Crypto.complete_ntor_handshake(circuit, server_public_key, auth) do
        {:ok, %{circuit | hops: [hop | hops]}}
      end
    end
  end

  defp receive_relay_rendezvous_established(circuit) do
    with {:ok, {_, :rendezvous_established}, circuit} <- receive_relay(circuit) do
      Logger.debug("Received RELAY_RENDEZVOUS_ESTABLISHED")

      {:ok, circuit}
    end
  end

  defp receive_relay_rendezvous2(%Circuit{hops: hops} = circuit) do
    with {:ok, {_, :rendezvous2, {server_public_key, auth}}, circuit} <-
           receive_relay(circuit) do
      Logger.debug("Received RELAY_RENDEZVOUZ2")

      with {:ok, hop} <-
             Crypto.HiddenService.complete_ntor_handshake(circuit, server_public_key, auth) do
        {:ok, %{circuit | hops: [hop | hops]}}
      end
    end
  end

  defp receive_relay_introduce_ack(circuit) do
    with {:ok, {_, :introduce_ack, status}, circuit} <- receive_relay(circuit) do
      Logger.debug("Received RELAY_INTRODUCE_ACK #{status}")

      if status == :success do
        {:ok, circuit}
      else
        {:error, :"introduce_#{status}"}
      end
    end
  end

  defp generate_keypair(circuit) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)
    %{circuit | public_key: public_key, private_key: private_key}
  end

  defp recv_next_cell(%Circuit{buffer: buffer, socket: socket} = circuit, data) do
    case Circuit.Cell.decode(buffer <> data) do
      {:ok, cell, tail} ->
        {:ok, cell, %{circuit | buffer: tail}}

      {:more, buffer} ->
        with {:ok, data} <- :ssl.recv(socket, 0) do
          recv_next_cell(%{circuit | buffer: buffer}, data)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_data(%Circuit{buffer: buffer} = circuit, data) do
    case Circuit.Cell.decode(buffer <> data) do
      {:ok, cell, tail} ->
        with {:ok, circuit} <- handle_cell(circuit, cell) do
          handle_data(%{circuit | buffer: ""}, tail)
        end

      {:more, buffer} ->
        {:ok, %{circuit | buffer: buffer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_cell(%Circuit{id: circuit_id}, {circuit_id, :destroy, reason}) do
    Logger.debug("Received DESTROY #{reason}")

    {:error, reason}
  end

  defp handle_cell(%Circuit{id: circuit_id} = circuit, {circuit_id, :relay, relay_cell}) do
    with {:ok, relay_cell, circuit} <- decode_relay_cell(circuit, relay_cell) do
      handle_relay_cell(circuit, relay_cell)
    end
  end

  defp handle_cell(circuit, _), do: {:ok, circuit}

  defp handle_relay_cell(circuit, {stream_id, :connected, _, _, _}) do
    Logger.debug("Received RELAY_CONNECTED ##{stream_id}")

    with %Circuit.Stream{from: from} <- circuit.streams[stream_id] do
      GenServer.reply(from, :ok)
    end

    {:ok, circuit}
  end

  defp handle_relay_cell(circuit, {stream_id, :data, data}) do
    %Circuit.Stream{from: {pid, _}} = circuit.streams[stream_id]

    send(pid, {:ssl, {self(), stream_id}, data})

    circuit =
      circuit.streams[stream_id]
      |> update_in(&decrement_window/1)
      |> decrement_window()

    with {:ok, circuit} <- consider_sending_circuit_sendme(circuit),
         {:ok, circuit} <- consider_sending_stream_sendme(circuit, stream_id) do
      {:ok, circuit}
    end
  end

  defp handle_relay_cell(circuit, {stream_id, :end, reason}) do
    Logger.debug("Received RELAY_END ##{stream_id} #{reason}")

    with %Circuit.Stream{from: {pid, _}} <- circuit.streams[stream_id] do
      send(pid, {:ssl_closed, {self(), stream_id}})
    end

    {:ok, %{circuit | streams: Map.delete(circuit.streams, stream_id)}}
  end

  defp handle_relay_cell(circuit, {stream_id, :truncated, reason}) do
    Logger.debug("Received RELAY_TRUNCATED ##{stream_id} #{reason}")

    %Circuit.Stream{from: {pid, _}} = circuit.streams[stream_id]

    send(pid, {:ssl_closed, {self(), stream_id}})

    {:ok, %{circuit | streams: Map.delete(circuit.streams, stream_id)}}
  end

  defp handle_relay_cell(circuit, {stream_id, :sendme}) do
    Logger.debug("Received RELAY_SENDME ##{stream_id}")

    {:ok, circuit}
  end

  defp send_versions(%Circuit{socket: socket, id: circuit_id} = circuit) do
    Logger.debug("Sending VERSIONS")

    payload = <<3::16, 4::16>>
    packet = <<circuit_id::16, 7, byte_size(payload)::16, payload::binary>>

    with :ok <- :ssl.send(socket, packet) do
      {:ok, circuit}
    end
  end

  defp send_netinfo(
         %Circuit{socket: socket, id: circuit_id} = circuit,
         {their_type, their_address},
         {my_type, my_address}
       ) do
    Logger.debug("Sending NETINFO")

    padding_size = 514 - 14 - byte_size(their_address) - byte_size(my_address)

    packet =
      <<circuit_id::32, 8, System.system_time(:second)::32, their_type, byte_size(their_address),
        their_address::binary, 1, my_type, byte_size(my_address), my_address::binary,
        0::size(padding_size)-unit(8)>>

    with :ok <- :ssl.send(socket, packet) do
      {:ok, circuit}
    end
  end

  defp send_create2(
         %Circuit{
           socket: socket,
           public_key: public_key,
           id: circuit_id,
           routers: [
             %Router{
               fingerprint: fingerprint,
               ntor_onion_key: ntor_onion_key
             }
           ]
         } = circuit
       ) do
    Logger.debug("Sending CREATE2")

    padding_size = 514 - 9 - 84

    packet = [
      <<circuit_id::32, 10, 2::16, 84::16>>,
      fingerprint,
      ntor_onion_key,
      public_key,
      <<0::size(padding_size)-unit(8)>>
    ]

    with :ok <- :ssl.send(socket, packet) do
      {:ok, circuit}
    end
  end

  defp send_relay(
         %Circuit{
           socket: socket,
           id: circuit_id,
           hops: [%Circuit.Hop{forward_digest: forward_digest} = last_hop | prev_hops] = hops
         } = circuit,
         stream_id,
         command_id,
         data
       ) do
    head = <<command_id, 0::16, stream_id::16>>
    data_size = IO.iodata_length(data)
    padding_size = 514 - 5 - byte_size(head) - 6 - data_size

    data = [<<data_size::16>>, data, <<0::size(padding_size)-unit(8)>>]

    {digest, forward_digest} = Crypto.digest_relay_cell(head, data, forward_digest)

    command = if Enum.count(hops) > 1, do: 3, else: 9

    packet = [
      <<circuit_id::32, command>>,
      Enum.reduce(
        hops,
        [head, digest, data],
        fn %Circuit.Hop{forward_cipher: forward_cipher}, data ->
          :crypto.crypto_update(forward_cipher, data)
        end
      )
    ]

    with :ok <- :ssl.send(socket, packet) do
      hops = [%{last_hop | forward_digest: forward_digest} | prev_hops]

      {:ok, %{circuit | hops: hops}}
    end
  end

  defp decode_relay_cell(%Circuit{hops: hops} = circuit, relay_cell) do
    with {:ok, relay_cell, hops} <- decrypt_relay_cell_layer(relay_cell, Enum.reverse(hops)),
         {:ok, relay_cell} <- Circuit.RelayCell.decode(relay_cell) do
      {:ok, relay_cell, %{circuit | hops: hops}}
    end
  end

  defp decrypt_relay_cell_layer(inner_cell, next_hops, previous_hops \\ [])

  defp decrypt_relay_cell_layer(inner_cell, [hop | next_hops], previous_hops) do
    inner_cell = :crypto.crypto_update(hop.backward_cipher, inner_cell)

    with <<command_id, 0::16, stream_id::16, digest::binary-size(4), tail::binary>> <-
           inner_cell,
         {^digest, backward_digest} <-
           Crypto.digest_relay_cell(
             <<command_id, 0::16, stream_id::16>>,
             tail,
             hop.backward_digest
           ) do
      hops = List.flatten([%{hop | backward_digest: backward_digest} | previous_hops], next_hops)

      {:ok, inner_cell, hops}
    else
      _ ->
        decrypt_relay_cell_layer(inner_cell, next_hops, [hop | previous_hops])
    end
  end

  defp decrypt_relay_cell_layer(_, [], _), do: {:error, :encryption}

  defp consider_sending_stream_sendme(
         %Circuit{
           streams: streams,
           hops: [%Circuit.Hop{backward_digest: backward_digest} | _]
         } = circuit,
         stream_id
       ) do
    case streams[stream_id] do
      %Circuit.Stream{window: window} when rem(window, 50) == 0 ->
        Logger.debug("Sending stream-level RELAY_SENDME ##{stream_id} [#{window}]")

        payload = <<1, 20::16, :crypto.hash_final(backward_digest)::binary>>

        send_relay(circuit, stream_id, 5, payload)

      _ ->
        {:ok, circuit}
    end
  end

  defp consider_sending_circuit_sendme(
         %Circuit{
           window: window,
           hops: [%Circuit.Hop{backward_digest: backward_digest} | _]
         } = circuit
       )
       when rem(window, 100) == 0 do
    Logger.debug("Sending circuit-level RELAY_SENDME [#{window}]")

    send_relay(circuit, 0, 5, <<1, 20::16, :crypto.hash_final(backward_digest)::binary>>)
  end

  defp consider_sending_circuit_sendme(circuit), do: {:ok, circuit}

  defp decrement_window(item), do: Map.update!(item, :window, &(&1 - 1))
end
