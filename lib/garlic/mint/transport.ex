defmodule Garlic.Mint.Transport do
  @moduledoc "Mint custom transport for Tor circuits"

  require Logger

  alias Garlic.Circuit

  @behaviour Mint.Core.Transport

  @impl true
  def connect(domain, port, opts) do
    Logger.debug("Connecting to #{domain}:#{port}")

    pid = Keyword.fetch!(opts, :pid)
    stream_id = Keyword.get(opts, :stream_id, 1)

    with :ok <- Circuit.begin(pid, stream_id, domain, port) do
      {:ok, {pid, stream_id}}
    end
  end

  @impl true
  def getopts({pid, _}, opts) do
    Circuit.getopts(pid, opts)
  end

  @impl true
  def setopts({pid, _}, opts) do
    Circuit.setopts(pid, opts)
  end

  @impl true
  def send({pid, stream_id}, payload) do
    Circuit.send(pid, stream_id, payload)
  end

  @impl true
  def close({pid, stream_id}) do
    Circuit.close(pid, stream_id, :done)
  end

  @impl true
  def wrap_error(reason) do
    %Mint.TransportError{reason: reason}
  end

  @impl true
  def recv(_conn, _bytes, _timeout), do: raise("not implemented")

  @impl true
  def controlling_process(_conn, _other_pid), do: raise("not implemented")

  @impl true
  def upgrade(_, _, _, _, _), do: raise("not implemented")

  @impl true
  def negotiated_protocol(_conn), do: raise("not implemented")
end
