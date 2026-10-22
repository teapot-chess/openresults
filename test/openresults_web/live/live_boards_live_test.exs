defmodule OpenResultsWeb.LiveBoardsLiveTest do
  @moduledoc """
  The spectator side of the live boards: the round grid, one game, the PGN
  download and the hall display's live view. What matters here is that a
  page changes when a game does - without a reload and without waiting for a
  poll - that none of it comes out of the page cache, that the broadcast
  delay holds, and that nothing the arbiter withheld shows.
  """

  use OpenResultsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]

  alias OpenResults.LiveBoards
  alias OpenResults.Moderation
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  @opera ~w(e4 e5 Nf3 d6 d4 Bg4 dxe5 Bxf3 Qxf3 dxe5 Bc4 Nf6 Qb3 Qe7 Nc3 c6 Bg5 b5 Nxb5 cxb5
            Bxb5+ Nbd7 O-O-O Rd8 Rxd7 Rxd7 Rd1 Qe6 Bxd7+ Nxd7 Qb8+ Nxb8 Rd8#)

  # The swiss fixture with round 5 freshly paired - no result in yet - under a
  # slug of its own.
  defp publish!(tweak \\ & &1) do
    slug = unique_slug("watch")

    payload =
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "slug"], slug)
      |> update_in(["rounds"], fn rounds ->
        Enum.map(rounds, fn
          %{"number" => 5} = round ->
            Map.update!(round, "boards", fn boards ->
              Enum.map(boards, &Map.put(&1, "result", nil))
            end)

          round ->
            round
        end)
      end)
      |> tweak.()

    {:ok, _} = Snapshots.ingest(payload)
    slug
  end

  defp report(slug, board, moves, extra \\ %{}, opts \\ []) do
    params = Map.merge(%{"round" => 5, "board" => board, "moves" => moves}, extra)
    assert {:ok, _} = LiveBoards.ingest(slug, params, opts)
  end

  defp settle(view), do: _ = :sys.get_state(view.pid)

  defp hall_state(view) do
    hall = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#hall")

    %{
      view: hall |> LazyHTML.attribute("data-view") |> List.first(),
      cycle: hall |> LazyHTML.attribute("data-cycle") |> List.first() |> String.to_integer()
    }
  end

  describe "the round page" do
    test "lists every published board of the newest round, none started", %{conn: conn} do
      slug = publish!()
      {:ok, view, html} = live(conn, "/t/#{slug}/live/5/all")

      assert html =~ "Live boards"
      for board <- 1..5, do: assert(has_element?(view, "#live-5-#{board}.lb-status-waiting"))
      refute has_element?(view, "#live-5-6")
      refute has_element?(view, ".lb-status-live")
    end

    test "round chips lead to the other rounds, and an unpublished round is said so", %{
      conn: conn
    } do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/1/all")

      assert has_element?(view, "#live-1-1")
      refute has_element?(view, "#live-5-1")
      assert has_element?(view, "#lb-rounds a.lb-pill.is-current", "1")

      # Round 4 is the fixture's unpublished round.
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/4/all")
      assert has_element?(view, "#lb-unknown-round")
      # Not a dead end: the latest round is one tap away.
      assert has_element?(view, ~s(#lb-latest-round a[href="/t/#{slug}/live/5/all"]))
      refute has_element?(view, ".lb-tile")
    end

    test "a game reported while the page is open appears on it, move by move", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#live-5-2.lb-status-waiting")

      report(slug, 2, ~w(e4 e5), %{
        "white_ms" => 300_000,
        "black_ms" => 299_000,
        "running" => "white"
      })

      settle(view)

      assert has_element?(view, "#live-5-2.lb-status-live")
      assert has_element?(view, "#live-5-2 .lb-last-move", "1... e5")
      assert has_element?(view, "#live-5-2-clock-white.is-running")
      # The side that is not running holds its time exactly.
      assert has_element?(view, "#live-5-2-clock-black", "4:59")
      assert has_element?(view, "#live-5-1.lb-status-waiting")

      report(slug, 2, ~w(e4 e5 Nf3), %{"running" => "black"})
      settle(view)
      assert has_element?(view, "#live-5-2 .lb-last-move", "2. Nf3")
      assert has_element?(view, "#live-5-2-clock-black.is-running")
    end

    test "a finished game shows its provisional result, and the published one wins", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      report(slug, 3, @opera, %{"status" => "finished", "result" => "1-0"})
      settle(view)

      assert has_element?(view, "#live-5-3.lb-status-finished .lb-result", "1-0")
      assert has_element?(view, "#live-5-3 .lb-provisional")

      # Round 1 board 1 carries the arbiter's result in the fixture.
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/1/all")
      assert has_element?(view, "#live-1-1 .lb-result")
      refute has_element?(view, "#live-1-1 .lb-provisional")
    end

    test "a round whose results are withheld shows that a game is over and nothing more", %{
      conn: conn
    } do
      slug =
        publish!(fn payload ->
          update_in(payload["rounds"], fn rounds ->
            Enum.map(rounds, fn
              %{"number" => 5} = round -> Map.put(round, "results_public", false)
              round -> round
            end)
          end)
        end)

      report(slug, 1, @opera, %{"status" => "finished", "result" => "1-0"})
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      assert has_element?(view, "#live-5-1.lb-status-finished")
      refute has_element?(view, "#live-5-1 .lb-result")
    end

    test "a game on a board the snapshot does not list is not shown", %{conn: conn} do
      slug = publish!()
      report(slug, 99, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      refute has_element?(view, "#live-5-99")
      assert has_element?(view, ".lb-status-waiting")
    end

    test "names, ratings and titles follow the arbiter's ticks", %{conn: conn} do
      slug =
        publish!(fn payload ->
          put_in(payload, ["tournament", "display", "rating"], false)
        end)

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, ".lb-person")
      refute has_element?(view, ".lb-rating")
    end

    test "withheld pairings mean no live boards at all", %{conn: conn} do
      slug =
        publish!(fn payload -> put_in(payload, ["tournament", "display", "pairings"], false) end)

      report(slug, 1, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      refute has_element?(view, ".lb-tile")
      assert has_element?(view, "#lb-no-rounds")
    end

    test "is never served from the page cache", %{conn: conn} do
      slug = publish!()
      conn = get(conn, "/t/#{slug}/live/5/all")

      assert html_response(conn, 200) =~ "Live boards"
      assert get_resp_header(conn, "etag") == []

      first = conn |> get("/t/#{slug}/live/5/all") |> html_response(200)
      report(slug, 1, ~w(e4))
      second = build_conn() |> get("/t/#{slug}/live/5/all") |> html_response(200)
      refute first == second
      assert second =~ "lb-status-live"
    end

    test "an unknown or hidden tournament is the site's 404", %{conn: conn} do
      assert conn
             |> get("/t/no-such-#{System.unique_integer([:positive])}/live")
             |> html_response(404)

      slug = publish!()
      {:ok, _} = Moderation.hide(slug, %{email: "m@example.invalid"})
      assert conn |> get("/t/#{slug}/live") |> html_response(404)
      assert conn |> get("/t/#{slug}/live/5/1") |> html_response(404)
      assert conn |> get("/t/#{slug}/live/5/1/pgn") |> html_response(404)
    end
  end

  describe "the broadcast delay on the pages" do
    test "a game is behind by the delay, and appears when it has passed", %{conn: conn} do
      slug = publish!()
      {:ok, _} = LiveBoards.put_delay(slug, 10, "m@example.invalid")
      now = System.os_time(:millisecond)

      report(slug, 1, ~w(e4 e5), %{}, now_ms: now - :timer.minutes(5))
      report(slug, 2, ~w(d4 d5), %{}, now_ms: now - :timer.minutes(15))

      {:ok, view, html} = live(conn, "/t/#{slug}/live/5/all")
      assert html =~ "10 minutes behind"
      # Heard five minutes ago: not yet. Heard fifteen minutes ago: yes.
      assert has_element?(view, "#live-5-1.lb-status-waiting")
      assert has_element?(view, "#live-5-2.lb-status-live")

      {:ok, game, _html} = live(conn, "/t/#{slug}/live/5/1")
      assert has_element?(game, "#lb-not-started")
      refute has_element?(game, "#lb-moves")
    end

    test "only the plies that are old enough are in the move list and the PGN", %{conn: conn} do
      slug = publish!()
      {:ok, _} = LiveBoards.put_delay(slug, 10, "m@example.invalid")
      now = System.os_time(:millisecond)

      report(slug, 1, ~w(e4 e5), %{}, now_ms: now - :timer.minutes(20))
      report(slug, 1, ~w(e4 e5 Nf3 Nc6), %{}, now_ms: now - :timer.minutes(2))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      assert has_element?(view, "#lb-ply-2")
      refute has_element?(view, "#lb-ply-3")

      pgn = conn |> get("/t/#{slug}/live/5/1/pgn") |> response(200)
      assert pgn =~ "1. e4 e5 *"
      refute pgn =~ "Nf3"
    end

    test "the delay hides a move's clock with the move, in the game's PGN and the round's", %{
      conn: conn
    } do
      slug = publish!()
      {:ok, _} = LiveBoards.put_delay(slug, 10, "m@example.invalid")
      now = System.os_time(:millisecond)
      ago = fn minutes -> [now_ms: now - :timer.minutes(minutes)] end

      clocks = fn white, black, running ->
        %{"white_ms" => white, "black_ms" => black, "running" => running}
      end

      report(slug, 1, ~w(e4), clocks.(5_400_000, 5_400_000, "black"), ago.(21))
      # e5 told before its press: Black's clock still running in the report.
      report(slug, 1, ~w(e4 e5), clocks.(5_400_000, 5_395_000, "black"), ago.(20))
      # Inside the delay: the press (Black's clock with its increment), and
      # White's next move with White's clock.
      report(slug, 1, ~w(e4 e5), clocks.(5_400_000, 5_420_000, "white"), ago.(3))
      report(slug, 1, ~w(e4 e5 Nf3), clocks.(5_111_000, 5_420_000, "white"), ago.(2))

      for path <- ["/t/#{slug}/live/5/1/pgn", "/t/#{slug}/live/5/pgn"] do
        pgn = conn |> get(path) |> response(200)
        assert pgn =~ "1. e4 {[%clk 1:30:00]} 1... e5 {[%clk 1:29:55]} *"
        refute pgn =~ "Nf3"
        # Neither Nf3's clock nor what was said about Black's since.
        refute pgn =~ "1:25:11"
        refute pgn =~ "1:30:20"
      end

      # With no delay, all of it.
      {:ok, _} = LiveBoards.put_delay(slug, 0, "m@example.invalid")

      for path <- ["/t/#{slug}/live/5/1/pgn", "/t/#{slug}/live/5/pgn"] do
        pgn = conn |> get(path) |> response(200)
        assert pgn =~ "1... e5 {[%clk 1:30:20]} 2. Nf3 {[%clk 1:25:11]} *"
      end
    end

    test "changing the delay changes the page at once", %{conn: conn} do
      slug = publish!()
      now = System.os_time(:millisecond)
      report(slug, 1, ~w(e4), %{}, now_ms: now - :timer.minutes(1))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#live-5-1.lb-status-live")

      {:ok, _} = LiveBoards.put_delay(slug, 30, "m@example.invalid")
      settle(view)
      assert has_element?(view, "#live-5-1.lb-status-waiting")
    end
  end

  describe "the player bars" do
    defp with_time_control(text) do
      fn payload -> put_in(payload, ["tournament", "time_control"], text) end
    end

    test "carry the whole name, and the same facts for both colours", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")

      for colour <- ~w(white black) do
        name = view |> element("#lb-bar-#{colour} .lb-person") |> render()
        assert name =~ ~r/\p{L}+, \p{L}+/u
        refute name =~ "..."
      end
    end

    test "show the time control's base time, idle, before the first move", %{conn: conn} do
      slug = publish!(with_time_control("90 min + 30 s per move"))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")

      assert has_element?(view, "#lb-game-clock-white.is-idle", "1:30:00")
      assert has_element?(view, "#lb-game-clock-black.is-idle", "1:30:00")
      refute has_element?(view, "#lb-game-clock-white.is-running")
      refute has_element?(view, "#lb-bar-white.is-to-move")
    end

    test "show nothing when the time control gives no base time", %{conn: conn} do
      slug = publish!(with_time_control("40 moves in 90 minutes"))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      refute has_element?(view, "#lb-game-clock-white")

      slug = publish!(with_time_control(""))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      refute has_element?(view, "#lb-game-clock-white")
    end

    test "prefer a structured base time, and the clock's own reading over both", %{conn: conn} do
      slug = publish!(&put_in(&1, ["tournament", "time_control_minutes"], 15))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      assert has_element?(view, "#lb-game-clock-white.is-idle", "15:00")

      report(slug, 1, [], %{"white_ms" => 600_000, "black_ms" => 601_000})
      assert render(view) =~ "10:00"
      refute has_element?(view, "#lb-game-clock-white.is-idle")
      assert has_element?(view, "#lb-game-clock-black", "10:01")
    end

    test "a zero on the side that is not running is an unknown clock, not a flag fall", %{
      conn: conn
    } do
      slug = publish!()

      report(slug, 1, ~w(e4 e5), %{
        "white_ms" => 0,
        "black_ms" => 5_538_000,
        "running" => "white"
      })

      report(slug, 2, ~w(e4 e5 Nf3), %{
        "white_ms" => 0,
        "black_ms" => 5_538_000,
        "running" => "black"
      })

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/2")

      # Board 2: white's clock runs out only while it is running; black is the
      # one running here, so white's 0 is no reading at all.
      assert has_element?(view, "#lb-game-clock-white", "-:--")
      refute has_element?(view, "#lb-game-clock-white", "0:00")
      assert has_element?(view, "#lb-game-clock-black", ~r/1:32:1[78]/)

      # Board 1: the running side may truly be at zero - that one stays.
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      assert has_element?(view, "#lb-game-clock-white", "0:00")
      assert has_element?(view, "#lb-game-clock-black", ~r/1:32:1[78]/)
    end

    test "the name is whole text with a tooltip, so a cut-off one can still be read", %{
      conn: conn
    } do
      slug = publish!()
      report(slug, 1, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")

      for colour <- ~w(white black) do
        assert has_element?(view, "#lb-bar-#{colour} .lb-bar-name[title*=\",\"]")
        assert has_element?(view, "#lb-bar-#{colour} .lb-bar-meta .lb-rating")
      end
    end

    test "leave the step buttons where they are when you step back", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5 Nf3), %{"white_ms" => 1, "black_ms" => 1, "running" => "black"})
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")

      assert has_element?(view, ".lb-controls #lb-follow-slot")
      refute has_element?(view, "#lb-follow")

      view |> element("#lb-prev") |> render_click()

      assert has_element?(view, ".lb-controls #lb-follow-slot #lb-follow")
      assert has_element?(view, ".lb-controls > #lb-prev")
      assert has_element?(view, ".lb-controls > #lb-flip")
    end
  end

  describe "one game" do
    setup %{conn: conn} do
      slug = publish!()

      report(slug, 1, ~w(e4 e5 Nf3 Nc6), %{
        "white_ms" => 120_000,
        "black_ms" => 118_000,
        "running" => "white"
      })

      {:ok, view, html} = live(conn, "/t/#{slug}/live/5/1")
      {:ok, slug: slug, view: view, html: html}
    end

    test "shows the board, both players, the clocks and the moves", %{view: view} do
      assert has_element?(view, "#lb-game-board")
      assert has_element?(view, "#lb-game-status.lb-status-live")
      assert has_element?(view, "#lb-game-title", "board 1")
      assert has_element?(view, ".lb-player-white .lb-clock.is-running")
      assert has_element?(view, ".lb-player-black .lb-clock", "1:58")
      assert has_element?(view, "#lb-ply-1", "e4")
      assert has_element?(view, "#lb-ply-4.is-current", "Nc6")
      assert has_element?(view, "#lb-pgn[href$='/live/5/1/pgn']")
      refute has_element?(view, "#lb-follow")
    end

    test "clicking a move shows the position after it, and stops following", %{view: view} do
      before = render(element(view, "#lb-game-board"))
      view |> element("#lb-ply-2") |> render_click()

      assert has_element?(view, "#lb-ply-2.is-current")
      assert has_element?(view, "#lb-follow")
      refute render(element(view, "#lb-game-board")) == before
    end

    test "the arrow keys step, and the end of the game follows live again", %{view: view} do
      render_keydown(view, "key", %{"key" => "ArrowLeft"})
      assert has_element?(view, "#lb-ply-3.is-current")
      render_keydown(view, "key", %{"key" => "ArrowLeft"})
      assert has_element?(view, "#lb-ply-2.is-current")
      render_keydown(view, "key", %{"key" => "ArrowUp"})
      refute has_element?(view, ".lb-move.is-current")

      render_keydown(view, "key", %{"key" => "ArrowRight"})
      assert has_element?(view, "#lb-ply-1.is-current")
      render_keydown(view, "key", %{"key" => "End"})
      assert has_element?(view, "#lb-ply-4.is-current")
      refute has_element?(view, "#lb-follow")

      # Stepping past the last move is following the game.
      render_keydown(view, "key", %{"key" => "ArrowLeft"})
      render_keydown(view, "key", %{"key" => "ArrowRight"})
      assert has_element?(view, "#lb-ply-4.is-current")
      refute has_element?(view, "#lb-follow")
    end

    test "flipping the board turns it round, and f does the same", %{view: view} do
      assert has_element?(view, ".lb-board-column > .lb-player-black:first-child")
      view |> element("#lb-flip") |> render_click()
      assert has_element?(view, ".lb-board-column > .lb-player-white:first-child")
      render_keydown(view, "key", %{"key" => "f"})
      assert has_element?(view, ".lb-board-column > .lb-player-black:first-child")
    end

    test "a move that arrives is on the board, unless the viewer is looking back", %{
      slug: slug,
      view: view
    } do
      report(slug, 1, ~w(e4 e5 Nf3 Nc6 Bb5), %{"running" => "black"})
      settle(view)
      assert has_element?(view, "#lb-ply-5.is-current")

      view |> element("#lb-ply-2") |> render_click()
      report(slug, 1, ~w(e4 e5 Nf3 Nc6 Bb5 a6))
      settle(view)

      assert has_element?(view, "#lb-ply-6")
      assert has_element?(view, "#lb-ply-2.is-current")
      view |> element("#lb-follow") |> render_click()
      assert has_element?(view, "#lb-ply-6.is-current")
    end

    test "the end of a game: its result, and no follow button", %{slug: slug, view: view} do
      report(slug, 1, ~w(e4 e5 Nf3 Nc6), %{"status" => "finished", "result" => "1/2-1/2"})
      settle(view)

      assert has_element?(view, "#lb-game-status.lb-status-finished")
      assert has_element?(view, "#lb-game-result", "½-½")
      view |> element("#lb-ply-1") |> render_click()
      refute has_element?(view, "#lb-follow")
    end

    test "a dropped connection is said out loud, and only then", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")
      assert has_element?(view, "[role=status] > #lb-offline[hidden][phx-disconnected]")

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#lb-offline[hidden][phx-connected]")
    end

    test "a board that is not published says so", %{conn: conn, slug: slug} do
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/77")
      assert has_element?(view, "#lb-no-game")
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/x/1")
      assert has_element?(view, "#lb-unknown-round")
      assert has_element?(view, ~s(#lb-latest-round a[href="/t/#{slug}/live/5"]))
    end

    test "a game reported by position alone has a board and no move list", %{conn: conn} do
      slug = publish!()

      assert {:ok, _} =
               LiveBoards.ingest(slug, %{
                 "round" => 5,
                 "board" => 2,
                 "ply" => 7,
                 "fen" => "4k3/8/8/8/8/8/4P3/4K3 b - - 0 4"
               })

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/2")
      assert has_element?(view, "#lb-game-board")
      assert has_element?(view, "#lb-no-moves")
      assert has_element?(view, "#lb-prev[disabled]")
    end
  end

  describe "the broadcast" do
    defp player_name(no) do
      SnapshotPayloads.swiss()
      |> Map.fetch!("players")
      |> Enum.find(&(&1["no"] == no))
      |> Map.fetch!("name")
    end

    test "/live goes to the newest round, keeping ?pieces=", %{conn: conn} do
      slug = publish!()

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/t/#{slug}/live")
      assert to == "/t/#{slug}/live/5"

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/t/#{slug}/live?pieces=chessnut")

      assert to == "/t/#{slug}/live/5?pieces=chessnut"
    end

    test "the three columns are there, whatever the screen", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")

      for id <- ~w(#lb-broadcast #lb-rail #lb-stage #lb-side #lb-rounds #lb-pairings
                   #lb-pairings-toggle #lb-search #lb-event #lb-game-board #lb-view-switch) do
        assert has_element?(view, id), "missing #{id}"
      end

      assert has_element?(view, "#lb-pairings-toggle[aria-controls='lb-rail-panel']")
      assert has_element?(view, "#lb-switch-broadcast[aria-current='page']")
      assert has_element?(view, "#lb-switch-all[href='/t/#{slug}/live/5/all']")
    end

    test "a round opens on its first game in progress, marked in the list", %{conn: conn} do
      slug = publish!()
      report(slug, 3, ~w(e4 e5), %{"running" => "white"})

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")

      assert has_element?(view, "#lb-game-title", "board 3")
      assert has_element?(view, "#lb-pair-5-3 a.is-current[aria-current='true']")
      refute has_element?(view, "#lb-pair-5-1 a[aria-current]")
      assert has_element?(view, "#lb-pair-5-3 .lb-live-dot")
      for board <- 1..5, do: assert(has_element?(view, "#lb-pair-5-#{board}"))
    end

    test "a row of the list features its game, and the highlight moves", %{conn: conn} do
      slug = publish!()
      report(slug, 2, ~w(d4 d5 c4), %{"running" => "black"})

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      assert has_element?(view, "#lb-game-title", "board 1")

      view |> element("#lb-pair-5-2 a") |> render_click()
      assert_patch(view, "/t/#{slug}/live/5/2")

      assert has_element?(view, "#lb-game-title", "board 2")
      assert has_element?(view, "#lb-pair-5-2 a[aria-current='true']")
      refute has_element?(view, "#lb-pair-5-1 a[aria-current]")
      assert has_element?(view, "#lb-ply-3")
      assert has_element?(view, "#lb-bar-white .lb-person", player_name(3))
    end

    test "the round pills patch to another round", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")

      assert has_element?(view, "#lb-rounds a.lb-pill.is-current[aria-current='page']", "5")

      view |> element("#lb-rounds a", "1") |> render_click()
      assert_patch(view, "/t/#{slug}/live/1")

      assert has_element?(view, "#lb-rounds a[aria-current='page']", "1")
      assert has_element?(view, "#lb-pair-1-1")
      refute has_element?(view, "#lb-pair-5-1")
    end

    test "a team round lists its boards under their matches, with the score", %{conn: conn} do
      slug = unique_slug("teamlive")
      payload = put_in(SnapshotPayloads.team_swiss(), ["tournament", "slug"], slug)
      {:ok, _} = Snapshots.ingest(payload)

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/2")

      assert has_element?(view, "#lb-match-2-1 .lb-match-score", "2-1")
      assert has_element?(view, "#lb-match-2-2 .lb-match-score", "1½-1½")
      assert has_element?(view, "#lb-search-q[placeholder='Find a player or a team']")

      team = payload |> Map.fetch!("teams") |> Enum.find(&(&1["no"] == 3)) |> Map.fetch!("name")
      view |> element("#lb-search") |> render_change(%{"search" => %{"q" => team}})
      assert has_element?(view, "#lb-match-2-2")
      refute has_element?(view, "#lb-match-2-1")
    end

    test "the search keeps the rows whose player matches", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")

      view |> element("#lb-search") |> render_change(%{"search" => %{"q" => player_name(5)}})

      assert has_element?(view, "#lb-pair-5-2")
      refute has_element?(view, "#lb-pair-5-1")

      view |> element("#lb-search") |> render_change(%{"search" => %{"q" => "zzzz-nobody"}})
      refute has_element?(view, "[id^='lb-pair-']")
      assert has_element?(view, "#lb-pairings-empty")

      view |> element("#lb-search") |> render_change(%{"search" => %{"q" => ""}})
      for board <- 1..5, do: assert(has_element?(view, "#lb-pair-5-#{board}"))
    end

    test "figurines: a piece's move shows the set's piece and keeps its SAN", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5 Nf3 Nc6))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1?pieces=chessnut")

      assert has_element?(view, "table#lb-moves thead th[scope='col']")
      assert has_element?(view, "table#lb-moves tbody tr#lb-row-2 th[scope='row']", "2")
      assert has_element?(view, "#lb-ply-3 use[href='/pieces/chessnut.svg#wN']")
      assert has_element?(view, "#lb-ply-3 .visually-hidden", "Nf3")
      refute has_element?(view, "#lb-ply-1 use")
      assert has_element?(view, "#lb-ply-4.is-current[aria-current='step']")
    end
  end

  test "figurine parts: piece, square, promotion, castling" do
    alias OpenResultsWeb.LiveBoardsComponents, as: C

    assert C.figurine_parts("Nf3") == [{:piece, "N"}, {:text, "f3"}]
    assert C.figurine_parts("exd8=Q+") == [{:text, "exd8"}, {:piece, "Q"}, {:text, "+"}]
    assert C.figurine_parts("O-O-O") == [{:text, "O-O-O"}]
    assert C.figurine_parts("e4") == [{:text, "e4"}]
  end

  describe "a board published as unplayed" do
    defp with_result(board, result) do
      publish!(fn payload ->
        update_in(payload["rounds"], fn rounds ->
          Enum.map(rounds, fn
            %{"number" => 5} = round ->
              Map.update!(round, "boards", fn boards ->
                Enum.map(boards, fn
                  %{"board" => ^board} = b -> Map.put(b, "result", result)
                  b -> b
                end)
              end)

            round ->
              round
          end)
        end)
      end)
    end

    defp pieces_on(view, selector) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector <> " use.lb-pc")
      |> Enum.count()
    end

    test "a forfeit is a forfeit on the grid, not a game that never starts", %{conn: conn} do
      slug = with_result(4, "1-0FF")
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      assert has_element?(view, "#live-5-4.lb-status-forfeit .lb-badge", "Forfeit")
      assert has_element?(view, "#live-5-4 .lb-result", "1-0")
      assert has_element?(view, "#live-5-4 .lb-ff", "FF")
      assert has_element?(view, "#live-5-4 .lb-unplayed-note", "forfeit")
      assert has_element?(view, "#live-5-4 .lb-board-muted")
      assert pieces_on(view, "#live-5-4") == 0
      # Its neighbours are as they were.
      assert has_element?(view, "#live-5-3.lb-status-waiting")
      assert pieces_on(view, "#live-5-3") == 32
    end

    test "and in the broadcast: a muted board, a line, no controls", %{conn: conn} do
      slug = with_result(4, "0-1FF")
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/4")

      assert has_element?(view, "#lb-game-status.lb-status-forfeit", "Forfeit")
      assert has_element?(view, "#lb-game-result", "0-1")
      assert has_element?(view, "#lb-game-result .lb-ff")
      assert has_element?(view, "#lb-unplayed", "Not played - forfeit")
      assert has_element?(view, "#lb-game-board.lb-board-muted")
      assert pieces_on(view, "#lb-game-board") == 0
      refute has_element?(view, "#lb-not-started")
      refute has_element?(view, "#lb-first")
      assert has_element?(view, "#lb-score-white", "0")
      assert has_element?(view, "#lb-score-black", "1")
      assert has_element?(view, "#lb-pair-5-4 .lb-ff")
    end

    test "the published forfeit wins over anything a relay sends", %{conn: conn} do
      slug = with_result(4, "1-0FF")
      report(slug, 4, ~w(e4 e5))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      assert has_element?(view, "#live-5-4.lb-status-forfeit")
      assert pieces_on(view, "#live-5-4") == 0
    end

    test "a double forfeit says so", %{conn: conn} do
      slug = with_result(4, "0-0FF")
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/4")

      assert has_element?(view, "#lb-game-status.lb-status-double_forfeit", "Double forfeit")
      assert has_element?(view, "#lb-unplayed", "double forfeit")
    end

    test "the broadcast does not open on a forfeit when a game exists", %{conn: conn} do
      slug = with_result(1, "1-0FF")
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")

      refute has_element?(view, "#lb-game-title", "board 1")
      assert has_element?(view, "#lb-game-title", "board 2")
    end

    test "with the round's results withheld, only that the game is over", %{conn: conn} do
      slug =
        publish!(fn payload ->
          update_in(payload["rounds"], fn rounds ->
            Enum.map(rounds, fn
              %{"number" => 5} = round ->
                round
                |> Map.put("results_public", false)
                |> Map.update!("boards", fn boards ->
                  Enum.map(boards, fn
                    %{"board" => 4} = b -> Map.put(b, "result", "1-0FF")
                    b -> b
                  end)
                end)

              round ->
                round
            end)
          end)
        end)

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#live-5-4.lb-status-finished")
      refute has_element?(view, "#live-5-4 .lb-result")
      refute has_element?(view, "#live-5-4 .lb-ff")
    end
  end

  describe "the PGN download" do
    test "is the game with the tournament's headers", %{conn: conn} do
      slug = publish!()
      report(slug, 3, @opera, %{"status" => "finished", "result" => "1-0"})

      conn = get(conn, "/t/#{slug}/live/5/3/pgn")
      pgn = response(conn, 200)

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/x-chess-pgn"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment; filename="#{slug}-round5-board3.pgn")
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert pgn =~ ~s([Event "Gent Spring Open 2026"])
      assert pgn =~ ~s([Site "Ghent"])
      assert pgn =~ ~s([Round "5.3"])
      assert pgn =~ ~r/\[White "[^"]+"\]/
      assert pgn =~ ~r/\[WhiteElo "\d+"\]/
      assert pgn =~ ~s([Result "1-0"])
      assert pgn =~ "1. e4 e5 2. Nf3 d6"
      assert pgn =~ ~r/17\.\s+Rd8#\s+1-0/
    end

    test "carries the clock time of every move that was reported with one", %{conn: conn} do
      slug = publish!()

      clocks = fn white, black, running ->
        %{"white_ms" => white, "black_ms" => black, "running" => running}
      end

      report(slug, 3, ~w(e4), clocks.(5_400_000, 5_400_000, "black"))
      report(slug, 3, ~w(e4 e5), clocks.(5_400_000, 5_390_000, "white"))
      # Two moves in one report: the clocks are Nc6's.
      report(slug, 3, ~w(e4 e5 Nf3 Nc6), clocks.(5_381_000, 5_365_000, "white"))

      pgn = conn |> get("/t/#{slug}/live/5/3/pgn") |> response(200)

      assert pgn =~
               "1. e4 {[%clk 1:30:00]} 1... e5 {[%clk 1:29:50]} 2. Nf3 Nc6 {[%clk 1:29:25]} *"

      # A game reported without clocks is the file it always was.
      report(slug, 1, ~w(d4 d5))
      plain = conn |> get("/t/#{slug}/live/5/1/pgn") |> response(200)
      assert plain =~ "1. d4 d5 *"
      refute plain =~ "%clk"
    end

    test "leaves out the ratings the arbiter keeps off the pages", %{conn: conn} do
      slug = publish!(&put_in(&1, ["tournament", "display", "rating"], false))
      report(slug, 3, ~w(e4))

      pgn = conn |> get("/t/#{slug}/live/5/3/pgn") |> response(200)
      refute pgn =~ "Elo"
    end

    test "a board with no game is a 404", %{conn: conn} do
      slug = publish!()
      assert conn |> get("/t/#{slug}/live/5/3/pgn") |> response(404)
      assert conn |> get("/t/#{slug}/live/x/3/pgn") |> response(404)
    end
  end

  describe "the round as one PGN" do
    # The games of a document: a blank line, then the next game's first tag.
    defp games_of(pgn), do: String.split(pgn, ~r/\n\n(?=\[Event)/, trim: true)

    # The tags and the result of the game on one board, from the document.
    defp game_on(pgn, board),
      do: Enum.find(games_of(pgn), &(&1 =~ ~s([Round "5.#{board}"])))

    test "is every board of the round, in board order, as the per-game route writes them", %{
      conn: conn
    } do
      slug = publish!()
      report(slug, 3, @opera, %{"status" => "finished", "result" => "1-0"})
      report(slug, 1, ~w(e4 e5))

      conn = get(conn, "/t/#{slug}/live/5/pgn")
      pgn = response(conn, 200)

      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "application/x-chess-pgn"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]

      rounds = Regex.scan(~r/\[Round "(5\.\d)"\]/, pgn, capture: :all_but_first)
      assert List.flatten(rounds) == ~w(5.1 5.2 5.3 5.4 5.5)

      # Each game is exactly what its own route serves, blank-line separated.
      expected =
        for board <- 1..5 do
          cond do
            board in [1, 3] -> conn |> get("/t/#{slug}/live/5/#{board}/pgn") |> response(200)
            true -> nil
          end
        end

      for game <- Enum.reject(expected, &is_nil/1), do: assert(pgn =~ game)

      assert pgn =~ "1. e4 e5 *"
      refute pgn =~ "%clk"
      assert pgn =~ ~r/17\.\s+Rd8#\s+1-0/
      assert length(games_of(pgn)) == 5
    end

    test "every game carries its clock times, as its own route writes them", %{conn: conn} do
      slug = publish!()

      clocks = fn white, black, running ->
        %{"white_ms" => white, "black_ms" => black, "running" => running}
      end

      report(slug, 1, ~w(e4), clocks.(5_400_000, 5_400_000, "black"))
      report(slug, 1, ~w(e4 e5), clocks.(5_400_000, 5_390_000, "white"))
      # Told before the press: White's own clock still runs in the report.
      report(slug, 2, ~w(d4), clocks.(180_000, 180_000, "white"))
      report(slug, 4, ~w(c4 c5))

      pgn = conn |> get("/t/#{slug}/live/5/pgn") |> response(200)

      assert game_on(pgn, 1) =~ "1. e4 {[%clk 1:30:00]} 1... e5 {[%clk 1:29:50]} *"
      assert game_on(pgn, 2) =~ "1. d4 {[%clk 0:03:00]} *"
      assert game_on(pgn, 4) =~ "1. c4 c5 *"
      refute game_on(pgn, 4) =~ "%clk"
      refute game_on(pgn, 3) =~ "%clk"

      for board <- [1, 2, 4] do
        own = conn |> get("/t/#{slug}/live/5/#{board}/pgn") |> response(200)
        assert pgn =~ own
      end

      # The press, told at the same ply (two seconds of increment): the
      # move's clock is now the standing one, and the file's ETag moves.
      first = get(conn, "/t/#{slug}/live/5/pgn")
      [etag] = get_resp_header(first, "etag")
      report(slug, 2, ~w(d4), clocks.(182_000, 180_000, "black"))
      moved = conn |> put_req_header("if-none-match", etag) |> get("/t/#{slug}/live/5/pgn")
      assert response(moved, 200) =~ "1. d4 {[%clk 0:03:02]} *"
    end

    test "boards nobody played are header-only games with their result", %{conn: conn} do
      slug =
        publish!(fn payload ->
          update_in(payload["rounds"], fn rounds ->
            Enum.map(rounds, fn
              %{"number" => 5} = round ->
                Map.update!(round, "boards", fn boards ->
                  Enum.map(boards, fn
                    %{"board" => 4} = b -> Map.put(b, "result", "1-0FF")
                    %{"board" => 5} = b -> Map.put(b, "result", "0-0FF")
                    b -> b
                  end)
                end)

              round ->
                round
            end)
          end)
        end)

      pgn = conn |> get("/t/#{slug}/live/5/pgn") |> response(200)
      assert length(games_of(pgn)) == 5

      for {board, result} <- [{2, "*"}, {4, "1-0"}, {5, "*"}] do
        game = game_on(pgn, board)
        assert game =~ ~s([Result "#{result}"])
        assert game |> String.trim_trailing() |> String.ends_with?("]\n\n" <> result)
        refute game =~ "FF"
        refute game =~ ~r/\d\. /
      end
    end

    test "respects the broadcast delay, per game", %{conn: conn} do
      slug = publish!()
      {:ok, _} = LiveBoards.put_delay(slug, 10, "m@example.invalid")
      now = System.os_time(:millisecond)

      report(slug, 1, ~w(e4 e5), %{}, now_ms: now - :timer.minutes(20))
      report(slug, 1, ~w(e4 e5 Nf3 Nc6), %{}, now_ms: now - :timer.minutes(2))
      report(slug, 2, ~w(d4 d5), %{}, now_ms: now - :timer.minutes(2))

      pgn = conn |> get("/t/#{slug}/live/5/pgn") |> response(200)
      assert pgn =~ "1. e4 e5 *"
      refute pgn =~ "Nf3"
      refute pgn =~ "d4"
    end

    test "answers 304 to a matching If-None-Match, and a new ETag once the body moves", %{
      conn: conn
    } do
      slug = publish!()
      report(slug, 1, ~w(e4 e5))

      first = get(conn, "/t/#{slug}/live/5/pgn")
      assert [etag] = get_resp_header(first, "etag")
      assert response(first, 200) =~ "e4 e5"

      again = conn |> put_req_header("if-none-match", etag) |> get("/t/#{slug}/live/5/pgn")
      assert response(again, 304) == ""
      assert get_resp_header(again, "etag") == [etag]

      weak = conn |> put_req_header("if-none-match", "W/" <> etag) |> get("/t/#{slug}/live/5/pgn")
      assert response(weak, 304) == ""

      report(slug, 1, ~w(e4 e5 Nf3))

      moved = conn |> put_req_header("if-none-match", etag) |> get("/t/#{slug}/live/5/pgn")
      assert response(moved, 200) =~ "Nf3"
      assert get_resp_header(moved, "etag") != [etag]
    end

    test "sends no CORS headers, like the per-game route", %{conn: conn} do
      slug = publish!()
      round = get(conn, "/t/#{slug}/live/5/pgn")
      assert get_resp_header(round, "access-control-allow-origin") == []
      assert round.status == 200
    end

    test "is a 404 for an unknown or unpublished round, a hidden tournament, pairings off", %{
      conn: conn
    } do
      slug = publish!()
      assert conn |> get("/t/#{slug}/live/9/pgn") |> response(404)
      # The fixture's unpublished round.
      assert conn |> get("/t/#{slug}/live/4/pgn") |> response(404)
      assert conn |> get("/t/#{slug}/live/x/pgn") |> response(404)

      assert conn
             |> get("/t/no-such-#{System.unique_integer([:positive])}/live/5/pgn")
             |> response(404)

      off = publish!(&put_in(&1, ["tournament", "display", "pairings"], false))
      assert conn |> get("/t/#{off}/live/5/pgn") |> response(404)

      {:ok, _} = Moderation.hide(slug, %{email: "m@example.invalid"})
      assert conn |> get("/t/#{slug}/live/5/pgn") |> response(404)
    end

    test "does not swallow the board page or the per-game PGN", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/1")
      assert has_element?(view, "#lb-pgn[href$='/live/5/1/pgn']")
      assert conn |> get("/t/#{slug}/live/5/1/pgn") |> response(200) =~ "1. e4 e5 *"
    end

    test "is linked from the broadcast page and the all-boards page", %{conn: conn} do
      slug = publish!()

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5")
      assert has_element?(view, "#lb-round-pgn[href$='/live/5/pgn']")

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#lb-round-pgn[href$='/live/5/pgn']")
    end
  end

  describe "the hall display" do
    test "skips the live view until a game is in progress", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/hall?views=live")

      assert has_element?(view, "#hall-idle")
      refute has_element?(view, "#hall-live")
    end

    test "shows the games in progress as they start, and drops one that finishes", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/hall?views=live")

      report(slug, 2, ~w(e4 e5), %{
        "white_ms" => 60_000,
        "black_ms" => 60_000,
        "running" => "white"
      })

      settle(view)

      assert has_element?(view, "#hall-live")
      assert has_element?(view, "#live-5-2.lb-tile-hall .lb-clock")
      assert has_element?(view, "#hall-view-name", "Live boards")

      report(slug, 2, ~w(e4 e5), %{"status" => "finished", "result" => "1/2-1/2"})
      settle(view)
      refute has_element?(view, "#hall-live")
    end

    test "four games a page", %{conn: conn} do
      slug = publish!()
      for board <- 1..5, do: report(slug, board, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/hall?views=live")

      tiles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(".lb-tile-hall")
        |> LazyHTML.attribute("id")

      assert length(tiles) == 4
      assert has_element?(view, "#hall-page", "Page 1 of 2")
    end

    test "the arbiter can switch it off", %{conn: conn} do
      slug = publish!(&put_in(&1, ["tournament", "hall"], %{"live" => false}))
      report(slug, 1, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/hall?views=live")

      refute has_element?(view, "#hall-live")
    end

    test "it is a cycle view like the others, in the default hall", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4))
      {:ok, view, _html} = live(conn, "/t/#{slug}/hall")

      seen =
        for _ <- 1..8 do
          %{view: name, cycle: cycle} = hall_state(view)
          send(view.pid, {:advance, cycle})
          settle(view)
          name
        end

      assert "live" in seen
    end
  end

  describe "the static pages link to it only on the arbiter's word" do
    test "a snapshot that says live_boards: true gets a chip, and one that does not gets none", %{
      conn: conn
    } do
      with_flag = publish!(&put_in(&1, ["tournament", "live_boards"], true))
      without = publish!()

      assert conn |> get("/t/#{with_flag}") |> html_response(200) =~ ~s(id="live-boards-link")
      refute build_conn() |> get("/t/#{without}") |> html_response(200) =~ "live-boards-link"
    end
  end

  describe "piece sets" do
    defp piece_hrefs(view, selector) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")
    end

    test "the round page draws with the default set and points at its sprite", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")

      hrefs = piece_hrefs(view, "#live-5-1 use.lb-pc")
      assert length(hrefs) == 32
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/pieces/cburnett.svg#"))
      assert "/pieces/cburnett.svg#wK" in hrefs
      refute has_element?(view, ".lb-sprite")
    end

    test "?pieces= picks a set and an unknown one falls back to the default", %{conn: conn} do
      slug = publish!()

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all?pieces=chessnut")
      assert "/pieces/chessnut.svg#bQ" in piece_hrefs(view, "#live-5-1 use.lb-pc")

      # A set that is no longer shipped is an unknown one: a bookmarked
      # `?pieces=merida` draws the default.
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all?pieces=merida")
      hrefs = piece_hrefs(view, "#live-5-1 use.lb-pc")
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/pieces/cburnett.svg#"))

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all?pieces=../../etc/passwd")
      hrefs = piece_hrefs(view, "#live-5-1 use.lb-pc")
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/pieces/cburnett.svg#"))
    end

    test "the picker re-draws the grid and the game page with the chosen set", %{conn: conn} do
      slug = publish!()

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#lb-pieces-picker")
      render_hook(view, "pieces", %{"set" => "chessnut"})
      assert "/pieces/chessnut.svg#wP" in piece_hrefs(view, "#live-5-3 use.lb-pc")

      # Junk is ignored; the set stays.
      render_hook(view, "pieces", %{"set" => "nope"})
      assert "/pieces/chessnut.svg#wP" in piece_hrefs(view, "#live-5-3 use.lb-pc")

      {:ok, game, _html} = live(conn, "/t/#{slug}/live/5/1")
      render_hook(game, "pieces", %{"set" => "chessnut"})
      assert "/pieces/chessnut.svg#wK" in piece_hrefs(game, "#lb-game-board use.lb-pc")
    end

    test "the hall display honours ?pieces= and has no picker", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5), %{"white_ms" => 300_000, "black_ms" => 300_000})

      {:ok, view, _html} = live(conn, "/t/#{slug}/hall?views=live&pieces=chessnut")
      hrefs = piece_hrefs(view, "use.lb-pc")
      assert hrefs != []
      assert Enum.all?(hrefs, &String.starts_with?(&1, "/pieces/chessnut.svg#"))
      refute has_element?(view, "#lb-pieces-picker")
    end
  end
end
