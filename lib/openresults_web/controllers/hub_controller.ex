defmodule OpenResultsWeb.HubController do
  @moduledoc """
  The results hub's listings and search - finding a tournament without
  knowing its address:

    * `GET /federations` - every federation with a tournament here, and how
      many;
    * `GET /f/:code` - one federation: live, upcoming, finished in the last
      30 days, then the archive by page and year. `/f/none` is the
      tournaments that name no federation (or hide it);
    * `GET /search?q=` - tournaments by name and city, players by name or
      FIDE id.

  All read from `OpenResults.ResultsIndex`, never from the snapshots. The
  two listings are cached per federation through `OpenResultsWeb.HubCache`;
  search is not cached - an FTS5 query is cheap and the key space is
  whatever anybody types - and is rate-limited per address instead, like the
  site's other open lookups.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.RateLimit
  alias OpenResults.ResultsIndex
  alias OpenResults.ResultsIndex.Generations
  alias OpenResultsWeb.ClientAddress
  alias OpenResultsWeb.HubCache

  @search_limit 30
  @search_window_ms 60_000

  def federations(conn, _params) do
    today = Date.utc_today()

    HubCache.serve(conn, :federations, {Generations.get(:all), today}, conn.query_string == "", fn
      conn ->
        render(conn, :federations,
          page_title: gettext("Tournaments by federation"),
          page_description: gettext("Chess tournaments published on this site, by federation."),
          federations: ResultsIndex.federations(today)
        )
    end)
  end

  def federation(conn, %{"code" => raw} = params) do
    case code(raw) do
      nil ->
        not_found(conn, gettext("%{value} is not a federation code.", value: raw))

      {:redirect, canonical} ->
        conn
        |> put_status(:moved_permanently)
        |> redirect(to: OpenResultsWeb.HubHTML.federation_path(canonical))

      code ->
        today = Date.utc_today()
        years = ResultsIndex.archive_years(code, today)
        year = if params["year"] in years, do: params["year"]
        page = page(params["page"])
        canonical = canonical_query(year: year, page: if(page > 1, do: Integer.to_string(page)))

        HubCache.serve(
          conn,
          {:federation, code},
          {Generations.get({:federation, code}), today},
          conn.query_string == canonical,
          &render_federation(&1, code, today, years, year, page)
        )
    end
  end

  defp render_federation(conn, code, today, years, year, page) do
    groups = ResultsIndex.current_groups(code, today, ResultsIndex.federation_recent_days())
    archive = ResultsIndex.archive(code, today, year: year, page: page)
    label = OpenResultsWeb.HubHTML.federation_label(code)

    conn
    |> assign(:feed_path, OpenResultsWeb.HubHTML.federation_path(code) <> "/feed.xml")
    |> render(:federation,
      page_title: gettext("%{federation} - tournaments", federation: label),
      page_description:
        gettext("Chess tournaments of %{federation} published on this site.", federation: label),
      code: code,
      groups: groups,
      archive: archive,
      years: if(length(years) > 1, do: years, else: []),
      year: year,
      empty?: archive.total == 0 and is_nil(year) and Enum.all?(Map.values(groups), &(&1 == []))
    )
  end

  @doc """
  `GET /tournaments` - every tournament the listings show, by name, one
  letter at a time (`?letter=b`, `?page=2`). The letters are the names
  folded the way search folds them, so "Émile" is under E; `#` holds the
  rest.
  """
  def alphabetical(conn, params) do
    today = Date.utc_today()
    letters = ResultsIndex.letters(today)
    letter = if params["letter"] in letters, do: params["letter"], else: List.first(letters)
    page = page(params["page"])

    canonical =
      canonical_query(
        letter: if(params["letter"] in letters, do: letter),
        page: if(page > 1, do: Integer.to_string(page))
      )

    HubCache.serve(
      conn,
      :alphabetical,
      {Generations.get(:all), today},
      conn.query_string == canonical,
      fn conn ->
        render(conn, :alphabetical,
          page_title: gettext("Tournaments A-Z"),
          page_description: gettext("Every chess tournament published on this site, by name."),
          letters: letters,
          letter: letter,
          list:
            if(letter,
              do: ResultsIndex.alphabetical(letter, today, page),
              else: %{entries: [], page: 1, pages: 1, total: 0}
            )
        )
      end
    )
  end

  @doc """
  `GET /statistics` - counting, and only counting: per federation, how many
  tournaments started in each month of a year (`?year=2026`) and how many
  player entries they had. See `ResultsIndex.statistics/2` for what is
  counted.
  """
  def statistics(conn, params) do
    today = Date.utc_today()
    years = ResultsIndex.statistics_years(today)
    year = if params["year"] in years, do: params["year"], else: List.first(years)
    canonical = canonical_query(year: if(params["year"] in years, do: year))

    HubCache.serve(
      conn,
      :statistics,
      {Generations.get(:all), today},
      conn.query_string == canonical,
      fn conn ->
        rows = if year, do: ResultsIndex.statistics(year, today), else: []

        render(conn, :statistics,
          page_title: gettext("Statistics"),
          page_description:
            gettext("How many tournaments were published here, by federation and month."),
          years: years,
          year: year,
          rows: rows,
          totals: totals(rows)
        )
      end
    )
  end

  defp totals(rows) do
    %{
      months:
        Map.new(1..12, fn m -> {m, rows |> Enum.map(&Map.get(&1.months, m, 0)) |> Enum.sum()} end),
      tournaments: rows |> Enum.map(& &1.tournaments) |> Enum.sum(),
      players: rows |> Enum.map(& &1.players) |> Enum.sum()
    }
  end

  def search(conn, params) do
    q =
      if is_binary(params["q"]),
        do: params["q"] |> String.trim() |> String.slice(0, 100),
        else: ""

    {outcome, results} =
      case ResultsIndex.search(q) do
        {:error, :too_short} ->
          {:too_short, nil}

        {:ok, _results} = found ->
          case RateLimit.take({:hub_search, ClientAddress.of(conn)},
                 limit: @search_limit,
                 window_ms: @search_window_ms
               ) do
            :ok -> {:ok, elem(found, 1)}
            {:denied, _retry_in_ms} -> {:rate_limited, nil}
          end
      end

    conn
    |> put_status(if(outcome == :rate_limited, do: :too_many_requests, else: :ok))
    |> put_resp_header("cache-control", "private, no-cache")
    # A results page for whatever somebody typed is not a page to index.
    |> put_resp_header("x-robots-tag", "noindex")
    |> render(:search,
      page_title: if(q == "", do: gettext("Search"), else: gettext("Search: %{query}", query: q)),
      page_description: gettext("Search the tournaments and players published on this site."),
      noindex: true,
      q: q,
      outcome: outcome,
      results: results
    )
  end

  # `BEL` is a code, `bel` is a code typed in lower case (sent to `BEL`),
  # `none` is the no-federation bucket, and anything else is not an address
  # this route could ever have meant.
  defp code("none"), do: :none

  defp code(raw) when is_binary(raw) do
    cond do
      raw =~ ~r/\A[A-Z]{2,4}\z/ -> raw
      raw =~ ~r/\A[A-Za-z]{2,4}\z/ -> {:redirect, String.upcase(raw)}
      true -> nil
    end
  end

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n < 100_000 -> n
      _ -> 1
    end
  end

  defp page(_absent), do: 1

  defp canonical_query(pairs) do
    pairs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> URI.encode_query()
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OpenResultsWeb.TournamentHTML)
    |> render(:not_found,
      page_title: gettext("Not found"),
      page_description: OpenResultsWeb.Meta.not_found(),
      message: message,
      back: ~p"/federations"
    )
  end
end
