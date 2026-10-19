defmodule OpenResultsWeb.LiveBoardController do
  @moduledoc """
  `POST /api/tournaments/:slug/live` - a hall relay reporting what is on the
  boards. The contract is `docs/live-boards-api.md`; the rules of what is
  kept and what is ignored are `OpenResults.LiveBoards`'s.

  Authenticated like a publish, or with a relay key: the ingest plug on the pipeline decides which
  credential this is (the operator token, or an installation key that owns the
  slug), and the tournament's own key, if the slug has been claimed, has to
  come in `x-openresults-key` as well - the relay is one more machine that is
  allowed to speak for the tournament, not a way round who is. A relay key
  (`OpenResults.RelayKeys`) is that tournament's own, bound to this slug by
  the plug, and replaces the header - the box in the hall should not have to
  hold the tournament's key to report a board.

  The current snapshot bounds what may be stored (the 2026-10-19 sweep):
  only its `(round, board)` pairs, at most `LiveBoards.bounds/2`'s cap of
  games, and below the free-disk floor no new game except with the operator
  token. Worked out once per request and handed to every board's ingest.

  One board per request, or `{"boards": [...]}` for up to #{64}. A batch answers
  200 with one result per board, because one illegal move must not hide that
  the other boards were stored.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.LiveBoards
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError

  @batch_limit 64
  @key_header "x-openresults-key"

  def create(conn, %{"slug" => slug}) do
    with {:ok, snapshot} <- published(slug),
         :ok <- authorize_key(conn, slug) do
      bounds =
        LiveBoards.bounds(snapshot.payload, floor?: conn.assigns[:credential] != :operator)

      case conn.body_params do
        %{"boards" => boards} when is_list(boards) and length(boards) <= @batch_limit ->
          results = Enum.map(boards, &batch_item(slug, &1, bounds))
          json(conn, %{status: "ok", results: results})

        %{"boards" => _too_many_or_junk} ->
          ApiError.send(conn, :invalid_request, %{
            detail: "`boards` must be a list of at most #{@batch_limit} board updates"
          })

        body ->
          single(conn, slug, body, bounds)
      end
    else
      {:error, :tournament_not_published} ->
        ApiError.send(conn, :tournament_not_published)

      {:error, reason} when reason in [:key_required, :key_mismatch] ->
        ApiError.send(conn, reason)
    end
  end

  defp single(conn, slug, body, bounds) do
    case LiveBoards.ingest(slug, body, bounds) do
      {:ok, outcome} ->
        json(conn, ok_body(outcome))

      {:error, code, detail} ->
        ApiError.send(conn, code, %{detail: detail})

      {:error, code, detail, extra} ->
        ApiError.send(conn, code, Map.put(extra, :detail, detail))
    end
  end

  defp batch_item(slug, body, bounds) do
    identity = if is_map(body), do: %{round: body["round"], board: body["board"]}, else: %{}

    case LiveBoards.ingest(slug, body, bounds) do
      {:ok, outcome} ->
        Map.merge(identity, ok_body(outcome))

      {:error, code, detail} ->
        Map.merge(identity, %{status: "error", error: Atom.to_string(code), detail: detail})

      {:error, code, detail, extra} ->
        Map.merge(
          identity,
          Map.merge(extra, %{status: "error", error: Atom.to_string(code), detail: detail})
        )
    end
  end

  defp ok_body(%{applied?: applied?, ply: ply}) do
    base = %{status: "ok", applied: applied?, ply: ply}
    if applied?, do: base, else: Map.put(base, :reason, "older_than_stored")
  end

  # A tournament that has published, and is not hidden: the same door every
  # public page uses. A hidden one is the arbiter's to delete and nobody's to
  # feed.
  defp published(slug) do
    case Tournaments.public_latest(slug) do
      nil -> {:error, :tournament_not_published}
      snapshot -> {:ok, snapshot}
    end
  end

  # A relay key is bound to this slug already (`OpenResultsWeb.RelayAccess`)
  # and is what the relay holds INSTEAD of the tournament's key, so it does
  # not also need one.
  defp authorize_key(%{assigns: %{credential: {:relay, _relay_key}}}, _slug), do: :ok

  defp authorize_key(conn, slug) do
    key =
      case get_req_header(conn, @key_header) do
        [key | _duplicates] -> key
        [] -> nil
      end

    TournamentKeys.authorize_read(slug, key, break_glass: conn.assigns[:credential] == :operator)
  end
end
