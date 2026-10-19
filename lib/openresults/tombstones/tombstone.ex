defmodule OpenResults.Tombstones.Tombstone do
  @moduledoc """
  What is left of a tournament the operator deleted: its slug, who deleted
  it and when, and the installation that owned it. See `OpenResults.Tombstones`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:slug, :string, autogenerate: false}
  schema "tournament_tombstones" do
    field :installation_id, :string
    field :deleted_by, :string
    field :deleted_at, :utc_datetime_usec
  end
end
