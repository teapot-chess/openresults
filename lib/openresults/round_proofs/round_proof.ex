defmodule OpenResults.RoundProofs.RoundProof do
  @moduledoc """
  One round's pairing proof, as uploaded. See `OpenResults.RoundProofs`.

  `gzip` is the file byte for byte as it arrived and as it is served;
  `sha256` is the lowercase hex digest of exactly those bytes and `bytes`
  their count. Large (a few hundred kilobytes is ordinary), so no query
  that lists proofs selects it.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "round_proofs" do
    field :tournament_slug, :string
    field :round, :integer
    field :sha256, :string
    field :bytes, :integer
    field :gzip, :binary, redact: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
