defmodule OpenResultsWeb.ApiError do
  @moduledoc """
  The error body every API route answers with:

      {"error": "<code>", "detail": "<an English sentence for logs>"}

  plus the extra fields a code carries. `docs/public-publishing.md`, "Error
  bodies", is the contract; this is the one place the codes, their statuses
  and their extra fields are written down in code, so two routes cannot
  answer the same code two ways.

  **Clients dispatch on `error`**, never on `detail` and never on the status
  alone - two different 403s mean two different things to an arbiter. So
  `detail` may be reworded freely and `error` may never be.
  """

  import Plug.Conn

  @codes %{
    unauthorized: {401, "a valid credential is required"},
    key_required: {403, "this tournament has been claimed; send its key in `x-openresults-key`"},
    key_mismatch: {403, "`x-openresults-key` is not the key this tournament was claimed with"},
    installation_suspended:
      {403, "this installation is suspended; it may delete its own tournaments and nothing else"},
    installation_revoked:
      {403,
       "this installation's key has been revoked; it may delete its own tournaments and nothing else"},
    owner_suspended:
      {403,
       "the installation that publishes this tournament is suspended; its relay keys are refused until it is not"},
    owner_revoked:
      {403, "the installation that published this tournament has been revoked; so has this relay"},
    installation_key_required:
      {403, "tournaments are minted for an installation; call this with an installation key"},
    not_owner: {403, "this tournament was not minted for this installation"},
    relay_key_revoked: {403, "this relay key has been revoked; ask the organiser for a new one"},
    relay_key_wrong_tournament: {403, "this relay key belongs to a different tournament"},
    relay_key_limit:
      {409,
       "this tournament already holds as many relay keys as it may; an administrator of this server can revoke some"},
    tournament_hidden:
      {403,
       "this tournament has been hidden by the operator; it can be deleted but not published"},
    tournament_deleted:
      {410,
       "the operator of this server deleted this tournament; it cannot be published again under this slug"},
    tournament_limit: {403, "this installation already holds as many tournaments as it may"},
    address_blocked: {403, "requests from this address are blocked; contact the operator"},
    snapshot_too_large: {413, "the snapshot is larger than an installation key may publish"},
    registration_closed: {503, "this server is not accepting new installations right now"},
    publishing_paused: {503, "publishing with installation keys is paused on this server"},
    storage_low:
      {503,
       "this server is low on disk space; installation keys may publish again when it has room, and may still delete"},
    rate_limited: {429, "too many requests; wait `retry_after` seconds"},
    tournament_not_published:
      {404, "nothing has been published under this slug yet; publish the tournament first"},
    invalid_request: {422, "the board update is malformed"},
    board_not_published:
      {409, "this round and board are not in the published snapshot; publish the round first"},
    live_game_limit: {409, "this tournament holds as many live games as it may"},
    invalid_fen: {422, "a FEN in the board update is not a legal position"},
    invalid_moves: {422, "a move in the board update is not legal"},
    ply_mismatch: {422, "`ply` does not match the number of `moves`"},
    fen_mismatch: {422, "`fen` is not the position `moves` lead to"},
    moves_conflict: {409, "the moves disagree with those already held for this board"},
    not_configured:
      {404, "this server does not relay a Belgian (KBSB/FRBE) roster; ask the operator"}
  }

  @doc "The codes this module knows, for tests."
  def codes, do: Map.keys(@codes)

  @doc "The status a code is answered with."
  def status(code), do: @codes |> Map.fetch!(code) |> elem(0)

  @doc """
  Sends `code` and halts. `extra` is merged into the body; for
  `rate_limited`, `retry_after` (seconds) also becomes the `Retry-After`
  header.
  """
  @spec send(Plug.Conn.t(), atom(), map() | keyword()) :: Plug.Conn.t()
  def send(conn, code, extra \\ %{}) do
    {status, detail} = Map.fetch!(@codes, code)
    # One counter increment, for the admin stats page's refusals by code.
    OpenResults.Stats.count({:refused, code})
    extra = Map.new(extra)

    conn =
      case extra do
        %{retry_after: seconds} ->
          put_resp_header(conn, "retry-after", Integer.to_string(seconds))

        _no_retry ->
          conn
      end

    body = Map.merge(%{error: Atom.to_string(code), detail: detail}, extra)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  @doc "Whole seconds, rounded up, from a `RateLimit` denial - never 0."
  @spec retry_seconds(non_neg_integer()) :: pos_integer()
  def retry_seconds(retry_in_ms), do: max(1, ceil(retry_in_ms / 1000))
end
