defmodule OpenResultsWeb.LivePgnController do
  @moduledoc """
  `GET /t/:slug/live/:round/:board/pgn` - the game on one board as a PGN file.

  Built on every request from the stored game, at the tournament's broadcast
  delay, through the same tile the page draws - so the file can never show a
  move, a result or a name the page would not. The tournament's headers come
  from the published snapshot and follow the same display ticks.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.LiveBoards.Pgn
  alias OpenResults.Tournaments
  alias OpenResultsWeb.LiveBoardsData

  def show(conn, %{"slug" => slug, "round" => round, "board" => board}) do
    with {round, ""} <- Integer.parse(round),
         {board, ""} <- Integer.parse(board),
         %{payload: payload} <- Tournaments.public_latest(slug),
         %{view: %{} = view} = tile <- LiveBoardsData.tile(payload, slug, round, board) do
      pgn = Pgn.build(view, LiveBoardsData.pgn_tags(payload, tile))

      conn
      |> put_resp_content_type("application/x-chess-pgn", "utf-8")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(slug)}-round#{round}-board#{board}.pgn")
      )
      # A game that is still being played changes under this URL.
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, pgn)
    else
      _no_such_game -> conn |> put_status(:not_found) |> text("No such game.\n")
    end
  end

  @doc """
  `GET /t/:slug/live/:round/pgn` - every game of the round as ONE PGN
  document, for a poller (Lichess's broadcast tool, chess.com's, a script).

  Boards in ascending order, each built by the same `Pgn.build/2` as the
  per-game route and at the same delay (one `LiveBoardsData.tiles/3` read
  for the round). A board with no game to show - not started yet, behind the
  delay, or forfeited - is a header-only game with its result, `*` until it
  has one. The ETag is a hash of the body actually served, so a delay
  uncovering a move changes it with no write behind it; `If-None-Match` is
  answered 304. No `Last-Modified`: the body changes with the clock as well
  as with the data, and no stored timestamp says when.
  """
  def round_pgn(conn, %{"slug" => slug, "round" => round}) do
    with {round, ""} <- Integer.parse(round),
         %{payload: payload} <- Tournaments.public_latest(slug),
         [_ | _] = tiles <- LiveBoardsData.tiles(payload, slug, round) do
      send_pgn(conn, tiles |> game_list(payload) |> Enum.join("\n"))
    else
      _no_such_round -> conn |> put_status(:not_found) |> text("No such round.\n")
    end
  end

  @doc """
  `GET /t/:slug/games.pgn` - every game of every published round as ONE PGN
  document, the file to hand to an analysis tool after the event.

  The rounds in order, each exactly as `round_pgn/2` builds it (same tiles,
  same delay, same header-only games for boards with nothing to show), and
  answered with the same ETag and 304 handling. A tournament with no boards
  published is a 404, not an empty file.
  """
  def all_pgn(conn, %{"slug" => slug}) do
    with %{payload: payload} <- Tournaments.public_latest(slug),
         [_ | _] = rounds <- LiveBoardsData.rounds(payload),
         [_ | _] = games <- Enum.flat_map(rounds, &round_games(payload, slug, &1)) do
      conn
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(slug)}.pgn")
      )
      |> send_pgn(Enum.join(games, "\n"))
    else
      _no_games -> conn |> put_status(:not_found) |> text("No such tournament.\n")
    end
  end

  defp round_games(payload, slug, round) do
    payload |> LiveBoardsData.tiles(slug, Map.get(round, "number")) |> game_list(payload)
  end

  defp game_list(tiles, payload) do
    tiles |> Enum.sort_by(& &1.board) |> Enum.map(&game(payload, &1))
  end

  defp send_pgn(conn, body) do
    etag = ~s("#{:crypto.hash(:sha256, body) |> Base.url_encode64(padding: false)}")

    conn =
      conn
      |> put_resp_content_type("application/x-chess-pgn", "utf-8")
      |> put_resp_header("etag", etag)
      # Cacheable, but revalidated every time: it moves under this URL.
      |> put_resp_header("cache-control", "no-cache")

    if fresh?(conn, etag), do: send_resp(conn, 304, ""), else: send_resp(conn, 200, body)
  end

  defp game(payload, %{view: %{}} = tile),
    do: Pgn.build(tile.view, LiveBoardsData.pgn_tags(payload, tile))

  defp game(payload, tile), do: Pgn.build_header_only(LiveBoardsData.pgn_tags(payload, tile))

  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
    |> Enum.any?(&(&1 in ["*", etag]))
  end

  defp filename(slug), do: String.replace(slug, ~r/[^A-Za-z0-9._-]/, "_")
end
