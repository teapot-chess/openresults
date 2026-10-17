defmodule OpenResults.Stats.TrafficDay do
  @moduledoc "One day's totals: who read the site and how. See `OpenResults.Stats.Viewers`."

  use Ecto.Schema

  schema "traffic_days" do
    field :day, :date
    field :unique_viewers, :integer, default: 0
    field :page_views, :integer, default: 0
    field :bot_hits, :integer, default: 0
    field :refreshes, :integer, default: 0
  end
end
