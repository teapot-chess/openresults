defmodule OpenResults.Repo.Migrations.CreateEventClaims do
  use Ecto.Migration

  @moduledoc """
  Who claimed each event id first - see `OpenResults.TournamentGroups`. Until
  now that was worked out on every read from the tournaments still claiming
  the id, so it moved to the next claimant when the first one's sections went.

  Backfilled from what the old rule would have answered today: the earliest
  claim among the tournaments that are not hidden, or, for an id only hidden
  tournaments claim, the earliest of those. Ties on `event_since` go to the
  older row.
  """

  def up do
    create table(:event_claims, primary_key: false) do
      add :event_id, :string, primary_key: true
      # `nil` is the operator token's publisher.
      add :installation_id, :string
      add :claimed_at, :utc_datetime_usec
    end

    execute """
    INSERT INTO event_claims (event_id, installation_id, claimed_at)
    SELECT t.event_id, t.installation_id, t.event_since
    FROM tournaments AS t
    WHERE t.event_id IS NOT NULL
      AND t.id = (
        SELECT t2.id FROM tournaments AS t2
        WHERE t2.event_id = t.event_id
        ORDER BY (t2.status = 'hidden'), t2.event_since, t2.id
        LIMIT 1
      )
    """
  end

  def down do
    drop table(:event_claims)
  end
end
