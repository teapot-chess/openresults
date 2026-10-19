defmodule OpenResults.TournamentKeys do
  @moduledoc """
  Which machine is allowed to touch which tournament.

  There are two questions on the write path and they are not the same
  question:

  | | asked by | answers |
  |---|---|---|
  | the ingest token | `OpenResultsWeb.Plugs.IngestAuth` | may this machine talk to this server at all |
  | the tournament key | this module | may it touch THIS tournament |

  Before this existed there was only the first one, which meant a single
  shared secret let anything holding it overwrite any tournament on the
  server, including one it had never published - and, once the delete route
  arrived, remove one. Publishing rights over `gent-spring-open-2026` and
  publishing rights over somebody else's event are different grants, so they
  are now different secrets.

  ## Trust on first use

  The arbiter's machine generates a random key per tournament and sends it
  with the first publish. That publish CLAIMS the slug: the digest is stored
  and every later publish, and any delete, must present the same key.

  This is TOFU, with everything TOFU implies - the server takes the first
  claimant's word for it, because at that moment there is nothing else to
  check it against. Two reasons that is the right trade here rather than a
  hole:

  1. **The first question is already answered.** With the operator token,
     the claimant is not the public; it is a machine an operator deliberately
     configured. The exposure this guards is ACCIDENT - two arbiters' laptops
     picking the same obvious slug for two different events, one silently
     flattening the other - rather than attack.
  2. **The alternative is an account system.** Verifying a claim needs an
     identity to verify it against, and this app deliberately has no accounts,
     no sessions and no cookies. Adding them so that a slug could be
     pre-registered would cost the whole read-side design to close a gap the
     ingest token already narrows to configured machines.

  ## Installation keys, where the claimant IS the public

  Public publishing (`docs/public-publishing.md`) broke reason 1. An
  installation key is handed to any OpenPairings copy that asks, so a publish
  carrying one comes from whoever that is - and TOFU against the public, on
  slugs the public chooses, is squatting: register a key, publish to
  `gent-open-2026` before its arbiter does, and the claim is yours.

  What makes TOFU safe again is not in this module - it is that an
  installation never gets to choose, or reach, a slug that could already mean
  something:

    * **The server mints the slug.** `POST /api/tournaments` picks nine random
      bytes and binds the slug to the installation that asked
      (`OpenResults.Tournaments.mint/2`). No readable name can be requested.
    * **An installation key touches only its own slugs.** Every route checks
      the binding before this module is asked anything, and the publish path
      checks it again inside the transaction that stores the snapshot. An
      operator-published slug, a legacy slug with no key, another
      installation's slug and a slug never minted are all `not_owner`.

  So the only slug an installation's first keyed publish can claim is one
  created for that installation moments earlier, and there is nobody else it
  could be taking it from. TOFU is back to guarding the case it was written
  for: the owner's own machine, and a key that must not change under it.

  Break-glass is never available to an installation credential - see below.

  ## A publish carrying no key

  Allowed, and the slug simply stays unclaimed.

  This is the additive-only rule from `docs/snapshot-schema.md` applied to
  authentication instead of to fields. Snapshots already exist in
  production-shaped databases from before any of this, so slugs exist that
  have published for a season and have no key; and OpenPairings laptops in the
  field will not learn to send one until their arbiters update, which they do
  when they feel like it. Refusing a keyless publish would take those
  tournaments off the air mid-event, and the arbiter would find out in the
  hall.

  So there is no backfill and no admin step. **A legacy slug is adopted by the
  first publish that carries a key** - the same TOFU path a brand-new slug
  takes, which is why there is only one path. Until that happens the slug
  behaves exactly as it did before this module existed.

  The protection is not weakened by that, because claiming is one-way: once a
  slug HAS a key, a keyless publish to it is refused (`:key_required`). An old
  client cannot take a claimed tournament over by simply omitting the header,
  which would otherwise make the whole thing decorative. The cost is that an
  arbiter who claims a slug and then DOWNGRADES to a client that cannot send
  keys is locked out - deliberately, and that is what break-glass is for.

  ## Break-glass

  A key lives on one laptop. Laptops die, and a tournament whose key died with
  it would be unpublishable and undeletable forever, which is a worse failure
  than the one this module prevents.

  So a request may present the SERVER-WIDE INGEST TOKEN in the tournament-key
  position and the key check is overridden. That is a deliberate act - an
  operator has to go and paste the server's master secret where a per-event
  secret belongs - so it cannot happen by accident, and it grants nothing the
  token holder could not already do by editing the database by hand. Every use
  is logged at warning level with the slug and the action, and written to the
  moderation action log with `break-glass` as the actor
  (`OpenResults.Moderation`), where the admin panel shows it.

  Only when the request authenticated with the operator token. A request that
  authenticated with an installation key passes `break_glass: false`, and then
  the operator token in the key header is just a wrong key. Otherwise the
  master secret would be one header away from a credential the public holds -
  harmless while nobody has both, and exactly the kind of property that stops
  holding the day somebody does.

  Break-glass never claims a slug. Storing a hash of the server-wide token as
  a tournament key would quietly promote the master secret into a per-event
  one, and then rotating the ingest token would lock out every tournament
  claimed that way.
  """

  import Ecto.Query, warn: false

  require Logger

  alias OpenResults.Repo
  alias OpenResults.TournamentKeys.TournamentKey

  @type error :: :key_required | :key_mismatch
  @type outcome :: :ok | {:error, error()}

  @typedoc """
  What authorised a delete: the tournament's own key, nothing beyond the
  caller's credential (the slug was never claimed), or break-glass - which
  this module has already logged, so a caller must never log it again.
  """
  @type form :: :tournament_key | :no_key | :break_glass

  @doc """
  May this request publish to `slug`?

  Writes, on the one path that is allowed to: an unclaimed slug presented with
  a key is claimed here. Everything else is a read.

  ## Options

    * `:break_glass` - whether the operator token in the key position
      overrides the key. Default `true`; `false` for a request authenticated
      with an installation key. The same option on all three functions.
  """
  @spec authorize_publish(String.t(), String.t() | nil, keyword()) :: outcome()
  def authorize_publish(slug, presented, opts \\ []),
    do: slug |> authorize(presented, :publish, opts) |> plain()

  @doc """
  May this request delete `slug`?

  Identical to `authorize_publish/2` except that it never claims. Claiming a
  slug on the way to destroying it would leave a key row pointing at nothing,
  and `OpenResults.Takedown.purge/1` would only have to delete it again.

  An UNCLAIMED slug can be deleted by anyone holding the ingest token, which
  is the same authority that could already overwrite it into an empty
  tournament. Refusing here instead would mean a legacy tournament - one
  published before keys existed, holding the player names and email addresses
  this whole feature is about - could never be taken down at all, which is the
  hole rather than the fix.

  Unlike its two siblings it says HOW the delete was authorised, as
  `{:ok, form}`: `:tournament_key` when the real per-tournament key matched,
  `:no_key` when the slug was never claimed and nothing but the caller's own
  credential authorised it, and `:break_glass` when the operator token stood
  in for the key - already written to the moderation action log here, so the
  caller must not log it a second time.
  """
  @spec authorize_delete(String.t(), String.t() | nil, keyword()) ::
          {:ok, form()} | {:error, error()}
  def authorize_delete(slug, presented, opts \\ []),
    do: authorize(slug, presented, :delete, opts)

  @doc """
  May this request READ `slug`'s registration queue?

  The only route that returns an email address, so it is the one read worth
  gating twice. Before this existed, any holder of the server-wide ingest
  token could pull the entries for a tournament it had never published -
  which is exactly the authority a per-tournament key exists to divide.

  Same rule as deletion, and unclaimed behaves the same way for the same
  reason: a tournament published before keys existed must stay reachable by
  the arbiter running it, and that arbiter has nothing to present. Refusing
  would strand the queue rather than protect it.
  """
  @spec authorize_read(String.t(), String.t() | nil, keyword()) :: outcome()
  def authorize_read(slug, presented, opts \\ []),
    do: slug |> authorize(presented, :read, opts) |> plain()

  @doc """
  Is `slug` claimed with exactly `presented`? A read, for
  `GET /api/tournaments/:slug/claim`: never claims, never logs, and the
  operator token in the key position is only a key that does not match -
  this answers what a file's key proves, and break-glass proves nothing about
  a file.
  """
  @spec verify(String.t(), String.t() | nil) ::
          :tournament_key | :unclaimed | {:error, error()}
  def verify(slug, presented) do
    case {fetch(slug), normalize(presented)} do
      {nil, _any} ->
        :unclaimed

      {%TournamentKey{}, nil} ->
        {:error, :key_required}

      {%TournamentKey{key_hash: stored}, key} ->
        if Plug.Crypto.secure_compare(stored, hash(key)),
          do: :tournament_key,
          else: {:error, :key_mismatch}
    end
  end

  @doc """
  Has `slug` been claimed?

  Diagnostic. It says nothing about whether the tournament has published.
  """
  @spec claimed?(String.t()) :: boolean()
  def claimed?(slug), do: not is_nil(fetch(slug))

  @doc """
  Is `presented` - a value from the tournament-key header - the operator
  token? What break-glass is. For `OpenResults.Tombstones`, which lets
  exactly that through a deleted tournament and nothing else.
  """
  @spec break_glass_key?(term()) :: boolean()
  def break_glass_key?(presented) do
    case normalize(presented) do
      nil -> false
      key -> master_token?(key)
    end
  end

  @doc """
  Forgets the claim on `slug`, returning how many rows went.

  Part of a takedown and only that. There is no other way to release a key,
  because the point of a claim is that it outlives the machine's mood.
  """
  @spec release(String.t()) :: non_neg_integer()
  def release(slug) do
    {count, _returned} =
      from(k in TournamentKey, where: k.tournament_slug == ^slug) |> Repo.delete_all()

    count
  end

  @doc """
  The digest stored for a key: SHA-256, lowercase hex.

  Public so a test can assert the plaintext key is nowhere in the row. Nothing
  on the request path should need it.
  """
  @spec hash(String.t()) :: String.t()
  def hash(key) when is_binary(key) do
    :sha256 |> :crypto.hash(key) |> Base.encode16(case: :lower)
  end

  @doc """
  Normalises a presented key: `nil` for anything that is not a usable secret.

  An empty or whitespace-only header is treated as ABSENT rather than as a
  key, and that is not politeness. `hash("")` is a publicly known constant, so
  claiming a slug with a blank key would hand it to anyone who could send an
  empty header - a claimed slug that anybody can re-claim is worse than an
  unclaimed one, because it looks protected.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(key) when is_binary(key) do
    case String.trim(key) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize(_absent_or_not_a_string), do: nil

  # Publish and read keep their bare `:ok`; only delete reports the form.
  defp plain({:ok, _form}), do: :ok
  defp plain(error), do: error

  defp authorize(slug, presented, action, opts) do
    glass? = Keyword.get(opts, :break_glass, true)

    case {fetch(slug), normalize(presented)} do
      # Unclaimed and nothing presented: a legacy slug, or a client too old to
      # know about keys. Publishes as it always did, and stays unclaimed.
      {nil, nil} ->
        {:ok, :no_key}

      {nil, key} ->
        unclaimed(slug, key, action, glass?)

      # Claimed, and the request did not even try. Refused: this is the case
      # that stops a claimed tournament being taken over by omission.
      {%TournamentKey{}, nil} ->
        {:error, :key_required}

      {%TournamentKey{} = claim, key} ->
        compare(slug, claim, key, action, glass?)
    end
  end

  defp unclaimed(slug, key, action, glass?) do
    cond do
      # Checked BEFORE claiming, never after. See the moduledoc: the
      # server-wide token must never end up stored as a tournament key.
      master_token?(key) and glass? ->
        break_glass(slug, action, "slug is not claimed, so nothing was claimed for it")
        {:ok, :break_glass}

      # The same secret from a request that may not use it as one. Refused
      # rather than claimed with: storing it would promote the master secret
      # into this tournament's key, and hand it to an installation's owner.
      master_token?(key) ->
        {:error, :key_mismatch}

      # Neither deleting nor reading may CLAIM. Delete would leave a key row
      # pointing at nothing; read would let a pull silently take ownership of
      # a tournament this machine has never published, which is the opposite
      # of what a read should do.
      action in [:delete, :read] ->
        {:ok, :no_key}

      true ->
        claim(slug, key, glass?)
    end
  end

  defp claim(slug, key, glass?) do
    %TournamentKey{}
    |> TournamentKey.changeset(%{
      tournament_slug: slug,
      key_hash: hash(key),
      claimed_at: DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: :tournament_slug)

    # Re-read rather than trust what the insert reported. `on_conflict:
    # :nothing` succeeds whether it wrote or was beaten to it, and on SQLite it
    # returns a struct either way - so the insert's own answer cannot tell
    # "I claimed this" from "somebody else did, a microsecond ago".
    #
    # Reading back and judging against whatever row now exists collapses both
    # into one rule: first publish wins, and a second machine racing it with a
    # DIFFERENT key is refused exactly as it would be a day later.
    case fetch(slug) do
      # Only reachable if the row was deleted between the insert and this
      # read - a takedown landing mid-publish. Nothing is claimed and the
      # publish stands, which is the same outcome as an unclaimed slug.
      nil -> {:ok, :no_key}
      claim -> compare(slug, claim, key, :publish, glass?)
    end
  end

  defp compare(slug, %TournamentKey{key_hash: stored}, key, action, glass?) do
    cond do
      # The real key first, so an ordinary publish never trips the break-glass
      # log even in the pathological case where the two secrets are equal.
      Plug.Crypto.secure_compare(stored, hash(key)) ->
        {:ok, :tournament_key}

      glass? and master_token?(key) ->
        break_glass(slug, action, "the tournament key was overridden")
        {:ok, :break_glass}

      true ->
        {:error, :key_mismatch}
    end
  end

  defp master_token?(key) do
    case Application.get_env(:openresults, :ingest_token) do
      token when is_binary(token) and token != "" ->
        # Digests for the same reason `IngestAuth` uses them: `secure_compare/2`
        # returns early on a length difference and would otherwise leak how long
        # the server token is.
        Plug.Crypto.secure_compare(hash(token), hash(key))

      _unset ->
        false
    end
  end

  defp fetch(slug), do: Repo.get_by(TournamentKey, tournament_slug: slug)

  # Loud on purpose, and at warning rather than info: this is the audit trail
  # for somebody using the master key on a single tournament, and the question
  # it has to answer afterwards is "when did that happen and to what". The key
  # itself is never in the line - the whole point is that secrets do not get
  # written down.
  #
  # And to the moderation action log, as the actor `break-glass`, because the
  # person who most needs to see this is the operator reading the admin panel,
  # who is not reading journalctl.
  defp break_glass(slug, action, detail) do
    Logger.warning(
      "BREAK-GLASS: #{action} on #{inspect(slug)} authorised with the server-wide " <>
        "ingest token instead of the tournament key - #{detail}"
    )

    OpenResults.Moderation.log_break_glass(slug, action, detail)
  end
end
