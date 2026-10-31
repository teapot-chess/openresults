defmodule OpenResultsWeb.SitemapController do
  @moduledoc """
  `GET /sitemap.xml` - a sitemap INDEX, and `GET /sitemaps/:part` - the
  sitemaps it points to:

    * `pages.xml` - the front page, the terms, `/federations`, the
      alphabetical list, the statistics page and each federation's listing;
    * `tournaments-N.xml` - 1,000 tournaments a file, each with its
      standings, its cross-table and its rounds, each only when the arbiter
      publishes that page;
    * `players-N.xml` - 40,000 player pages a file.

  One sitemap may hold 50,000 URLs; a site with ten thousand tournaments of
  eleven rounds passes that on its own, which is why this is an index from
  the start rather than from the day it would have broken.

  Which tournaments: exactly the ones the listings show (not hidden by
  moderation, listed by their arbiter), read from the results index
  (`OpenResults.ResultsIndex`) - which also copied which pages each one
  publishes - so building the sitemap decodes no snapshot. It did, all of
  them, on every request, until phase 2. Player cards are left out on
  purpose: a sitemap full of people's names per tournament is an index of
  people, and that is not something this site sets out to build.

  The cross-tournament player pages ARE listed, for players who are
  certainly adults by the FIDE list's birth year
  (`OpenResultsWeb.PlayerHistoryController.minor?/2` - an unknown year
  counts as a minor) and whose page was not hidden at their request. That
  is a sitemap of people's names after all, and that is the maintainer's
  decision of 2026-10-31: the player page is the reason people search this
  site, for players old enough to have been asked.

  `lastmod` is the date of a tournament's newest publish. Every part is
  cached like a listing (`OpenResultsWeb.HubCache`), under the index's
  `:all` generation, the FIDE list's (which decides who is an adult) and
  today's date.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.FideList
  alias OpenResults.ResultsIndex
  alias OpenResults.ResultsIndex.Generations
  alias OpenResultsWeb.HubCache
  alias OpenResultsWeb.PlayerHistoryController

  @tournaments_per_file 1_000
  @players_per_file 40_000
  @xml "application/xml"

  def show(conn, _params) do
    serve(conn, :index, fn conn ->
      {_entries, tournament_files} = ResultsIndex.sitemap_tournaments(1, @tournaments_per_file)
      player_files = player_files(length(player_ids()))

      locs =
        [url(~p"/sitemaps/pages.xml")] ++
          for(n <- 1..tournament_files, do: url(~p"/sitemaps/#{"tournaments-#{n}.xml"}")) ++
          for n <- 1..player_files//1, do: url(~p"/sitemaps/#{"players-#{n}.xml"}")

      send_xml(conn, [
        ~s(<?xml version="1.0" encoding="utf-8"?>\n),
        ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
        Enum.map(locs, &["  <sitemap><loc>", esc(&1), "</loc></sitemap>\n"]),
        "</sitemapindex>\n"
      ])
    end)
  end

  def part(conn, %{"part" => "pages.xml"}) do
    serve(conn, :pages, fn conn ->
      federations =
        for {code, _count} <- ResultsIndex.federations(Date.utc_today()),
            do: url(~p"/f/#{code || "none"}")

      urlset(
        conn,
        Enum.map(
          [
            url(~p"/"),
            url(~p"/terms"),
            url(~p"/federations"),
            url(~p"/tournaments"),
            url(~p"/statistics")
          ] ++ federations,
          &{&1, nil}
        )
      )
    end)
  end

  def part(conn, %{"part" => part}) do
    case Regex.run(~r/\A(tournaments|players)-([1-9][0-9]{0,5})\.xml\z/, part) do
      [_all, "tournaments", n] -> tournaments(conn, String.to_integer(n))
      [_all, "players", n] -> players(conn, String.to_integer(n))
      _other -> not_found(conn)
    end
  end

  defp tournaments(conn, n) do
    serve(conn, {:tournaments, n}, fn conn ->
      case ResultsIndex.sitemap_tournaments(n, @tournaments_per_file) do
        {_entries, pages} when n > pages -> not_found(conn)
        {entries, _pages} -> urlset(conn, Enum.flat_map(entries, &tournament_urls/1))
      end
    end)
  end

  defp players(conn, n) do
    serve(conn, {:players, n}, fn conn ->
      ids = player_ids()

      if n > player_files(length(ids)) do
        not_found(conn)
      else
        ids
        |> Enum.drop((n - 1) * @players_per_file)
        |> Enum.take(@players_per_file)
        |> Enum.map(&{url(~p"/players/#{&1}"), nil})
        |> then(&urlset(conn, &1))
      end
    end)
  end

  # The FIDE ids with an indexable page: in order, adults only.
  defp player_ids do
    today = Date.utc_today()

    ResultsIndex.indexable_fide_ids()
    |> Enum.sort()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      listed = FideList.lookup(chunk)

      for id <- chunk,
          row = Map.get(listed, id),
          not PlayerHistoryController.minor?(row, today),
          do: id
    end)
  end

  defp player_files(0), do: 0
  defp player_files(count), do: div(count + @players_per_file - 1, @players_per_file)

  defp tournament_urls(entry) do
    slug = entry.slug
    lastmod = lastmod(entry)

    standings = if entry.standings_shown, do: [url(~p"/t/#{slug}")], else: []
    crosstable = if entry.crosstable_shown, do: [url(~p"/t/#{slug}/crosstable")], else: []

    rounds =
      if entry.pairings_shown,
        do: for(n <- ResultsIndex.round_numbers(entry), do: url(~p"/t/#{slug}/round/#{n}")),
        else: []

    for loc <- standings ++ crosstable ++ rounds, do: {loc, lastmod}
  end

  defp serve(conn, slot, render) do
    generation = {Generations.get(:all), Generations.get(:fide_list), Date.utc_today()}
    HubCache.serve(conn, {:sitemap, slot}, generation, conn.query_string == "", render, @xml)
  end

  defp urlset(conn, urls) do
    send_xml(conn, [
      ~s(<?xml version="1.0" encoding="utf-8"?>\n),
      ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      Enum.map(urls, &entry/1),
      "</urlset>\n"
    ])
  end

  defp send_xml(conn, body) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found\n")
  end

  defp entry({loc, nil}), do: ["  <url><loc>", esc(loc), "</loc></url>\n"]

  defp entry({loc, lastmod}),
    do: ["  <url><loc>", esc(loc), "</loc><lastmod>", lastmod, "</lastmod></url>\n"]

  defp lastmod(%{last_published_at: %DateTime{} = at}),
    do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp lastmod(_entry), do: nil

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
