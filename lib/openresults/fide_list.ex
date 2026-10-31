defmodule OpenResults.FideList do
  @moduledoc """
  This server's own copy of the FIDE rating list, for the entry form's
  "find yourself" search.

  ## Why a copy, after all

  Until 2026-10-18 the search was lent by the arbiter's OpenPairings, over
  `localhost`. That was one list instead of two, and it worked exactly where
  both programs share a box. An arbiter running OpenPairings on a laptop
  behind a club's router cannot be reached from here at all - which is most
  arbiters - so for them the search was simply absent. A copy that is at
  most a day stale beats a search that does not exist; the ratings in it
  change once a month anyway, and what changes in between is mostly players
  FIDE has just registered.

  ## The pieces

    * `OpenResults.FideList.Sync` decides when to look;
    * `OpenResults.FideList.Run` looks, and imports only when it is new;
    * `OpenResults.FideList.Source` talks to FIDE;
    * `OpenResults.FideList.ZipLines` and `OpenResults.FideList.Parser` read
      the file without ever holding it;
    * `OpenResults.FideList.Store` keeps it in its own database file
      (`OpenResults.FideList.Repo`) and swaps a new list in whole.

  ## The search

  All digits is a FIDE id. Anything else is words, in
  `OpenResults.FideList.Parser.search_key/1` form, asked two ways:

    * **The key, by prefix**, once for each rotation of the words: "jorian
      burssens" rotates to "burssens jorian", which starts FIDE's "Burssens,
      Jorian". Exact and cheap, but only the last word may be half typed.
    * **The word index** (`OpenResults.FideList.Store.words/3`): every word
      typed is the start of some word of the name, in any order. This is the
      one that finds "oswald de" while its owner is still typing "winne",
      "winne" on its own, and "dewinne", which is how a fair share of
      Flanders writes a surname FIDE keeps in two words.

  One word is asked of surnames only. A first name on its own would find
  thousands, and forty strangers called Jan is not an answer to "which of
  these is me".

  Nothing found and more than one word typed: each word is left out in turn,
  once, so one misspelt name ("Oswalt De Winne") still finds the other two.

  Ranked by how well the words fit - whole words over halves, the surname
  typed first over not - and then by rating, so the fifteen shown are the
  likeliest rather than the first fifteen alphabetically.
  """

  alias OpenResults.FideList.{Parser, Store, Sync}

  @limit 15
  # Per rotation, and from the word index. Ranked afterwards.
  @candidates 50
  @word_candidates 200
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

      case matches(words) do
        [] -> near_misses(words)
        found -> found
      end
    end
  end

  defp matches([]), do: []

  defp matches(words) do
    by_key =
      words
      |> rotations()
      |> Enum.flat_map(&Store.prefix(Enum.join(&1, " "), @candidates))

    (by_key ++ by_words(words))
    |> Enum.uniq_by(& &1.fide_id)
    |> Enum.filter(&fits?(&1, words))
    |> rank(words)
  end

  defp by_words(words) do
    if Store.words_available?() do
      Store.words(words, @word_candidates, surname_only: match?([_], words))
    else
      # A list imported before the word index existed. The next check
      # rebuilds it; until then, the key alone, as before.
      []
    end
  end

  # One misspelt word should not cost the other two. Two words at least must
  # remain - one would be a lone surname or first name standing in for a
  # whole name, and the list is too big for that to mean anything.
  defp near_misses(words) when length(words) >= 3 do
    words
    |> Enum.with_index()
    |> Enum.flat_map(fn {word, i} ->
      words |> List.delete_at(i) |> matches() |> Enum.map(&{&1, closeness(word, &1)})
    end)
    # Nearest spelling first: "ilze de vos" is Ilse, whatever Jan's rating.
    |> Enum.sort_by(fn {player, close} -> {-close, -(player.standard_rating || 0)} end)
    |> Enum.uniq_by(fn {player, _close} -> player.fide_id end)
    |> Enum.map(fn {player, _close} -> player end)
    |> Enum.take(@limit)
  end

  defp near_misses(_words), do: []

  # How near the word left out is to the nearest word of the name.
  defp closeness(word, player) do
    player |> name_words() |> Enum.map(&String.jaro_distance(word, &1)) |> Enum.max(fn -> 0.0 end)
  end

  # The word index answers per word; this is the check that each typed word
  # found a word of its own, so "de de" is not satisfied by one "De".
  defp fits?(player, words) do
    name_words = name_words(player)

    Enum.reduce_while(words, name_words, fn word, left ->
      case Enum.find_index(left, &String.starts_with?(&1, word)) do
        nil -> {:halt, false}
        i -> {:cont, List.delete_at(left, i)}
      end
    end) != false
  end

  defp rank(players, words) do
    players
    |> Enum.sort_by(fn player ->
      name_words = name_words(player)
      whole = Enum.count(words, &(&1 in name_words))
      surname_first = String.starts_with?(player.search_key, hd(words))

      {-whole, not surname_first, is_nil(player.standard_rating), -(player.standard_rating || 0),
       player.name}
    end)
    |> Enum.take(@limit)
  end

  # The key's words, plus the surname and the given names run together, so
  # "dewinne" counts as a whole word for "De Winne, Oswald".
  defp name_words(player) do
    %{surname_terms: surname, given_terms: given} = Parser.name_terms(player.name)
    String.split(surname <> " " <> given, " ", trim: true)
  end

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
  The list's rows for `ids`, as a map from FIDE id to row - name, title,
  federation, birth year and the three ratings. `%{}` when there is no list,
  or when it cannot be read: the results hub then shows what tournaments
  published and nothing else, which is a smaller page rather than a broken one.
  """
  @spec lookup([integer()]) :: %{integer() => map()}
  def lookup([]), do: %{}

  def lookup(ids) when is_list(ids) do
    if available?() do
      ids |> Store.by_ids() |> Map.new(&{&1.fide_id, &1})
    else
      %{}
    end
  rescue
    _unreadable -> %{}
  catch
    :exit, _not_started -> %{}
  end

  @doc """
  Where the zip is written while it is read: `:fide_list_work_dir`, or a
  directory beside the list's database. Never the system's temp directory,
  which on some hosts is memory - and 45 MB of it counted against this
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
