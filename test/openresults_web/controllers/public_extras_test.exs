defmodule OpenResultsWeb.PublicExtrasTest do
  @moduledoc """
  The feed, the sitemap, the player's board link, the embed view, the year
  filter on the front page and the round page's share text.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  setup do
    swiss = SnapshotPayloads.swiss()
    {:ok, _snapshot} = Snapshots.ingest(swiss)

    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  # The sitemap index and every sitemap it points to, as one text.
  defp whole_sitemap(conn) do
    index = conn |> get("/sitemap.xml") |> response(200)

    parts =
      for [_, loc] <- Regex.scan(~r{<loc>([^<]+)</loc>}, index) do
        build_conn() |> get(URI.parse(loc).path) |> response(200)
      end

    Enum.join([index | parts], "\n")
  end

  defp publish(payload), do: {:ok, _snapshot} = Snapshots.ingest(payload)

  defp display(payload, key, value),
    do: put_in(payload, ["tournament", "display", key], value)

  describe "the feed" do
    test "is Atom, and names a state per entry", %{conn: conn, slug: slug} do
      conn = get(conn, "/t/#{slug}/feed.xml")

      assert response(conn, 200)
      assert [type | _] = get_resp_header(conn, "content-type")
      assert type =~ "application/atom+xml"

      body = conn.resp_body
      assert body =~ ~s(<feed xmlns="http://www.w3.org/2005/Atom">)
      assert body =~ "#standings-2</id>"
      assert body =~ "#round-5-results</id>"
      assert body =~ "#round-5-pairings</id>"
      # Round 3 still has a board without a result: its pairings are out, its
      # results are not complete.
      assert body =~ "#round-3-pairings</id>"
      refute body =~ "#round-3-results</id>"
    end

    test "escapes what it is sent", %{conn: conn, swiss: swiss} do
      payload =
        swiss
        |> put_in(["tournament", "slug"], "escaped-feed")
        |> put_in(["tournament", "name"], "Rook & Pawn <Open>")

      publish(payload)
      body = conn |> get("/t/escaped-feed/feed.xml") |> response(200)

      assert body =~ "Rook &amp; Pawn &lt;Open&gt;"
      refute body =~ "<Open>"
    end

    test "announces no pairings when the arbiter publishes none", %{conn: conn, swiss: swiss} do
      payload =
        swiss |> put_in(["tournament", "slug"], "no-pairings-feed") |> display("pairings", false)

      publish(payload)
      body = conn |> get("/t/no-pairings-feed/feed.xml") |> response(200)

      refute body =~ "round-"
      assert body =~ "#standings-2</id>"
    end

    test "is a 404 for a tournament that never published", %{conn: conn} do
      assert conn |> get("/t/nothing-here/feed.xml") |> response(404)
    end

    test "is linked from the tournament's pages", %{conn: conn, slug: slug} do
      html = conn |> get("/t/#{slug}") |> html_response(200)

      assert html =~ ~s(type="application/atom+xml")
      assert html =~ ~s(href="/t/#{slug}/feed.xml")
    end
  end

  describe "the sitemap" do
    test "lists a listed tournament's pages and no player cards", %{conn: conn, slug: slug} do
      body = whole_sitemap(conn)

      assert body =~ "/t/#{slug}</loc>"
      assert body =~ "/t/#{slug}/round/5</loc>"
      assert body =~ "<lastmod>"
      refute body =~ "/player/"
    end

    test "leaves out a tournament the arbiter did not list", %{conn: conn, swiss: swiss} do
      swiss
      |> put_in(["tournament", "slug"], "unlisted-sitemap")
      |> put_in(["tournament", "listed"], false)
      |> publish()

      body = whole_sitemap(conn)
      refute body =~ "unlisted-sitemap"
    end
  end

  describe "a player's board" do
    test "redirects to the latest round, at their board", %{conn: conn, slug: slug} do
      conn = get(conn, "/t/#{slug}/player/1/board")
      assert redirected_to(conn) == "/t/#{slug}/round/5#board-1"
    end

    test "the round page carries the anchor it lands on", %{conn: conn, slug: slug} do
      html = conn |> get("/t/#{slug}/round/5") |> html_response(200)
      assert html =~ ~s(id="board-1")
    end

    test "is linked from the player's card", %{conn: conn, slug: slug} do
      html = conn |> get("/t/#{slug}/player/1") |> html_response(200)
      assert html =~ ~s(href="/t/#{slug}/player/1/board")
    end

    test "is a 404 for a player who is not in the tournament", %{conn: conn, slug: slug} do
      assert conn |> get("/t/#{slug}/player/999/board") |> html_response(404)
    end

    test "is withheld with the pairings", %{conn: conn, swiss: swiss} do
      swiss
      |> put_in(["tournament", "slug"], "no-pairings-board")
      |> display("pairings", false)
      |> publish()

      assert conn |> get("/t/no-pairings-board/player/1/board") |> html_response(404)
    end
  end

  describe "the embed" do
    test "drops the site's chrome and keeps a way back", %{conn: conn, slug: slug} do
      document =
        conn |> get("/t/#{slug}?embed=1") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query(".masthead-bar") |> Enum.empty?()
      assert document |> LazyHTML.query(".page.embed-mode") |> Enum.count() == 1
      assert document |> LazyHTML.query(~s(base[target="_top"])) |> Enum.count() == 1
      assert document |> LazyHTML.query(~s(.embed-foot a[href="/t/#{slug}"])) |> Enum.count() == 1
    end

    test "the ordinary page is untouched", %{conn: conn, slug: slug} do
      document = conn |> get("/t/#{slug}") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query(".masthead-bar") |> Enum.count() == 1
      assert document |> LazyHTML.query("base") |> Enum.empty?()
    end
  end

  describe "a federation archive's years" do
    test "are offered once there is more than one, and filter", %{conn: conn, swiss: swiss} do
      swiss
      |> put_in(["tournament", "slug"], "last-year-open")
      |> put_in(["tournament", "name"], "Last Year Open")
      |> put_in(["tournament", "start_date"], "2025-03-01")
      |> put_in(["tournament", "end_date"], "2025-03-05")
      |> publish()

      html = conn |> get("/f/BEL") |> html_response(200)
      assert html =~ ~s(href="/f/BEL?year=2025")
      assert html =~ "Last Year Open"

      filtered = build_conn() |> get("/f/BEL?year=2026") |> html_response(200)
      refute filtered =~ "Last Year Open"
      assert filtered =~ "Gent Spring Open 2026"
    end

    test "are not offered for a single year", %{conn: conn} do
      html = conn |> get("/f/BEL") |> html_response(200)
      refute html =~ "?year="
    end
  end

  describe "a round's share text" do
    test "names board 1 and its result", %{conn: conn, slug: slug} do
      html = conn |> get("/t/#{slug}/round/5") |> html_response(200)
      assert html =~ "Board 1: Đurić, Nikola - Müller, Jörg, 0-1."
    end
  end
end
