defmodule OpenResults.FideList.Run do
  @moduledoc """
  One check of the FIDE list, start to finish: look, and only if the list is
  new, download it, read it and make it live.

  Synchronous and self-contained, so a test can call `once/1` in its own
  process; `OpenResults.FideList.Sync` runs it in a process of its own and
  watches it.

  ## Gentle, because of the neighbours

  The server this runs on has two cores and an arbiter's pairing program on
  it. So nothing here is ever whole in memory: the zip streams to a file, its
  text is inflated sixteen kilobytes at a time (`OpenResults.FideList.ZipLines`),
  and rows go to the database a thousand at a time, each chunk its own short
  commit in a database file nothing else writes to. The process runs at low
  priority and pauses between chunks (`:fide_list_chunk_pause_ms`), which
  costs a minute or two of wall-clock time on a job that runs while everybody
  is asleep, and buys the requests arriving during it a scheduler.

  ## When the new list is wrong

  The live list is replaced only by one that is at least half its size. A
  truncated download, an error page that happened to be a zip, a month in
  which FIDE served an empty file: each of those parses into far fewer rows
  than a real list, and each would otherwise have replaced 1.9 million
  players with whatever it held. Last month's list is a much better answer
  than that, and it stays.
  """

  require Logger

  alias OpenResults.FideList.{ImportError, Parser, Source, Store, ZipLines}

  @chunk 1_000

  # The real list unpacks to about 250 MB of text. Generous, and still a
  # bound - see `OpenResults.FideList.ZipLines`.
  @max_text_bytes 2_000_000_000

  @type result :: :unchanged | {:imported, non_neg_integer()} | {:error, String.t()}

  @doc """
  Looks, and imports when there is something new. Returns what happened and
  records it in the meta table as the last check.

  Options: `:report` - `fn phase, text -> ... end`, called as the run moves
  along (`:checking`, `:downloading`, `:importing`); `:work_dir` - where the
  zip is written while it is read; `:chunk_pause_ms`.
  """
  @spec once(keyword()) :: result()
  def once(opts \\ []) do
    report = Keyword.get(opts, :report, fn _phase, _text -> :ok end)
    Store.ensure_meta!()
    stored = stored_fingerprint()

    result =
      try do
        check(stored, report, opts)
      rescue
        e in ImportError ->
          {:error, e.message}

        # Anything else is a bug here, not a property of the download. Its
        # type and nothing more: an exception's message can quote the line
        # it choked on, and a line of this file is somebody's name and
        # birth year.
        e ->
          Logger.error("FIDE list run crashed: #{inspect(e.__struct__)}")

          {:error, "the import crashed (#{inspect(e.__struct__)})"}
      end

    record(result)
    result
  end

  defp check(stored, report, opts) do
    report.(:checking, "Asking whether the list has changed")

    case Source.head() do
      {:ok, remote} ->
        if Source.changed?(remote, stored), do: fetch(nil, report, opts), else: :unchanged

      # A server that will not answer HEAD can still answer a conditional
      # GET, and a 304 to it is the same "nothing new".
      {:refused, _status} ->
        fetch(stored, report, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(conditional_on, report, opts) do
    if OpenResults.DiskSpace.low?() do
      # Two lists side by side and a zip beside them is a few hundred
      # megabytes. Below the floor that publishing already refuses at, those
      # are better left to tournaments.
      {:error, "free disk space is below the floor; the download was not attempted"}
    else
      work_dir = Keyword.get_lazy(opts, :work_dir, &OpenResults.FideList.work_dir/0)
      zip = Path.join(work_dir, "players_list.zip")
      report.(:downloading, "Downloading the list")

      try do
        case Source.download(zip, conditional_on, &report.(:downloading, "Downloaded #{mb(&1)}")) do
          {:ok, fingerprint} -> import(zip, fingerprint, report, opts)
          :not_modified -> :unchanged
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(zip)
      end
    end
  end

  defp import(zip, fingerprint, report, opts) do
    pause = Keyword.get_lazy(opts, :chunk_pause_ms, &chunk_pause_ms/0)
    lines = ZipLines.stream!(zip, @max_text_bytes)

    offsets =
      case Enum.take(lines, 1) do
        [header] ->
          case Parser.offsets(header) do
            {:ok, offsets} -> offsets
            {:error, reason} -> raise ImportError, reason
          end

        [] ->
          raise ImportError, "the list is empty"
      end

    report.(:importing, "Reading players")
    Store.begin_scratch!()

    lines
    |> Stream.drop(1)
    |> Stream.map(&Parser.parse_line(&1, offsets))
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(@chunk)
    |> Stream.with_index(1)
    |> Enum.each(fn {rows, i} ->
      Store.insert_chunk!(rows)

      # Every line is cut from a 100-odd-kilobyte inflated chunk, and a
      # process that only ever allocates small things collects rarely - so
      # without this the chunks it has finished with pile up as binaries
      # nobody has let go of yet, and the import's memory climbs into the
      # hundreds of megabytes on a service capped at a few hundred.
      if rem(i, 10) == 0, do: :erlang.garbage_collect()
      if rem(i, 25) == 0, do: report.(:importing, "Read #{i * @chunk} players")
      if pause > 0, do: Process.sleep(pause)
    end)

    imported = Store.scratch_count!()
    live = Store.live_count()

    cond do
      imported == 0 ->
        Store.drop_leftovers!()
        raise ImportError, "the list held no usable players; the old list stays"

      imported < div(live, 2) ->
        Store.drop_leftovers!()

        raise ImportError,
              "the list held #{imported} players against #{live} in the current one; " <>
                "it looks truncated, and the old list stays"

      true ->
        report.(:importing, "Indexing #{imported} players")
        Store.index_scratch!()

        Store.swap!(%{
          "etag" => fingerprint.etag,
          "last_modified" => fingerprint.last_modified,
          "content_length" => fingerprint.content_length,
          "imported_at" => now(),
          "player_count" => imported
        })

        {:imported, imported}
    end
  end

  defp stored_fingerprint do
    meta = Store.meta()
    # A list without the word index counts as no list, so the next check
    # downloads again instead of answering "unchanged" for a month.
    if Map.has_key?(meta, "imported_at") and Store.available?() and Store.words_available?(),
      do: meta
  end

  defp record(result) do
    {outcome, error} =
      case result do
        :unchanged -> {"unchanged", nil}
        {:imported, _n} -> {"imported", nil}
        {:error, reason} -> {"failed", reason}
      end

    Store.put_meta!(%{
      "last_check_at" => now(),
      "last_check_result" => outcome,
      "last_error" => error
    })
  rescue
    e -> Logger.warning("FIDE list: could not record the check (#{inspect(e.__struct__)})")
  end

  defp chunk_pause_ms, do: Application.get_env(:openresults, :fide_list_chunk_pause_ms, 5)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp mb(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
