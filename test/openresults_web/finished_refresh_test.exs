defmodule OpenResultsWeb.FinishedRefreshTest do
  @moduledoc """
  A finished tournament's pages tell their refresher to stop polling
  (`data-results-finished`); a live one's, and every page that is not a
  tournament's, do not. The polling itself is browser script and is not
  run here: this is the server half, the mark the script reads.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  # Every board reported, the calendar over: nothing left to wait for.
  defp finished(payload) do
    payload
    |> put_in(["tournament", "end_date"], "2026-03-05")
    |> update_in(["rounds"], fn rounds ->
      Enum.map(rounds, fn round ->
        update_in(round, ["boards"], fn boards ->
          Enum.map(boards, fn board ->
            if is_binary(board["result"]), do: board, else: Map.put(board, "result", "1-0")
          end)
        end)
      end)
    end)
  end

  # Results still coming in, and the calendar says the event is on.
  defp live(payload) do
    payload
    |> put_in(["tournament", "end_date"], "2999-01-01")
    |> put_in(["tournament", "rounds_count"], 9)
  end

  defp marked?(conn, path) do
    conn
    |> get(path)
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-results-finished]")
    |> Enum.any?()
  end

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  test "a finished tournament's pages carry the mark", %{conn: conn} do
    slug = publish(finished(SnapshotPayloads.swiss()))

    assert marked?(conn, ~p"/t/#{slug}")
    assert marked?(build_conn(), ~p"/t/#{slug}/round/1")
    assert marked?(build_conn(), ~p"/t/#{slug}/crosstable")
  end

  test "the projector view carries it too", %{conn: conn} do
    slug = publish(finished(SnapshotPayloads.swiss()))
    assert marked?(conn, ~p"/t/#{slug}/round/1?display=1")
  end

  test "a live tournament's pages do not", %{conn: conn} do
    slug = publish(live(SnapshotPayloads.swiss()))

    refute marked?(conn, ~p"/t/#{slug}")
    refute marked?(build_conn(), ~p"/t/#{slug}/round/1")
    refute marked?(build_conn(), ~p"/t/#{slug}/round/1?display=1")
  end

  test "a past end date with a result still missing is not finished", %{conn: conn} do
    # The swiss fixture's round 3 has a board without a result.
    slug = publish(put_in(SnapshotPayloads.swiss(), ["tournament", "end_date"], "2026-03-05"))
    refute marked?(conn, ~p"/t/#{slug}")
  end

  test "the next poll of a tournament that has just finished carries the mark", %{conn: conn} do
    live_payload = live(SnapshotPayloads.swiss())
    slug = publish(live_payload)
    refute marked?(conn, ~p"/t/#{slug}")

    publish(finished(SnapshotPayloads.republished(live_payload)))

    polled =
      build_conn()
      |> put_req_header("x-openresults-refresh", "1")
      |> marked?(~p"/t/#{slug}")

    assert polled
  end

  test "pages that are not a tournament's keep polling", %{conn: conn} do
    publish(finished(SnapshotPayloads.swiss()))

    refute marked?(conn, ~p"/")
  end

  test "the refresher script stops on the mark and keeps its intervals" do
    {:ok, layout} = File.read("lib/openresults_web/components/layouts/root.html.heex")

    assert layout =~ "data-results-finished"
    # No back-off: the two paces are what they were.
    assert layout =~ "? 10000 : 20000"
  end
end
