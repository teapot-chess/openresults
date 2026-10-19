defmodule OpenResults.Repo.Migrations.CreateTournamentTombstones do
  use Ecto.Migration

  @moduledoc """
  A row per slug the operator deleted from the admin panel - see
  `OpenResults.Tombstones` and `docs/public-publishing.md`, "Deleted
  tournaments". Every publish refuses a slug with one.

  Its own table rather than a status on `tournaments`, because the takedown
  deletes that row on purpose: a tombstone is what is left when the
  tournament is not.
  """

  def change do
    create table(:tournament_tombstones, primary_key: false) do
      add :slug, :string, primary_key: true
      # The installation that owned the slug when it was deleted; nil for an
      # operator-published tournament. Only that installation is told
      # `tournament_deleted` rather than `not_owner`.
      add :installation_id, :string
      add :deleted_by, :string, null: false
      add :deleted_at, :utc_datetime_usec, null: false
    end
  end
end
