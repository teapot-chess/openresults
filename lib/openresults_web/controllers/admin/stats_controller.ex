defmodule OpenResultsWeb.Admin.StatsController do
  @moduledoc """
  The stats page: traffic, server health, publishing and the database, from
  the in-memory counters of `OpenResults.Stats`. Read-only, and it reloads
  itself every 30 seconds with a `<meta http-equiv="refresh">` - the panel
  runs no JavaScript.

  Cheap to open: the counters are already folded by the collector, the row
  counts are the collector's last (timed) count, and the only file-system
  reads are two `stat`s and the disk measurement `OpenResults.DiskSpace`
  already keeps.
  """
  use OpenResultsWeb, :controller

  alias OpenResults.DiskSpace
  alias OpenResults.Stats
  alias OpenResults.Stats.DbCounts
  alias OpenResults.Stats.Report
  alias OpenResults.Stats.Viewers
  alias OpenResults.Tournaments

  @refresh_seconds 30

  def show(conn, _params) do
    report = Stats.report()

    render(conn, :show,
      page_title: "Stats",
      refresh_seconds: @refresh_seconds,
      report: report,
      readers: Viewers.report(),
      files: DbCounts.files(),
      disk: DiskSpace.reading(),
      statuses: statuses(report)
    )
  end

  # The visibility of every tournament the page lists, so a hidden one is
  # marked as hidden. Read from `Tournaments.status/1`'s cache.
  defp statuses(nil), do: %{}

  defp statuses(report) do
    for points <- [report.hour, report.day],
        total = Report.total(points),
        {slug, _count} <-
          elem(Report.top_slugs(total, 10), 0) ++ elem(Report.top_refreshes(total, 10), 0),
        into: %{},
        do: {slug, Tournaments.status(slug)}
  end
end
