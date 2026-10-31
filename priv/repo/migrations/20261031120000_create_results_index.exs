defmodule OpenResults.Repo.Migrations.CreateResultsIndex do
  use Ecto.Migration

  @moduledoc """
  The results hub's derived tables - see `OpenResults.ResultsIndex`.

  Nothing in here is a source of truth. Every row is a copy of fields a
  stored snapshot already carries, after the display rules the pages apply,
  and `mix openresults.reindex` (or the boot backfill) rebuilds the lot from
  `snapshots`. Which is also why this migration does not backfill: the boot
  backfill does, in the background, so a deploy does not wait on it.

  `player_suppressions` is the one table here that is not derived: a FIDE id
  whose cross-tournament page the operator took down at the player's
  request. It is kept until the player withdraws the request.
  """

  def up do
    create table(:tournament_index) do
      add :slug, :string, null: false
      add :snapshot_id, :integer, null: false
      add :index_version, :integer, null: false
      add :name, :string, null: false
      add :city, :string
      # NULL when the arbiter hides the federation, which files it under
      # "no federation" rather than under a code the pages would not print.
      add :federation, :string
      add :start_date, :string
      add :end_date, :string
      add :dates_shown, :boolean, null: false, default: true
      add :rounds_count, :integer, null: false, default: 0
      add :rounds_published, :integer, null: false, default: 0
      add :players_count, :integer, null: false, default: 0
      add :system, :string
      add :team, :boolean, null: false, default: false
      add :fide_rated, :boolean, null: false, default: false
      add :arbiter_listed, :boolean, null: false, default: true
      # The two date-free halves of `OpenResultsWeb.Tournament.status/2`, so
      # the life-cycle group is worked out at query time against today.
      add :complete, :boolean, null: false, default: false
      add :not_begun, :boolean, null: false, default: false
      add :event_id, :string
      add :last_published_at, :utc_datetime_usec, null: false
    end

    create unique_index(:tournament_index, [:slug])
    create index(:tournament_index, [:federation, :start_date])
    create index(:tournament_index, [:start_date])

    create table(:player_appearances) do
      add :slug, :string, null: false
      add :no, :integer, null: false
      add :name, :string
      add :federation, :string
      add :title, :string
      add :rating, :integer
      add :club, :string
      add :fide_id, :integer
      add :rank, :integer
      add :points, :float
      add :ranked_total, :integer
      add :performance, :integer
      add :card_linkable, :boolean, null: false, default: true
      # true/false against the FIDE list at index time; NULL when the list
      # had no answer. The player page asks the list again - see
      # `OpenResults.ResultsIndex.NameMatch`.
      add :fide_name_mismatch, :boolean
      add :start_date, :string
    end

    create index(:player_appearances, [:slug])
    create index(:player_appearances, [:fide_id, :start_date])

    # Full-text search. A plain FTS5 table keyed by rowid: a tournament's row
    # is its `tournament_index.id`, an appearance's its `player_appearances.id`,
    # each in its own table so a delete by rowid needs no scan.
    execute """
    CREATE VIRTUAL TABLE tournament_search USING fts5(
      body, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
    )
    """

    execute """
    CREATE VIRTUAL TABLE player_search USING fts5(
      body, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
    )
    """

    create table(:player_suppressions, primary_key: false) do
      add :fide_id, :integer, primary_key: true
      add :scope, :string, null: false, default: "history"
      add :note, :string
      add :created_by, :string
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop table(:player_suppressions)
    execute "DROP TABLE player_search"
    execute "DROP TABLE tournament_search"
    drop table(:player_appearances)
    drop table(:tournament_index)
  end
end
