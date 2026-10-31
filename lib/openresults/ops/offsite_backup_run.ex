defmodule OpenResults.Ops.OffsiteBackupRun do
  @moduledoc """
  One attempt to send a backup off the box: `"ok"` or `"failed"`, which
  object, how big, and - on failure - a reason with no secret in it. Written
  only by `OpenResults.Ops.OffsiteBackup`.
  """
  use Ecto.Schema

  schema "offsite_backup_runs" do
    field :status, :string
    field :object_key, :string
    field :bytes, :integer
    field :error, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
  end
end
