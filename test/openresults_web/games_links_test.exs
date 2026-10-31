defmodule OpenResultsWeb.GamesLinksTest do
  @moduledoc """
  The ways into a game other than the "Live boards" chip: a link on every
  board of a round page and on every game of a player card, and the whole
  tournament as one PGN. The links follow the arbiter's word alone - these
  pages are cached per snapshot - and the file follows the round PGN.
  """

  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]

  alias OpenResults.LiveBoards
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  defp publish!(live_boards?) do
    slug = unique_slug("games")

    payload =
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "slug"], slug)
      |> put_in(["tournament", "live_boards"], live_boards?)

    {:ok, _} = Snapshots.ingest(payload)
    slug
  end

  defp doc(html), do: LazyHTML.from_document(html)

  describe "round page" do
    test "every board links to its game and its PGN when the arbiter says live boards", %{
      conn: conn
    } do
      slug = publish!(true)
      html = conn |> get("/t/#{slug}/round/1") |> html_response(200)
      links = doc(html) |> LazyHTML.query("#pairings .game-links a") |> LazyHTML.attribute("href")

      assert "/t/#{slug}/live/1/1" in links
      assert "/t/#{slug}/live/1/1/pgn" in links
    end

    test "no links without the word", %{conn: conn} do
      slug = publish!(false)
      html = conn |> get("/t/#{slug}/round/1") |> html_response(200)
      assert doc(html) |> LazyHTML.query(".game-links") |> Enum.count() == 0
    end
  end

  describe "player card" do
    test "a played round links to its board", %{conn: conn} do
      slug = publish!(true)
      html = conn |> get("/t/#{slug}/player/1") |> html_response(200)

      links =
        doc(html) |> LazyHTML.query("table.card .game-links a") |> LazyHTML.attribute("href")

      assert Enum.any?(links, &String.match?(&1, ~r{^/t/#{slug}/live/\d+/\d+$}))
      assert Enum.any?(links, &String.match?(&1, ~r{^/t/#{slug}/live/\d+/\d+/pgn$}))
    end

    test "no links without the word", %{conn: conn} do
      slug = publish!(false)
      html = conn |> get("/t/#{slug}/player/1") |> html_response(200)
      assert doc(html) |> LazyHTML.query(".game-links") |> Enum.count() == 0
    end
  end

  describe "download all games" do
    test "the standings page offers it only with live boards", %{conn: conn} do
      with_flag = publish!(true)
      without = publish!(false)

      html = conn |> get("/t/#{with_flag}") |> html_response(200)
      assert html =~ ~s(id="export-games")
      assert html =~ "/t/#{with_flag}/games.pgn"

      refute build_conn() |> get("/t/#{without}") |> html_response(200) =~ "export-games"
    end

    test "is every round's boards in one file, with the headers of the single-game PGN", %{
      conn: conn
    } do
      slug = publish!(true)

      assert {:ok, _} =
               LiveBoards.ingest(slug, %{"round" => 1, "board" => 1, "moves" => ~w(e4 e5)})

      conn = get(conn, "/t/#{slug}/games.pgn")
      pgn = response(conn, 200)

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/x-chess-pgn"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="#{slug}.pgn")

      assert pgn =~ ~s([Event "Gent Spring Open 2026"])
      assert pgn =~ ~s([Round "1.1"])
      assert pgn =~ ~s([Round "5.1"])
      assert pgn =~ "1. e4 e5"

      games = Regex.scan(~r/^\[Event /m, pgn) |> length()
      round_one = build_conn() |> get("/t/#{slug}/live/1/pgn") |> response(200)
      assert games > Regex.scan(~r/^\[Event /m, round_one) |> length()
    end

    test "answers a repeat request with 304 and an unknown tournament with 404", %{conn: conn} do
      slug = publish!(true)
      first = get(conn, "/t/#{slug}/games.pgn")
      [etag] = get_resp_header(first, "etag")

      again = build_conn() |> put_req_header("if-none-match", etag) |> get("/t/#{slug}/games.pgn")
      assert response(again, 304) == ""

      assert build_conn() |> get("/t/no-such-#{slug}/games.pgn") |> response(404)
    end
  end
end
