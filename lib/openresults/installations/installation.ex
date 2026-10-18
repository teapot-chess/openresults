defmodule OpenResults.Installations.Installation do
  @moduledoc """
  One OpenPairings installation holding an installation key. See
  `OpenResults.Installations`.

  `key_hash` is a digest; the key itself is never stored, logged or returned
  after the registration response that created it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(active suspended revoked)

  @primary_key {:id, :string, autogenerate: false}
  schema "installations" do
    field :key_hash, :string, redact: true
    field :client, :string
    field :client_version, :string
    field :status, :string, default: "active"
    field :created_from, :string
    field :last_seen_at, :utc_datetime_usec
    field :last_seen_from, :string

    # A trusted installation's new tournaments start `listed` rather than
    # `pending`. Cleared by a revoke. See `OpenResults.Moderation.trust/3`.
    field :trusted, :boolean, default: false

    # Its own limits; `nil` is the server's. See
    # `OpenResults.PublicPublishing.installation_limits/1`.
    field :max_tournaments, :integer
    field :max_snapshot_bytes, :integer
    field :publishes_per_minute, :integer
    field :max_versions, :integer

    # The operator's own name for it; the admin panel is the only place it is
    # shown, and only `label_changeset/2` writes it.
    field :label, :string

    # Filled by `OpenResults.Installations.list/1`; never stored.
    field :tournament_count, :integer, virtual: true

    has_many :tournaments, OpenResults.Tournaments.Tournament

    timestamps(type: :utc_datetime_usec)
  end

  @limits [:max_tournaments, :max_snapshot_bytes, :publishes_per_minute, :max_versions]

  @doc "The four limits an installation may carry its own value for."
  def limits, do: @limits

  @doc "The three statuses, as stored."
  def statuses, do: @statuses

  @label_max 80

  @doc "The longest label the panel stores."
  def label_max, do: @label_max

  @doc """
  The operator's label: trimmed, blank is `nil`, at most #{@label_max}
  characters. The only changeset that casts `:label`.
  """
  def label_changeset(installation, attrs) do
    installation
    |> cast(attrs, [:label])
    |> update_change(:label, fn
      label when is_binary(label) ->
        case String.trim(label) do
          "" -> nil
          trimmed -> trimmed
        end

      other ->
        other
    end)
    |> validate_length(:label, max: @label_max)
  end

  @doc false
  def create_changeset(installation, attrs) do
    installation
    |> cast(attrs, [:id, :key_hash, :client, :client_version, :created_from])
    |> validate_required([:id, :key_hash])
    |> put_change(:status, "active")
    |> unique_constraint(:key_hash)
  end
end
