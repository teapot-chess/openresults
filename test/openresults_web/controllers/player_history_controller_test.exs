defmodule OpenResultsWeb.PlayerHistoryControllerTest do
  @moduledoc """
  One player, found by FIDE id, across every tournament this server holds.

  The display-rule and takedown rules this file exists to prove are the same
  ones the rest of the site already honours - this page is a new VIEW of
  published data, never a new way to see something an arbiter withheld.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots, Takedown}
  alias OpenResultsWeb.PlayerHistory

  @fide_id 1_503_014

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp later(payload) do
    payload
    |> put_in(["tournament", "slug"], "later-open-2026")
    |> put_in(["tournament", "name"], "Later Open 2026")
    |> put_in(["tournament", "start_date"], "2026-04-01")
    |> put_in(["tournament", "end_date"], "2026-04-03")
  end

  defp hiding(payload, keys) do
    display = Map.new(keys, &{&1, false})
    put_in(payload, ["tournament", "display"], display)
  end

  describe "OpenResultsWeb.PlayerHistory.for_fide_id/1" do
    test "finds a tournament by the player's FIDE id, and only that one" do
      slug = publish(SnapshotPayloads.swiss())

      assert [entry] = PlayerHistory.for_fide_id(@fide_id)
      assert entry.slug == slug
      assert entry.player_name == "Müller, Jörg"
      assert entry.player_no == 1
      assert entry.rank == 3
      assert entry.points == 1.5
      assert entry.total == 10
      assert entry.linkable?
    end

    test "a FIDE id nothing has published is an empty list, not an error" do
      publish(SnapshotPayloads.swiss())
      assert PlayerHistory.for_fide_id(999_999_999) == []
    end

    test "the same FIDE id in two tournaments is two entries, newest first" do
      publish(SnapshotPayloads.swiss())
      publish(later(SnapshotPayloads.swiss()))

      assert [newest, oldest] = PlayerHistory.for_fide_id(@fide_id)
      assert newest.slug == "later-open-2026"
      assert oldest.slug == "gent-spring-open-2026"
    end

    test "anything that is not an integer is an empty list" do
      publish(SnapshotPayloads.swiss())
      for junk <- [nil, "1503014", 1.5, :atom], do: assert(PlayerHistory.for_fide_id(junk) == [])
    end
  end

  describe "the display-rule leak case" do
    test "withheld standings show the tournament with no placing", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> hiding(["standings"]) |> publish()

      [entry] = PlayerHistory.for_fide_id(@fide_id)
      assert entry.slug == slug
      refute entry.rank
      refute entry.points
      refute entry.total

      html = conn |> get(~p"/players/#{@fide_id}") |> html_response(200)
      assert html =~ "Gent Spring Open 2026"
      refute html =~ "rank 1 of"
    end

    test "a tournament that publishes standings still shows the placing, as the control", %{
      conn: conn
    } do
      publish(SnapshotPayloads.swiss())

      html = conn |> get(~p"/players/#{@fide_id}") |> html_response(200)
      assert html =~ "rank 3 of 10"
    end

    test "withheld player cards list the tournament without a link", %{conn: conn} do
      publish(hiding(SnapshotPayloads.swiss(), ["player_cards"]))

      html = conn |> get(~p"/players/#{@fide_id}") |> html_response(200)

      assert html =~ "Gent Spring Open 2026"
      refute html =~ ~s|href="/t/gent-spring-open-2026/player/1"|
    end
  end

  describe "unlisted and taken-down tournaments" do
    test "an unlisted tournament does not appear, though its own page still does", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> put_in(["tournament", "listed"], false) |> publish()

      assert PlayerHistory.for_fide_id(@fide_id) == []

      html = conn |> get(~p"/players/#{@fide_id}") |> html_response(200)
      refute html =~ "Gent Spring Open 2026"

      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "Gent Spring Open 2026"
    end

    test "a taken-down tournament is gone from the history, not merely unlinked", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      assert conn |> get(~p"/players/#{@fide_id}") |> html_response(200) =~
               "Gent Spring Open 2026"

      Takedown.purge(slug)

      refute conn |> get(~p"/players/#{@fide_id}") |> html_response(200) =~
               "Gent Spring Open 2026"

      assert PlayerHistory.for_fide_id(@fide_id) == []
    end
  end

  describe "GET /players/:fide_id" do
    test "a FIDE id with nothing published yet is 200, not 404", %{conn: conn} do
      html = conn |> get(~p"/players/999999999") |> html_response(200)
      assert html =~ "No published tournament"
    end

    test "something that is not a FIDE id at all is 404", %{conn: conn} do
      for junk <- ["abc", "1503014x", "-1", "0"] do
        html = conn |> get("/players/#{junk}") |> html_response(404)
        assert html =~ "is not a FIDE id"
      end
    end

    test "the two readers of the same address get the same bytes", %{conn: conn} do
      publish(SnapshotPayloads.swiss())

      first = conn |> get(~p"/players/#{@fide_id}") |> html_response(200)
      second = build_conn() |> get(~p"/players/#{@fide_id}") |> html_response(200)

      assert first == second
    end
  end

  describe "the cross-link from the player page" do
    test "a player with a FIDE id is linked to their history", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      html = conn |> get(~p"/t/#{slug}/player/1") |> html_response(200)
      assert html =~ ~s|href="/players/#{@fide_id}"|

      link = html |> LazyHTML.from_document() |> LazyHTML.query("a#player-history-link")
      assert LazyHTML.attribute(link, "href") == ["/players/#{@fide_id}"]
      assert LazyHTML.text(link) =~ "Müller, Jörg"
    end

    test "a player with no FIDE id gets no cross-link", %{conn: conn} do
      # Player 4 in the fixture carries a null fide_id.
      slug = publish(SnapshotPayloads.swiss())

      html = conn |> get(~p"/t/#{slug}/player/4") |> html_response(200)
      refute html =~ "/players/"

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("a#player-history-link")
             |> Enum.empty?()
    end
  end
end
