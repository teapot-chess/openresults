defmodule OpenResults.Repo.Migrations.CreateTrafficDays do
  use Ecto.Migration

  # Daily totals of who read the site, kept so the admin stats page has a
  # history that survives a restart. Numbers only: the hashes that tell one
  # reader from another live in memory for the day and are never written here.
  # See `OpenResults.Stats.Viewers`.
  def change do
    create table(:traffic_days) do
      add :day, :date, null: false
      add :unique_viewers, :integer, null: false, default: 0
      add :page_views, :integer, null: false, default: 0
      add :bot_hits, :integer, null: false, default: 0
      add :refreshes, :integer, null: false, default: 0
    end

    create unique_index(:traffic_days, [:day])

    create table(:traffic_tournament_days) do
      add :day, :date, null: false
      add :slug, :string, null: false
      add :unique_viewers, :integer, null: false, default: 0
      add :page_views, :integer, null: false, default: 0
    end

    create unique_index(:traffic_tournament_days, [:day, :slug])
    create index(:traffic_tournament_days, [:slug])
  end
end
