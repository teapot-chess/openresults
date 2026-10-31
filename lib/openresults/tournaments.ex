defmodule OpenResults.Tournaments do
  @moduledoc """
  Who owns a tournament, and who may see it.

  `OpenResults.Snapshots` stores what a tournament says; this stores two facts
  ABOUT it that no snapshot can carry, because an arbiter's machine does not
  get to decide them:

    * **status** - `pending`, `listed` or `hidden`;
    * **owner** - the installation a slug was minted for, or nobody.

  ## Visibility

  | | pending | listed | hidden |
  |---|---|---|---|
  | reachable at its URL | yes | yes | no - the same 404 as an unknown slug |
  | homepage and its search | yes | yes | no |
  | cross-tournament player pages | **no** | yes | no |
  | entry and report forms | yes | yes | no |

  **Pending is public, except on player pages** (the admin upgrade,
  2026-09-13). Publishing and discovery are open by default: an arbiter's
  event must never wait for an approval on a Saturday morning, and it is on
  the front page, in its search and open to search engines straight away.
  The one thing pending withholds is the cross-tournament player pages,
  because otherwise anyone could publish a fake tournament full of real FIDE
  ids and have invented results appear on real players' histories. Approving
  a tournament is what puts it there. A trusted installation's tournaments
  start listed.

  **Hidden is indistinguishable from absent.** Every public surface asks
  `public_latest/1` or `status/1`, and a hidden tournament answers exactly what
  a slug that never published answers.

  ## A slug with no row

  Reads as `listed`. After the migration that created this table backfilled
  every existing slug, the only way to have snapshots and no row is a publish
  with the operator token - and `Snapshots.ingest/2` writes the row for those
  too. So the default is not a loophole for installations: they can publish
  only to a slug minted for them, and minting writes the row first.

  ## Minting

  In public mode the server picks the whole slug - 9 random bytes, base64url,
  the shape OpenPairings' own `public_slug` already has - and binds it to the
  installation that asked. No name can be chosen, so no readable name can be
  squatted, and no existing tournament can be claimed: an installation key may
  touch only slugs minted for it.

  ## Changing status

  Drops that tournament's rendered pages in every language
  (`OpenResultsWeb.Plugs.Revalidate.Page.forget/1`, the same per-tournament
  sweep a publish triggers) and writes the new status to `StatusCache` - see
  there for why a writer's value always beats a reader's.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Installations.Installation
  alias OpenResults.PublicPublishing
  alias OpenResults.Repo
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments.StatusCache
  alias OpenResults.Tournaments.Tournament
  alias OpenResultsWeb.Plugs.Revalidate.Page

  @type status :: :pending | :listed | :hidden

  @doc """
  The visibility of `slug`: `:pending`, `:listed` or `:hidden`. `:listed` when
  there is no row - see "A slug with no row".

  Answered from `StatusCache` when it can be, which is almost always.
  """
  @spec status(String.t()) :: status()
  def status(slug) when is_binary(slug) do
    case StatusCache.fetch(slug) do
      {:ok, status} ->
        status

      :miss ->
        status = read_status(slug)
        StatusCache.remember(slug, status)
        status
    end
  end

  defp read_status(slug) do
    from(t in Tournament, where: t.slug == ^slug, select: t.status)
    |> Repo.one()
    |> to_status()
  end

  defp to_status("pending"), do: :pending
  defp to_status("hidden"), do: :hidden
  defp to_status(_listed_or_no_row), do: :listed

  @doc """
  The current snapshot of `slug` as the public may see it: `nil` when there is
  none OR when the tournament is hidden. Every public page reads through this,
  so hidden and unknown cannot drift apart.
  """
  @spec public_latest(String.t()) :: OpenResults.Snapshots.Snapshot.t() | nil
  def public_latest(slug) when is_binary(slug) do
    # The snapshot first and the status only when there is one, so a slug
    # nobody published never reaches `StatusCache` - see
    # `OpenResultsWeb.Plugs.Visibility`, "Cost".
    with %{} = snapshot <- OpenResults.Snapshots.latest(slug),
         status when status != :hidden <- status(slug) do
      snapshot
    else
      _absent_or_hidden -> nil
    end
  end

  @doc "The row for `slug`, or `nil`."
  @spec get(String.t()) :: Tournament.t() | nil
  def get(slug) when is_binary(slug), do: Repo.get_by(Tournament, slug: slug)
  def get(_not_a_slug), do: nil

  @doc """
  Makes sure an operator-published slug has its row: `listed`, no owner.
  Changes nothing about a slug that already has one - an operator publish to
  an installation's tournament neither adopts it nor approves it.
  """
  @spec ensure_listed(String.t()) :: :ok
  def ensure_listed(slug) when is_binary(slug) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Tournament,
      [%{slug: slug, status: "listed", inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: :slug
    )

    # Whatever is there now, row we wrote or row that already existed. A put
    # rather than a remember: this is a writer, and a stale `hidden` left in
    # the cache for a slug that has just been published with no row must not
    # outlive the row that now says otherwise.
    StatusCache.put(slug, read_status(slug))
    :ok
  end

  @doc """
  Records who published `slug`, from a hosted OpenPairings' `publisher` field
  - see `docs/snapshot-schema.md`. Admin panel display only.

  `payload` is the whole decoded snapshot; only `publisher.email` and
  `publisher.host` (both strings) are read. Absent or malformed - an older
  client, a local/desktop publish, an installation-key publish (which never
  carries this field) - changes nothing: a tournament keeps showing its last
  known publisher rather than losing it to a snapshot that does not repeat
  it. Called after the row is known to exist (`ensure_listed/1` for the
  operator path); a slug with no row yet is a no-op.
  """
  @spec set_publisher(String.t(), map()) :: :ok
  def set_publisher(slug, payload) when is_binary(slug) and is_map(payload) do
    case publisher_fields(payload) do
      nil ->
        :ok

      {email, host} ->
        from(t in Tournament, where: t.slug == ^slug)
        |> Repo.update_all(
          set: [owner_email: email, owner_host: host, updated_at: DateTime.utc_now()]
        )

        :ok
    end
  end

  defp publisher_fields(payload) do
    case Map.get(payload, "publisher") do
      %{"email" => email} = publisher when is_binary(email) ->
        host = Map.get(publisher, "host")
        {email, if(is_binary(host), do: host, else: nil)}

      _absent_or_malformed ->
        nil
    end
  end

  @doc """
  May `installation` publish to `slug`? Called inside the publish transaction
  - see `OpenResults.Snapshots.ingest/2` - so the answer cannot change between
  being given and the snapshot being stored.

  `{:error, :not_owner}` for any slug not minted for this installation,
  including one that does not exist; `{:error, :tournament_hidden}` for its own
  tournament that moderation hid.
  """
  @spec authorize_owner(String.t(), Installation.t(), :publish | :read | :delete) ::
          :ok | {:error, :not_owner | :tournament_hidden | :tournament_deleted}
  def authorize_owner(slug, %Installation{id: id}, action) when is_binary(slug) do
    case get(slug) do
      %Tournament{installation_id: ^id, status: "hidden"} when action == :publish ->
        {:error, :tournament_hidden}

      %Tournament{installation_id: ^id} ->
        :ok

      # No row, or someone else's. A slug the operator deleted while this
      # installation owned it is told so - `not_owner` would send its arbiter
      # to ask for a transfer of a tournament that no longer exists. Deleting
      # it again is allowed and removes nothing. See `OpenResults.Tombstones`.
      _someone_elses_or_none ->
        cond do
          not OpenResults.Tombstones.deleted_from?(slug, id) -> {:error, :not_owner}
          action == :delete -> :ok
          true -> {:error, :tournament_deleted}
        end
    end
  end

  def authorize_owner(_not_a_slug, %Installation{}, _action), do: {:error, :not_owner}

  @doc """
  Mints a slug for `installation`: `pending` - or `listed` when the
  installation is trusted - with no snapshot.

  `{:error, {:tournament_limit, limit}}` once the installation holds `limit`
  tournaments that are `pending` or `listed`. Counted and inserted in one
  immediate transaction, so two mints racing cannot both take the last place.
  """
  @spec mint(Installation.t(), keyword()) ::
          {:ok, Tournament.t()} | {:error, {:tournament_limit, non_neg_integer()}}
  def mint(%Installation{id: id} = installation, opts \\ []) do
    limit =
      Keyword.get_lazy(opts, :limit, fn ->
        PublicPublishing.installation_max_tournaments(installation)
      end)

    # `insert_all` does not cast, and a usec column refuses a DateTime of any
    # other precision - which is what a test's `~U[...]` literal is.
    now =
      opts
      |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
      |> then(fn %DateTime{microsecond: {us, _}} = dt -> %{dt | microsecond: {us, 6}} end)

    Repo.transaction(
      fn ->
        if active_count(id) >= limit, do: Repo.rollback({:tournament_limit, limit})

        slug = unused_slug()

        # A trusted installation's tournaments start listed - see
        # `OpenResults.Moderation.trust/3`. Read from the row inside this
        # transaction, not from the struct the caller holds, so trust given or
        # taken a moment ago is what applies.
        status = if trusted?(id), do: "listed", else: "pending"

        {1, [tournament]} =
          Repo.insert_all(
            Tournament,
            [
              %{
                slug: slug,
                status: status,
                installation_id: id,
                minted_at: now,
                inserted_at: now,
                updated_at: now
              }
            ],
            returning: true
          )

        tournament
      end,
      mode: :immediate
    )
    |> tap(fn
      {:ok, %Tournament{slug: slug, status: stored}} -> StatusCache.put(slug, to_status(stored))
      _refused -> :ok
    end)
  end

  defp trusted?(installation_id) do
    from(i in Installation, where: i.id == ^installation_id, select: i.trusted)
    |> Repo.one() == true
  end

  @doc """
  Lists every `pending` tournament an installation holds and returns their
  slugs, oldest first - what trusting it with "list its pending tournaments
  too" does. Each changes as `transition/3` changes one: cache updated,
  rendered pages dropped.
  """
  @spec list_pending_for(String.t()) :: [String.t()]
  def list_pending_for(installation_id) do
    slugs =
      from(t in Tournament,
        where: t.installation_id == ^installation_id and t.status == "pending",
        order_by: [asc: t.inserted_at, asc: t.slug],
        select: t.slug
      )
      |> Repo.all()

    from(t in Tournament, where: t.slug in ^slugs and t.status == "pending")
    |> Repo.update_all(set: [status: "listed", updated_at: DateTime.utc_now()])

    Enum.each(slugs, &changed/1)
    slugs
  end

  @doc "How many `pending` or `listed` tournaments an installation holds."
  @spec active_count(String.t()) :: non_neg_integer()
  def active_count(installation_id) do
    from(t in Tournament,
      where: t.installation_id == ^installation_id and t.status in ["pending", "listed"]
    )
    |> Repo.aggregate(:count)
  end

  # Nine random bytes is 72 bits, so a collision is not a thing that happens;
  # checked anyway, against every table that knows a slug, because the one it
  # would collide with could be a legacy tournament that has no row here.
  defp unused_slug(attempts \\ 5)

  defp unused_slug(0), do: raise("could not mint an unused slug")

  defp unused_slug(attempts) do
    slug = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    taken? =
      Repo.exists?(from t in Tournament, where: t.slug == ^slug) or
        Repo.exists?(from s in Snapshot, where: s.tournament_slug == ^slug) or
        TournamentKeys.claimed?(slug) or
        OpenResults.Tombstones.tombstoned?(slug)

    if taken?, do: unused_slug(attempts - 1), else: slug
  end

  @doc """
  Moves `slug` from one of `from_statuses` to `to`, dropping its cached pages.
  """
  @spec transition(String.t(), [String.t()], String.t()) ::
          {:ok, Tournament.t()} | {:error, :not_found | :invalid_status}
  def transition(slug, from_statuses, to) when is_binary(slug) do
    now = DateTime.utc_now()

    case from(t in Tournament, where: t.slug == ^slug and t.status in ^from_statuses)
         |> Repo.update_all(set: [status: to, updated_at: now]) do
      {1, _} ->
        changed(slug)
        {:ok, get(slug)}

      {0, _} ->
        if get(slug), do: {:error, :invalid_status}, else: {:error, :not_found}
    end
  end

  def transition(_not_a_slug, _from, _to), do: {:error, :not_found}

  @doc """
  Hides every `pending` or `listed` tournament an installation holds, returning
  their slugs.
  """
  @spec hide_all_for(String.t()) :: [String.t()]
  def hide_all_for(installation_id) do
    slugs =
      from(t in Tournament,
        where: t.installation_id == ^installation_id and t.status in ["pending", "listed"],
        select: t.slug
      )
      |> Repo.all()

    from(t in Tournament, where: t.slug in ^slugs)
    |> Repo.update_all(set: [status: "hidden", updated_at: DateTime.utc_now()])

    Enum.each(slugs, &changed/1)
    slugs
  end

  @doc """
  Rebinds `slug` to `installation_id` and releases its tournament key, so the
  new owner's next keyed publish claims it. Status is unchanged.
  """
  @spec transfer(String.t(), String.t()) :: {:ok, Tournament.t()} | {:error, :not_found}
  def transfer(slug, installation_id) when is_binary(slug) do
    {:ok, result} =
      Repo.transaction(fn ->
        before = get(slug)

        case from(t in Tournament, where: t.slug == ^slug)
             |> Repo.update_all(
               set: [installation_id: installation_id, updated_at: DateTime.utc_now()]
             ) do
          {1, _} ->
            TournamentKeys.release(slug)

            OpenResults.TournamentGroups.follow_transfer(
              before.event_id,
              before.installation_id,
              installation_id
            )

            :ok

          {0, _} ->
            :not_found
        end
      end)

    case result do
      :ok -> {:ok, get(slug)}
      :not_found -> {:error, :not_found}
    end
  end

  def transfer(_not_a_slug, _installation_id), do: {:error, :not_found}

  @doc """
  Deletes the row for `slug`. Only `OpenResults.Takedown.purge/1` calls this,
  inside its transaction; `forget/1` afterwards.
  """
  @spec delete_row(String.t()) :: non_neg_integer()
  def delete_row(slug) do
    {count, _} = from(t in Tournament, where: t.slug == ^slug) |> Repo.delete_all()
    count
  end

  @doc """
  After a row was deleted: the cache learns there is no row, and the pages go.
  """
  @spec forget(String.t()) :: :ok
  def forget(slug) do
    changed(slug)
    :ok
  end

  @doc """
  Releases slugs minted before `cutoff` that never received a publish,
  returning the slugs released.

  Each delete re-checks "no snapshot" in the same statement, so a first
  publish landing at the moment of release either finds its row gone (and is
  refused `not_owner`, because the publish checks ownership inside its own
  transaction) or keeps it.
  """
  @spec release_unpublished_before(DateTime.t()) :: [String.t()]
  def release_unpublished_before(%DateTime{} = cutoff) do
    stale =
      from(t in Tournament,
        as: :t,
        where:
          not is_nil(t.installation_id) and not is_nil(t.minted_at) and t.minted_at < ^cutoff and
            not exists(from s in Snapshot, where: s.tournament_slug == parent_as(:t).slug),
        select: t.slug
      )
      |> Repo.all()

    Enum.filter(stale, fn slug ->
      {count, _} =
        from(t in Tournament,
          as: :t,
          where:
            t.slug == ^slug and
              not exists(from s in Snapshot, where: s.tournament_slug == parent_as(:t).slug)
        )
        |> Repo.delete_all()

      if count == 1 do
        TournamentKeys.release(slug)
        forget(slug)
        true
      else
        false
      end
    end)
  end

  # The one place a write tells the read path. The cache gets what the
  # database now says - including "no row", which reads as listed - and every
  # rendered page of this tournament goes, in every language - and a hall
  # display showing it re-reads, so a hidden tournament leaves the screen too.
  defp changed(slug) do
    case from(t in Tournament, where: t.slug == ^slug, select: t.status) |> Repo.one() do
      nil -> StatusCache.delete(slug)
      stored -> StatusCache.put(slug, to_status(stored))
    end

    Page.forget(slug)
    OpenResults.TournamentEvents.changed(slug)

    # The listings and player pages it is on: status is joined at query time
    # there, so nothing in the index changes, but what they show does.
    OpenResults.ResultsIndex.touch(slug)

    # A tournament hidden or shown again is on its siblings' tab strips too.
    # (A deleted row cannot say who they were - `Takedown.purge/1` asks
    # before it deletes.)
    OpenResults.TournamentGroups.touch_siblings(slug)
  end
end
