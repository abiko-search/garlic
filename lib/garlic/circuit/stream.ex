defmodule Garlic.Circuit.Stream do
  defstruct window: 500,
            from: nil

  @type t() :: %__MODULE__{
          window: integer,
          from: GenServer.from()
        }

  @type id :: pos_integer
end
