defmodule OpenResults.Repo.Migrations.AddPhase2ToResultsIndex do
  use Ecto.Migration

  @moduledoc """
  The results hub's second batch of copied fields - see
  `OpenResults.ResultsIndex`, index version 2.

  Still nothing in here is a source of truth: every column is something the
  newest snapshot carries, after the display rules. Existing rows get the
  defaults and are rewritten by the boot backfill, which sees their
  `index_version` is 1 and rebuilds them, so no data step is needed here.

    * `series_id` - the series the tournament says it is an edition of
      (`tournament.series_id`), for the "other editions" block.
    * `name_key` - the name folded for sorting and the alphabetical list.
    * `round_numbers` - the published rounds, comma separated, and the three
      `*_shown` flags: what the sitemap may list without decoding the
      snapshot.
  """

  def change do
    alter table(:tournament_index) do
      add :series_id, :string
      add :name_key, :string, null: false, default: ""
      add :round_numbers, :string, null: false, default: ""
      add :standings_shown, :boolean, null: false, default: true
      add :pairings_shown, :boolean, null: false, default: true
      add :crosstable_shown, :boolean, null: false, default: true
    end

    create index(:tournament_index, [:series_id])
    create index(:tournament_index, [:name_key])
  end
end
