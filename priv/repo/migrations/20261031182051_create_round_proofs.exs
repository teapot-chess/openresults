defmodule OpenResults.Repo.Migrations.CreateRoundProofs do
  use Ecto.Migration

  @moduledoc """
  A round's pairing proof, as its publisher uploaded it - see
  `OpenResults.RoundProofs`.

  The snapshot names a proof by digest (`rounds[].proof.sha256`); the bytes
  live here, once, rather than inside every stored version of the snapshot.
  `gzip` is the file exactly as received and served; `sha256` is the digest
  of those bytes, checked on the way in. No personal data: a proof speaks in
  starting ranks.
  """

  def change do
    create table(:round_proofs) do
      add :tournament_slug, :string, null: false
      add :round, :integer, null: false
      add :sha256, :string, null: false
      add :bytes, :integer, null: false
      add :gzip, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:round_proofs, [:tournament_slug, :round, :sha256])
  end
end
