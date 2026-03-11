defmodule Garlic.ORConnection do
  @moduledoc """
  Multiplexed OR (onion router) connection.

  Manages a single TLS connection to a Tor relay, multiplexing many circuits
  over it using circuit IDs. This mirrors C Tor's `or_connection_t` — one TCP
  connection per relay, shared by all circuits routed through that relay.

  ## Architecture

  Each ORConnection owns:
  - A TLS socket to a single relay
  - A map of `circuit_id => owner_pid` for demultiplexing incoming cells
  - The VERSIONS/CERTS/NETINFO handshake state (performed once)

  Circuits register themselves after creation and send cells through
  `send_cell/3`. Incoming cells are dispatched to the owning circuit process.
  """

  use GenServer

  require Logger

  alias Garlic.Router

  defstruct [
    :socket,
    :router,
    buffer: "",
    circuits: %{},
    status: :disconnected
  ]

  @default_timeout 15_000

  def start_link(router, opts \\ []) do
    GenServer.start_link(__MODULE__, router, opts)
  end

  @doc "Connect to the relay and complete the OR handshake."
  @spec connect(pid(), timeout()) :: :ok | {:error, term()}
  def connect(pid, timeout \\ @default_timeout) do
    GenServer.call(pid, :connect, timeout)
  end

  @doc "Register a circuit ID so incoming cells are forwarded to the caller."
  @spec register_circuit(pid(), pos_integer(), pid()) :: :ok
  def register_circuit(pid, circuit_id, owner) do
    GenServer.call(pid, {:register_circuit, circuit_id, owner})
  end

  @doc "Unregister a circuit ID (circuit closed)."
  @spec unregister_circuit(pid(), pos_integer()) :: :ok
  def unregister_circuit(pid, circuit_id) do
    GenServer.cast(pid, {:unregister_circuit, circuit_id})
  end

  @doc "Send a raw cell (already framed with circuit_id + command + payload)."
  @spec send_cell(pid(), iodata()) :: :ok | {:error, term()}
  def send_cell(pid, cell_data) do
    GenServer.call(pid, {:send_cell, cell_data})
  end

  @doc "How many circuits are using this connection?"
  @spec circuit_count(pid()) :: non_neg_integer()
  def circuit_count(pid) do
    GenServer.call(pid, :circuit_count)
  end

  @doc "Check if the connection is alive and handshake complete."
  @spec connected?(pid()) :: boolean()
  def connected?(pid) do
    GenServer.call(pid, :connected?)
  catch
    :exit, _ -> false
  end

  # -- GenServer callbacks --

  @impl true
  def init(%Router{} = router) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{router: router}}
  end

  @impl true
  def handle_call(:connect, _from, %{status: :connected} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:connect, _from, %{router: router} = state) do
    %Router{ipv4: address, onion_port: port, nickname: nickname} = router

    {address, port} = Garlic.resolve_address(address, port)
    Logger.debug("ORConn: connecting to #{nickname} #{:inet.ntoa(address)}:#{port}")

    tcp_options = [:binary, send_timeout: @default_timeout, active: false]
    ssl_options = [verify: :verify_peer, verify_fun: {&verify_certificate/3, nil}, cacerts: []]

    with {:ok, tcp_socket} <- :gen_tcp.connect(address, port, tcp_options, 10_000),
         {:ok, ssl_socket} <- upgrade_to_tls(tcp_socket, ssl_options),
         {:ok, state} <- do_handshake(%{state | socket: ssl_socket}),
         :ok <- :ssl.setopts(ssl_socket, active: :once) do
      {:reply, :ok, %{state | status: :connected}}
    else
      {:error, reason} ->
        Logger.warning("ORConn: failed to connect to #{nickname}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_circuit, circuit_id, owner}, _from, state) do
    Process.monitor(owner)
    state = put_in(state.circuits[circuit_id], owner)
    {:reply, :ok, state}
  end

  def handle_call({:send_cell, cell_data}, _from, %{socket: socket} = state) do
    case :ssl.send(socket, cell_data) do
      :ok -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:circuit_count, _from, state) do
    {:reply, map_size(state.circuits), state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.status == :connected, state}
  end

  @impl true
  def handle_cast({:unregister_circuit, circuit_id}, state) do
    {:noreply, %{state | circuits: Map.delete(state.circuits, circuit_id)}}
  end

  @impl true
  def handle_info({:ssl, _, data}, %{socket: socket} = state) do
    case dispatch_cells(state, state.buffer <> data) do
      {:ok, state} ->
        :ssl.setopts(socket, active: :once)
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:ssl_closed, _}, state) do
    Logger.debug("ORConn: connection to #{state.router.nickname} closed")
    notify_all_circuits(state, :or_connection_closed)
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, _, reason}, state) do
    Logger.warning("ORConn: SSL error on #{state.router.nickname}: #{inspect(reason)}")
    notify_all_circuits(state, {:or_connection_error, reason})
    {:stop, reason, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    circuits =
      state.circuits
      |> Enum.reject(fn {_id, owner} -> owner == pid end)
      |> Map.new()

    {:noreply, %{state | circuits: circuits}}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket} = _state) when socket != nil do
    close_ssl_socket(socket)
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Connection handshake (VERSIONS / CERTS / AUTH_CHALLENGE / NETINFO) --

  defp do_handshake(state) do
    # Use a temporary circuit ID 0 for the handshake (link-level cells)
    with {:ok, state} <- send_versions(state),
         {:ok, state} <- receive_versions(state),
         {:ok, state} <- receive_certs(state),
         {:ok, state} <- receive_auth_challenge(state),
         {:ok, {their_address, my_address}, state} <- receive_netinfo(state),
         {:ok, state} <- send_netinfo(state, their_address, my_address) do
      {:ok, state}
    end
  end

  defp send_versions(%{socket: socket} = state) do
    payload = <<3::16, 4::16>>
    packet = <<0::16, 7, byte_size(payload)::16, payload::binary>>

    case :ssl.send(socket, packet) do
      :ok -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  defp receive_versions(state) do
    with {:ok, {0, :versions}, state} <- recv_next_cell(state) do
      {:ok, state}
    end
  end

  defp receive_certs(state) do
    with {:ok, {0, :certs, _}, state} <- recv_next_cell(state) do
      {:ok, state}
    end
  end

  defp receive_auth_challenge(state) do
    with {:ok, {0, :auth_challenge}, state} <- recv_next_cell(state) do
      {:ok, state}
    end
  end

  defp receive_netinfo(state) do
    with {:ok, {0, :netinfo, {_, my_address, [their_address | _]}}, state} <-
           recv_next_cell(state) do
      {:ok, {their_address, my_address}, state}
    end
  end

  defp send_netinfo(%{socket: socket} = state, {their_type, their_address}, {my_type, my_address}) do
    padding_size = 514 - 14 - byte_size(their_address) - byte_size(my_address)

    packet =
      <<0::32, 8, System.system_time(:second)::32, their_type, byte_size(their_address),
        their_address::binary, 1, my_type, byte_size(my_address), my_address::binary,
        0::size(padding_size)-unit(8)>>

    case :ssl.send(socket, packet) do
      :ok -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  # -- Cell receive (synchronous, used only during handshake) --

  defp recv_next_cell(%{buffer: buffer, socket: socket} = state) do
    case Garlic.Circuit.Cell.decode(buffer) do
      {:ok, :padding, tail} ->
        recv_next_cell(%{state | buffer: tail})

      {:ok, cell, tail} ->
        {:ok, cell, %{state | buffer: tail}}

      {:more, buffer} ->
        case :ssl.recv(socket, 0, @default_timeout) do
          {:ok, data} -> recv_next_cell(%{state | buffer: buffer <> data})
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Cell dispatch (async, after handshake) --

  defp dispatch_cells(state, data) do
    case Garlic.Circuit.Cell.decode(data) do
      {:ok, :padding, tail} ->
        dispatch_cells(%{state | buffer: ""}, tail)

      {:ok, cell, tail} ->
        state = dispatch_one_cell(state, cell)
        dispatch_cells(%{state | buffer: ""}, tail)

      {:more, buffer} ->
        {:ok, %{state | buffer: buffer}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_one_cell(state, {circuit_id, _command, _payload} = cell) do
    case Map.get(state.circuits, circuit_id) do
      nil ->
        state

      owner_pid ->
        send(owner_pid, {:or_cell, cell})
        state
    end
  end

  defp dispatch_one_cell(state, {circuit_id, _command} = cell) do
    case Map.get(state.circuits, circuit_id) do
      nil ->
        state

      owner_pid ->
        send(owner_pid, {:or_cell, cell})
        state
    end
  end



  defp notify_all_circuits(state, reason) do
    Enum.each(state.circuits, fn {_id, pid} ->
      send(pid, {:or_connection_down, reason})
    end)
  end

  defp upgrade_to_tls(tcp_socket, ssl_options) do
    case :ssl.connect(tcp_socket, ssl_options) do
      {:ok, _} = ok -> ok
      {:error, _} = err ->
        :gen_tcp.close(tcp_socket)
        err
    end
  end

  defp close_ssl_socket(socket) do
    ssl_pids =
      case Process.info(self(), :links) do
        {:links, links} -> Enum.filter(links, &is_pid/1)
        _ -> []
      end

    :ssl.close(socket)

    Enum.each(ssl_pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp verify_certificate(_certificate, _event, _state), do: {:valid, nil}
end
