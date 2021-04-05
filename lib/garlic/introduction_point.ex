defmodule Garlic.IntroductionPoint do
  @moduledoc "Hidden service introduction point"

  defstruct [
    :router,
    :encryption_key,
    :onion_key,
    :authentication_key,
    :subcredential
  ]

  @type t() :: %__MODULE__{
          router: Garlic.Router.t(),
          encryption_key: binary,
          onion_key: binary,
          authentication_key: binary,
          subcredential: binary
        }
end
