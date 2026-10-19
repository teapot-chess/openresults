defmodule OpenResultsWeb.ClaimController do
  @moduledoc """
  `GET /api/tournaments/:slug/claim` - is the slug claimed with the key in
  `x-openresults-key`? The contract is `docs/public-publishing.md`,
  "Checking a tournament key".

  The operator token only (the router gives it no `installation_access`, so
  an installation key never gets here). A hosted OpenPairings serves many
  arbiters with that one token, so it asks this before believing a key a
  backup file carried in: the file is the arbiter's to edit, and the server
  is the only party that knows which key actually claimed the slug.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Tombstones
  alias OpenResults.TournamentKeys
  alias OpenResultsWeb.ApiError

  @key_header "x-openresults-key"

  def show(conn, %{"slug" => slug}) do
    presented =
      case get_req_header(conn, @key_header) do
        [key | _duplicates] -> key
        [] -> nil
      end

    if Tombstones.tombstoned?(slug) do
      ApiError.send(conn, :tournament_deleted)
    else
      case TournamentKeys.verify(slug, presented) do
        :tournament_key -> json(conn, %{claim: "tournament_key"})
        :unclaimed -> json(conn, %{claim: "unclaimed"})
        {:error, code} -> ApiError.send(conn, code)
      end
    end
  end
end
