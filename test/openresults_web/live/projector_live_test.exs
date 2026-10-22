defmodule OpenResultsWeb.ProjectorLiveTest do
  @moduledoc """
  The projector: the dialog that chooses the boards and writes the address,
  and the screen behind that address - only the chosen games, each with
  names, Elo, points and clocks, and in the automatic mode a finished game
  that leaves after its result has been on screen and an end screen once
  nothing is left.

  The half minute a result stays up is not waited out: the test sends the
  page the message its own timer would (`{:drop, board}`), after checking
  the timer's state the page is in.
  """

  use OpenResultsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]

  alias OpenResults.LiveBoards
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.ProjectorLive
  alias OpenResultsWeb.Tournament

  # The swiss fixture with round 5 freshly paired - no result in yet.
  defp publish!(tweak \\ & &1) do
    slug = unique_slug("proj")

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

  defp report(slug, board, moves, extra \\ %{}) do
    params = Map.merge(%{"round" => 5, "board" => board, "moves" => moves}, extra)
    assert {:ok, _} = LiveBoards.ingest(slug, params)
  end

  defp settle(view), do: _ = :sys.get_state(view.pid)

  defp boards_of_round_5(slug) do
    payload = OpenResults.Tournaments.public_latest(slug).payload
    payload |> Tournament.round(5) |> Tournament.boards() |> Enum.map(& &1["board"])
  end

  describe "the picker" do
    test "is on the broadcast and the All boards pages, lists the round, builds the address",
         %{conn: conn} do
      slug = publish!()
      boards = boards_of_round_5(slug)

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/all")
      assert has_element?(view, "#projector-button")
      refute has_element?(view, "#projector-picker")

      view |> element("#projector-button") |> render_click()
      assert has_element?(view, "#projector-picker [role=dialog]")
      for b <- boards, do: assert(has_element?(view, "#projector-board-#{b}[checked]"))
      assert has_element?(view, "#projector-auto[checked]")

      # Everything chosen: no list in the address, which means every board.
      assert has_element?(
               view,
               ~s(#projector-open[href="/t/#{slug}/live/5/projector?auto=1&pieces=cburnett"])
             )

      view
      |> form("#projector-form", %{
        "projector" => %{"boards" => ["", "1", "3"], "auto" => "false"}
      })
      |> render_change()

      assert has_element?(
               view,
               ~s(#projector-open[href="/t/#{slug}/live/5/projector?boards=1,3&auto=0&pieces=cburnett"])
             )

      view |> element("#projector-none") |> render_click()
      refute has_element?(view, "#projector-open")
      assert has_element?(view, "#projector-pick-one")

      view |> element("#projector-all") |> render_click()
      assert has_element?(view, "#projector-open")

      view |> element("#projector-close") |> render_click()
      refute has_element?(view, "#projector-picker")
    end

    test "on the broadcast page, with the piece set in use", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5?pieces=chessnut")

      view |> element("#projector-button") |> render_click()

      view
      |> form("#projector-form", %{"projector" => %{"boards" => ["", "2"], "auto" => "true"}})
      |> render_change()

      assert has_element?(
               view,
               ~s(#projector-open[href="/t/#{slug}/live/5/projector?boards=2&auto=1&pieces=chessnut"][target=_blank])
             )
    end
  end

  describe "the projector" do
    test "shows only the chosen boards, with names, Elo, points and clocks", %{conn: conn} do
      slug = publish!()

      report(slug, 1, ~w(e4 e5 Nf3), %{
        "white_ms" => 300_000,
        "black_ms" => 290_000,
        "running" => "black"
      })

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?boards=1,3&pieces=chessnut")

      assert has_element?(view, "#proj-1")
      assert has_element?(view, "#proj-3")
      refute has_element?(view, "#proj-2")
      refute has_element?(view, "#proj-4")

      # Black on top, White below; each with its name, Elo, points and clock.
      for colour <- ~w(white black) do
        assert has_element?(view, "#proj-1-#{colour}-name")
        assert has_element?(view, "#proj-1-#{colour}-points")
        assert has_element?(view, "#proj-1-clock-#{colour}")
      end

      # The running clock has moved on by the time the page reads it.
      assert has_element?(view, "#proj-1-clock-black.is-running")
      assert has_element?(view, "#proj-1-clock-white", "5:00")
      assert has_element?(view, "#proj-1-black.is-to-move")
      # The last move is marked, and drawn with the chosen set.
      assert has_element?(view, "#proj-1-board .lb-sq-last")
      assert has_element?(view, "#proj-1-board use[href^='/pieces/chessnut.svg']")
      # Nothing to step through.
      refute has_element?(view, "#lb-moves")
      refute has_element?(view, "#lb-prev")
      refute has_element?(view, ".masthead-bar")
      assert has_element?(view, "#proj-fullscreen")
    end

    test "Elo and points are the published ones going into the round", %{conn: conn} do
      slug = publish!()
      payload = OpenResults.Tournaments.public_latest(slug).payload
      board = payload |> Tournament.round(5) |> Tournament.boards() |> hd()
      scores = Tournament.scores_before(payload, 5)
      white = Map.get(Tournament.players_by_no(payload), board["white"])

      {:ok, view, _html} =
        live(conn, "/t/#{slug}/live/5/projector?boards=#{board["board"]}")

      expected = OpenResultsWeb.TournamentHTML.number(scores[board["white"]]) || "-"
      assert has_element?(view, "#proj-#{board["board"]}-white-points", expected)

      if white["rating"] do
        assert has_element?(
                 view,
                 "#proj-#{board["board"]}-white-elo",
                 to_string(white["rating"])
               )
      end
    end

    test "points are left out when the arbiter keeps pairing scores off", %{conn: conn} do
      slug =
        publish!(fn payload ->
          put_in(payload, ["tournament", "display"], %{"pairing_scores" => false})
        end)

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector")
      assert has_element?(view, "#proj-1-white-name")
      refute has_element?(view, "#proj-1-white-points")
    end

    test "no list, a junk list or boards the round does not have: every board", %{conn: conn} do
      slug = publish!()
      boards = boards_of_round_5(slug)

      for query <- ["", "?boards=", "?boards=abc,-2", "?boards=99,100"] do
        {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector" <> query)
        for b <- boards, do: assert(has_element?(view, "#proj-#{b}"), "#{query}: board #{b}")
      end

      # Junk among good numbers is simply dropped.
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?boards=2,x,%201")
      assert has_element?(view, "#proj-1")
      assert has_element?(view, "#proj-2")
      refute has_element?(view, "#proj-3")
    end

    test "an unpublished round says so", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/42/projector")
      assert has_element?(view, "#proj-unknown-round")
      # The hall screen says when it has stopped hearing moves.
      assert has_element?(view, "#proj-offline[hidden][phx-disconnected]")
      refute has_element?(view, ".proj-tile")
    end

    test "the old projector address is still the pairings screen", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/projector")
      assert has_element?(view, "#hall[data-screen=projector]")
    end

    test "the server's first grid is the one that gives the largest board" do
      assert ProjectorLive.best_grid(1) == {1, 1}
      assert ProjectorLive.best_grid(3) == {3, 1}
      assert ProjectorLive.best_grid(8) == {4, 2}
      assert ProjectorLive.best_grid(0) == {1, 1}
      assert ProjectorLive.parse_boards("3, 1,x,3,0") == [3, 1]
    end
  end

  describe "the automatic mode" do
    test "leaves out forfeits and games already over", %{conn: conn} do
      slug = with_result(4, "1-0FF")
      report(slug, 3, ~w(e4 e5), %{"status" => "finished", "result" => "1/2-1/2"})

      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?auto=1")
      refute has_element?(view, "#proj-4")
      refute has_element?(view, "#proj-3")
      assert has_element?(view, "#proj-1")
      assert has_element?(view, "#proj[data-count='#{length(boards_of_round_5(slug)) - 2}']")
    end

    test "a game that ends keeps its tile with the result, then the tile goes", %{conn: conn} do
      slug = publish!()
      report(slug, 1, ~w(e4 e5))
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?boards=1,2")

      report(slug, 1, ~w(e4 e5 Qh5), %{"status" => "finished", "result" => "1-0"})
      settle(view)

      assert has_element?(view, "#proj-1 .proj-tile.is-leaving")
      assert has_element?(view, "#proj-1-result", "1-0")
      assert has_element?(view, "#proj[data-count='2']")

      # The page's own timer would send this after `hold_ms/0`.
      send(view.pid, {:drop, 1})
      settle(view)

      refute has_element?(view, "#proj-1")
      assert has_element?(view, "#proj-2")
      assert has_element?(view, "#proj[data-count='1']")
      refute has_element?(view, "#proj-end")

      # A stray drop for a game still being played does nothing.
      send(view.pid, {:drop, 2})
      settle(view)
      assert has_element?(view, "#proj-2")
    end

    test "when every chosen game is over: the end screen and the results", %{conn: conn} do
      slug = publish!()
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?boards=1,2&auto=1")

      report(slug, 1, ~w(e4 e5), %{"status" => "finished", "result" => "1-0"})
      report(slug, 2, ~w(d4 d5), %{"status" => "finished", "result" => "1/2-1/2"})
      settle(view)
      refute has_element?(view, "#proj-end")

      send(view.pid, {:drop, 1})
      send(view.pid, {:drop, 2})
      settle(view)

      assert has_element?(view, "#proj-end")
      assert has_element?(view, "#proj-end-1", "1-0")
      assert has_element?(view, "#proj-end-2", "½-½")
      refute has_element?(view, ".proj-tile")
    end

    test "opening on a round whose chosen games are all over goes straight to the end screen",
         %{conn: conn} do
      slug = publish!()
      report(slug, 2, ~w(d4 d5), %{"status" => "finished", "result" => "0-1"})
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?boards=2")
      assert has_element?(view, "#proj-end-2", "0-1")
    end
  end

  describe "without the automatic mode" do
    test "a finished game and a forfeit stay, with their results", %{conn: conn} do
      slug = with_result(4, "1-0FF")
      {:ok, view, _html} = live(conn, "/t/#{slug}/live/5/projector?auto=0&boards=1,4")

      assert has_element?(view, "#proj-4")
      assert has_element?(view, "#proj-4-result", "1-0")

      report(slug, 1, ~w(e4 e5), %{"status" => "finished", "result" => "0-1"})
      settle(view)

      assert has_element?(view, "#proj-1-result", "0-1")
      refute has_element?(view, "#proj-1 .is-leaving")
      send(view.pid, {:drop, 1})
      settle(view)
      assert has_element?(view, "#proj-1")
      refute has_element?(view, "#proj-end")
    end
  end
end
