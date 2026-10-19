defmodule OpenResults.RelayKeys do
  @moduledoc """
  Relay keys: the credential a hall relay carries instead of anything that
  could rewrite a tournament.

  A relay is a box in a playing hall. It can be lost, stolen, or left on a
  shelf in a venue's cupboard for a year. The operator token and an
  installation key both reach far more than "report what is on the boards";
  a relay key reaches exactly that.

  ## What one may do

  `POST /api/tournaments/:slug/live` for the one tournament it was made for.
  Nothing else: not another slug, not a publish, not history, not delete, not
  the admin panel. `OpenResultsWeb.Plugs.IngestAuth` refuses it with the
  anonymous 401 on every route that has not opted in with
  `private: %{relay_access: true}`, and `OpenResultsWeb.RelayAccess` holds the
  checks of the one that has. The tournament's own key is something the relay
  must not hold, so on that route a relay key stands in for it.

  ## The key

  `orrk_` and 43 characters: 32 random bytes, base64url. Shown once, on the
  page that created it; the server keeps the SHA-256, found through a unique
  index, for the reasons `OpenResults.Installations` gives. Revoking sets a
  timestamp rather than deleting, so the list can say what was revoked and
  when, and a revoked key is told so rather than treated as a stranger.

  Creating and revoking are logged as `relay_key_create` /
  `relay_key_revoke` with the key's id and label. The secret never reaches
  the log.

  ## Two makers

  `origin` says who made a key:

    * `"publisher"` - the tournament's own publisher, over
      `POST /api/tournaments/:slug/relay-keys`
      (`OpenResultsWeb.RelayKeyController`), with the credentials a publish
      takes. The normal way: the arbiter's program asks, hands the key to the
      box, and nobody copies anything.
    * `"admin"` - the panel, for a box that has no such program behind it.

  A publisher's key is **rotated by label**: asking again under the same
  label revokes the one it made before and returns a new one. The server
  keeps a fingerprint and cannot return the same key twice, so "ask again"
  can only mean "the old one is lost"; revoking it is what keeps a retry
  after a lost reply from piling keys up. An admin's key is never touched by
  that, whatever its label.

  ## When a publisher loses its keys

  A takedown deletes every key of the tournament; a transfer to another
  installation revokes them; revoking an installation revokes the keys of
  all its tournaments. Hiding a tournament revokes nothing and needs not to:
  the live endpoint refuses a hidden tournament whatever is presented, and
  unhiding it should not cost the hall a new key.
  """

  import Ecto.Query, warn: false

  alias OpenResults.RelayKeys.RelayKey
  alias OpenResults.Repo

  @prefix "orrk_"

  # A tournament has a handful of boxes. The cap is a leash on a script that
  # forgot to stop, not a feature.
  @max_active 10

  # "Last used" is for a person, and a relay posts every few seconds.
  @touch_every_seconds 60

  @doc "The prefix every relay key carries."
  def prefix, do: @prefix

  @doc "How many unrevoked keys one tournament may hold."
  def max_active, do: @max_active

  @doc "Does this bearer token look like a relay key at all?"
  @spec key?(term()) :: boolean()
  def key?(@prefix <> _rest), do: true
  def key?(_other), do: false

  @doc false
  # Inside the caller's transaction (`OpenResults.Moderation`), which writes
  # the log row beside it. Returns the key - the only time it exists outside
  # the relay.
  @spec create(String.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, %{relay_key: RelayKey.t(), key: String.t()}} | {:error, :too_many}
  def create(slug, label, created_by, origin \\ "admin")
      when is_binary(slug) and origin in ["admin", "publisher"] do
    if active_count(slug) >= @max_active do
      {:error, :too_many}
    else
      key = @prefix <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

      relay_key =
        Repo.insert!(%RelayKey{
          tournament_slug: slug,
          key_hash: hash(key),
          label: label,
          hint: String.slice(key, -4, 4),
          created_by: created_by,
          origin: origin
        })

      {:ok, %{relay_key: relay_key, key: key}}
    end
  end

  @doc false
  @spec revoke(String.t(), term(), String.t(), DateTime.t()) ::
          {:ok, RelayKey.t()} | {:error, :not_found | :already_revoked}
  def revoke(slug, id, revoked_by, now \\ DateTime.utc_now()) do
    case get(slug, id) do
      nil ->
        {:error, :not_found}

      %RelayKey{revoked_at: %DateTime{}} ->
        {:error, :already_revoked}

      %RelayKey{} = relay_key ->
        {:ok,
         relay_key
         |> Ecto.Changeset.change(revoked_at: now, revoked_by: revoked_by)
         |> Repo.update!()}
    end
  end

  @doc false
  # The publisher's live keys of a tournament - under one label, or all of
  # them for `nil` - revoked. Inside the caller's transaction, like `create/4`.
  # Returns the keys as they were, for the log.
  @spec revoke_publisher_keys(String.t(), String.t() | nil, String.t(), DateTime.t()) ::
          [RelayKey.t()]
  def revoke_publisher_keys(slug, label, revoked_by, now \\ DateTime.utc_now())
      when is_binary(slug) do
    query =
      from k in RelayKey,
        where: k.tournament_slug == ^slug and k.origin == "publisher" and is_nil(k.revoked_at)

    query = if is_binary(label), do: where(query, [k], k.label == ^label), else: query
    keys = Repo.all(query)

    if keys != [] do
      ids = Enum.map(keys, & &1.id)

      Repo.update_all(from(k in RelayKey, where: k.id in ^ids),
        set: [revoked_at: now, revoked_by: revoked_by]
      )
    end

    keys
  end

  @doc """
  Revokes every live key of every tournament of an installation - what
  revoking the installation does. A publisher that may no longer publish
  does not keep a box that may.
  """
  @spec revoke_all_for_installation(String.t(), String.t(), DateTime.t()) :: non_neg_integer()
  def revoke_all_for_installation(installation_id, revoked_by, now \\ DateTime.utc_now()) do
    slugs =
      from t in OpenResults.Tournaments.Tournament,
        where: t.installation_id == ^installation_id,
        select: t.slug

    {count, _} =
      Repo.update_all(
        from(k in RelayKey,
          where: k.tournament_slug in subquery(slugs) and is_nil(k.revoked_at)
        ),
        set: [revoked_at: now, revoked_by: revoked_by]
      )

    count
  end

  @doc "One key of a tournament, or `nil`. The slug is part of the lookup on purpose."
  @spec get(String.t(), term()) :: RelayKey.t() | nil
  def get(slug, id) when is_binary(slug) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(RelayKey, id: id, tournament_slug: slug)
      _not_an_id -> nil
    end
  end

  @doc "A tournament's keys, newest first, revoked ones included."
  @spec list(String.t()) :: [RelayKey.t()]
  def list(slug) when is_binary(slug) do
    Repo.all(
      from k in RelayKey,
        where: k.tournament_slug == ^slug,
        order_by: [desc: k.inserted_at, desc: k.id]
    )
  end

  @doc "How many unrevoked keys a tournament holds."
  @spec active_count(String.t()) :: non_neg_integer()
  def active_count(slug) do
    Repo.aggregate(
      from(k in RelayKey, where: k.tournament_slug == ^slug and is_nil(k.revoked_at)),
      :count
    )
  end

  @doc """
  The key a presented bearer token belongs to, revoked or not. `:error` for
  anything this server never issued.
  """
  @spec authenticate(term()) :: {:ok, RelayKey.t()} | :error
  def authenticate(@prefix <> _rest = presented) do
    case Repo.get_by(RelayKey, key_hash: hash(presented)) do
      nil -> :error
      relay_key -> {:ok, relay_key}
    end
  end

  def authenticate(_not_a_relay_key), do: :error

  @doc "Records a use, at most once a minute."
  @spec touch(RelayKey.t(), DateTime.t()) :: :ok
  def touch(%RelayKey{} = relay_key, now \\ DateTime.utc_now()) do
    stale? =
      is_nil(relay_key.last_used_at) or
        DateTime.diff(now, relay_key.last_used_at, :second) >= @touch_every_seconds

    if stale? do
      from(k in RelayKey, where: k.id == ^relay_key.id)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  @doc """
  Revokes every live key of a tournament - what a transfer to another
  installation does. The box in the hall belonged to the old owner; handing
  the new one a tournament that a stranger's Raspberry Pi can still post
  into would be an odd welcome present.
  """
  @spec revoke_all_for(String.t(), String.t(), DateTime.t()) :: [RelayKey.t()]
  def revoke_all_for(slug, revoked_by, now \\ DateTime.utc_now()) do
    keys =
      Repo.all(from k in RelayKey, where: k.tournament_slug == ^slug and is_nil(k.revoked_at))

    if keys != [] do
      ids = Enum.map(keys, & &1.id)

      Repo.update_all(from(k in RelayKey, where: k.id in ^ids),
        set: [revoked_at: now, revoked_by: revoked_by]
      )
    end

    keys
  end

  @doc false
  # For `OpenResults.ModerationJournal`: the keys among `fingerprints` (their
  # stored SHA-256) that a restored database still holds unrevoked, revoked
  # again. Returns how many. Revoked is final, so this never asks whether it
  # should.
  @spec revoke_fingerprints([String.t()], String.t(), DateTime.t()) :: non_neg_integer()
  def revoke_fingerprints(fingerprints, revoked_by, now \\ DateTime.utc_now())

  def revoke_fingerprints([], _revoked_by, _now), do: 0

  def revoke_fingerprints(fingerprints, revoked_by, now) when is_list(fingerprints) do
    {count, _} =
      Repo.update_all(
        from(k in RelayKey, where: k.key_hash in ^fingerprints and is_nil(k.revoked_at)),
        set: [revoked_at: now, revoked_by: revoked_by]
      )

    count
  end

  @doc "Deletes every key of a tournament - a takedown leaves no credential behind."
  @spec delete_all_for(String.t()) :: non_neg_integer()
  def delete_all_for(slug) do
    {count, _} = Repo.delete_all(from k in RelayKey, where: k.tournament_slug == ^slug)
    count
  end

  defp hash(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
end
