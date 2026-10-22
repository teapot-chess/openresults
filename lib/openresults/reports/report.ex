defmodule OpenResults.Reports.Report do
  @moduledoc """
  One report about a tournament page, sent from its public report form. See
  `OpenResults.Reports`.

  The validation messages are looked up in the `errors` catalogue by
  `OpenResultsWeb.CoreComponents.translate_error/1`, like the entry form's -
  so a message changed here has to be changed in `errors.pot` and all three
  catalogues too.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @reasons ~w(wrong_or_fake_results personal_data spam_or_offensive other)
  @max_details 2000

  schema "reports" do
    field :tournament_slug, :string
    field :reason, :string
    field :details, :string
    field :contact_email, :string
    field :client_address, :string
    field :reference, :string
    field :status, :string, default: "open"
    field :resolution, :string
    field :resolved_by, :string
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The reasons a report may give, as stored."
  def reasons, do: @reasons

  @doc "The longest `details` may be, in characters."
  def max_details, do: @max_details

  @doc """
  What the public form may set: `reason`, `details`, `contact_email`. Nothing
  else - the slug, the address and the status are the server's.
  """
  def submission_changeset(report \\ %__MODULE__{}, attrs) do
    report
    |> cast(attrs, [:reason, :details, :contact_email])
    |> update_change(:details, &trim_to_nil/1)
    |> update_change(:contact_email, &trim_to_nil/1)
    |> validate_required([:reason], message: "choose what is wrong with this page")
    |> validate_inclusion(:reason, @reasons, message: "choose what is wrong with this page")
    |> validate_length(:details,
      max: @max_details,
      message: "please keep the details to 2000 characters"
    )
    |> validate_length(:contact_email,
      max: 254,
      message: "that is too long to be an email address"
    )
    |> validate_format(:contact_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "that does not look like an email address - check for a missing @ or a typo"
    )
  end

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(other), do: other
end
