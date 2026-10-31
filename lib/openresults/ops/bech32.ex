defmodule OpenResults.Ops.Bech32 do
  @moduledoc """
  Bech32 (BIP 173, the original checksum - not bech32m), which is how age
  spells its keys: `age1...` for a public key, `AGE-SECRET-KEY-1...` for a
  secret one.

  Written out rather than pulled in as a dependency because it is forty lines
  of arithmetic and a dependency is a supply chain. Like age, and unlike
  BIP 173, there is no 90-character limit: an X25519 key does not fit in one.
  """

  import Bitwise

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @generator [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

  @doc "Encodes `bytes` under the human-readable part `hrp` (lower case)."
  @spec encode(String.t(), binary()) :: String.t()
  def encode(hrp, bytes) when is_binary(hrp) and is_binary(bytes) do
    hrp = String.downcase(hrp)
    data = to_5bit(bytes)
    checksum = checksum(hrp, data)
    hrp <> "1" <> for(v <- data ++ checksum, into: "", do: <<Enum.at(@charset, v)>>)
  end

  @doc """
  Decodes a bech32 string into `{hrp, bytes}`. Mixed case is refused, as the
  format requires; all-upper-case is accepted and the hrp comes back lower.
  """
  @spec decode(String.t()) :: {:ok, {String.t(), binary()}} | {:error, :invalid}
  def decode(string) when is_binary(string) do
    lower = String.downcase(string)

    with true <- lower == string or String.upcase(string) == string,
         [hrp, payload] <- split_last_one(lower),
         true <- hrp != "" and byte_size(payload) >= 6,
         {:ok, values} <- values(payload),
         true <- polymod(hrp_expand(hrp) ++ values) == 1,
         {:ok, bytes} <- from_5bit(Enum.drop(values, -6)) do
      {:ok, {hrp, bytes}}
    else
      _ -> {:error, :invalid}
    end
  end

  def decode(_), do: {:error, :invalid}

  defp split_last_one(string) do
    case :binary.matches(string, "1") do
      [] ->
        :error

      matches ->
        {pos, 1} = List.last(matches)
        [binary_part(string, 0, pos), binary_part(string, pos + 1, byte_size(string) - pos - 1)]
    end
  end

  defp values(payload) do
    payload
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, []}, fn char, {:ok, acc} ->
      case Enum.find_index(@charset, &(&1 == char)) do
        nil -> {:halt, :error}
        index -> {:cont, {:ok, [index | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp checksum(hrp, data) do
    mod = bxor(polymod(hrp_expand(hrp) ++ data ++ [0, 0, 0, 0, 0, 0]), 1)
    for i <- 0..5, do: mod >>> (5 * (5 - i)) &&& 31
  end

  defp hrp_expand(hrp) do
    chars = String.to_charlist(hrp)
    Enum.map(chars, &(&1 >>> 5)) ++ [0] ++ Enum.map(chars, &(&1 &&& 31))
  end

  defp polymod(values) do
    Enum.reduce(values, 1, fn value, chk ->
      top = chk >>> 25
      chk = bxor((chk &&& 0x1FFFFFF) <<< 5, value)

      @generator
      |> Enum.with_index()
      |> Enum.reduce(chk, fn {g, i}, acc ->
        if (top >>> i &&& 1) == 1, do: bxor(acc, g), else: acc
      end)
    end)
  end

  defp to_5bit(bytes) do
    bits = for <<bit::1 <- bytes>>, do: bit
    pad = rem(5 - rem(length(bits), 5), 5)

    (bits ++ List.duplicate(0, pad))
    |> Enum.chunk_every(5)
    |> Enum.map(fn group -> Enum.reduce(group, 0, &(&2 * 2 + &1)) end)
  end

  defp from_5bit(values) do
    bits = for v <- values, <<(bit::1 <- <<v::5>>)>>, do: bit
    whole = div(length(bits), 8) * 8
    {data, padding} = Enum.split(bits, whole)

    # Valid padding is fewer than five bits and all zero.
    if length(padding) < 5 and Enum.all?(padding, &(&1 == 0)) do
      {:ok,
       for(
         byte <- Enum.chunk_every(data, 8),
         into: <<>>,
         do: <<Enum.reduce(byte, 0, &(&2 * 2 + &1))>>
       )}
    else
      :error
    end
  end
end
