defmodule OpenResults.Repo.Migrations.AddOpsTables do
  use Ecto.Migration

  # Two small operator-only tables (`OpenResults.Ops`): crashes, one row
  # per distinct fingerprint, and the off-site backup's run log. Both are
  # capped by the code that writes them, so neither grows without bound.
  def change do
    create table(:error_reports) do
      add :fingerprint, :string, null: false
      add :kind, :string, null: false
      add :message, :text, null: false
      add :location, :string
      add :stacktrace, :text, null: false, default: ""
      add :count, :integer, null: false, default: 1
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
    end

    create unique_index(:error_reports, [:fingerprint])
    create index(:error_reports, [:last_seen_at])

    create table(:offsite_backup_runs) do
      add :status, :string, null: false
      add :object_key, :string
      add :bytes, :integer
      add :error, :text
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime, null: false
    end

    create index(:offsite_backup_runs, [:finished_at])
  end
end
