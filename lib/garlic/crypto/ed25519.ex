defmodule Garlic.Crypto.Ed25519 do
  @moduledoc """
  Hand-crafted Ed25519 primitives and public key blinding
  """

  use Bitwise

  import Integer, only: [mod: 2]

  @t254 0x4000000000000000000000000000000000000000000000000000000000000000
  @p 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED

  @d -4_513_249_062_541_557_337_682_894_930_092_624_173_785_641_285_191_125_241_628_941_591_882_900_924_598_840_740
  @i 19_681_161_376_707_505_956_807_079_304_988_542_015_446_066_515_923_890_162_744_021_073_123_829_784_752

  @base {15_112_221_349_535_400_772_501_151_409_588_531_511_454_012_693_041_857_206_046_113_283_949_847_762_202,
         46_316_835_694_926_478_169_428_394_003_475_163_141_307_993_866_256_225_615_783_033_603_165_251_855_960}

  @spec base_string() :: binary
  def base_string() do
    "(#{elem(@base, 0)}, #{elem(@base, 1)})"
  end

  @doc """
  Blinds a public key with supplied param as described in Section A.2 of rend-spec-v3.txt

  ## Parameters

    - `public_key` - a public key
    - `param` - hashed param
  """

  @spec blind_public_key(binary, binary) :: binary
  def blind_public_key(public_key, param) do
    param
    |> a_from_hash()
    |> scalarmult(decode_point(public_key))
    |> encode_point()
  end

  defp scalarmult(0, _), do: {0, 1}

  defp scalarmult(e, p) do
    q = e |> div(2) |> scalarmult(p)
    q = edwards(q, q)

    case e &&& 1 do
      1 -> edwards(q, p)
      _ -> q
    end
  end

  defp edwards({x1, y1}, {x2, y2}) do
    x = (x1 * y2 + x2 * y1) * inv(1 + @d * x1 * x2 * y1 * y2)
    y = (y1 * y2 + x1 * x2) * inv(1 - @d * x1 * x2 * y1 * y2)

    {mod(x, @p), mod(y, @p)}
  end

  defp expmod(b, e, m) when b > 0 do
    b
    |> :crypto.mod_pow(e, m)
    |> :binary.decode_unsigned()
  end

  defp expmod(b, e, m) do
    i =
      b
      |> abs()
      |> :crypto.mod_pow(e, m)
      |> :binary.decode_unsigned()

    cond do
      mod(e, 2) == 0 -> i
      i == 0 -> i
      true -> m - i
    end
  end

  defp inv(x), do: expmod(x, @p - 2, @p)

  defp encode_point({x, y}) do
    val =
      y
      |> band(0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
      |> bor((x &&& 1) <<< 255)

    <<val::little-size(256)>>
  end

  defp decode_point(<<n::little-size(256)>>) do
    xc = n >>> 255
    y = n &&& 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    x = xrecover(y)

    point = if (x &&& 1) == xc, do: {x, y}, else: {@p - x, y}

    if is_on_curve(point), do: point, else: raise("point off curve")
  end

  defp is_on_curve({x, y}), do: mod(-x * x + y * y - 1 - @d * x * x * y * y, @p) == 0

  defp a_from_hash(<<h::little-size(256), _rest::binary>>) do
    @t254 + band(h, 0xF3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF8)
  end

  defp xrecover(y) do
    xx = (y * y - 1) * inv(@d * y * y + 1)
    x = expmod(xx, div(@p + 3, 8), @p)

    x =
      case mod(x * x - xx, @p) do
        0 -> x
        _ -> mod(x * @i, @p)
      end

    case mod(x, 2) do
      0 -> @p - x
      _ -> x
    end
  end
end
