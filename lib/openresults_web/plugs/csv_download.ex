defmodule OpenResultsWeb.Plugs.CsvDownload do
  @moduledoc """
  Marks a request as one of the CSV exports (`OpenResultsWeb.ExportController`)
  before `OpenResultsWeb.Plugs.Revalidate` sees it.

  Two things have to be on the response whether it is rendered or answered
  from the page cache, and a cache hit never reaches the controller:

    * `Content-Disposition`, so the browser saves `<slug>-standings.csv`
      rather than showing a wall of commas;
    * `X-Robots-Tag: noindex`. Every row of an export is already on a page a
      search engine may read; the file adds nothing to find, and a
      spreadsheet of names in a search result is an index of people by
      another door.

  And it tells `Revalidate` the route serves `text/csv`, so a stored body is
  labelled as what it is and an HTML error page is never stored in its place.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    slug = conn.params["slug"]
    kind = conn.request_path |> Path.basename(".csv")

    filename =
      if is_binary(slug) and slug =~ ~r/\A[A-Za-z0-9_-]{1,120}\z/,
        do: "#{slug}-#{kind}.csv",
        else: "#{kind}.csv"

    conn
    |> put_private(:revalidate_content_type, "text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> put_resp_header("x-robots-tag", "noindex")
  end
end
