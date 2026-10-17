defmodule OpenResults.Stats.TrafficTournamentDay do
  @moduledoc "One tournament's readers on one day. See `OpenResults.Stats.Viewers`."

  use Ecto.Schema

  schema "traffic_tournament_days" do
    field :day, :date
    field :slug, :string
    field :unique_viewers, :integer, default: 0
    field :page_views, :integer, default: 0
  end
end
