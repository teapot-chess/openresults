defmodule OpenResultsWeb.PlayerPagePolishTest do
  @moduledoc """
  The player page's three small kindnesses: a "?" that says how a tie-break
  is worked out, the two links sitting beside the name instead of under it,
  and the federation's flag before the name.
  """
  use OpenResultsWeb.ConnCase

  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.TiebreakHelp

  # Player 1 has a federation and a FIDE id; player 4 has a federation and no
  # FIDE id. The tweak can strip a federation from player 1.
  defp publish!(tweak \\ & &1) do
    slug = unique_slug("polish")

    payload =
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "slug"], slug)
      |> tweak.()

    {:ok, _} = Snapshots.ingest(payload)
    slug
  end

  defp doc(conn, path), do: conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp no_federation(payload) do
    update_in(payload, ["players"], fn players ->
      Enum.map(players, fn
        %{"no" => 1} = player -> Map.delete(player, "federation")
        player -> player
      end)
    end)
  end

  describe "tie-break explanations" do
    test "the player page puts a ? beside a tie-break's name", %{conn: conn} do
      slug = publish!()
      document = doc(conn, ~p"/t/#{slug}/player/1")

      assert count(document, "#player-summary .tiebreak-summary th button.tb-help[aria-expanded]") >
               0

      assert count(document, "#player-summary .tiebreak-summary th .tb-help-text[role=tooltip]") >
               0

      assert document
             |> LazyHTML.query(".tb-help-text")
             |> Enum.any?(&(LazyHTML.text(&1) =~ "final scores of all your opponents"))
    end

    test "the standings headings carry the same ?", %{conn: conn} do
      slug = publish!()
      document = doc(conn, ~p"/t/#{slug}")

      assert count(document, "thead th button.tb-help[data-tb-help]") > 0
    end

    test "a Dutch visitor reads Dutch", %{conn: conn} do
      slug = publish!()
      document = doc(conn, "/t/#{slug}/player/1?lang=nl")

      assert document
             |> LazyHTML.query(".tb-help-text")
             |> Enum.any?(&(LazyHTML.text(&1) =~ "eindscores van al je tegenstanders"))
    end

    test "every code with an explanation is spelled both ways and unknown codes get none" do
      assert TiebreakHelp.explain("BHC1") == TiebreakHelp.explain("BH/C1")
      assert TiebreakHelp.explain("MBH") == TiebreakHelp.explain("BH/M1")
      assert is_binary(TiebreakHelp.explain("SB"))
      assert is_binary(TiebreakHelp.explain("ARO/C1"))
      assert TiebreakHelp.explain("NOPE") == nil
      assert TiebreakHelp.explain(nil) == nil
    end
  end

  describe "the flag" do
    test "renders before the name for a player with a federation", %{conn: conn} do
      slug = publish!()
      document = doc(conn, ~p"/t/#{slug}/player/1")

      assert count(document, "#player-heading h2 img.flag-name[alt=GER]") == 1
    end

    test "falls back to the empty box without a federation, and to nothing with flags off", %{
      conn: conn
    } do
      slug = publish!(&no_federation/1)
      document = doc(conn, ~p"/t/#{slug}/player/1")

      assert count(document, "#player-heading h2 img.flag-name") == 0
      assert count(document, "#player-heading h2 span.flag-none") == 1

      off =
        publish!(fn payload ->
          update_in(payload, ["tournament", "display"], &Map.delete(&1, "flags"))
        end)

      document = doc(conn, ~p"/t/#{off}/player/1")
      assert count(document, "#player-heading h2 .flag") == 0
    end
  end

  describe "the two links" do
    test "sit in the heading row beside the name", %{conn: conn} do
      slug = publish!()
      document = doc(conn, ~p"/t/#{slug}/player/1")

      assert count(document, "#player-heading #player-actions a#player-history-link") == 1
      assert count(document, "#player-heading #player-actions button#follow-player") == 1
      assert count(document, "#player-heading #player-actions[data-peek-hide]") == 1
    end

    test "a player without a FIDE id gets the follow switch and no history link", %{conn: conn} do
      slug = publish!()
      document = doc(conn, ~p"/t/#{slug}/player/4")

      assert count(document, "#player-actions a#player-history-link") == 0
      assert count(document, "#player-actions button#follow-player") == 1
    end
  end
end
