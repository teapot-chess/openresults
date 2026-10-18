defmodule OpenResults.Installations do
  @moduledoc """
  Installation keys: the credential any OpenPairings copy can obtain for
  itself, scoped to the tournaments minted for it.

  ## The key

  `orik_` and 43 characters: 32 random bytes, base64url without padding. The
  prefix is for people and tools rather than for this code - it makes the key
  recognisable in a log line or to a secret scanner, and it means nobody can
  paste one where the operator token goes and have it mistaken for that.
  `OpenResultsWeb.Plugs.IngestAuth` does use it, but only to skip a database
  lookup for a bearer token that could never be one.

  The key is shown once, in the registration response, and the server keeps
  its SHA-256. Not a password hash, for the reason `tournament_keys` gives: the
  secret is 256 random bits nobody chose, so there is no small space for a
  work factor to slow a search of.

  ## The lookup

  By digest, through a unique index - the request presents a key, its digest
  is computed, and the row is found or not. The digest of a random 256-bit
  value is itself effectively random, so the index's timing says nothing about
  the key; there is no stored secret being compared byte by byte against a
  guess, which is the thing `Plug.Crypto.secure_compare/2` exists to protect.

  ## Addresses

  An installation remembers the address it registered from and the one it was
  last seen from, because an address block is only safe to place when the
  operator can see how many installations it would reach. Both are personal
  data about whoever sat at that laptop, so `OpenResults.Retention` nulls each
  of them thirty days after its own timestamp.
  """

  import Ecto.Query, warn: false

  alias OpenResults.AddressBlocks.CIDR
  alias OpenResults.Installations.Installation
  alias OpenResults.Repo
  alias OpenResults.Tournaments.Tournament

  @prefix "orik_"

  # "Last seen" is for a person reading the admin panel, not an audit trail,
  # so it is written at most this often per installation. A publish every two
  # seconds from a busy hall would otherwise be a second write per publish on a
  # database with one writer.
  @touch_every_seconds 60

  @doc "The prefix every installation key carries."
  def prefix, do: @prefix

  @doc """
  Creates an installation and returns its key - the only time the key exists
  outside the caller's machine.

  `attrs` is what the client sent (`client`, `client_version`), taken only
  when it is text and truncated, because an unauthenticated caller wrote it.
  """
  @spec register(map(), :inet.ip_address() | nil) ::
          {:ok, %{installation: Installation.t(), key: String.t()}}
          | {:error, Ecto.Changeset.t()}
  def register(attrs, address) when is_map(attrs) do
    key = @prefix <> random(32)

    %Installation{}
    |> Installation.create_changeset(%{
      id: new_id(),
      key_hash: hash(key),
      client: text(attrs, "client", 100),
      client_version: text(attrs, "client_version", 50),
      created_from: CIDR.address_to_string(address)
    })
    |> Repo.insert()
    |> case do
      {:ok, installation} -> {:ok, %{installation: installation, key: key}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The installation a presented bearer token belongs to, whatever its status.

  `:error` for anything that is not a key this server issued. The caller - the
  ingest plug - turns every `:error` into the same anonymous 401.
  """
  @spec authenticate(term()) :: {:ok, Installation.t()} | :error
  def authenticate(@prefix <> _rest = presented) do
    case Repo.get_by(Installation, key_hash: hash(presented)) do
      nil -> :error
      installation -> {:ok, installation}
    end
  end

  def authenticate(_not_an_installation_key), do: :error

  @doc "Does this bearer token look like an installation key at all?"
  @spec key?(term()) :: boolean()
  def key?(@prefix <> _rest), do: true
  def key?(_other), do: false

  @doc """
  Records that `installation` was just used from `address`. Written at most
  once a minute unless the address changed.
  """
  @spec touch(Installation.t(), :inet.ip_address() | nil, DateTime.t()) :: :ok
  def touch(%Installation{} = installation, address, now \\ DateTime.utc_now()) do
    seen_from = CIDR.address_to_string(address)

    stale? =
      is_nil(installation.last_seen_at) or installation.last_seen_from != seen_from or
        DateTime.diff(now, installation.last_seen_at, :second) >= @touch_every_seconds

    if stale? do
      from(i in Installation, where: i.id == ^installation.id)
      |> Repo.update_all(set: [last_seen_at: now, last_seen_from: seen_from])
    end

    :ok
  end

  @doc "One installation by id, with its tournaments, or `nil`."
  @spec get(term()) :: Installation.t() | nil
  def get(id) when is_binary(id) do
    Installation
    |> Repo.get(id)
    |> Repo.preload(tournaments: from(t in Tournament, order_by: [desc: t.inserted_at]))
  end

  def get(_not_an_id), do: nil

  @doc """
  Installations, newest first. Filters: `status` (`active` | `suspended` |
  `revoked`), `search` (a substring of the id, label, client, client version or
  either address), `limit`, `offset`.

  Each carries `tournament_count`: its `pending` and `listed` tournaments,
  the number `tournament_limit` counts.
  """
  @spec list(map() | keyword()) :: [Installation.t()]
  def list(filters \\ %{}) do
    filters = Map.new(filters)

    counts =
      from t in Tournament,
        where: t.status in ["pending", "listed"] and not is_nil(t.installation_id),
        group_by: t.installation_id,
        select: %{installation_id: t.installation_id, count: count(t.id)}

    from(i in Installation,
      left_join: c in subquery(counts),
      on: c.installation_id == i.id,
      order_by: [desc: i.inserted_at, asc: i.id],
      select_merge: %{tournament_count: coalesce(c.count, 0)}
    )
    |> filter_status(filters)
    |> filter_search(filters)
    |> OpenResults.QueryFilters.paginate(filters)
    |> Repo.all()
  end

  defp filter_status(query, %{status: status}) when not is_nil(status) do
    where(query, [i], i.status == ^to_string(status))
  end

  defp filter_status(query, _filters), do: query

  defp filter_search(query, %{search: search}) when is_binary(search) and search != "" do
    pattern = OpenResults.QueryFilters.like_pattern(search)

    where(
      query,
      [i],
      fragment("? LIKE ? ESCAPE '\\'", i.id, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", i.label, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", i.client, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", i.client_version, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", i.created_from, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", i.last_seen_from, ^pattern)
    )
  end

  defp filter_search(query, _filters), do: query

  @doc """
  Moves an installation from one of `from` to `to`. `{:error, :not_found}` or
  `{:error, :invalid_status}` when it cannot.
  """
  @spec transition(String.t(), [String.t()], String.t()) ::
          {:ok, Installation.t()} | {:error, :not_found | :invalid_status}
  def transition(id, from_statuses, to) when is_binary(id) do
    now = DateTime.utc_now()

    # Revoking ends trust with the key, whichever path revokes - the panel,
    # or the moderation journal's replay after a restore.
    changes =
      if to == "revoked",
        do: [status: to, trusted: false, updated_at: now],
        else: [status: to, updated_at: now]

    case from(i in Installation, where: i.id == ^id and i.status in ^from_statuses)
         |> Repo.update_all(set: changes) do
      {1, _} ->
        {:ok, get(id)}

      {0, _} ->
        if Repo.get(Installation, id), do: {:error, :invalid_status}, else: {:error, :not_found}
    end
  end

  def transition(_not_an_id, _from, _to), do: {:error, :not_found}

  @doc """
  Sets or clears `trusted`. `{:error, :invalid_status}` when it is already
  so, or - to trust - when the installation is revoked.
  """
  @spec set_trusted(String.t(), boolean()) ::
          {:ok, Installation.t()} | {:error, :not_found | :invalid_status}
  def set_trusted(id, trusted) when is_binary(id) and is_boolean(trusted) do
    statuses = if trusted, do: ["active", "suspended"], else: Installation.statuses()

    case from(i in Installation,
           where: i.id == ^id and i.status in ^statuses and i.trusted != ^trusted
         )
         |> Repo.update_all(set: [trusted: trusted, updated_at: DateTime.utc_now()]) do
      {1, _} ->
        {:ok, get(id)}

      {0, _} ->
        if Repo.get(Installation, id), do: {:error, :invalid_status}, else: {:error, :not_found}
    end
  end

  def set_trusted(_not_an_id, _trusted), do: {:error, :not_found}

  @doc """
  Checks an installation's own limits as the panel's form sends them -
  string keys `max_tournaments`, `max_snapshot_bytes`, `publishes_per_minute`,
  `max_versions`, each a whole number or blank for "the server's value" -
  with the ranges of the server-wide settings they override
  (`OpenResults.ServerSettings.validate/2`). Stores nothing.
  """
  @spec limits_changeset(Installation.t(), map()) :: Ecto.Changeset.t()
  def limits_changeset(%Installation{} = installation, attrs) when is_map(attrs) do
    Enum.reduce(Installation.limits(), Ecto.Changeset.change(installation), fn field, cs ->
      name = Atom.to_string(field)
      raw = Map.get(attrs, name, Map.get(attrs, field))

      case raw do
        blank when blank in [nil, ""] ->
          Ecto.Changeset.put_change(cs, field, nil)

        raw ->
          raw = if is_binary(raw), do: String.trim(raw), else: raw

          if raw == "" do
            Ecto.Changeset.put_change(cs, field, nil)
          else
            global = OpenResults.PublicPublishing.global_for(field)

            case OpenResults.ServerSettings.validate(global, raw) do
              {:ok, value} ->
                Ecto.Changeset.put_change(cs, field, value)

              {:error, _sentence} ->
                spec = OpenResults.ServerSettings.spec(global)
                Ecto.Changeset.add_error(cs, field, range_message(spec), validation: :range)
            end
          end
      end
    end)
    |> Map.put(:action, :validate)
  end

  defp range_message(%{min: min, max: nil}), do: "is a whole number of at least #{min}"
  defp range_message(%{min: min, max: max}), do: "is a whole number from #{min} to #{max}"

  @doc false
  # Stores a valid limits changeset. For `OpenResults.Moderation`.
  def update_limits!(%Ecto.Changeset{valid?: true} = changeset) do
    changeset
    |> Map.put(:action, nil)
    |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now())
    |> Repo.update!()
  end

  @doc """
  The operator's label for an installation, as the panel's form sends it
  (string key `label`). Stores nothing.
  """
  @spec label_changeset(Installation.t(), map()) :: Ecto.Changeset.t()
  def label_changeset(%Installation{} = installation, attrs) when is_map(attrs) do
    installation
    |> Installation.label_changeset(attrs)
    |> Map.put(:action, :validate)
  end

  @doc false
  # Stores a valid label changeset. For `OpenResults.Moderation`.
  def update_label!(%Ecto.Changeset{valid?: true} = changeset) do
    changeset
    |> Map.put(:action, nil)
    |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now())
    |> Repo.update!()
  end

  @doc """
  The labels of the given installations, `%{id => label}`; those without one
  are left out. For the panel's lists.
  """
  @spec labels([String.t() | nil]) :: %{String.t() => String.t()}
  def labels(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(i in Installation, where: i.id in ^ids and not is_nil(i.label), select: {i.id, i.label})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  How many installations registered from, or were last seen from, an address
  inside `ip_or_cidr`. 0 for something that is not an address or range.
  """
  @spec seen_from(String.t()) :: non_neg_integer()
  def seen_from(ip_or_cidr) do
    case CIDR.parse(ip_or_cidr) do
      {:ok, cidr} ->
        from(i in Installation,
          where: not is_nil(i.created_from) or not is_nil(i.last_seen_from),
          select: {i.created_from, i.last_seen_from}
        )
        |> Repo.all()
        |> Enum.count(fn {created, seen} ->
          (created && CIDR.contains?(cidr, created)) || (seen && CIDR.contains?(cidr, seen))
        end)

      :error ->
        0
    end
  end

  @doc """
  Nulls every address older than `cutoff`, each against its own timestamp.
  Returns how many address fields were cleared.
  """
  @spec null_addresses_before(DateTime.t()) :: non_neg_integer()
  def null_addresses_before(%DateTime{} = cutoff) do
    {created, _} =
      from(i in Installation, where: not is_nil(i.created_from) and i.inserted_at < ^cutoff)
      |> Repo.update_all(set: [created_from: nil])

    {seen, _} =
      from(i in Installation,
        where: not is_nil(i.last_seen_from) and i.last_seen_at < ^cutoff
      )
      |> Repo.update_all(set: [last_seen_from: nil])

    created + seen
  end

  @doc "SHA-256 of a key, lowercase hex. Public so tests can check what is stored."
  @spec hash(String.t()) :: String.t()
  def hash(key) when is_binary(key),
    do: :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)

  # `in_` and ten characters: seven random bytes. The id is not a secret - it
  # appears in the admin panel and the action log - so it only has to be
  # unique, which the primary key enforces; 56 bits makes a retry theoretical.
  defp new_id, do: "in_" <> random(7)

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp text(attrs, key, max) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case value |> String.trim() |> String.slice(0, max) do
          "" -> nil
          trimmed -> trimmed
        end

      _absent_or_not_text ->
        nil
    end
  end
end
