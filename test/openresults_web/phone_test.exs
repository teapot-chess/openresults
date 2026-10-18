defmodule OpenResultsWeb.PhoneTest do
  @moduledoc """
  The parts of the phone layout a server-rendered page can prove: the
  viewport, the search that is on every table page, and the classes the
  stylesheet's phone rules hang on. The rules themselves are read out of
  `assets/css/app.css`, the way `contrast_test.exs` reads the tokens - a
  rename on either side fails here rather than quietly dropping a phone
  layout.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots}

  @css Path.expand("../../assets/css/app.css", __DIR__)

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp doc(conn), do: LazyHTML.from_document(html_response(conn, 200))

  defp present?(document, selector),
    do: not (document |> LazyHTML.query(selector) |> Enum.empty?())

  defp hiding(payload, keys) do
    update_in(payload, ["tournament", "display"], fn display ->
      Enum.reduce(keys, display, &Map.put(&2, &1, false))
    end)
  end

  # Comments out, so a selector named in prose never counts as a rule.
  defp stylesheet, do: Regex.replace(~r{/\*.*?\*/}s, File.read!(@css), "")

  test "the viewport reaches the screen's edges and the page keeps clear of them", %{conn: conn} do
    slug = publish(SnapshotPayloads.swiss())

    [content] =
      conn
      |> get(~p"/t/#{slug}")
      |> doc()
      |> LazyHTML.query("meta[name=viewport]")
      |> LazyHTML.attribute("content")

    assert content =~ "width=device-width"
    assert content =~ "viewport-fit=cover"
    # Zoom is never taken away: a reader who needs bigger type pinches.
    refute content =~ "user-scalable"
    refute content =~ "maximum-scale"
    assert stylesheet() =~ "env(safe-area-inset-left"
  end

  describe "finding your own name" do
    test "every table page has the player search", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      for path <- [~p"/t/#{slug}", ~p"/t/#{slug}/round/1", ~p"/t/#{slug}/crosstable"] do
        document = conn |> get(path) |> doc()
        assert present?(document, "#filter-bar #player-search[type=search][name=q]"), path
      end
    end

    test "a round with nothing to filter by still offers the search", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> hiding(["club", "federation", "category"])
        |> put_in(["tournament", "categories"], [])
        |> publish()

      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert present?(document, "#player-search")
      # No empty disclosure beside it.
      refute present?(document, "details.filter-disclosure")
    end

    test "searching a round keeps the matching board and marks the seat", %{conn: conn} do
      payload = SnapshotPayloads.swiss()
      slug = publish(payload)
      [round | _] = payload["rounds"]
      board = hd(round["boards"])
      name = Enum.find(payload["players"], &(&1["no"] == board["white"]))["name"]

      document = conn |> get(~p"/t/#{slug}/round/#{round["number"]}?#{[q: name]}") |> doc()

      assert present?(document, "#board-#{board["board"]} td.seat.pairing-match")
    end

    test "the search bar stays on screen on a phone", _context do
      css = stylesheet()

      assert css =~
               ~r/@media screen and \(max-width: 48rem\)\s*\{\s*\.filter-bar\s*\{[^}]*position:\s*sticky/
    end
  end

  describe "the pairings on a phone" do
    test "the ratings and points going in are the columns a phone drops", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert present?(document, "table.pairings th.col-rating")
      assert present?(document, "table.pairings td.col-rating")
      assert present?(document, "table.pairings th.col-pts")
      assert present?(document, "table.pairings td.col-pts")

      assert document
             |> LazyHTML.query("table.pairings > tbody > tr:first-child > td.seat")
             |> Enum.count() == 2

      assert stylesheet() =~
               ~r/\.pairings \.col-rating,\s*\.pairings \.col-pts\s*\{\s*display:\s*none/
    end
  end

  describe "touch and type" do
    test "no text box is under 16px where iOS would zoom on it" do
      css = stylesheet()

      [_, block] =
        Regex.run(
          ~r/@media screen and \(pointer: coarse\), screen and \(max-width: 40rem\)\s*\{(.*?)\}\s*\}/s,
          css
        )

      for selector <- [
            ".index-search-input",
            ".filter-search-input",
            ".field textarea",
            ".fide-search input"
          ] do
        assert block =~ selector, selector
      end

      assert block =~ ~r/font-size:\s*1rem/
    end

    test "controls a finger uses are at least 44px on a touch screen" do
      css = stylesheet()
      [_, block] = Regex.run(~r/@media screen and \(pointer: coarse\)\s*\{(.*?)\n\}/s, css)

      for selector <- [
            ".chip",
            ".filter-summary",
            ".theme-picker-trigger",
            ".card-close",
            ".lang-opt"
          ] do
        assert block =~ selector, selector
      end

      assert block =~ "min-height: 2.75rem"
    end
  end

  describe "the second pass" do
    test "the rounds swipe on one line, the current one marked", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      assert present?(document, "nav.rounds > #round-strip > a.chip.current[aria-current=page]")
      # The page links stay outside it, in the wrapping line.
      refute present?(document, "#round-strip a[href='/t/#{slug}']")

      assert stylesheet() =~ ~r/\.round-strip\s*\{\s*display:\s*contents/
      assert stylesheet() =~ ~r/\.rounds \.round-strip\s*\{[^}]*overflow-x:\s*auto/
    end

    test "a board has the hooks the stacked phone layout hangs on", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()

      row = "#pairings > tbody > tr:first-child"
      assert present?(document, "#{row} > th.col-bd")
      assert present?(document, "#{row} > td.seat.seat-white")
      assert present?(document, "#{row} > td.col-result")
      assert present?(document, "#{row} > td.seat.seat-black")

      assert stylesheet() =~ ~r/grid-template-areas:\s*"bd white res"\s*"bd black res"/
      # Never the projector's table, which has its own idea of a screen.
      assert stylesheet() =~ ".pairings:not(.projector-pairings) > tbody > tr:not(.match-head)"
    end

    test "the columns a phone hides are said under the name, opt-in ones too", %{conn: conn} do
      payload =
        SnapshotPayloads.swiss()
        |> update_in(["players"], fn players -> Enum.map(players, &Map.put(&1, "sex", "F")) end)
        |> update_in(["standings", "rows"], fn rows ->
          Enum.map(rows, &(&1 |> Map.put("performance", 2400) |> Map.put("rounds_played", 3)))
        end)

      slug = publish(payload)
      document = conn |> get(~p"/t/#{slug}") |> doc()

      [meta | _] =
        document
        |> LazyHTML.query("table.standings > tbody > tr > th.row-head > .row-meta")
        |> Enum.map(&LazyHTML.text/1)

      assert meta =~ "F"
      assert meta =~ "Rds 3"
      assert meta =~ "Perf. 2400"

      css = stylesheet()

      for column <- ~w(col-rating col-sex col-cat col-rds col-perf) do
        assert css =~ ".standings .#{column}", column
      end

      assert css =~ ~r/\.standings \.row-meta\s*\{\s*display:\s*block/
    end

    test "a row whose hidden columns are all empty carries no line", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> hiding(["rating", "category"])
        |> publish()

      document = conn |> get(~p"/t/#{slug}") |> doc()
      refute present?(document, ".row-meta")
    end

    test "a player's round-by-round table drops to what fits", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert present?(document, "table.card td.col-colour > .colour-mark")
      assert present?(document, "table.card td.col-colour > .colour-word")
      assert present?(document, "table.card td.col-no")
      assert stylesheet() =~ ~r/\.card \.col-no,/
    end
  end

  describe "following a player" do
    test "the standings and a round carry an empty, hidden pin", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      for path <- [~p"/t/#{slug}", ~p"/t/#{slug}/round/1"] do
        document = build_conn() |> get(path) |> doc()

        assert present?(document, "#follow-pin[hidden][data-follow-pin='#{slug}']"), path
        assert present?(document, "#follow-pin [data-follow-rows]"), path
        assert present?(document, "#follow-pin #follow-stop[data-follow-stop]"), path
        # Empty: what goes in it is this visitor's business, not the page's.
        assert document |> LazyHTML.query("#follow-pin tr") |> Enum.empty?(), path
      end

      _ = conn
    end

    test "a player's page offers the switch, hidden until the script shows it", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/player/1") |> doc()

      assert present?(
               document,
               "#player-heading #follow-player[hidden][data-follow-slug='#{slug}'][data-follow-no='1']"
             )

      # In the heading row, marked so the right-click peek (which lifts
      # #player-summary) strips it rather than carrying a second switch.
      assert present?(document, "#player-summary #player-actions[data-peek-hide] #follow-player")
    end

    test "no pin where names are not links, since nothing could be found", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["player_cards"]) |> publish()
      document = conn |> get(~p"/t/#{slug}") |> doc()

      refute present?(document, "#follow-pin")
    end

    test "the script keeps the choice per tournament and survives storage that throws", %{
      conn: conn
    } do
      slug = publish(SnapshotPayloads.swiss())
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      assert html =~ ~s("openresults:follow:" + slug)
      assert html =~ ~r/try \{ return localStorage\.getItem\(key\(slug\)\); \} catch/
    end

    test "the cross-table carries the hook the followed row is marked by", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}/crosstable") |> doc()

      assert present?(document, "table.crosstable[data-follow-table='#{slug}']")
      assert present?(document, "table.crosstable tbody th.row-head a.player[data-player='1']")
      # Marked by the script alone: nothing followed arrives in the bytes.
      refute present?(document, "table.crosstable tr.is-followed")

      html = conn |> get(~p"/t/#{slug}/crosstable") |> html_response(200)
      assert html =~ "table.crosstable[data-follow-table]"
      assert stylesheet() =~ ~r/tr\.is-followed > \*/
    end
  end

  describe "the masthead's facts on a phone" do
    test "stay on one line, clipped rather than removed", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert present?(document, "header.masthead p.details")

      assert stylesheet() =~
               ~r/\.masthead \.details \{[^}]*white-space: nowrap;[^}]*text-overflow: ellipsis/s
    end
  end
end
