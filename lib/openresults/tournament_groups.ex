defmodule OpenResults.TournamentGroups do
  @moduledoc """
  Which tournaments say they are sections of one event, and what this server
  is prepared to believe about that.

  An arbiter's app may put a `group` object in a tournament's snapshot (see
  `docs/snapshot-schema.md`, "`tournament.group`"): the event's public id and
  name, this tournament's label and place, and its siblings by slug. The
  pages turn that into a tab strip and an event page
  (`OpenResultsWeb.EventGroup`). This module is the part that does not trust
  it.

  ## What a snapshot may not decide

  A snapshot is a claim by whoever published it, and with public publishing
  that is anybody. Left alone, "I am part of event X, and so are these
  slugs" would let a stranger put a tournament of their own on somebody
  else's event page, or hang somebody else's tournament under an event of
  theirs. So a tournament counts as a member of an event only when the
  server's own facts agree:

    * it is public here - published, and not hidden by moderation;
    * its own latest snapshot names the same event id (`tournaments.event_id`,
      written at ingest - never taken from another tournament's word);
    * it belongs to **the same publisher** as the tournament it is shown
      beside: the same installation, or both published with the operator
      token. An event's sections are run from one arbiter's app; a slug
      owned by another installation is a different person's tournament,
      whatever either snapshot says.

  The event page has no tournament to stand beside, so its publisher is the
  one that claimed the id first: an id is random and unknown to everyone
  else until its first publish, so nobody can get there before its owner.

  "First" is a row of its own in `event_claims` (`EventClaim`), written once
  by the first publish naming the id (the 2026-10-19 sweep). It used to be
  derived from whichever non-hidden tournament claimed the id earliest, so
  hiding or deleting the owner's sections handed the event to whoever had
  copied the id off a public page and published under it since. Only the
  operator moves a claim: `follow_transfer/3`, from a transfer in the admin
  panel.

  ## Telling the pages

  A tournament's tab strip is drawn from OTHER tournaments' state - whether a
  sibling is still public, whether it has a round 5 yet. The page cache and
  the ETag (`OpenResultsWeb.Plugs.Revalidate`) are keyed by the tournament's
  own snapshot, which does not move when a sibling's does. So each slug has
  an **epoch**, in ETS, that `Revalidate` folds into the ETag; a change to a
  tournament bumps the epoch of every other slug naming the same event, drops
  their rendered pages and tells their open pages to poll. A tournament in no
  event pays one ETS miss per request for this and nothing else.

  Epochs do not survive a restart, and do not need to: the ETag's secret is
  redrawn at boot too, so every tag is new anyway.
  """

  import Ecto.Query

  alias OpenResults.Repo
  alias OpenResults.TournamentGroups.Epochs
  alias OpenResults.TournamentGroups.EventClaim
  alias OpenResults.Tournaments.Tournament
  alias OpenResultsWeb.Plugs.Revalidate.Page

  @id ~r/\A[A-Za-z0-9_-]{6,64}\z/

  @doc """
  The event id a snapshot claims, or nil: absent, malformed, or not the
  shape an id has. Only this and the row it is stored in are ever compared;
  the rest of the block is display text, read by `OpenResultsWeb.EventGroup`.
  """
  @spec claimed_id(map()) :: String.t() | nil
  def claimed_id(payload) when is_map(payload) do
    with %{"group" => %{"id" => id}} <- Map.get(payload, "tournament"),
         true <- is_binary(id) and Regex.match?(@id, id) do
      id
    else
      _absent_or_malformed -> nil
    end
  end

  def claimed_id(_not_a_payload), do: nil

  @doc """
  Records what `slug`'s newest snapshot says about its event, and tells the
  tournaments it is - or just stopped being - shown beside.

  Called by `OpenResults.Snapshots.ingest/2` after the snapshot is stored and
  its row exists. `changed?` is whether this publish stored a new snapshot; an
  unchanged repeat with the same event moves nothing.
  """
  @spec record(String.t(), map(), boolean()) :: :ok
  def record(slug, payload, changed?) when is_binary(slug) do
    new = claimed_id(payload)

    {old, owner} =
      Repo.one(
        from t in Tournament, where: t.slug == ^slug, select: {t.event_id, t.installation_id}
      ) || {nil, nil}

    if new != old do
      now = DateTime.utc_now()

      from(t in Tournament, where: t.slug == ^slug)
      |> Repo.update_all(set: [event_id: new, event_since: new && now, updated_at: now])

      if new, do: claim(new, owner, now)
    end

    if new != old or (changed? and not is_nil(new)) do
      [old, new]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(&slugs_claiming/1)
      |> Enum.uniq()
      |> List.delete(slug)
      |> touch()
    end

    :ok
  end

  @doc """
  The other slugs claiming the event `slug` claims. For a caller about to
  delete `slug`'s row, which is where that claim is stored.
  """
  @spec sibling_slugs(String.t()) :: [String.t()]
  def sibling_slugs(slug) when is_binary(slug) do
    case Repo.one(from t in Tournament, where: t.slug == ^slug, select: t.event_id) do
      nil -> []
      id -> id |> slugs_claiming() |> List.delete(slug)
    end
  end

  @doc "`touch/1` for `slug`'s siblings: its status changed, and their strips show it."
  @spec touch_siblings(String.t()) :: :ok
  def touch_siblings(slug) when is_binary(slug), do: slug |> sibling_slugs() |> touch()

  @doc """
  Marks each of `slugs` as changed for a reason its own snapshot does not
  show: a new epoch (so its ETag moves), its rendered pages dropped, its open
  pages told to poll.
  """
  @spec touch([String.t()]) :: :ok
  def touch(slugs) when is_list(slugs) do
    Enum.each(slugs, fn slug ->
      Epochs.bump(slug)
      Page.forget(slug)
      OpenResults.TournamentEvents.changed(slug)
    end)
  end

  @doc "The epoch of `slug`: 0 until something beside it has changed."
  @spec epoch(String.t()) :: non_neg_integer()
  def epoch(slug), do: Epochs.get(slug)

  @doc """
  What this server knows about each of `slugs`:
  `%{slug => %{event_id, installation_id, status}}`. A slug with no row is
  absent.
  """
  @spec facts([String.t()]) :: %{String.t() => map()}
  def facts(slugs) when is_list(slugs) do
    from(t in Tournament,
      where: t.slug in ^slugs,
      select:
        {t.slug, %{event_id: t.event_id, installation_id: t.installation_id, status: t.status}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The slugs that are members of event `id` as far as this server's own rows
  go: not hidden, claiming `id`, and owned by the publisher that claimed it
  first. In the order they claimed it. The caller still reads each one
  through `Tournaments.public_latest/1`.
  """
  @spec member_slugs(String.t()) :: [String.t()]
  def member_slugs(id) when is_binary(id) do
    case Repo.get(EventClaim, id) do
      nil ->
        []

      %EventClaim{installation_id: owner} ->
        from(t in Tournament,
          where: t.event_id == ^id and t.status != "hidden",
          order_by: [asc: t.event_since, asc: t.id],
          select: t.slug
        )
        |> same_publisher(owner)
        |> Repo.all()
    end
  end

  def member_slugs(_not_an_id), do: []

  @doc """
  The publisher each of `ids` belongs to - the one that claimed it first:
  `%{id => installation_id | nil}`. An id nobody has claimed is absent.
  """
  @spec owners([String.t()]) :: %{String.t() => String.t() | nil}
  def owners(ids) when is_list(ids) do
    from(c in EventClaim, where: c.event_id in ^ids, select: {c.event_id, c.installation_id})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Moves event claims along with a tournament the operator transferred from
  `from` to `to` (`OpenResults.Tournaments.transfer/2`, inside its
  transaction): each claim `from` holds on `event_id` goes to `to` once `from`
  has no tournament left claiming it. A claim held by someone else stays
  where it is - a transfer is about the tournament, not a way to win an
  event.
  """
  @spec follow_transfer(String.t() | nil, String.t() | nil, String.t() | nil) :: :ok
  def follow_transfer(nil, _from, _to), do: :ok

  def follow_transfer(event_id, from, to) do
    still_held? =
      from(t in Tournament, where: t.event_id == ^event_id)
      |> same_publisher(from)
      |> Repo.exists?()

    unless still_held? do
      from(c in EventClaim, where: c.event_id == ^event_id)
      |> claimed_by(from)
      |> Repo.update_all(set: [installation_id: to])
    end

    :ok
  end

  defp claim(id, owner, now) do
    Repo.insert_all(
      EventClaim,
      [%{event_id: id, installation_id: owner, claimed_at: now}],
      on_conflict: :nothing,
      conflict_target: :event_id
    )
  end

  # `nil` is the operator token's publisher, and SQL's `=` never matches it.
  defp same_publisher(query, nil), do: where(query, [t], is_nil(t.installation_id))
  defp same_publisher(query, owner), do: where(query, [t], t.installation_id == ^owner)

  defp claimed_by(query, nil), do: where(query, [c], is_nil(c.installation_id))
  defp claimed_by(query, owner), do: where(query, [c], c.installation_id == ^owner)

  defp slugs_claiming(id) do
    Repo.all(from t in Tournament, where: t.event_id == ^id, select: t.slug)
  end
end
