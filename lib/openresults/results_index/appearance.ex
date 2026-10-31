defmodule OpenResults.ResultsIndex.Appearance do
  @moduledoc """
  One player in one indexed tournament - `(slug, no)` - with what that
  tournament shows about them. A value the tournament withholds is `nil`
  here. See `OpenResults.ResultsIndex`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "player_appearances" do
    field :slug, :string
    field :no, :integer
    field :name, :string
    field :federation, :string
    field :title, :string
    field :rating, :integer
    field :club, :string
    field :fide_id, :integer
    field :rank, :integer
    field :points, :float
    field :ranked_total, :integer
    field :performance, :integer
    field :card_linkable, :boolean, default: true
    field :fide_name_mismatch, :boolean
    field :start_date, :string

    # Filled by queries that join the tournament, never stored.
    field :tournament_name, :string, virtual: true
    field :city, :string, virtual: true
    field :end_date, :string, virtual: true
    field :dates_shown, :boolean, virtual: true
  end
end
