defmodule OpenResultsWeb.ExportController do
  @moduledoc """
  A tournament's lists as CSV files, for the organiser's spreadsheet and the
  journalist's table:

    * `GET /t/:slug/standings.csv` - the standings (the team standings for a
      team event, the starting list before round 1);
    * `GET /t/:slug/crosstable.csv` - the cross-table;
    * `GET /t/:slug/pairings.csv` - every published round's boards and byes;
    * `GET /t/:slug/players.csv` - the player list.

  Each one is behind exactly the switch its page is behind, answers a hidden
  tournament with the same 404 as one that never published, and holds
  nothing that page does not show - see `OpenResultsWeb.Export` for the
  columns and why.

  Cached the way the pages are: `OpenResultsWeb.Plugs.CsvDownload` marks the
  route as CSV and `OpenResultsWeb.Plugs.Revalidate` gives it an ETag on the
  snapshot id and keeps the rendered file in the page cache until the next
  publish. A 304 costs a primary-key lookup; a hit costs an ETS read.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Tournaments
  alias OpenResultsWeb.Export
  alias OpenResultsWeb.Tournament

  def standings(conn, %{"slug" => slug}) do
    export(conn, slug, &Tournament.show?(&1, "standings"), &Export.standings/1)
  end

  def crosstable(conn, %{"slug" => slug}) do
    export(conn, slug, &Tournament.crosstable?/1, &Export.crosstable/1)
  end

  def pairings(conn, %{"slug" => slug}) do
    export(conn, slug, &Tournament.show?(&1, "pairings"), &Export.pairings/1)
  end

  # The starting list is the standings page before round 1, so it is behind
  # the same switch.
  def players(conn, %{"slug" => slug}) do
    export(conn, slug, &Tournament.show?(&1, "standings"), &Export.players/1)
  end

  defp export(conn, slug, allowed?, rows) do
    case Tournaments.public_latest(slug) do
      nil ->
        refuse(conn, "Not found\n")

      %{payload: payload} ->
        if allowed?.(payload) do
          conn
          |> put_resp_content_type("text/csv")
          |> send_resp(200, payload |> rows.() |> Export.to_csv())
        else
          refuse(conn, "This tournament does not publish this list.\n")
        end
    end
  end

  # A 404 is a page, not a file: no attachment, and plain text.
  defp refuse(conn, message) do
    conn
    |> delete_resp_header("content-disposition")
    |> put_resp_content_type("text/plain")
    |> send_resp(404, message)
  end
end
