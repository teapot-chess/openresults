defmodule OpenResults.Ops.ErrorReport do
  @moduledoc """
  One distinct crash: what it was, where, how often, and when first and last.
  Written only by `OpenResults.Ops.ErrorReports`, which decides what is
  allowed into it - see there for what is kept out.
  """
  use Ecto.Schema

  schema "error_reports" do
    field :fingerprint, :string
    field :kind, :string
    field :message, :string
    field :location, :string
    field :stacktrace, :string, default: ""
    field :count, :integer, default: 1
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
  end
end
