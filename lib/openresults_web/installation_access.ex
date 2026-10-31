defmodule OpenResultsWeb.InstallationAccess do
  @moduledoc """
  What an installation key may do on a route that opted in to it.

  Called only from `OpenResultsWeb.Plugs.IngestAuth`, and only once a key has
  been recognised and the route has named its action in the router
  (`private: %{installation_access: action}`). Every check an action implies
  runs here, before the controller, so opting in cannot skip one.

  ## The actions

  | action | route | owner check | refused while suspended | while revoked | budget, block, pause, storage |
  |---|---|---|---|---|---|
  | `:mint` | `POST /api/tournaments` | - | yes | yes | yes |
  | `:publish` | `POST /api/snapshots` | payload's slug | yes | yes | yes, and the size cap |
  | `:history` | `GET /api/tournaments/:slug/history` | path slug | yes | yes | - |
  | `:registrations` | `GET /api/tournaments/:slug/registrations` | path slug | yes | yes | - |
  | `:delete` | `DELETE /api/tournaments/:slug` | path slug | **no** | **no** | - |
  | `:live` | `POST /api/tournaments/:slug/live` | path slug | yes | yes | its own budget, block, pause |
  | `:relay_key` | `POST /api/tournaments/:slug/relay-keys` | path slug | yes | yes | block, pause; the route's own budget per tournament |
  | `:relay_key_revoke` | `DELETE /api/tournaments/:slug/relay-keys` | path slug | **no** | yes | the route's own budget per tournament |
  | `:proof` | `POST /api/tournaments/:slug/proofs` | path slug | yes | yes | block, pause, storage; no budget of its own (a proof is taken only once, and only when the current snapshot announces it) |

  `:relay_key` hands out a credential for `:live`, so it is refused whenever
  `:live` would be - a hidden tournament included. Withdrawing one
  (`:relay_key_revoke`) only ever takes access away, so a suspended
  installation may still do it.

  `:live` is a write, but not a publish: a hall relay posts a board every few
  seconds, so it has its own generous per-minute budget (`@live_per_minute`
  per installation) instead of the publish budget, and it skips the size cap
  and, here, the storage floor - a board update is a few hundred bytes. The
  floor applies to `:live` for a NEW game only, which only
  `OpenResults.LiveBoards.ingest/3` can tell (the 2026-10-19 sweep), along
  with the board-must-be-published rule and the per-tournament cap. The
  operator's pause and an address block still stop it here.

  An action this module does not know is the anonymous 401 - a typo in the
  router must fail closed, not open.

  **Delete is always allowed for the owner** - suspended, revoked, paused or
  blocked. Withdrawing your own tournament is never the harmful action, and a
  moderation state that stopped an arbiter taking their own event down would
  be moderation keeping personal data public.

  ## Order

  Status, then the budget, then address block, then pause, then storage
  (`storage_low`, below the free-disk floor - an ETS read of
  `OpenResults.DiskSpace`'s last measurement), then size, then ownership. A
  block outranks storage because it is the refusal the arbiter must act on;
  the operator's pause outranks it because OpenPairings learns a pause has
  ended from `GET /api/server`, which says nothing about disk. The cheap ones first: a flood from a suspended key costs a
  lookup it already paid for, and a flood from an active one costs an ETS
  counter before anything reads the database. Ownership comes last because
  it is the one that has to read a tournament; the publish path checks it a
  second time inside its own transaction (`OpenResults.Snapshots.ingest/2`).

  The mint budget and the publish budget are ONE budget per installation: a
  mint is a write, and two budgets would let an installation spend twice the
  documented rate.
  """

  import Plug.Conn

  alias OpenResults.AddressBlocks
  alias OpenResults.DiskSpace
  alias OpenResults.Installations
  alias OpenResults.Installations.Installation
  alias OpenResults.PublicPublishing
  alias OpenResults.RateLimit
  alias OpenResults.Settings
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError
  alias OpenResultsWeb.ClientAddress
  alias OpenResultsWeb.Plugs.IngestAuth

  @actions [
    :mint,
    :publish,
    :history,
    :registrations,
    :delete,
    :live,
    :relay_key,
    :relay_key_revoke,
    :proof
  ]
  @writes [:mint, :publish]
  @refused_while_suspended [:mint, :publish, :history, :registrations, :live, :relay_key, :proof]
  @live_per_minute 1200

  @doc "The actions a route may opt in to."
  def actions, do: @actions

  @doc false
  @spec authorize(Plug.Conn.t(), Installation.t(), atom()) :: Plug.Conn.t()
  def authorize(conn, %Installation{} = installation, action) when action in @actions do
    address = ClientAddress.of(conn)
    Installations.touch(installation, address)

    with :ok <- status(installation, action),
         :ok <- budget(installation, action),
         :ok <- address_block(address, action),
         :ok <- pause(action),
         :ok <- storage(action),
         :ok <- size(conn, installation, action),
         :ok <- ownership(conn, installation, action) do
      assign(conn, :credential, {:installation, installation})
    else
      {:error, code} -> ApiError.send(conn, code)
      {:error, code, extra} -> ApiError.send(conn, code, extra)
    end
  end

  def authorize(conn, %Installation{}, _unknown_action), do: IngestAuth.unauthorized(conn)

  defp status(%Installation{status: "revoked"}, action) when action != :delete,
    do: {:error, :installation_revoked}

  defp status(%Installation{status: "suspended"}, action)
       when action in @refused_while_suspended,
       do: {:error, :installation_suspended}

  defp status(%Installation{status: status}, _action) when status in ~w(active suspended revoked),
    do: :ok

  # A status this code has never heard of is not permission.
  defp status(%Installation{}, _action), do: {:error, :installation_revoked}

  defp budget(%Installation{id: id} = installation, action) when action in @writes do
    case RateLimit.take({:installation_writes, id},
           limit: PublicPublishing.installation_publishes_per_minute(installation),
           window_ms: :timer.minutes(1)
         ) do
      :ok ->
        :ok

      {:denied, retry_in_ms} ->
        {:error, :rate_limited, %{retry_after: ApiError.retry_seconds(retry_in_ms)}}
    end
  end

  defp budget(%Installation{id: id}, :live) do
    case RateLimit.take({:installation_live, id},
           limit: @live_per_minute,
           window_ms: :timer.minutes(1)
         ) do
      :ok ->
        :ok

      {:denied, retry_in_ms} ->
        {:error, :rate_limited, %{retry_after: ApiError.retry_seconds(retry_in_ms)}}
    end
  end

  defp budget(_installation, _action), do: :ok

  defp address_block(address, action)
       when action in @writes or action in [:live, :relay_key, :proof] do
    if AddressBlocks.blocked?(address), do: {:error, :address_blocked}, else: :ok
  end

  defp address_block(_address, _action), do: :ok

  defp pause(action) when action in @writes or action in [:live, :relay_key, :proof] do
    if Settings.get(:public_publishing_paused), do: {:error, :publishing_paused}, else: :ok
  end

  defp pause(_action), do: :ok

  # Five measurements: a retry sooner would be answered from the same one.
  @storage_retry_after 300

  # Mint and publish only. Delete is what makes room, and a measurement that
  # could not be made reads `:unknown`, which is not low - see
  # `OpenResults.DiskSpace`.
  defp storage(action) when action in @writes or action == :proof do
    if DiskSpace.low?(),
      do: {:error, :storage_low, %{retry_after: @storage_retry_after}},
      else: :ok
  end

  defp storage(_action), do: :ok

  # The bytes actually read off the wire, counted by `OpenResultsWeb.BodyReader`
  # while `Plug.Parsers` read them - not a `content-length` a client can
  # understate, and not a re-encoding of the parsed map, which would measure
  # this server's JSON rather than the client's.
  defp size(conn, installation, :publish) do
    limit = PublicPublishing.installation_max_snapshot_bytes(installation)

    received =
      conn.private[:openresults_body_bytes] || content_length(conn)

    if received > limit,
      do: {:error, :snapshot_too_large, %{limit_bytes: limit}},
      else: :ok
  end

  defp size(_conn, _installation, _action), do: :ok

  defp content_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {bytes, ""} <- Integer.parse(value) do
      bytes
    else
      _absent -> 0
    end
  end

  defp ownership(_conn, _installation, :mint), do: :ok

  # A payload with no usable slug has nothing to own; the envelope check in
  # `Snapshots.ingest/2` refuses it before anything is written, and checks
  # ownership again for the slug it does find.
  defp ownership(conn, installation, :publish) do
    case conn.body_params do
      %{"tournament" => %{"slug" => slug}} when is_binary(slug) ->
        Tournaments.authorize_owner(slug, installation, :publish)

      _no_slug ->
        :ok
    end
  end

  defp ownership(conn, installation, action) when action in [:live, :relay_key, :proof] do
    Tournaments.authorize_owner(conn.path_params["slug"], installation, :publish)
  end

  defp ownership(conn, installation, :relay_key_revoke) do
    Tournaments.authorize_owner(conn.path_params["slug"], installation, :delete)
  end

  defp ownership(conn, installation, action) when action in [:history, :registrations] do
    Tournaments.authorize_owner(conn.path_params["slug"], installation, :read)
  end

  defp ownership(conn, installation, :delete) do
    Tournaments.authorize_owner(conn.path_params["slug"], installation, :delete)
  end
end
