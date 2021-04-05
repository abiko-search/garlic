defmodule Garlic.Crypto.Keccak do
  use Bitwise

  @spec shake256(binary, integer) :: binary
  def shake256(input, output_len)
      when is_binary(input) and is_integer(output_len) and output_len >= 0 do
    keccak(1088, 512, input, 31, output_len)
  end

  defp rol64(a, n) do
    rem((a >>> (64 - rem(n, 64))) + (a <<< rem(n, 64)), 1 <<< 64)
  end

  defp keccak_f_1600_on_lanes(lanes) do
    keccak_f_1600_on_lanes(lanes, 1, 0)
  end

  defp keccak_f_1600_on_lanes(lanes, _r, 24), do: lanes

  defp keccak_f_1600_on_lanes(lanes, r, var_round) do
    lanes = theta(lanes)
    lanes = rho_and_pi(mget(lanes, 1, 0), lanes, 1, 0, 0)
    {lanes, rn} = iota(chi(lanes, 0), r, 0)

    keccak_f_1600_on_lanes(lanes, rn, var_round + 1)
  end

  defp theta(lanes) do
    c =
      for x <- 0..4 do
        e = elem(lanes, x)

        elem(e, 0)
        |> bxor(elem(e, 1))
        |> bxor(elem(e, 2))
        |> bxor(elem(e, 3))
        |> bxor(elem(e, 4))
      end

    d =
      for x <- 0..4 do
        bxor(Enum.at(c, rem(x + 4, 5)), rol64(Enum.at(c, rem(x + 1, 5)), 1))
      end

    List.to_tuple(
      for x <- 0..4 do
        List.to_tuple(for y <- 0..4, do: bxor(mget(lanes, x, y), Enum.at(d, x)))
      end
    )
  end

  defp rho_and_pi(_current, lanes, _x, _y, 24), do: lanes

  defp rho_and_pi(current, lanes, x, y, t) do
    xn = y
    yn = rem(2 * x + 3 * y, 5)
    zn = rol64(current, div((t + 1) * (t + 2), 2))

    rho_and_pi(mget(lanes, xn, yn), mput(lanes, xn, yn, zn), xn, yn, t + 1)
  end

  defp chi(lanes, 5), do: lanes

  defp chi(lanes, y) do
    t = List.to_tuple(for x <- 0..4, do: mget(lanes, x, y))

    chi(lanes, t, y, 0)
  end

  defp chi(lanes, _t, y, 5) do
    chi(lanes, y + 1)
  end

  defp chi(lanes, t, y, x) do
    v = bxor(elem(t, x), ~~~elem(t, rem(x + 1, 5)) &&& elem(t, rem(x + 2, 5)))
    chi(mput(lanes, x, y, v), t, y, x + 1)
  end

  defp iota(lanes, r, 7), do: {lanes, r}

  defp iota(lanes, r, j) do
    rn = rem(bxor(r <<< 1, (r >>> 7) * 113), 256)

    if band(rn, 2) == 0 do
      iota(lanes, rn, j + 1)
    else
      right = 1 <<< ((1 <<< j) - 1)
      left = mget(lanes, 0, 0)
      down = bxor(left, right)
      v = down
      iota(mput(lanes, 0, 0, v), rn, j + 1)
    end
  end

  defp keccak_f_1600(state) do
    state
    |> load_lanes()
    |> keccak_f_1600_on_lanes()
    |> store_lanes()
  end

  defp load_lanes(state) do
    load_lanes(state, 0, 0, [], [])
  end

  defp load_lanes(_state, 5, _y, [], lanes) do
    lanes
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp load_lanes(state, x, 5, lane, lanes) do
    load_lanes(state, x + 1, 0, [], [List.to_tuple(Enum.reverse(lane)) | lanes])
  end

  defp load_lanes(state, x, y, lane, lanes) do
    <<b::size(64)-unsigned-little-integer-unit(1)>> = binary_part(state, 8 * (x + 5 * y), 8)
    load_lanes(state, x, y + 1, [b | lane], lanes)
  end

  defp store_lanes(lanes) do
    store_lanes(lanes, 0, 0, <<0::1600>>)
  end

  defp store_lanes(_lanes, 5, _y, state), do: state

  defp store_lanes(lanes, x, 5, state) do
    store_lanes(lanes, x + 1, 0, state)
  end

  defp store_lanes(lanes, x, y, state) do
    pos = 8 * (x + 5 * y)
    <<state_head::size(pos)-binary, _::size(8)-binary, state_tail::binary>> = state

    store_lanes(
      lanes,
      x,
      y + 1,
      <<state_head::binary, mget(lanes, x, y)::size(64)-unsigned-little-integer-unit(1),
        state_tail::binary>>
    )
  end

  defp keccak(rate, capacity, input, delimited_suffix, output_len)
       when rate + capacity == 1600 and rem(rate, 8) == 0 do
    {rate, state} = keccak_absorb(div(rate, 8), input, <<0::1600>>, delimited_suffix)

    keccak_squeeze(rate, output_len, state, <<>>)
  end

  defp keccak_absorb(rate, input, state, delimited_suffix)
       when is_integer(rate) and byte_size(input) >= rate do
    <<input_head::size(rate)-binary, input_tail::binary>> = input
    <<state_head::size(rate)-binary, state_tail::binary>> = state
    state = <<:crypto.exor(state_head, input_head)::binary, state_tail::binary>>

    keccak_absorb(rate, input_tail, keccak_f_1600(state), delimited_suffix)
  end

  defp keccak_absorb(rate, input, state, delimited_suffix) do
    block_size = byte_size(input)

    <<state_head::size(block_size)-binary, state_tail::binary>> = state
    state = <<:crypto.exor(state_head, input)::binary, state_tail::binary>>

    keccak_pad(rate, block_size, state, delimited_suffix)
  end

  defp keccak_pad(rate, block_size, state, delimited_suffix) do
    <<state_head::size(block_size)-binary, s::size(8)-integer, state_tail::binary>> = state
    state = <<state_head::binary, bxor(s, delimited_suffix)::size(8)-integer, state_tail::binary>>

    state =
      if band(delimited_suffix, 128) != 0 and block_size == rate - 1 do
        keccak_f_1600(state)
      else
        state
      end

    rate_sub_one = rate - 1

    <<x_head::size(rate_sub_one)-binary, x::size(8)-integer, x_tail::binary>> = state
    state = <<x_head::binary, bxor(x, 128)::size(8)-integer, x_tail::binary>>
    state = keccak_f_1600(state)

    {rate, state}
  end

  defp keccak_squeeze(rate, output_len, state, output) when output_len > 0 do
    block_size = min(output_len, rate)
    state_block = binary_part(state, 0, block_size)
    new_output_len = output_len - block_size

    state = if new_output_len > 0, do: keccak_f_1600(state), else: state

    keccak_squeeze(
      rate,
      new_output_len,
      state,
      <<output::binary, state_block::binary>>
    )
  end

  defp keccak_squeeze(_, _, _, output), do: output

  defp mget(m, x, y) do
    elem(elem(m, x), y)
  end

  defp mput(m, x, y, v) do
    put_elem(m, x, put_elem(elem(m, x), y, v))
  end
end
