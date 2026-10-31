defmodule OpenResults.Takedown do
  @moduledoc """
  Removing everything this server holds for one tournament.

  A published tournament carries player names, ratings, clubs and federations,
  and its registration queue carries email addresses. Until this existed the
  only way to take any of that down was to SSH in and edit SQLite by hand,
  which is not a takedown process - it is the absence of one.

  ## Why it is a module and not a `delete_all`

  Because the obvious implementation is wrong in a way that LOOKS right.

  `snapshots` is append-only: every publish is its own row, and
  `GET /api/tournaments/:slug/history?at=` serves whichever row was current at
  an instant. Deleting the current snapshot therefore removes the tournament
  from every public page, returns 404 everywhere a person would look, and
  leaves every earlier row - names, ratings, federations, and any round or
  board the arbiter had already retracted - one query away for anyone holding
  the ingest token. It would report success and satisfy a spot check.

  A takedown that leaves history behind is worse than no takedown, because
  somebody believes it worked. So this deletes EVERY row for the slug across
  every table: all snapshots, the registration queue, and the key claim.

  ## Why the key goes too

  A takedown means the slug is gone, not sealed. Keeping the claim would stop
  the arbiter republishing under the same name with a fresh key after the
  laptop that held the old one died - the exact situation a takedown often
  follows. The slug returns to unclaimed and the next publish claims it again,
  by the same trust-on-first-use path as any other new slug.

  ## Unless the operator did it

  `tombstone: actor` - the admin panel's delete, and its replay - also
  leaves an `OpenResults.Tombstones` row, in the same transaction, so the
  slug stays gone: an unclaimed slug was otherwise exactly what a hosted
  OpenPairings' next automatic publish needed to put the page back. The
  arbiter's own withdrawal leaves none, for the reason above.

  ## What it leaves

  Reports about the tournament (`OpenResults.Reports`) and the moderation
  action log. Both are records of why somebody acted on the page rather than
  the page's own data, and a takedown is often the action they record.

  ## One transaction

  A purge that removed the snapshots and then failed would leave a registration
  queue - the email addresses - attached to a tournament that no longer exists
  and can no longer be found to retry. All or nothing.
  """

  alias OpenResults.LiveBoards
  alias OpenResults.Registrations
  alias OpenResults.RelayKeys
  alias OpenResults.Repo
  alias OpenResults.Snapshots
  alias OpenResults.Tombstones
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments

  @type counts :: %{
          snapshots: non_neg_integer(),
          registrations: non_neg_integer(),
          key: non_neg_integer()
        }

  @doc """
  Deletes everything held for `slug` and reports what went.

  Idempotent, and the counts are why it can afford to be: purging a slug that
  holds nothing is not an error, it is a no-op that truthfully reports three
  zeroes. A caller retrying after a timeout gets the same "it is gone" as the
  call that did the work, while a caller who mistyped the slug can still see
  from the counts that it removed nothing.
  """
  @spec purge(String.t(), keyword()) :: counts()
  def purge(slug, opts \\ []) do
    # Asked before the row goes: the row is where the claim is stored, and
    # the siblings' tab strips still name this tournament.
    siblings = OpenResults.TournamentGroups.sibling_slugs(slug)

    # The listing and player pages it is on - asked before its index rows go,
    # bumped after the commit. See `OpenResults.ResultsIndex.Generations`.
    index_keys = OpenResults.ResultsIndex.keys_for(slug)

    {:ok, counts} =
      Repo.transaction(fn ->
        # Read before the row goes: the row is where the owner is stored.
        with by when is_binary(by) <- Keyword.get(opts, :tombstone) do
          owner = Tournaments.get(slug)
          Tombstones.put(slug, owner && owner.installation_id, by)
        end

        # The tournament's row goes too - its status and, for a slug minted
        # for an installation, its owner - so the slug is gone rather than
        # sealed, for the same reason as the key above. Not in the counts:
        # those are the contract's response body, and they count what a
        # takedown is FOR, which is the published data.
        Tournaments.delete_row(slug)

        # The games reported from the hall and the tournament's delay setting.
        # Not in the counts - those are the response body's contract - and
        # not optional: a takedown that left the moves of a named game behind
        # would be the half-takedown this module exists to prevent.
        LiveBoards.delete_all_for(slug)

        # And the credentials made for the relays of those games.
        RelayKeys.delete_all_for(slug)

        # The results hub's copy: its listing row, its players, its search
        # entries. Derived data, but data about people all the same.
        OpenResults.ResultsIndex.delete(slug)

        # Each context deletes its own rows. The alternative - one query per
        # table written here - would put `snapshots` and `registrations` schema
        # knowledge in a third place that has no other reason to know it.
        %{
          snapshots: Snapshots.delete_all_for(slug),
          registrations: Registrations.delete_all_for(slug),
          key: TournamentKeys.release(slug)
        }
      end)

    # After the commit, so the read path learns what was committed.
    Tournaments.forget(slug)
    OpenResults.TournamentGroups.touch(siblings)
    OpenResults.ResultsIndex.bump(index_keys)

    counts
  end
end
