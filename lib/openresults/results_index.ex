defmodule OpenResults.ResultsIndex do
  @moduledoc """
  The results hub's index: one row per tournament, one per player in it, and
  full-text search over both - so the front page, the federation listings,
  search and the player pages can answer without decoding every snapshot on
  the server, which is what they did until this existed (fine at fifty
  tournaments, broken at ten thousand).

  ## The rule

  **An index is not a calculation and not a source of truth.** Every column
  is a field the newest snapshot carries, after the same display rules the
  tournament's own pages apply: a rating the arbiter hides is `nil` here, a
  placing behind switched-off standings is `nil` here, so no query on these
  tables can show what the page would not. The one thing derived is the
  life-cycle group (live, upcoming, finished), and that is
  `OpenResultsWeb.Tournament.status_from/4`, the front page's own rule, fed
  with the two date-free facts stored here and today's date.

  ## Kept in step

    * **Publish** - `index_snapshot/1` runs inside the ingest transaction that
      stores the snapshot, so the index can never be ahead of or behind the
      page. An unchanged repeat (same snapshot id, same `version/0`) is a
      no-op.
    * **Takedown** - `delete/1` runs inside `OpenResults.Takedown.purge/1`'s
      transaction.
    * **Moderation** - not copied at all. `tournaments.status` is joined at
      query time, so hiding, approving or deleting needs nothing here beyond
      telling the caches (`touch/1`).
    * **A changed indexer** - bump `version/0`; the boot backfill
      (`OpenResults.ResultsIndex.Backfill`) and `mix openresults.reindex`
      rebuild every tournament whose row is older.

  Retention and version pruning do not touch it: it follows the newest
  snapshot only, and pruning never removes the newest.

  ## Who sees what

  | | listings, tournament search | player pages, player search |
  |---|---|---|
  | listed (approved) | yes | yes |
  | pending | yes, marked unapproved | no |
  | hidden | no | no |
  | unlisted by the arbiter | no | no |

  Pending stays off the player pages for the reason in
  `OpenResults.Tournaments`: otherwise anybody could publish invented results
  under real FIDE ids.
  """

  import Ecto.Query, warn: false

  alias OpenResults.FideList
  alias OpenResults.FideList.Parser
  alias OpenResults.Repo
  alias OpenResults.ResultsIndex.{Appearance, Entry, Generations, NameMatch, Suppression}
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.Tournaments.Tournament, as: TournamentRow
  alias OpenResultsWeb.Tournament

  # Bump when what `index_snapshot/1` writes changes; the boot backfill then
  # rebuilds every row written by an older one.
  @version 1

  # A tournament that never published a round and started this long ago is a
  # shell somebody tried out and forgot - left off the listings.
  @stale_days 30
  @front_recent_days 14
  @federation_recent_days 30
  @archive_page_size 50
  @search_limit 50
  @search_rows 500
  @max_words 5
  @min_query 3

  @doc "The indexer's version - see \"Kept in step\"."
  def version, do: @version

  @doc "How many days of finished tournaments the front page keeps."
  def front_recent_days, do: @front_recent_days

  @doc "How many days of finished tournaments a federation listing keeps above its archive."
  def federation_recent_days, do: @federation_recent_days

  @doc "The shortest search the server answers."
  def min_query, do: @min_query

  ## ---------- writing ----------

  @doc """
  Indexes `snapshot` as its tournament's current one, replacing whatever was
  there. Call inside the transaction that stored it.
  """
  @spec index_snapshot(Snapshot.t()) :: :ok
  def index_snapshot(%Snapshot{tournament_slug: slug, id: id} = snapshot) do
    current =
      Repo.one(from e in Entry, where: e.slug == ^slug, select: {e.snapshot_id, e.index_version})

    case current do
      {^id, @version} -> :ok
      _absent_or_older -> write(snapshot)
    end
  end

  defp write(%Snapshot{tournament_slug: slug, id: id, payload: payload} = snapshot) do
    delete(slug)

    info = Tournament.info(payload)
    facts = Tournament.status_facts(payload)
    players = Tournament.players(payload)

    entry =
      Repo.insert!(%Entry{
        slug: slug,
        snapshot_id: id,
        index_version: @version,
        name: Tournament.name(payload),
        city: shown(payload, "city", text(info, "city")),
        federation: shown(payload, "federation", federation(info["federation"])),
        start_date: date_text(info["start_date"]),
        end_date: date_text(info["end_date"]),
        dates_shown: Tournament.show?(payload, "dates"),
        rounds_count: Tournament.rounds_count(payload),
        rounds_published: length(Tournament.round_numbers(payload)),
        players_count: length(players),
        system: Tournament.system(payload),
        team: Tournament.team_event?(payload),
        fide_rated: info["fide_rated"] == true,
        arbiter_listed: Tournament.listed?(payload),
        complete: facts.complete?,
        not_begun: facts.not_begun?,
        event_id: event_id(info),
        last_published_at: snapshot.received_at || DateTime.utc_now()
      })

    Repo.query!("INSERT INTO tournament_search (rowid, body) VALUES (?, ?)", [
      entry.id,
      Parser.search_key(Enum.join(Enum.reject([entry.name, entry.city], &is_nil/1), " "))
    ])

    write_appearances(payload, players, entry)
    :ok
  end

  defp write_appearances(_payload, [], _entry), do: :ok

  defp write_appearances(payload, players, entry) do
    listed =
      FideList.lookup(players |> Enum.map(&fide_id(&1["fide_id"])) |> Enum.reject(&is_nil/1))

    standings? = Tournament.show?(payload, "standings")
    total = if standings?, do: Tournament.ranked_total(payload)

    rows =
      if standings?,
        do: Map.new(Tournament.standings_rows(payload), &{&1["player"], &1}),
        else: %{}

    linkable? = Tournament.show?(payload, "player_cards")

    players
    |> Enum.filter(&is_integer(&1["no"]))
    |> Enum.map(fn player ->
      row = Map.get(rows, player["no"])
      id = fide_id(player["fide_id"])
      name = text(player, "name")

      %{
        slug: entry.slug,
        no: player["no"],
        name: name,
        federation: shown(payload, "federation", federation(player["federation"])),
        title: shown(payload, "title", text(player, "title")),
        rating: shown(payload, "rating", integer(player["rating"])),
        club: shown(payload, "club", text(player, "club")),
        fide_id: id,
        # Not counted (C.05 6.6) is not a place - the same reading as the
        # standings page and `OpenResultsWeb.PlayerHistory` before this.
        rank: if(row && not Tournament.uncounted?(row), do: integer(row["rank"])),
        points: row && number(row["points"]),
        ranked_total: row && total,
        performance: row && integer(row["performance"]),
        card_linkable: linkable?,
        fide_name_mismatch: mismatch(id, name, listed),
        start_date: entry.start_date
      }
    end)
    |> Enum.chunk_every(200)
    |> Enum.each(fn chunk ->
      {_count, inserted} = Repo.insert_all(Appearance, chunk, returning: [:id, :name, :fide_id])

      Repo.query!(
        "INSERT INTO player_search (rowid, body) VALUES " <>
          Enum.map_join(inserted, ", ", fn _ -> "(?, ?)" end),
        Enum.flat_map(inserted, &[&1.id, search_body(&1)])
      )
    end)
  end

  # The FIDE id goes into the searchable text too, so typing one finds the
  # player like typing the name does.
  defp search_body(%{name: name, fide_id: id}) do
    Parser.search_key(Enum.join(Enum.reject([name, id && Integer.to_string(id)], &is_nil/1), " "))
  end

  defp mismatch(nil, _name, _listed), do: nil

  defp mismatch(id, name, listed) do
    case Map.get(listed, id) do
      nil -> nil
      row -> not NameMatch.match?(name, row.name)
    end
  end

  @doc """
  Removes `slug` from the index. Inside `OpenResults.Takedown.purge/1`'s
  transaction, and before every rewrite.
  """
  @spec delete(String.t()) :: :ok
  def delete(slug) when is_binary(slug) do
    slug
    |> appearance_ids()
    |> Enum.chunk_every(500)
    |> Enum.each(fn ids ->
      Repo.query!(
        "DELETE FROM player_search WHERE rowid IN (#{Enum.map_join(ids, ", ", fn _ -> "?" end)})",
        ids
      )
    end)

    Repo.delete_all(from a in Appearance, where: a.slug == ^slug)

    case Repo.one(from e in Entry, where: e.slug == ^slug, select: e.id) do
      nil ->
        :ok

      id ->
        Repo.query!("DELETE FROM tournament_search WHERE rowid = ?", [id])
        Repo.delete_all(from e in Entry, where: e.id == ^id)
        :ok
    end
  end

  defp appearance_ids(slug),
    do: Repo.all(from a in Appearance, where: a.slug == ^slug, select: a.id)

  ## ---------- telling the caches ----------

  @doc """
  The cache generations a change to `slug` moves (see
  `OpenResults.ResultsIndex.Generations`): everything, its federation's
  listing and the page of every FIDE id it lists. Read from the committed
  index - a caller asks before a change and again after it, and bumps both.
  """
  @spec keys_for(String.t()) :: [term()]
  def keys_for(slug) when is_binary(slug) do
    case Repo.one(from e in Entry, where: e.slug == ^slug, select: {e.id, e.federation}) do
      nil ->
        [:all]

      {_id, federation} ->
        ids =
          Repo.all(
            from a in Appearance,
              where: a.slug == ^slug and not is_nil(a.fide_id),
              distinct: true,
              select: a.fide_id
          )

        [:all, {:federation, federation || :none} | Enum.map(ids, &{:player, &1})]
    end
  end

  @doc "Moves the generations of `keys` (from `keys_for/1`)."
  @spec bump([term()]) :: :ok
  def bump(keys), do: Generations.bump(keys)

  @doc """
  For a change that leaves the index as it is but changes what it shows -
  moderation: bumps everything `slug` touches.
  """
  @spec touch(String.t()) :: :ok
  def touch(slug) when is_binary(slug), do: bump(keys_for(slug))

  ## ---------- rebuilding ----------

  @doc """
  The slugs whose index row is missing, older than their newest snapshot, or
  written by an older `version/0` - and the index rows whose tournament has
  no snapshot left at all.
  """
  @spec stale() :: %{reindex: [String.t()], orphaned: [String.t()]}
  def stale do
    newest =
      Map.new(
        Repo.all(
          from s in Snapshot, group_by: s.tournament_slug, select: {s.tournament_slug, max(s.id)}
        )
      )

    indexed =
      Map.new(Repo.all(from e in Entry, select: {e.slug, {e.snapshot_id, e.index_version}}))

    %{
      reindex:
        newest
        |> Enum.reject(fn {slug, id} -> Map.get(indexed, slug) == {id, @version} end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort(),
      orphaned: indexed |> Map.keys() |> Enum.reject(&Map.has_key?(newest, &1)) |> Enum.sort()
    }
  end

  @doc """
  Rebuilds the index from the stored snapshots and returns how many
  tournaments it (re)indexed. `force: true` rewrites every row, not only the
  stale ones. Each tournament in a transaction of its own, so a publish is
  never held up for longer than one tournament takes.

  Reads each newest snapshot straight from the table rather than through
  `OpenResults.Snapshots.latest/1`, whose decode cache would otherwise end up
  holding every tournament on the server.
  """
  @spec reindex(keyword()) :: non_neg_integer()
  def reindex(opts \\ []) do
    %{reindex: reindex, orphaned: orphaned} = stale()

    slugs =
      if Keyword.get(opts, :force, false),
        do: Repo.all(from s in Snapshot, distinct: true, select: s.tournament_slug),
        else: reindex

    pause = Keyword.get(opts, :pause_ms, 0)
    progress = Keyword.get(opts, :progress, fn _done, _total -> :ok end)
    total = length(slugs)

    Enum.each(orphaned, fn slug ->
      keys = keys_for(slug)
      {:ok, :ok} = Repo.transaction(fn -> delete(slug) end)
      bump(keys)
    end)

    slugs
    |> Enum.with_index(1)
    |> Enum.each(fn {slug, done} ->
      reindex_one(slug, Keyword.get(opts, :force, false))
      progress.(done, total)
      if pause > 0, do: Process.sleep(pause)
    end)

    total
  end

  defp reindex_one(slug, force?) do
    before = keys_for(slug)

    {:ok, _} =
      Repo.transaction(
        fn ->
          case Repo.one(
                 from s in Snapshot,
                   where: s.tournament_slug == ^slug,
                   order_by: [desc: s.id],
                   limit: 1
               ) do
            nil -> delete(slug)
            snapshot when force? -> write(snapshot)
            snapshot -> index_snapshot(snapshot)
          end
        end,
        mode: :immediate
      )

    bump(before ++ keys_for(slug))
  end

  ## ---------- reading: listings ----------

  # Not hidden, and listed by the arbiter. Pending is in, with its status.
  defp visible_entries do
    from e in Entry,
      as: :entry,
      left_join: t in TournamentRow,
      on: t.slug == e.slug,
      as: :row,
      where: e.arbiter_listed and coalesce(t.status, "listed") != "hidden",
      select_merge: %{status: coalesce(t.status, "listed")}
  end

  # A shell: never published a round, and its start is long gone.
  defp without_shells(query, today) do
    cutoff = Date.to_iso8601(Date.add(today, -@stale_days))

    where(
      query,
      [entry: e],
      not (e.rounds_published == 0 and not is_nil(e.start_date) and e.start_date < ^cutoff)
    )
  end

  defp in_federation(query, :all), do: query
  defp in_federation(query, :none), do: where(query, [entry: e], is_nil(e.federation))
  defp in_federation(query, code), do: where(query, [entry: e], e.federation == ^code)

  # Still worth a place above the archive: ended (or, with no end date,
  # started) on or after `cutoff`, or with no end date and not complete - a
  # tournament still being played reads as live until it says otherwise,
  # exactly as on its own page.
  defp current(query, cutoff) do
    where(
      query,
      [entry: e],
      (not is_nil(e.end_date) and e.end_date >= ^cutoff) or
        (is_nil(e.end_date) and
           (not e.complete or is_nil(e.start_date) or e.start_date >= ^cutoff))
    )
  end

  defp archived(query, cutoff) do
    where(
      query,
      [entry: e],
      not ((not is_nil(e.end_date) and e.end_date >= ^cutoff) or
             (is_nil(e.end_date) and
                (not e.complete or is_nil(e.start_date) or e.start_date >= ^cutoff)))
    )
  end

  @doc """
  The tournaments worth a place above an archive, grouped as on their own
  pages: `%{live: [...], upcoming: [...], finished: [...]}`. `finished`
  holds those that ended within `recent_days` of `today`.
  """
  @spec current_groups(:all | :none | String.t(), Date.t(), pos_integer()) :: %{
          live: [Entry.t()],
          upcoming: [Entry.t()],
          finished: [Entry.t()]
        }
  def current_groups(federation, today, recent_days) do
    cutoff = Date.to_iso8601(Date.add(today, -recent_days))

    entries =
      visible_entries()
      |> in_federation(federation)
      |> without_shells(today)
      |> current(cutoff)
      |> Repo.all()

    grouped = Enum.group_by(entries, &status(&1, today))

    %{
      live: Enum.sort_by(Map.get(grouped, :live, []), &{&1.start_date || "", &1.name}, :desc),
      upcoming:
        Enum.sort_by(Map.get(grouped, :upcoming, []), &{&1.start_date || "9999", &1.name}),
      finished:
        grouped
        |> Map.get(:finished, [])
        |> Enum.sort_by(&{&1.end_date || &1.start_date || "", &1.name}, :desc)
    }
  end

  @doc "Where `entry` is in its life cycle on `today` - `OpenResultsWeb.Tournament.status_from/4`."
  @spec status(Entry.t(), Date.t()) :: :live | :upcoming | :finished
  def status(%Entry{} = entry, today) do
    Tournament.status_from(
      %{complete?: entry.complete, not_begun?: entry.not_begun},
      entry.start_date,
      entry.end_date,
      today
    )
  end

  @doc """
  One page of a federation's archive - what `current_groups/3` leaves out -
  newest first: `%{entries: [...], page: n, pages: n, total: n}`. `year`
  narrows it to tournaments that started that year and show their dates.
  """
  @spec archive(:all | :none | String.t(), Date.t(), keyword()) :: map()
  def archive(federation, today, opts \\ []) do
    cutoff = Date.to_iso8601(Date.add(today, -@federation_recent_days))

    base =
      visible_entries()
      |> in_federation(federation)
      |> without_shells(today)
      |> archived(cutoff)
      |> by_year(Keyword.get(opts, :year))

    total = Repo.aggregate(exclude(base, :select), :count)
    pages = max(div(total + @archive_page_size - 1, @archive_page_size), 1)
    page = opts |> Keyword.get(:page, 1) |> max(1) |> min(pages)

    entries =
      base
      |> order_by([entry: e],
        desc: coalesce(e.end_date, e.start_date),
        asc: e.name
      )
      |> limit(^@archive_page_size)
      |> offset(^((page - 1) * @archive_page_size))
      |> Repo.all()

    %{entries: entries, page: page, pages: pages, total: total}
  end

  defp by_year(query, nil), do: query

  defp by_year(query, year) do
    where(
      query,
      [entry: e],
      e.dates_shown and fragment("substr(?, 1, 4)", e.start_date) == ^year
    )
  end

  @doc "The years the archive of `federation` can be narrowed to, newest first."
  @spec archive_years(:all | :none | String.t(), Date.t()) :: [String.t()]
  def archive_years(federation, today) do
    cutoff = Date.to_iso8601(Date.add(today, -@federation_recent_days))

    visible_entries()
    |> in_federation(federation)
    |> without_shells(today)
    |> archived(cutoff)
    |> where([entry: e], e.dates_shown and not is_nil(e.start_date))
    |> exclude(:select)
    |> select([entry: e], fragment("substr(?, 1, 4)", e.start_date))
    |> distinct(true)
    |> Repo.all()
    |> Enum.filter(&(&1 =~ ~r/^\d{4}$/))
    |> Enum.sort(:desc)
  end

  @doc """
  Every federation with a visible tournament, and how many:
  `[{code_or_nil, count}]`, by code, the "no federation" bucket last.
  """
  @spec federations(Date.t()) :: [{String.t() | nil, non_neg_integer()}]
  def federations(today) do
    visible_entries()
    |> without_shells(today)
    |> exclude(:select)
    |> group_by([entry: e], e.federation)
    |> select([entry: e], {e.federation, count(e.id)})
    |> Repo.all()
    |> Enum.sort_by(fn {code, _count} -> {is_nil(code), code} end)
  end

  @doc "Whether `slug` is indexed and visible on the listings."
  @spec listed_slug?(String.t()) :: boolean()
  def listed_slug?(slug), do: Repo.exists?(where(visible_entries(), [entry: e], e.slug == ^slug))

  ## ---------- reading: players ----------

  # Appearances that may reach a player page: approved, listed by the
  # arbiter, and not under a suppressed FIDE id.
  defp player_appearances do
    from a in Appearance,
      as: :appearance,
      join: e in Entry,
      on: e.slug == a.slug,
      as: :entry,
      left_join: t in TournamentRow,
      on: t.slug == a.slug,
      where: e.arbiter_listed and coalesce(t.status, "listed") == "listed",
      select_merge: %{
        tournament_name: e.name,
        city: e.city,
        end_date: e.end_date,
        dates_shown: e.dates_shown
      }
  end

  @doc """
  The FIDE list's row for `fide_id` (or `nil`) and the appearances that
  belong on its page, newest first: approved tournaments only, and none
  whose published name is not this player's (`NameMatch`). Empty when the
  page is suppressed.
  """
  @spec player(integer()) :: %{listed: map() | nil, appearances: [Appearance.t()]}
  def player(fide_id) when is_integer(fide_id) do
    listed = fide_id |> List.wrap() |> FideList.lookup() |> Map.get(fide_id)

    appearances =
      if suppressed?(fide_id) do
        []
      else
        player_appearances()
        |> where([appearance: a], a.fide_id == ^fide_id)
        |> order_by([appearance: a], desc: a.start_date, desc: a.id)
        |> Repo.all()
        |> Enum.filter(&belongs?(&1, listed))
      end

    %{listed: listed, appearances: appearances}
  end

  defp belongs?(_appearance, nil), do: true
  defp belongs?(appearance, listed), do: NameMatch.match?(appearance.name, listed.name)

  @doc """
  The FIDE ids with a player page worth a sitemap entry: an appearance on an
  approved, listed tournament, not suppressed. The caller decides who of them
  is an adult.
  """
  @spec indexable_fide_ids() :: [integer()]
  def indexable_fide_ids do
    suppressed = from s in Suppression, select: s.fide_id

    player_appearances()
    |> where([appearance: a], not is_nil(a.fide_id) and a.fide_id not in subquery(suppressed))
    |> exclude(:select)
    |> select([appearance: a], a.fide_id)
    |> distinct(true)
    |> Repo.all()
  end

  ## ---------- reading: search ----------

  @doc """
  Tournaments and players matching `query`, or `{:error, :too_short}` under
  `min_query/0` letters.

    * `tournaments` - by name and city, pending included (they carry their
      status), hidden and unlisted not.
    * `players` - grouped by FIDE id, one row each: approved tournaments
      only, never a suppressed id, and never under an id whose listed name
      the published one does not match.
    * `appearances` - everything else that matched a name: a player with no
      FIDE id, or one whose id did not match the name. One row per
      tournament, never grouped - merging people by name is the thing this
      site does not do.
  """
  @spec search(String.t()) :: {:ok, map()} | {:error, :too_short}
  def search(query) when is_binary(query) do
    words =
      query
      |> Parser.search_key()
      |> String.split(" ", trim: true)
      |> Enum.take(@max_words)

    if String.length(Enum.join(words)) < @min_query do
      {:error, :too_short}
    else
      match = Enum.map_join(words, " ", &(~s(") <> &1 <> ~s("*)))
      {:ok, %{tournaments: search_tournaments(match), players: search_players(match)} |> split()}
    end
  end

  def search(_not_text), do: {:error, :too_short}

  defp search_tournaments(match) do
    visible_entries()
    |> join(
      :inner,
      [entry: e],
      s in fragment(
        "SELECT rowid AS id FROM tournament_search WHERE tournament_search MATCH ?",
        ^match
      ),
      on: s.id == e.id
    )
    |> order_by([entry: e], desc: e.start_date, asc: e.name)
    |> limit(^@search_limit)
    |> Repo.all()
  end

  defp search_players(match) do
    suppressed = from s in Suppression, select: s.fide_id

    player_appearances()
    |> join(
      :inner,
      [appearance: a],
      s in fragment("SELECT rowid AS id FROM player_search WHERE player_search MATCH ?", ^match),
      on: s.id == a.id
    )
    |> where([appearance: a], is_nil(a.fide_id) or a.fide_id not in subquery(suppressed))
    |> order_by([appearance: a], desc: a.start_date, desc: a.id)
    |> limit(^@search_rows)
    |> Repo.all()
  end

  defp split(%{players: hits} = results) do
    listed = hits |> Enum.map(& &1.fide_id) |> Enum.reject(&is_nil/1) |> FideList.lookup()

    {grouped, loose} =
      Enum.split_with(hits, fn hit ->
        hit.fide_id != nil and belongs?(hit, Map.get(listed, hit.fide_id))
      end)

    players =
      grouped
      |> Enum.group_by(& &1.fide_id)
      |> Enum.map(fn {id, [newest | _] = appearances} ->
        row = Map.get(listed, id)

        %{
          fide_id: id,
          name: (row && row.name) || newest.name,
          title: (row && row.title) || newest.title,
          federation: (row && row.federation) || newest.federation,
          tournaments: length(appearances),
          latest: newest
        }
      end)
      |> Enum.sort_by(&{-&1.tournaments, &1.name})
      |> Enum.take(@search_limit)

    %{results | players: players}
    |> Map.put(:appearances, Enum.take(loose, @search_limit))
  end

  ## ---------- suppressions ----------

  @doc "Whether `fide_id`'s player page was taken down."
  @spec suppressed?(integer()) :: boolean()
  def suppressed?(fide_id) when is_integer(fide_id),
    do: Repo.exists?(from s in Suppression, where: s.fide_id == ^fide_id)

  @doc "Every suppressed FIDE id, newest first."
  @spec list_suppressions() :: [Suppression.t()]
  def list_suppressions,
    do: Repo.all(from s in Suppression, order_by: [desc: s.inserted_at, desc: s.fide_id])

  @doc false
  # For `OpenResults.Moderation`, inside its transaction.
  def insert_suppression!(fide_id, note, actor) do
    Repo.insert!(
      %Suppression{
        fide_id: fide_id,
        scope: "history",
        note: note,
        created_by: actor,
        inserted_at: DateTime.utc_now()
      },
      on_conflict: :nothing,
      conflict_target: :fide_id
    )
  end

  @doc false
  def delete_suppression!(fide_id) do
    {count, _} = Repo.delete_all(from s in Suppression, where: s.fide_id == ^fide_id)
    count
  end

  @doc """
  Appearances whose published name did not match the FIDE list's name for
  their id when they were indexed - the admin panel's list of probable
  mistyped ids. Newest first, at most `limit`.
  """
  @spec name_mismatches(pos_integer()) :: [Appearance.t()]
  def name_mismatches(limit \\ 200) do
    from(a in Appearance,
      join: e in Entry,
      on: e.slug == a.slug,
      where: a.fide_name_mismatch == true,
      order_by: [desc: a.start_date, desc: a.id],
      limit: ^limit,
      select_merge: %{tournament_name: e.name}
    )
    |> Repo.all()
  end

  ## ---------- reading fields ----------

  defp shown(payload, key, value), do: if(Tournament.show?(payload, key), do: value)

  defp text(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, 200)
        end

      _absent ->
        nil
    end
  end

  # A code as federations write it - BEL, FID - and nothing else; anything
  # longer or stranger files the tournament under "no federation" rather than
  # under a listing nobody could type the address of.
  defp federation(value) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()
    if code =~ ~r/\A[A-Z]{2,4}\z/, do: code
  end

  defp federation(_absent), do: nil

  defp date_text(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date)
      _unparseable -> nil
    end
  end

  defp date_text(_absent), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_not_an_integer), do: nil

  defp number(value) when is_number(value), do: value / 1
  defp number(_not_a_number), do: nil

  defp fide_id(value) when is_integer(value) and value > 0, do: value
  defp fide_id(_absent), do: nil

  defp event_id(info) do
    case info["group"] do
      %{"id" => id} when is_binary(id) -> String.slice(id, 0, 100)
      _ -> nil
    end
  end
end
