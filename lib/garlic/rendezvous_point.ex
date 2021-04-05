defmodule Garlic.RendezvousPoint do
  @moduledoc "Hidden service rendezvous point"

  defstruct [
    :introduction_point,
    :public_key,
    :private_key,
    :cookie,
    :router
  ]

  @type t() :: %__MODULE__{
          introduction_point: Garlic.IntroductionPoint.t(),
          public_key: binary,
          private_key: binary,
          cookie: binary,
          router: Garlic.Router.t()
        }

  def build(introduction_point, router) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)

    %__MODULE__{
      cookie: :crypto.strong_rand_bytes(20),
      public_key: public_key,
      private_key: private_key,
      introduction_point: introduction_point,
      router: router
    }
  end
end
