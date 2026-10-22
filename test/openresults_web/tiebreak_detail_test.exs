defmodule OpenResultsWeb.TiebreakDetailTest do
  @moduledoc """
  A tiebreak value on the standings table, opened to its own per-round
  working.

  `<details>`/`<summary>` rather than anything scripted: the whole point of
  the markup choice is that it needs no JavaScript to open or close, by tap
  or by keyboard, which this file proves by never running any and getting a
  working disclosure anyway. `test/openresults_web/tiebreak_working_test.exs`
  already covers the CONTENT of a working block on the player page in full;
  this file is about where else it now appears and when it does not.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots, Takedown}
  alias OpenResultsWeb.Tournament

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp hiding(payload, keys) do
    display = Map.new(keys, &{&1, false})
    put_in(payload, ["tournament", "display"], display)
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  describe "OpenResultsWeb.Tournament.working_for_row/1" do
    test "agrees with working/2, for the row that function would have found" do
      swiss = SnapshotPayloads.swiss()

      for row <- Tournament.standings_rows(swiss) do
        assert Tournament.working_for_row(row) == Tournament.working(swiss, row["player"])
      end
    end

    test "a row with no working field reads as empty, not an error" do
      assert Tournament.working_for_row(%{"player" => 1}) == %{}
    end

    test "a team row's working - a bare list of parts, as OpenPairings sends it - keeps its parts" do
      payload = SnapshotPayloads.team_round_robin()
      [row | _] = Tournament.team_standings_rows(payload)
      [{code, parts} | _] = Map.to_list(row["working"])
      assert is_list(parts) and parts != []

      assert %{^code => %{"total" => nil, "parts" => ^parts}} =
               Tournament.team_working(payload, row["team"])
    end
  end

  describe "a tiebreak this tournament published working for" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, document: conn |> get(~p"/t/#{slug}") |> doc(), slug: slug}
    end

    test "opens with <details> and <summary>, natively - no script required", %{
      document: document
    } do
      first_row = document |> LazyHTML.query("table.standings > tbody > tr:first-child")
      details = LazyHTML.query(first_row, "td.tb-cell details.tb-detail")

      # Buchholz Cut-1, Buchholz and Sonneborn-Berger all carry working in
      # the fixture; Progressive score, the fourth column, does not - see
      # the next describe block.
      assert Enum.count(details) == 3
    end

    test "the summary shows the same number the column always showed", %{document: document} do
      first_row = document |> LazyHTML.query("table.standings > tbody > tr:first-child")
      summaries = texts(first_row, "td.tb-cell details.tb-detail summary")

      assert Enum.any?(summaries, &String.starts_with?(&1, "1 "))
      assert Enum.any?(summaries, &String.starts_with?(&1, "1.5 "))
    end

    test "opened, it carries the same per-round rows the player page shows in full", %{
      document: document,
      slug: slug
    } do
      first_row = document |> LazyHTML.query("table.standings > tbody > tr:first-child")
      cell = LazyHTML.query(first_row, "td.tb-cell") |> Enum.at(0)
      no = first_row |> LazyHTML.query("a.player") |> LazyHTML.attribute("data-player") |> hd()

      rows = texts(cell, "table.tb-working tbody tr")
      player_page = build_conn() |> get(~p"/t/#{slug}/player/#{no}") |> doc()
      full_rows = texts(player_page, ".working-block:first-of-type table.working-table tbody tr")

      assert rows == full_rows
      assert rows != []
    end

    test "a discarded contribution still carries its tag inside the detail", %{
      document: document
    } do
      first_row = document |> LazyHTML.query("table.standings > tbody > tr:first-child")
      cell = LazyHTML.query(first_row, "td.tb-cell") |> Enum.at(0)

      assert texts(cell, "table.tb-working") |> Enum.any?(&(&1 =~ "discarded"))
    end
  end

  describe "a tiebreak with no published working" do
    test "renders as a plain number, with no <details> to open", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}") |> doc()

      # Progressive score (PS) is the fixture's fourth tiebreak and carries
      # no `working` on any row.
      last_cell =
        document
        |> LazyHTML.query("table.standings > tbody > tr:first-child > td.tb-cell")
        |> Enum.at(3)

      assert LazyHTML.query(last_cell, "details") |> Enum.empty?()
      assert LazyHTML.text(last_cell) |> String.trim() == "3"
    end
  end

  describe "the display-rule leak case" do
    test "display.tiebreak_working off leaves the values but no working to open", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["tiebreak_working"]) |> publish()
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert document |> LazyHTML.query("details.tb-detail") |> Enum.empty?()

      # The tick hides the WORKING, not the arithmetic the standings already
      # published - the same distinction `display.tiebreaks` itself draws.
      values = texts(document, "table.standings > tbody > tr:first-child > td.tb-cell")
      assert values == ["1", "1.5", "1.5", "3"]
    end

    test "display.tiebreaks off leaves nothing to leak either", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["tiebreaks"]) |> publish()
      document = conn |> get(~p"/t/#{slug}") |> doc()

      assert document |> LazyHTML.query("details.tb-detail") |> Enum.empty?()
      assert document |> LazyHTML.query("td.tb-cell") |> Enum.empty?()
    end

    test "absent means shown, like every other display key" do
      payload =
        update_in(
          SnapshotPayloads.swiss(),
          ["tournament", "display"],
          &Map.delete(&1, "tiebreak_working")
        )

      assert Tournament.show?(payload, "tiebreak_working")
    end

    test "a short row with working for a column it sent no value for stays closed", %{
      conn: conn
    } do
      # Only Buchholz Cut-1 (index 0) is kept. Buchholz and Sonneborn-Berger
      # (indexes 1 and 2) still carry working in the fixture, but the row now
      # sends no VALUE for either - the shape a client cutting columns short
      # produces.
      short =
        SnapshotPayloads.swiss()
        |> update_in(["standings", "rows", Access.at(0), "tiebreaks"], &Enum.take(&1, 1))
        |> put_in(["tournament", "slug"], "short-row")

      {:ok, _} = Snapshots.ingest(short)

      document = conn |> get(~p"/t/short-row") |> doc()
      cells = document |> LazyHTML.query("table.standings > tbody > tr:first-child > td.tb-cell")

      # The kept column still has both a value and working, and opens as
      # usual - the control that proves the next line means something.
      assert LazyHTML.query(Enum.at(cells, 0), "details") |> Enum.count() == 1

      # The two truncated columns have working but no value: explaining a
      # blank would be explaining nothing.
      assert LazyHTML.query(Enum.at(cells, 1), "details") |> Enum.empty?()
      assert LazyHTML.query(Enum.at(cells, 2), "details") |> Enum.empty?()
    end
  end

  describe "takedown" do
    test "a taken-down tournament's standings, and any working on it, are gone", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "tb-detail"

      Takedown.purge(slug)

      assert conn |> get(~p"/t/#{slug}") |> html_response(404)
    end
  end

  describe "the cache" do
    test "two readers of the standings page get identical bytes, details and all", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      first = conn |> get(~p"/t/#{slug}") |> html_response(200)
      second = build_conn() |> get(~p"/t/#{slug}") |> html_response(200)

      assert first == second
      assert first =~ "tb-detail"
    end
  end
end
