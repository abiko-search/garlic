defmodule Garlic.Crypto.Keccak do
  @moduledoc """
  Keccak/SHAKE256 wrapper using OTP's built-in crypto.

  Uses :crypto.hash_xof/3 which takes output length in bits.
  """

  @spec shake256(binary, non_neg_integer) :: binary
  def shake256(input, output_len_bytes)
      when is_binary(input) and is_integer(output_len_bytes) and output_len_bytes >= 0 do
    :crypto.hash_xof(:shake256, input, output_len_bytes * 8)
  end
end
