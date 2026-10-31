defmodule OpenResultsWeb.HubCache do
  @moduledoc """
  The rendered-page cache and ETag for the pages that belong to no single
  tournament: the front page, `/federations`, `/f/:code` and
  `/players/:fide_id`.

  The same two mechanisms as a tournament page
  (`OpenResultsWeb.Plugs.Revalidate`), with one difference: there is no
  snapshot id to key on, so the key is a GENERATION - see
  `OpenResults.ResultsIndex.Generations` for what moves which one. The
  caller hands over the cache slot (`:front`, `{:federation, "BEL"}`,
  `{:player, 1503014}`) and the generation; this module does the rest:

    * the ETag is a keyed digest of the path, the query string, the
      language, the public notice and the generation - so a browser holding
      a page rendered under any other one of those gets a 200, not a 304;
    * the body is stored in `OpenResultsWeb.Plugs.Revalidate.Page` under the
      slot, the generation, the language and the tag. `Page` drops a slot's
      older bodies the moment one under a new generation is stored, exactly
      as it drops a tournament's on a new snapshot, and its per-slot cap
      still applies;
    * `private, no-cache`, as everywhere: the reader always asks, and an
      unchanged page costs a counter lookup and a 304.

  Only a request in canonical form is stored (`cacheable?`), for the reason
  `Revalidate` gives under "The filter bar and the page cache": otherwise
  `?page=2&x=1`, `?page=02` and friends would each earn an entry and a
  stranger could churn a federation's cache by typing.
  """

  import Plug.Conn

  alias OpenResultsWeb.Plugs.Revalidate
  alias OpenResultsWeb.Plugs.Revalidate.Page

  @gzip_min_bytes 512

  @doc """
  Answers from the cache when it can, and otherwise calls `render` (a
  function of the conn that returns a conn with the page) and keeps a 200
  for the next reader.
  """
  @spec serve(Plug.Conn.t(), term(), term(), boolean(), (Plug.Conn.t() -> Plug.Conn.t())) ::
          Plug.Conn.t()
  def serve(conn, slot, generation, cacheable?, render) do
    locale = conn.assigns[:locale] || OpenResultsWeb.Locale.default()
    notice = OpenResultsWeb.Plugs.PublicNotice.version(conn)

    etag =
      ~s("h-#{locale}-) <>
        Revalidate.sign({conn.request_path, conn.query_string, locale, notice, slot, generation}) <>
        ~s(")

    conn =
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "private, no-cache")
      |> put_resp_header("vary", vary(conn))

    gzip = (cacheable? and gzip?(conn)) && Page.get(slot, generation, locale, etag <> "|gzip")
    body = cacheable? && Page.get(slot, generation, locale, etag)

    cond do
      etag in request_etags(conn) ->
        conn |> send_resp(304, "") |> halt()

      gzip ->
        conn
        |> put_resp_header("content-encoding", "gzip")
        |> put_resp_content_type("text/html")
        |> send_resp(200, gzip)
        |> halt()

      body ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, body) |> halt()

      cacheable? ->
        conn
        |> register_before_send(&keep(&1, slot, generation, locale, etag))
        |> render.()

      true ->
        render.(conn)
    end
  end

  defp keep(%{status: 200} = conn, slot, generation, locale, etag) do
    if Enum.any?(get_resp_header(conn, "content-type"), &String.starts_with?(&1, "text/html")) do
      body = IO.iodata_to_binary(conn.resp_body)
      Page.put(slot, generation, locale, etag, body)

      if byte_size(body) >= @gzip_min_bytes,
        do: Page.put(slot, generation, locale, etag <> "|gzip", :zlib.gzip(body))
    end

    conn
  end

  defp keep(conn, _slot, _generation, _locale, _etag), do: conn

  defp vary(conn) do
    case get_resp_header(conn, "vary") do
      [] -> "accept-encoding"
      [existing | _] -> existing <> ", accept-encoding"
    end
  end

  defp gzip?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(String.downcase(&1), "gzip"))
  end

  defp request_etags(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end
end
