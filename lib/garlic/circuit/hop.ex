defmodule Garlic.Circuit.Hop do
  defstruct forward_digest: nil,
            backward_digest: nil,
            forward_cipher: nil,
            backward_cipher: nil

  @type t() :: %__MODULE__{
          forward_digest: :crypto.hash_state(),
          backward_digest: :crypto.hash_state(),
          forward_cipher: :crypto.crypto_state(),
          backward_cipher: :crypto.crypto_state()
        }
end
