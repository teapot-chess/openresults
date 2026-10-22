defmodule OpenResults.Reports do
  @moduledoc """
  What the public reports about a tournament page, for the operator to read.

  The one moderation input that needs no account: a player who finds invented
  results under their name, or their email address on a page, has to be able
  to say so from the page itself. A report changes nothing on its own - it
  sits in the admin panel's queue until somebody resolves it.

  Stored with the address it came from, so a flood of reports can be told
  from many people reporting one page, and that address is personal data, so
  `OpenResults.Retention` nulls it after thirty days.

  A takedown does not delete a tournament's reports. They are the record of
  why moderation acted, which is worth more after the page is gone than
  before.
  """

  import Ecto.Query, warn: false

  alias OpenResults.AddressBlocks.CIDR
  alias OpenResults.Repo
  alias OpenResults.Reports.Report

  @doc """
  Stores a report for `slug`. The caller has already checked the tournament is
  one the public can see.
  """
  @spec create(String.t(), map(), :inet.ip_address() | nil) ::
          {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create(slug, attrs, address) when is_binary(slug) and is_map(attrs) do
    changeset =
      attrs
      |> Report.submission_changeset()
      |> Ecto.Changeset.put_change(:tournament_slug, slug)
      |> Ecto.Changeset.put_change(:client_address, CIDR.address_to_string(address))
      |> Ecto.Changeset.put_change(:status, "open")

    insert_with_reference(changeset, 5)
  end

  # Forty random bits make a clash vanishingly rare, not impossible; the unique
  # index is the arbiter and a clash simply draws another number.
  defp insert_with_reference(changeset, attempts_left) do
    changeset
    |> Ecto.Changeset.put_change(:reference, new_reference())
    |> Ecto.Changeset.unique_constraint(:reference)
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{errors: errors} = failed} = error ->
        if attempts_left > 1 and Keyword.has_key?(errors, :reference),
          do:
            insert_with_reference(
              Ecto.Changeset.delete_change(failed, :reference),
              attempts_left - 1
            ),
          else: error

      other ->
        other
    end
  end

  @doc """
  A fresh reference: eight characters of base32 (`A-Z`, `2-7`), 40 random bits.
  Not a counter, so one number says nothing about the next, and a stranger
  walking the lookup page gets a rate limit long before a hit.
  """
  @spec new_reference() :: String.t()
  def new_reference, do: Base.encode32(:crypto.strong_rand_bytes(5), padding: false)

  @doc "The reference as shown to people: `ABCD-EFGH`."
  @spec format_reference(String.t() | nil) :: String.t() | nil
  def format_reference(<<a::binary-size(4), b::binary-size(4)>>), do: a <> "-" <> b
  def format_reference(other), do: other

  @doc """
  Finds a report by what the reporter typed: case, spaces and hyphens do not
  matter. `nil` for anything that is not a reference or matches no report.
  """
  @spec get_by_reference(term()) :: Report.t() | nil
  def get_by_reference(input) when is_binary(input) do
    normalised = input |> String.upcase() |> String.replace(~r/[\s-]/u, "")

    if normalised =~ ~r/\A[A-Z2-7]{8}\z/,
      do: Repo.get_by(Report, reference: normalised),
      else: nil
  end

  def get_by_reference(_other), do: nil

  @doc "One report by id, or `nil`."
  @spec get(term()) :: Report.t() | nil
  def get(id) do
    case OpenResults.AddressBlocks.integer_id(id) do
      nil -> nil
      int -> Repo.get(Report, int)
    end
  end

  @doc """
  Reports, newest first. Filters: `status` (`open` | `resolved`), `slug`,
  `limit`, `offset`.
  """
  @spec list(map() | keyword()) :: [Report.t()]
  def list(filters \\ %{}) do
    filters = Map.new(filters)

    from(r in Report, order_by: [desc: r.inserted_at, desc: r.id])
    |> filter(:status, filters)
    |> filter(:slug, filters)
    |> OpenResults.QueryFilters.paginate(filters)
    |> Repo.all()
  end

  defp filter(query, :status, %{status: status}) when not is_nil(status),
    do: where(query, [r], r.status == ^to_string(status))

  defp filter(query, :slug, %{slug: slug}) when is_binary(slug),
    do: where(query, [r], r.tournament_slug == ^slug)

  defp filter(query, _key, _filters), do: query

  @doc """
  Marks a report resolved. `{:error, :already_resolved}` for one that is.
  """
  @spec resolve(term(), String.t(), String.t()) ::
          {:ok, Report.t()} | {:error, :not_found | :already_resolved}
  def resolve(id, resolution, resolved_by) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %Report{status: "resolved"} ->
        {:error, :already_resolved}

      %Report{} = report ->
        report
        |> Ecto.Changeset.change(
          status: "resolved",
          resolution: resolution,
          resolved_by: resolved_by,
          resolved_at: DateTime.utc_now()
        )
        |> Repo.update()
    end
  end

  @doc "Open reports per slug, as a map. For the moderation listing."
  @spec open_counts() :: %{String.t() => pos_integer()}
  def open_counts do
    from(r in Report,
      where: r.status == "open",
      group_by: r.tournament_slug,
      select: {r.tournament_slug, count(r.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Nulls the address of every report older than `cutoff`, returning how many."
  @spec null_addresses_before(DateTime.t()) :: non_neg_integer()
  def null_addresses_before(%DateTime{} = cutoff) do
    {count, _} =
      from(r in Report, where: not is_nil(r.client_address) and r.inserted_at < ^cutoff)
      |> Repo.update_all(set: [client_address: nil])

    count
  end

  @doc """
  Nulls the contact email of every report RESOLVED before `cutoff`, returning
  how many changed. An open report keeps its contact however old it is: the
  operator may still need to answer it.
  """
  @spec null_contact_emails_before(DateTime.t()) :: non_neg_integer()
  def null_contact_emails_before(%DateTime{} = cutoff) do
    {count, _} =
      from(r in Report,
        where: not is_nil(r.contact_email) and r.status == "resolved" and r.resolved_at < ^cutoff
      )
      |> Repo.update_all(set: [contact_email: nil])

    count
  end
end
