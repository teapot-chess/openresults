defmodule OpenResults.TournamentGroups.EventClaim do
  @moduledoc """
  Who claimed an event id first - see `OpenResults.TournamentGroups`. One row
  per id, written by the first publish naming it; only an operator's transfer
  moves it.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:event_id, :string, autogenerate: false}
  schema "event_claims" do
    # `nil` is the operator token's publisher.
    field :installation_id, :string
    field :claimed_at, :utc_datetime_usec
  end
end
