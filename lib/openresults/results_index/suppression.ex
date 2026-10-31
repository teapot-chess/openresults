defmodule OpenResults.ResultsIndex.Suppression do
  @moduledoc """
  A FIDE id whose cross-tournament player page the operator took down at the
  player's request (the GDPR right to object, answered without a fight). The
  page is gone and the id is out of player search and the sitemap; the
  tournaments themselves, and the name on them, are untouched - those are the
  organiser's publication. Kept until the player withdraws the request.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:fide_id, :integer, autogenerate: false}
  schema "player_suppressions" do
    field :scope, :string, default: "history"
    field :note, :string
    field :created_by, :string
    field :inserted_at, :utc_datetime_usec
  end
end
