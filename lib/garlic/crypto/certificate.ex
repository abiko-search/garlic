defmodule Garlic.Crypto.Certificate do
  @moduledoc "Tor ED25519 certificate"

  defstruct version: nil,
            type: nil,
            expiration_date: nil,
            key_type: nil,
            certified_key: nil,
            extensions: [],
            signature: nil

  @type t() :: %__MODULE__{}

  defmodule Extension do
    @moduledoc "Tor ED25519 certificate extension"

    defstruct type: nil,
              flags: nil,
              data: nil

    @type t() :: %__MODULE__{}
  end

  @doc """
  Parses an ED25519 certificate
  """
  @spec parse(binary) :: __MODULE__.t()
  def parse(
        <<version, type, expiration_date::32, key_type, certified_key::binary-size(32),
          n_extensions, tail::binary>>
      ) do
    %__MODULE__{
      version: version,
      type: type,
      expiration_date: expiration_date,
      key_type: key_type,
      certified_key: certified_key
    }
    |> parse_extensions(n_extensions, tail)
  end

  defp parse_extensions(
         certificate,
         n_extensions,
         <<len::16, type, flags, data::binary-size(len), tail::binary>>
       ) do
    certificate
    |> Map.update!(:extensions, &[%Extension{type: type, flags: flags, data: data} | &1])
    |> parse_extensions(n_extensions - 1, tail)
  end

  defp parse_extensions(certificate, 0, <<signature::binary-size(64)>>) do
    %{certificate | signature: signature}
  end
end
