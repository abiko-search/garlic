defmodule Garlic.Mint.Client do
  @moduledoc false

  require Logger

  # Mint supports custom transport modules as scheme but its typespec doesn't reflect that
  @dialyzer {:nowarn_function, request: 8}

  def request(pid, stream_id, host, port, method, path, headers, body) do
    Stream.resource(
      fn ->
        opts = [
          transport_opts: [pid: pid, stream_id: stream_id]
        ]

        with {:ok, conn} <- Mint.HTTP1.connect(Garlic.Mint.Transport, host, port, opts),
             {:ok, conn, ref} <- Mint.HTTP.request(conn, method, path, headers, body) do
          {conn, ref, :continue}
        else
          {:error, reason} ->
            Logger.warning("Mint connect/request failed: #{inspect(reason)}")
            {nil, nil, :halt}
        end
      end,
      &parse_chunks/1,
      fn
        {nil, _} -> :ok
        {conn, _} -> Mint.HTTP.close(conn)
      end
    )
  end

  def parse_chunks({conn, ref, :halt}) do
    {:halt, {conn, ref}}
  end

  def parse_chunks({conn, ref, :continue}) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, chunks} ->
            handle_chunks(conn, ref, chunks)

          {:error, conn, _error, chunks} ->
            {chunks, {conn, ref, :halt}}
        end
    end
  end

  defp handle_chunks(conn, ref, chunks) do
    next =
      if Keyword.has_key?(chunks, :done) do
        :halt
      else
        :continue
      end

    {filter_data(chunks), {conn, ref, next}}
  end

  defp filter_data(chunks) do
    Enum.flat_map(
      chunks,
      fn
        {:data, _ref, chunk} -> [chunk]
        _ -> []
      end
    )
  end
end
