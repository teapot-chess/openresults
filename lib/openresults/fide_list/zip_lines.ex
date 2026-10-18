defmodule OpenResults.FideList.ZipLines do
  @moduledoc """
  The lines of the `.txt` inside FIDE's zip, inflated a few kilobytes at a
  time.

  `:zip.extract/2` would have been one line. It also puts the whole 250 MB
  of text either in memory - on a service whose memory ceiling is a few
  hundred megabytes - or on disk beside the zip, which is 250 MB of scratch
  file for something read exactly once, front to back. So the entry is found
  through the central directory (`:zip.list_dir/1`, which reads only the
  directory), and its compressed bytes are fed through `:zlib` from the file,
  sixteen kilobytes at a time.

  Bounded twice: the entry's DECLARED size is checked before anything is
  inflated, and the bytes actually inflated are counted as they come out,
  because a declared size is only a claim. Either past `max_bytes` raises
  `OpenResults.FideList.ImportError`.
  """

  alias OpenResults.FideList.ImportError

  @read_size 16_384

  @doc """
  A stream of the lines (without line endings, as raw Latin-1 bytes) of the
  first `.txt` entry in `zip_path`. Raises `ImportError` - when the stream
  is run, or here for a zip with no such entry - rather than returning an
  error, because the failure can come from the middle of a file.
  """
  @spec stream!(Path.t(), pos_integer()) :: Enumerable.t()
  def stream!(zip_path, max_bytes) do
    {offset, comp_size} = locate!(zip_path, max_bytes)

    zip_path
    |> chunks(offset, comp_size, max_bytes)
    |> Stream.transform(fn -> "" end, &split/2, &{[&1], ""}, fn _rest -> :ok end)
    |> Stream.map(&String.trim_trailing(&1, "\r"))
  end

  defp locate!(zip_path, max_bytes) do
    entries =
      case :zip.list_dir(String.to_charlist(zip_path)) do
        {:ok, entries} -> entries
        {:error, reason} -> raise ImportError, "not a zip file (#{inspect(reason)})"
      end

    entry =
      Enum.find(entries, fn
        {:zip_file, name, _info, _comment, _offset, _size} ->
          name |> to_string() |> String.downcase() |> String.ends_with?(".txt")

        _comment ->
          false
      end)

    case entry do
      nil ->
        raise ImportError, "the zip has no .txt file in it"

      {:zip_file, _name, info, _comment, offset, comp_size} ->
        # `info` is a `:file_info` record; its second element is the size.
        declared = elem(info, 1)

        if declared > max_bytes do
          raise ImportError,
                "the zip declares #{declared} bytes of text, past the #{max_bytes}-byte limit"
        end

        {offset, comp_size}
    end
  end

  defp chunks(zip_path, offset, comp_size, max_bytes) do
    Stream.resource(
      fn -> open!(zip_path, offset, comp_size) end,
      fn
        %{remaining: 0} = state ->
          {:halt, state}

        state ->
          read = min(@read_size, state.remaining)

          data =
            case :file.pread(state.fd, state.pos, read) do
              {:ok, data} when byte_size(data) == read -> data
              _short -> raise ImportError, "the zip ends in the middle of its text"
            end

          out = inflate(state, data)
          total = state.total + IO.iodata_length(out)

          if total > max_bytes do
            raise ImportError, "the zip's text runs past the #{max_bytes}-byte limit"
          end

          {[IO.iodata_to_binary(out)],
           %{state | pos: state.pos + read, remaining: state.remaining - read, total: total}}
      end,
      &close/1
    )
  end

  defp open!(zip_path, offset, comp_size) do
    {:ok, fd} = :file.open(String.to_charlist(zip_path), [:read, :binary, :raw])

    # The local header in front of the data: 30 fixed bytes, then the name
    # and an "extra" field whose lengths it gives. The central directory's
    # offset points at this header, not at the data.
    case :file.pread(fd, offset, 30) do
      {:ok,
       <<0x04034B50::little-32, _version::16, _flags::16, method::little-16, _skip::binary-16,
         name_len::little-16, extra_len::little-16>>} ->
        z =
          case method do
            8 ->
              z = :zlib.open()
              :ok = :zlib.inflateInit(z, -15)
              z

            0 ->
              nil

            other ->
              :file.close(fd)
              raise ImportError, "the zip uses compression method #{other}, not deflate"
          end

        %{
          fd: fd,
          z: z,
          pos: offset + 30 + name_len + extra_len,
          remaining: comp_size,
          total: 0
        }

      _other ->
        :file.close(fd)
        raise ImportError, "the zip's entry header is damaged"
    end
  end

  defp inflate(%{z: nil}, data), do: data
  defp inflate(%{z: z}, data), do: :zlib.inflate(z, data)

  defp close(%{fd: fd, z: z}) do
    if z do
      # `inflateEnd` complains about a stream that did not finish, which is
      # what an abandoned import is. Closing is all that matters here.
      try do
        :zlib.inflateEnd(z)
      rescue
        _incomplete -> :ok
      end

      :zlib.close(z)
    end

    :file.close(fd)
  end

  # The bytes so far, split into complete lines and the start of the next.
  defp split(chunk, rest) do
    parts = :binary.split(rest <> chunk, "\n", [:global])
    {complete, [last]} = Enum.split(parts, -1)
    {complete, last}
  end
end
