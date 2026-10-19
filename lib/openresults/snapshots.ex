defmodule OpenResults.Snapshots do
  @moduledoc """
  Storage and retrieval of published tournament snapshots.

  The whole of this app's write path. It takes a document an arbiter's machine
  produced, checks the envelope, and keeps the document verbatim. It does not
  interpret rounds, boards or standings, and it never computes a placing - the
  arbiter's screen and the public page have to agree, and the only way to
  guarantee that is to have exactly one thing doing the arithmetic.

  What is absent from a payload stays absent. An unpublished round and a
  hidden board are withheld at build time on the arbiter's machine, so there
  is nothing here to filter and nothing here to leak.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Envelope
  alias OpenResults.PublicPublishing
  alias OpenResults.Repo
  alias OpenResults.Snapshots.LatestIdCache
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments

  @schema_id "openresults/snapshot"

  # Every envelope version this server understands. A list rather than a
  # ceiling: see OpenResults.Envelope.
  @supported_versions [1]

  @doc """
  The schema identifier a snapshot payload must declare.
  """
  def schema_id, do: @schema_id

  @doc """
  Stores a published snapshot.

  `payload` is the decoded JSON document, exactly as it arrived. Unknown
  fields - at the top level or buried anywhere inside - are stored, not
  rejected: that tolerance is the reason the contract can add fields without
  stranding older servers.

  Returns `{:error, reason}` for the four things that are genuinely
  unstorable: `:not_an_object`, `:wrong_schema`, `:unknown_version`,
  `:missing_slug`.

  ## Options

    * `:key` - the tournament key the request presented, or `nil`. Checked by
      `OpenResults.TournamentKeys`, which also claims an unclaimed slug on a
      first publish. `{:error, :key_required}` and `{:error, :key_mismatch}`
      come from there.

    * `:received_at` - the server's clock, injectable for tests.

    * `:installation` - the `OpenResults.Installations.Installation` the
      request authenticated as, or absent for the operator token. See
      "Two paths" below.

  The key is checked AFTER the envelope, because the slug it authorises
  against is inside the envelope and there is nothing to authorise until it
  has been read. It is checked BEFORE anything is written, including before
  the idempotent-repeat comparison below: a request with the wrong key must
  change nothing, and it must not learn from a "nothing changed" answer what
  the tournament currently holds.

  ## Two paths

  **The operator token** publishes as it always did, and afterwards makes
  sure the slug has its `OpenResults.Tournaments` row - `listed`, no owner -
  without touching a row that already exists.

  **An installation key** may publish only to a slug minted for it
  (`{:error, :not_owner}`), not to one moderation hid
  (`{:error, :tournament_hidden}`), and never with break-glass. The ownership
  check, the key check and the insert run in ONE immediate transaction. The
  ingest plug already checked ownership, and this is not a second opinion but
  the one that cannot race: without it, a delete of the same tournament
  landing between the plug's check and the insert would leave a snapshot with
  no row behind it - which reads as `listed` - and a pending tournament would
  have promoted itself onto the front page and the player pages.

  The same transaction then prunes the tournament to its newest
  `PublicPublishing.installation_max_versions/0` versions
  (`prune_versions/2`) - after every accepted installation publish, an
  unchanged repeat included. The operator path keeps every version.
  """
  @spec ingest(term(), keyword()) ::
          {:ok, Snapshot.t()}
          | {:error,
             Envelope.error()
             | TournamentKeys.error()
             | :not_owner
             | :tournament_hidden
             | :tournament_deleted
             | Ecto.Changeset.t()}
  def ingest(payload, opts \\ []) do
    with {:ok, slug} <-
           Envelope.validate(payload, @schema_id, @supported_versions, ["tournament", "slug"]) do
      received_at = Keyword.get_lazy(opts, :received_at, &DateTime.utc_now/0)
      key = Keyword.get(opts, :key)

      # Read before the publish, to tell a new snapshot from an unchanged
      # repeat afterwards - see `TournamentGroups.record/3`.
      id_before = latest_id(slug)

      result =
        case Keyword.get(opts, :installation) do
          nil -> ingest_as_operator(slug, payload, key, received_at)
          installation -> ingest_as_installation(slug, payload, key, received_at, installation)
        end

      # Which event this tournament now says it belongs to, and the pages of
      # the tournaments shown beside it: their tab strips are drawn from this
      # one's state. After the commit, like the announcement below.
      with {:ok, %Snapshot{id: id}} <- result,
           do: OpenResults.TournamentGroups.record(slug, payload, id != id_before)

      # After the commit and after `LatestIdCache` has the new id, so a hall
      # display re-reading on this message finds the document it announces.
      # An unchanged repeat is announced too: it costs a listener one cache
      # hit, and deciding "unchanged" here would be a second copy of the rule.
      with {:ok, _snapshot} <- result, do: OpenResults.TournamentEvents.changed(slug)

      result
    end
  end

  # One immediate transaction, like the installation path, for the
  # tombstone's sake: an admin delete committing between "not deleted" and
  # the insert would otherwise be undone by the very publish it raced. See
  # `OpenResults.Tombstones`. Break-glass is the one key that gets past a
  # tombstone, and lifts it.
  defp ingest_as_operator(slug, payload, key, received_at) do
    Repo.transaction(
      fn ->
        with :ok <- OpenResults.Tombstones.check_operator_publish(slug, key),
             :ok <- TournamentKeys.authorize_publish(slug, key),
             {:ok, snapshot} <- store(slug, payload, received_at) do
          Tournaments.ensure_listed(slug)
          # Only the operator path: an installation-key publish never carries
          # `publisher` (see docs/snapshot-schema.md) - it already identifies
          # its installation in the admin panel.
          Tournaments.set_publisher(slug, payload)
          snapshot
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    # After the commit - see `ingest_as_installation/5`.
    |> cache_inserted_id(slug)
  end

  defp ingest_as_installation(slug, payload, key, received_at, installation) do
    Repo.transaction(
      fn ->
        with :ok <- Tournaments.authorize_owner(slug, installation, :publish),
             :ok <- TournamentKeys.authorize_publish(slug, key, break_glass: false),
             {:ok, snapshot} <- store(slug, payload, received_at) do
          # Inside the transaction that inserted, so the newest N at commit
          # are exactly the ones kept. See `prune_versions/2`.
          prune_versions(slug, PublicPublishing.installation_max_versions(installation))
          snapshot
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
    # After the commit, never inside the transaction. Inside, the new id was
    # in the cache while the row was still invisible to every other
    # connection, and a page requested in that window was rendered from the
    # OLD row under the NEW id's ETag - stored in the page cache and in the
    # reader's browser as current, so that page showed the old document until
    # the next publish. See `cache_inserted_id/2`.
    |> cache_inserted_id(slug)
  end

  defp store(slug, payload, received_at) do
    case latest(slug) do
      # A publish is idempotent by design: the document is whole, so re-sending
      # it after a timeout means the same thing as sending it once. Collapsing
      # a byte-identical repeat keeps the history a record of what changed
      # rather than a record of how flaky the hall's wifi was. If the round
      # trip through JSON ever perturbs a value the comparison misses, the
      # fallback is an extra identical row, which reads back the same.
      %Snapshot{payload: ^payload} = unchanged ->
        {:ok, unchanged}

      _new_or_changed ->
        %Snapshot{}
        |> Snapshot.changeset(%{
          tournament_slug: slug,
          version: Map.get(payload, "version"),
          source_app: source_field(payload, "app"),
          source_version: source_field(payload, "version"),
          published_at: Envelope.claimed_time(payload, "published_at"),
          received_at: received_at,
          payload: payload
        })
        |> Repo.insert()
    end
  end

  # The write side of `LatestIdCache`. The moment a publish's row is
  # committed and this process knows its id, every OTHER reader of this slug
  # must be able to see it too - immediately, not on their next cache miss -
  # or a poll already in flight could be told "unchanged" about a page that
  # no longer is. Committed first, not merely inserted: a reader that finds
  # the new id must also find the row behind it. See `OpenResults.Snapshots.LatestIdCache` for why this is a plain
  # overwrite rather than a compare-and-swap.
  defp cache_inserted_id({:ok, %Snapshot{id: id}} = result, slug) do
    LatestIdCache.put(slug, id)
    result
  end

  defp cache_inserted_id(error, _slug), do: error

  defp source_field(payload, key) do
    case Map.get(payload, "source") do
      source when is_map(source) ->
        case Map.get(source, key) do
          value when is_binary(value) -> value
          _absent_or_not_a_string -> nil
        end

      _absent_or_not_an_object ->
        nil
    end
  end

  @doc """
  The current snapshot for a tournament, or `nil`.

  What the public page renders. Newest by the server's clock, with the id
  breaking a tie, because two publishes can land in the same microsecond and
  the row that arrived second is the later one by definition.
  """
  @spec latest(String.t()) :: Snapshot.t() | nil
  def latest(slug) do
    case latest_id(slug) do
      nil -> nil
      id -> cached(slug, id)
    end
  end

  # One decode per published version, rather than one per reader.
  #
  # `OpenResultsWeb.Plugs.Revalidate` already makes an unchanged poll cost a
  # primary-key lookup, which is the common case and 566x cheaper than a
  # render. What it cannot help is the moment that actually matters: a round
  # finishes, the arbiter publishes, and every phone in the hall asks for the
  # new page inside the next twenty seconds. Each of those is a genuine 200,
  # and without this each would decode the same ~580 KB document again.
  #
  # Keyed by SLUG and validated by id, so a new publish is picked up on the
  # next request rather than needing anything to remember to invalidate. The
  # id comes from `latest_id/1`, which the caller has usually just paid for
  # anyway.
  #
  # ETS copies on read, so this saves the decode and not the copy - the
  # decode is the expensive half. Bounded by the number of tournaments being
  # read, one entry each, and an entry is replaced rather than added when a
  # tournament publishes again.
  defp cached(slug, id) do
    case lookup(slug) do
      %Snapshot{id: ^id} = hit ->
        hit

      _miss_or_stale ->
        snapshot = slug |> for_slug() |> limit(1) |> Repo.one()
        if snapshot, do: :ets.insert(table(), {slug, snapshot})
        snapshot
    end
  end

  defp lookup(slug) do
    case :ets.lookup(table(), slug) do
      [{^slug, snapshot}] -> snapshot
      [] -> nil
    end
  rescue
    # The table is created lazily, so the very first read can arrive before
    # it exists. A cache must never be the reason a page fails.
    ArgumentError -> nil
  end

  @cache :openresults_snapshot_cache

  defp table do
    case :ets.whereis(@cache) do
      :undefined ->
        :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])

      ref ->
        ref
    end
  rescue
    # Two processes racing to create it: whoever lost just uses the winner's.
    ArgumentError -> @cache
  end

  @doc """
  Forgets everything cached - both this module's snapshot-body cache and
  `LatestIdCache`. For tests, and for anything that deletes rows behind this
  module's back.
  """
  def clear_cache do
    case :ets.whereis(@cache) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(@cache)
    end

    LatestIdCache.clear()

    :ok
  end

  @doc """
  The id of the newest snapshot for `slug`, without loading it.

  The whole point is what it does NOT select. A published document is up to
  ~580 KB of JSON, and `latest/1` decodes all of it on every page view - so
  answering "has this changed since you last asked" by loading the snapshot
  would cost exactly what it is trying to save.

  The id alone identifies a version: the table appends, one row per changed
  publish, and a byte-identical re-send is collapsed rather than inserted
  (see `store/3`). So a reader holding id 41 and finding 41 still current is
  holding the current document, and nothing has to be read to prove it.

  A cache hit answers this without a query at all - see
  `OpenResults.Snapshots.LatestIdCache`, which `store/3` keeps current on
  every publish. A miss falls back to exactly the query this function used
  to always run, and remembers the answer for next time.
  """
  @spec latest_id(String.t()) :: integer() | nil
  def latest_id(slug) do
    case LatestIdCache.fetch(slug) do
      {:ok, id} ->
        id

      :miss ->
        id =
          slug
          |> for_slug()
          |> limit(1)
          |> select([s], s.id)
          |> Repo.one()

        if id, do: LatestIdCache.put(slug, id)
        id
    end
  end

  @doc """
  The snapshot that was current at `instant`, or `nil` if none had arrived yet.

  The reason the table appends. "What did the standings say at 14:00" is a
  question that follows a disputed result, and the contract forbids
  recomputing the answer, so it has to have been kept.
  """
  @spec as_of(String.t(), DateTime.t()) :: Snapshot.t() | nil
  def as_of(slug, %DateTime{} = instant) do
    slug
    |> for_slug_as_of(instant)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every snapshot held for a tournament, newest first.
  """
  @spec history(String.t()) :: [Snapshot.t()]
  def history(slug) do
    slug
    |> for_slug()
    |> Repo.all()
  end

  @doc """
  The current snapshot of every tournament that has ever published, by slug.

  For an index page. Picks the highest id per slug rather than the latest
  `received_at`, so a server clock that steps backwards cannot resurrect a
  superseded snapshot as the current one.
  """
  @spec list_current(keyword()) :: [Snapshot.t()]
  def list_current(opts \\ []) do
    newest_per_slug =
      from s in Snapshot,
        group_by: s.tournament_slug,
        select: max(s.id)

    from(s in Snapshot,
      where: s.id in subquery(newest_per_slug),
      order_by: [asc: s.tournament_slug]
    )
    |> only_listed(Keyword.get(opts, :listed_only, false))
    |> not_hidden(Keyword.get(opts, :visible_only, false))
    |> Repo.all()
  end

  # `visible_only: true` - leave out what moderation hid, and nothing else:
  # the front page and its search show pending tournaments too (the admin
  # upgrade, 2026-09-13). In SQL for the reason `only_listed/2` gives.
  defp not_hidden(query, true) do
    hidden =
      from t in OpenResults.Tournaments.Tournament, where: t.status == "hidden", select: t.slug

    where(query, [s], s.tournament_slug not in subquery(hidden))
  end

  defp not_hidden(query, _all), do: query

  # `listed_only: true` - leave out tournaments moderation has not listed
  # (`OpenResults.Tournaments`: pending and hidden), IN the query rather than
  # after it. An option the caller has to ask for, so this function still
  # never omits a row silently; and in SQL, because public publishing lets
  # anybody create pending tournaments of up to a few megabytes each, and a
  # listing that loaded all of them to throw them away would hand every
  # visitor to the front page that bill.
  defp only_listed(query, true) do
    unlisted =
      from t in OpenResults.Tournaments.Tournament, where: t.status != "listed", select: t.slug

    where(query, [s], s.tournament_slug not in subquery(unlisted))
  end

  defp only_listed(query, _all), do: query

  @doc """
  Deletes every version of `slug` older than its newest `keep`, returning how
  many went - the version cap of `docs/public-publishing.md`, "Storage
  bounds". Called by an installation-key publish inside its own transaction;
  an operator publish never prunes.

  Only the OLDEST go, by insertion (the row id), never by `received_at`, and
  never the newest: `keep` is at least 1. That is what keeps every reader
  whole. `latest/1`, `LatestIdCache`, the body cache, the ETag and the page
  cache all name the newest id, which is always kept. And `as_of/2` picks the
  highest id at or before an instant: removing only ids lower than every id
  kept can make that answer `nil`, never a different document. It is the opposite of the mistake `delete_all_for/1`
  warns about: that one would remove the newest row and leave the history;
  this removes the far end of the history and always leaves the newest.

  A tournament already over the cap is pruned lazily, by its next accepted
  installation publish. SQLite reuses the freed pages; nothing is vacuumed
  here.

  Writes no action log row: it is housekeeping, and the moderation journal's
  replay reads action rows about a tournament as moderation it already knows.
  """
  @spec prune_versions(String.t(), integer()) :: non_neg_integer()
  def prune_versions(slug, keep) when is_integer(keep) do
    keep = max(keep, 1)

    boundary =
      slug
      |> for_slug()
      |> offset(^(keep - 1))
      |> limit(1)
      |> select([s], s.id)
      |> Repo.one()

    case boundary do
      nil ->
        0

      id ->
        {count, _} =
          from(s in Snapshot, where: s.tournament_slug == ^slug and s.id < ^id)
          |> Repo.delete_all()

        count
    end
  end

  @doc """
  Deletes EVERY snapshot held for a tournament, returning how many went.

  Every one, not the current one. The table appends and `/history` serves
  earlier rows by `?at=`, so removing only the newest row would empty the
  public pages while leaving the whole event - and any round the arbiter had
  already retracted - readable by anyone holding the ingest token.

  Only ever called from `OpenResults.Takedown.purge/1`, which is what makes
  sure the registration queue and the key claim go in the same breath.

  Also forgets `slug` in `LatestIdCache`: after this, the true answer is "no
  snapshot", and a cache still holding the id of a row just deleted would be
  telling readers the opposite.
  """
  @spec delete_all_for(String.t()) :: non_neg_integer()
  def delete_all_for(slug) do
    {count, _returned} =
      from(s in Snapshot, where: s.tournament_slug == ^slug) |> Repo.delete_all()

    LatestIdCache.forget(slug)

    count
  end

  # Newest by INSERTION, not by timestamp. `received_at` is wall-clock and
  # wall-clock steps backwards - an NTP correction is enough - and a
  # superseded document winning that comparison is permanent: nothing
  # re-publishes to fix it, and no error is raised anywhere.
  #
  # `list_current/0` already defended itself this way with `max(s.id)` and
  # said so in its own docstring; the defence was simply never applied here,
  # so the index page and every public page could disagree about which
  # document is current. Reproduced with two publishes stamped 12:00:00 then
  # 11:59:59: the index linked to the new name, the standings page it linked
  # to served the old document.
  defp for_slug(slug) do
    from s in Snapshot,
      where: s.tournament_slug == ^slug,
      order_by: [desc: s.id]
  end

  # `as_of/2` is the one caller that legitimately reasons about wall-clock,
  # because "what was current at 14:00" is a question about time. It still
  # ORDERS by id: among rows stamped at or before the instant, the one
  # inserted last is the one that was current.
  defp for_slug_as_of(slug, instant) do
    from s in Snapshot,
      where: s.tournament_slug == ^slug and s.received_at <= ^instant,
      order_by: [desc: s.id]
  end
end
