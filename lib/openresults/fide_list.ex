defmodule OpenResults.FideList do
  @moduledoc """
  This server's own copy of the FIDE rating list, for the entry form's
  "find yourself" search.

  ## Why a copy, after all

  Until 2026-10-18 the search was lent by the arbiter's OpenPairings, over
  `localhost`. That was one list instead of two, and it worked exactly where
  both programs share a box. An arbiter running OpenPairings on a laptop
  behind a club's router cannot be reached from here at all - which is most
  arbiters - so for them the search was simply absent. A copy that is a day
  stale beats a search that does not exist, and FIDE only publishes monthly
  anyway: the copy is the same list the arbiter has on all but the first day
  of a month.

  ## The pieces

    * `OpenResults.FideList.Sync` decides when to look;
    * `OpenResults.FideList.Run` looks, and imports only when it is new;
    * `OpenResults.FideList.Source` talks to FIDE;
    * `OpenResults.FideList.ZipLines` and `OpenResults.FideList.Parser` read
      the file without ever holding it;
    * `OpenResults.FideList.Store` keeps it in its own database file
      (`OpenResults.FideList.Repo`) and swaps a new list in whole.

  ## The search

  Names are matched by prefix on a normalised key (see
  `OpenResults.FideList.Parser.search_key/1`), through an index, once for
  each rotation of the words typed. FIDE stores "Burssens, Jorian"; a person
  types "jorian burss". The rotation "burss jorian" is not a prefix of
  anything, "jorian burss" is not either, but "jorian burssens" rotates to
  "burssens jorian", and that is. A surname or the start of one finds the
  player on its own. A first name on its own finds nobody - it would find
  thousands, and forty strangers called Jan is not an answer to "which of
  these is me".
  All digits is a FIDE id.
  """

  alias OpenResults.FideList.{Parser, Store, Sync}

  @limit 15
  # Per rotation. Ranked by rating afterwards, so the fifteen shown are the
  # strongest of these rather than the first fifteen alphabetically.
  @candidates 50
  @max_words 5

  @doc "Whether the daily check is switched on (`:fide_list_sync`)."
  @spec sync_enabled?() :: boolean()
  def sync_enabled?, do: Application.get_env(:openresults, :fide_list_sync, true) == true

  @doc "Whether a list has been imported and can be searched."
  @spec available?() :: boolean()
  def available?, do: Store.available?()

  @doc """
  Whether the entry form shows the search at all: when there is a list, or
  when one is on its way. A server with the sync off and no list has nothing
  to offer, and a search box that cannot search is worse than none.
  """
  @spec offered?() :: boolean()
  def offered?, do: sync_enabled?() or available?()

  @doc """
  Candidates for `query`, in the entry form's own field names, or
  `:unavailable` while no list has been imported.

  `tempo` is the tournament's - "rapid", "blitz", anything else meaning
  standard - so the rating that comes back is the one this event is played
  at, falling back to the standard rating where the player has none in that
  list.
  """
  @spec search(term(), String.t() | nil) :: {:ok, [map()]} | :unavailable
  def search(query, tempo \\ nil)

  def search(query, tempo) when is_binary(query) do
    query = String.trim(query)

    cond do
      not available?() -> :unavailable
      not String.valid?(query) or String.length(query) < 2 -> {:ok, []}
      true -> {:ok, query |> find() |> Enum.map(&row(&1, tempo))}
    end
  rescue
    # The list being swapped out from under a query in the instant between
    # `available?/0` and the select, or a file that will not open: the form
    # works without this, so the honest answer is "not available".
    _ -> :unavailable
  end

  def search(_query, _tempo), do: if(available?(), do: {:ok, []}, else: :unavailable)

  defp find(query) do
    if Regex.match?(~r/\A\d+\z/, query) do
      case Integer.parse(query) do
        {id, ""} when id >= 1 and id <= 999_999_999_999 -> Store.by_id(id)
        _ -> []
      end
    else
      words =
        query
        |> Parser.search_key()
        |> String.split(" ", trim: true)
        |> Enum.take(@max_words)

      words
      |> rotations()
      |> Enum.flat_map(&Store.prefix(Enum.join(&1, " "), @candidates))
      |> Enum.uniq_by(& &1.fide_id)
      |> Enum.sort_by(&{is_nil(&1.standard_rating), -(&1.standard_rating || 0), &1.name})
      |> Enum.take(@limit)
    end
  end

  defp rotations([]), do: []

  defp rotations(words) do
    for i <- 0..(length(words) - 1) do
      {head, tail} = Enum.split(words, i)
      tail ++ head
    end
  end

  defp row(player, tempo) do
    %{
      "fide_id" => player.fide_id,
      "name" => player.name,
      "title" => player.title,
      "federation" => player.federation,
      "birth_year" => player.birth_year,
      "rating" => rating(player, tempo)
    }
  end

  defp rating(player, "rapid"), do: player.rapid_rating || player.standard_rating
  defp rating(player, "blitz"), do: player.blitz_rating || player.standard_rating
  defp rating(player, _standard), do: player.standard_rating

  @doc """
  What the admin dashboard says about the list: which one is live, when it
  was last looked for, and what the sync is doing now.
  """
  def status do
    meta = Store.meta()

    %{
      enabled?: sync_enabled?(),
      available?: available?(),
      player_count: int(meta["player_count"]),
      # The list's own date, as its server stated it - FIDE's publication,
      # not this server's download. `nil` for a server that dates nothing.
      list_date: http_date(meta["last_modified"]),
      imported_at: iso(meta["imported_at"]),
      last_check_at: iso(meta["last_check_at"]),
      last_check_result: meta["last_check_result"],
      last_error: meta["last_error"],
      source: OpenResults.FideList.Source.url(),
      sync: Sync.status()
    }
  end

  defp iso(nil), do: nil

  defp iso(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp http_date(nil), do: nil

  defp http_date(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{y, m, d}, {hh, mm, ss}} -> DateTime.new!(Date.new!(y, m, d), Time.new!(hh, mm, ss))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp int(nil), do: nil

  defp int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  @doc """
  Where the zip is written while it is read: `:fide_list_work_dir`, or a
  directory beside the list's database. Never the system's temp directory,
  which on some hosts is memory - and 41 MB of it counted against this
  service's memory ceiling.
  """
  def work_dir do
    case Application.get_env(:openresults, :fide_list_work_dir) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _unset ->
        database = Application.get_env(:openresults, OpenResults.FideList.Repo, [])[:database]
        Path.join(Path.dirname(database || "."), "fide_list_work")
    end
  end
end
