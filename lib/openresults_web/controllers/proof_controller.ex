defmodule OpenResultsWeb.ProofController do
  @moduledoc """
  Round pairing proofs - see `OpenResults.RoundProofs`.

  `create` - `POST /api/tournaments/:slug/proofs` - is the publisher
  uploading a proof its snapshot announced and the publish answer asked for
  (`proofs_wanted`). The credentials and the tournament key of a publish,
  checked the same way (`OpenResultsWeb.InstallationAccess`, action
  `:proof`). The body is JSON like every other route of the contract:
  `{"round": n, "sha256": "...", "gzip_base64": "..."}`.

  `show` - `GET /t/:slug/round/:n/proof` - is the file, for whoever reads
  the round page. Served only for the digest the CURRENT snapshot names for
  that round, behind the same `Visibility` and "pairings" switch as the
  round page itself: a proof of a round nobody may see is not a download.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.RoundProofs
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError
  alias OpenResultsWeb.Tournament

  @key_header "x-openresults-key"

  def create(conn, %{"slug" => slug}) do
    with {:ok, round, sha, gzip} <- body(conn.body_params),
         :ok <- published(slug),
         :ok <- authorize_key(conn, slug),
         {:ok, outcome} <- RoundProofs.store(slug, round, sha, gzip) do
      json(conn, %{
        status: "ok",
        slug: slug,
        round: round,
        sha256: sha,
        stored: outcome == :stored
      })
    else
      {:error, code, extra} -> ApiError.send(conn, code, extra)
      {:error, code} -> ApiError.send(conn, code)
    end
  end

  defp body(%{"round" => round, "sha256" => sha, "gzip_base64" => data})
       when is_integer(round) and round > 0 and is_binary(sha) and is_binary(data) do
    case Base.decode64(data) do
      {:ok, gzip} -> {:ok, round, sha, gzip}
      :error -> {:error, :invalid_request}
    end
  end

  defp body(_other), do: {:error, :invalid_request}

  defp published(slug) do
    if Tournaments.public_latest(slug), do: :ok, else: {:error, :tournament_not_published}
  end

  defp authorize_key(conn, slug) do
    key =
      case get_req_header(conn, @key_header) do
        [key | _duplicates] -> key
        [] -> nil
      end

    TournamentKeys.authorize_read(slug, key, break_glass: conn.assigns[:credential] == :operator)
  end

  def show(conn, %{"slug" => slug, "n" => n}) do
    with %{payload: payload} <- Tournaments.public_latest(slug),
         true <- Tournament.show?(payload, "pairings"),
         {number, ""} <- Integer.parse(n),
         %{"sha256" => sha} <- Tournament.round_proof(Tournament.round(payload, number)),
         gzip when is_binary(gzip) <- RoundProofs.fetch(slug, number, sha) do
      conn
      |> put_resp_content_type("application/gzip", nil)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(slug, number)}")
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "public, max-age=300")
      |> send_resp(200, gzip)
    else
      _absent ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, gettext("There is no pairing proof for this round."))
    end
  end

  # The slug is the publisher's; only the characters a file name can carry
  # anywhere survive into it.
  defp filename(slug, number) do
    safe = String.replace(slug, ~r/[^A-Za-z0-9_-]/, "_")
    "#{safe}-round-#{number}.proof.jsonl.gz"
  end
end
