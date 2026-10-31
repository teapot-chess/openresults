defmodule OpenResults.ResultsIndex.Entry do
  @moduledoc """
  One tournament in the results hub's index - a copy of fields its newest
  snapshot carries, after the display rules. See `OpenResults.ResultsIndex`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "tournament_index" do
    field :slug, :string
    field :snapshot_id, :integer
    field :index_version, :integer
    field :name, :string
    field :city, :string
    field :federation, :string
    field :start_date, :string
    field :end_date, :string
    field :dates_shown, :boolean, default: true
    field :rounds_count, :integer, default: 0
    field :rounds_published, :integer, default: 0
    field :players_count, :integer, default: 0
    field :system, :string
    field :team, :boolean, default: false
    field :fide_rated, :boolean, default: false
    field :arbiter_listed, :boolean, default: true
    field :complete, :boolean, default: false
    field :not_begun, :boolean, default: false
    field :event_id, :string
    field :last_published_at, :utc_datetime_usec

    # Joined from `tournaments` at query time, never stored here: moderation
    # status changes without a publish, and a copy would be one more thing
    # to keep in step.
    field :status, :string, virtual: true
  end
end
