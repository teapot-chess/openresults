defmodule OpenResultsWeb.ResultsHubPhase2Test do
  @moduledoc """
  The results hub's second phase: CSV exports, tournament series, the
  federation feed and calendar, JSON-LD, the sitemap index, the alphabetical
  list and the statistics page.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures, except: [payload: 1]

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.ResultsIndex
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.Tournaments

  setup do
    RateLimit.reset()
    :ok
  end

  defp publish!(payload) do
    {:ok, _} = Snapshots.ingest(payload, [])
    payload["tournament"]["slug"]
  end

  defp tournament(slug, opts \\ []) do
    today = Date.utc_today()
    start = Date.add(today, Keyword.get(opts, :starts_in, -1))
    finish = Date.add(start, Keyword.get(opts, :days, 4))

    SnapshotPayloads.swiss()
    |> put_in(["tournament", "slug"], slug)
    |> put_in(["tournament", "name"], Keyword.get(opts, :name, "Hub " <> slug))
    |> put_in(["tournament", "federation"], Keyword.get(opts, :federation, "BEL"))
    |> put_in(["tournament", "start_date"], Date.to_iso8601(start))
    |> put_in(["tournament", "end_date"], Date.to_iso8601(finish))
  end

  defp display(payload, key, value),
    do: put_in(payload, ["tournament", "display", key], value)

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_document()
  defp has?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count() > 0

  defp csv(conn), do: conn |> response(200) |> String.trim_leading("﻿")

  defp csv_rows(conn) do
    conn
    |> csv()
    |> String.split("\r\n", trim: true)
  end

  describe "CSV exports" do
    test "each list downloads as a file with its page's columns", %{conn: conn} do
      slug = publish!(tournament("csv-all"))

      standings = get(conn, "/t/#{slug}/standings.csv")
      assert [type] = get_resp_header(standings, "content-type")
      assert type =~ "text/csv"

      assert get_resp_header(standings, "content-disposition") == [
               ~s(attachment; filename="#{slug}-standings.csv")
             ]

      assert get_resp_header(standings, "x-robots-tag") == ["noindex"]
      assert response(standings, 200) =~ "﻿"

      [heading | rows] = csv_rows(standings)
      assert heading =~ ~s("Rank","No","Name","Title","Federation","Club","Rating")
      assert heading =~ ~s("Points")
      assert Enum.any?(rows, &(&1 =~ ~s("Müller, Jörg")))

      [heading | _] = csv_rows(get(build_conn(), "/t/#{slug}/crosstable.csv"))
      assert heading =~ ~s("Points")

      [heading | rows] = csv_rows(get(build_conn(), "/t/#{slug}/pairings.csv"))
      assert heading == ~s("Round","Board","White no","White","Result","Black no","Black")
      assert rows != []

      [heading | rows] = csv_rows(get(build_conn(), "/t/#{slug}/players.csv"))
      assert heading =~ ~s("FIDE ID")
      assert Enum.any?(rows, &(&1 =~ "1503014"))
    end

    test "a column the arbiter hides is not in the file", %{conn: conn} do
      slug =
        "csv-hidden"
        |> tournament()
        |> display("rating", false)
        |> display("club", false)
        |> display("player_cards", false)
        |> publish!()

      for list <- ~w(standings players crosstable) do
        body = conn |> recycle() |> get("/t/#{slug}/#{list}.csv") |> csv()
        refute body =~ ~s("Rating"), list
        refute body =~ ~s("Club"), list
        refute body =~ "2601", list
        refute body =~ "SF Berlin", list
      end

      refute build_conn() |> get("/t/#{slug}/players.csv") |> csv() =~ "1503014"
    end

    test "a list the arbiter does not publish is a 404, not a file", %{conn: conn} do
      slug =
        "csv-withheld"
        |> tournament()
        |> display("standings", false)
        |> display("pairings", false)
        |> publish!()

      for list <- ~w(standings players crosstable pairings) do
        response = conn |> recycle() |> get("/t/#{slug}/#{list}.csv")
        assert response.status == 404, list
        assert get_resp_header(response, "content-disposition") == []
      end
    end

    test "a hidden tournament's files are the 404 of one that never published", %{conn: conn} do
      slug = publish!(tournament("csv-hide-me"))
      {:ok, _} = Moderation.hide(slug, admin())

      assert get(conn, "/t/#{slug}/standings.csv").status == 404
      assert get(build_conn(), "/t/no-such-thing/standings.csv").status == 404
    end

    test "a name written as a formula stays text", %{conn: conn} do
      payload = tournament("csv-formula")

      payload =
        update_in(payload, ["players"], fn [first | rest] ->
          [Map.put(first, "name", "=HYPERLINK(\"http://x\")") | rest]
        end)

      slug = publish!(payload)
      body = conn |> get("/t/#{slug}/players.csv") |> csv()
      assert body =~ ~s{"'=HYPERLINK(""http://x"")"}
    end

    test "revalidates to a 304 and is answered from the page cache", %{conn: conn} do
      slug = publish!(tournament("csv-cache"))
      first = get(conn, "/t/#{slug}/standings.csv")
      [etag] = get_resp_header(first, "etag")

      again =
        build_conn() |> put_req_header("if-none-match", etag) |> get("/t/#{slug}/standings.csv")

      assert again.status == 304

      hit = get(build_conn(), "/t/#{slug}/standings.csv")
      assert response(hit, 200) == response(first, 200)
      assert [type] = get_resp_header(hit, "content-type")
      assert type =~ "text/csv"
      assert get_resp_header(hit, "content-disposition") != []
    end

    test "the standings page links the files it publishes", %{conn: conn} do
      slug = "csv-links" |> tournament() |> display("pairings", false) |> publish!()
      document = conn |> get("/t/#{slug}") |> doc()

      assert has?(document, ~s(#export-standings[href="/t/#{slug}/standings.csv"]))
      assert has?(document, "#export-players")
      refute has?(document, "#export-pairings")
      refute has?(document, "#export-crosstable")
    end
  end

  describe "tournament series" do
    defp edition(slug, series, year_offset) do
      slug
      |> tournament(starts_in: -365 * year_offset, name: "Open " <> slug)
      |> put_in(["tournament", "series_id"], series)
    end

    test "a tournament shows the other editions of its series", %{conn: conn} do
      old = publish!(edition("series-2025", "seriesAAAA01", 1))
      new = publish!(edition("series-2026", "seriesAAAA01", 0))
      _other = publish!(edition("series-other", "seriesBBBB02", 0))

      document = conn |> get("/t/#{new}") |> doc()
      assert has?(document, ~s(#other-editions #edition-#{old} a[href="/t/#{old}"]))
      refute has?(document, "#edition-#{new}")
      refute has?(document, "#edition-series-other")

      assert ResultsIndex.editions(old) |> Enum.map(& &1.slug) == [new]
    end

    test "no series, no block", %{conn: conn} do
      slug = publish!(tournament("series-none"))
      refute conn |> get("/t/#{slug}") |> doc() |> has?("#other-editions")
    end

    test "a copied series id from another publisher is not an edition", %{conn: conn} do
      mine = publish!(edition("series-mine", "seriesCCCC03", 0))

      {installation, key} = installation!()
      stranger = mint!(installation)

      stranger
      |> edition("seriesCCCC03", 1)
      |> put_in(["tournament", "slug"], stranger)
      |> publish(key, random_key())
      |> json_response(200)

      refute conn |> get("/t/#{mine}") |> doc() |> has?("#other-editions")
      assert ResultsIndex.editions(stranger) == []
    end

    test "hidden and unlisted editions are left out", %{conn: conn} do
      slug = publish!(edition("series-a", "seriesDDDD04", 0))
      hidden = publish!(edition("series-b", "seriesDDDD04", 1))

      unlisted =
        "series-c"
        |> edition("seriesDDDD04", 2)
        |> put_in(["tournament", "listed"], false)
        |> publish!()

      {:ok, _} = Moderation.hide(hidden, admin())

      document = conn |> get("/t/#{slug}") |> doc()
      refute has?(document, "#edition-#{hidden}")
      refute has?(document, "#edition-#{unlisted}")
    end

    test "a new edition reaches a cached page of an older one", %{conn: conn} do
      old = publish!(edition("series-cache-1", "seriesEEEE05", 1))
      first = get(conn, "/t/#{old}")
      [etag] = get_resp_header(first, "etag")
      refute first |> doc() |> has?("#other-editions")

      new = publish!(edition("series-cache-2", "seriesEEEE05", 0))

      again = build_conn() |> put_req_header("if-none-match", etag) |> get("/t/#{old}")
      assert again.status == 200
      assert again |> doc() |> has?("#edition-#{new}")

      # And it leaves again with the edition's status.
      {:ok, _} = Moderation.hide(new, admin())
      refute build_conn() |> get("/t/#{old}") |> doc() |> has?("#edition-#{new}")
    end

    test "a series id that is not the shape of one is ignored" do
      slug = publish!(edition("series-junk", "no", 0))
      assert ResultsIndex.editions(slug) == []
    end
  end

  describe "the federation feed and calendar" do
    test "the Atom feed announces approved tournaments of that federation", %{conn: conn} do
      bel = publish!(tournament("feed-bel", starts_in: -10, days: 2))
      pending = publish!(tournament("feed-pending"))
      {:ok, _} = Tournaments.transition(pending, ["listed"], "pending")
      ned = publish!(tournament("feed-ned", federation: "NED"))

      response = get(conn, "/f/BEL/feed.xml")
      [type] = get_resp_header(response, "content-type")
      assert type =~ "application/atom+xml"
      body = response(response, 200)

      assert body =~ "/t/#{bel}#published"
      assert body =~ "/t/#{bel}#finished"
      refute body =~ pending
      refute body =~ ned
      # Tournaments, never players.
      refute body =~ "Müller"
    end

    test "the calendar holds upcoming and running tournaments with their dates", %{conn: conn} do
      soon = publish!(tournament("cal-soon", starts_in: 10, days: 2))
      past = publish!(tournament("cal-past", starts_in: -30, days: 2))

      hidden_dates =
        "cal-nodates"
        |> tournament(starts_in: 5)
        |> display("dates", false)
        |> publish!()

      response = get(conn, "/f/bel/calendar.ics")
      [type] = get_resp_header(response, "content-type")
      assert type =~ "text/calendar"
      body = response(response, 200)

      start = Date.utc_today() |> Date.add(10) |> Calendar.strftime("%Y%m%d")
      finish = Date.utc_today() |> Date.add(13) |> Calendar.strftime("%Y%m%d")

      assert body =~ "BEGIN:VCALENDAR\r\n"
      assert body =~ "UID:#{soon}@"
      assert body =~ "DTSTART;VALUE=DATE:#{start}\r\n"
      assert body =~ "DTEND;VALUE=DATE:#{finish}\r\n"
      assert body =~ "LOCATION:Ghent\r\n"
      refute body =~ past
      refute body =~ hidden_dates
      assert body |> String.split("\r\n") |> Enum.all?(&(byte_size(&1) <= 75))
    end

    test "the listing links both, and the feed is cached under its generation", %{conn: conn} do
      publish!(tournament("feed-links"))
      document = conn |> get(~p"/f/BEL") |> doc()
      assert has?(document, ~s(#federation-feed[href="/f/BEL/feed.xml"]))
      assert has?(document, ~s(#federation-calendar[href="/f/BEL/calendar.ics"]))
      assert has?(document, ~s(link[rel="alternate"][href="/f/BEL/feed.xml"]))

      [etag] = build_conn() |> get("/f/BEL/feed.xml") |> get_resp_header("etag")

      revalidate = fn ->
        build_conn() |> put_req_header("if-none-match", etag) |> get("/f/BEL/feed.xml")
      end

      assert revalidate.().status == 304

      publish!(tournament("feed-links-2"))
      assert revalidate.().status == 200
    end

    test "an address that is not a federation is a 404", %{conn: conn} do
      assert get(conn, "/f/12345/feed.xml").status == 404
      assert get(build_conn(), "/f/12345/calendar.ics").status == 404
    end
  end

  describe "JSON-LD" do
    test "a tournament page describes the event and nobody in it", %{conn: conn} do
      slug = publish!(tournament("jsonld"))
      document = conn |> get("/t/#{slug}") |> doc()

      [json] =
        document
        |> LazyHTML.query(~s(script[type="application/ld+json"]))
        |> Enum.map(&LazyHTML.text/1)

      data = Jason.decode!(json)
      assert data["@type"] == "SportsEvent"
      assert data["name"] == "Hub jsonld"
      assert data["location"]["address"]["addressLocality"] == "Ghent"
      assert data["startDate"]
      refute json =~ "Müller"
    end

    test "leaves out what the arbiter hides", %{conn: conn} do
      slug =
        "jsonld-hidden"
        |> tournament()
        |> display("dates", false)
        |> display("city", false)
        |> publish!()

      [json] =
        conn
        |> get("/t/#{slug}")
        |> doc()
        |> LazyHTML.query(~s(script[type="application/ld+json"]))
        |> Enum.map(&LazyHTML.text/1)

      data = Jason.decode!(json)
      refute Map.has_key?(data, "startDate")
      refute Map.has_key?(data, "location")
    end
  end

  describe "the sitemap index" do
    test "points to its parts, and the parts list the pages", %{conn: conn} do
      slug = publish!(tournament("sitemap-t"))
      index = conn |> get("/sitemap.xml") |> response(200)
      assert index =~ "<sitemapindex"
      assert index =~ "/sitemaps/pages.xml</loc>"
      assert index =~ "/sitemaps/tournaments-1.xml</loc>"

      pages = build_conn() |> get("/sitemaps/pages.xml") |> response(200)
      assert pages =~ "/tournaments</loc>"
      assert pages =~ "/statistics</loc>"
      assert pages =~ "/f/BEL</loc>"

      tournaments = build_conn() |> get("/sitemaps/tournaments-1.xml") |> response(200)
      assert tournaments =~ "/t/#{slug}</loc>"
      assert tournaments =~ "/t/#{slug}/crosstable</loc>"
      assert tournaments =~ "/t/#{slug}/round/1</loc>"
    end

    test "a part that does not exist is a 404", %{conn: conn} do
      assert get(conn, "/sitemaps/tournaments-99.xml").status == 404
      assert get(build_conn(), "/sitemaps/nonsense.xml").status == 404
      assert get(build_conn(), "/sitemaps/players-1.xml").status == 404
    end
  end

  describe "/tournaments" do
    test "lists the tournaments under their folded first letter", %{conn: conn} do
      publish!(tournament("az-emile", name: "Émile Open"))
      publish!(tournament("az-brugge", name: "Brugge Open"))
      publish!(tournament("az-digit", name: "1st Club Cup"))

      document = conn |> get(~p"/tournaments") |> doc()
      assert has?(document, "#letter-b")
      assert has?(document, "#letter-e")
      assert has?(document, "#letter-other")
      # The first letter is the default.
      assert has?(document, "#alphabetical-list #t-az-brugge")

      e = build_conn() |> get(~p"/tournaments?letter=e") |> doc()
      assert has?(e, "#alphabetical-list #t-az-emile")
      refute has?(e, "#t-az-brugge")

      other = build_conn() |> get("/tournaments?letter=%23") |> doc()
      assert has?(other, "#t-az-digit")
    end

    test "leaves out hidden tournaments", %{conn: conn} do
      hidden = publish!(tournament("az-hidden", name: "Zeta hidden"))
      {:ok, _} = Moderation.hide(hidden, admin())
      refute conn |> get(~p"/tournaments?letter=z") |> html_response(200) =~ "az-hidden"
    end
  end

  describe "/statistics" do
    test "counts tournaments per federation and month", %{conn: conn} do
      year = Date.utc_today().year
      jan = Date.new!(year, 1, 10)
      offset = Date.diff(jan, Date.utc_today())

      publish!(tournament("stats-1", starts_in: offset))
      publish!(tournament("stats-2", starts_in: offset))
      publish!(tournament("stats-3", starts_in: offset, federation: "NED"))

      publish!(
        "stats-nodates"
        |> tournament(starts_in: offset)
        |> display("dates", false)
      )

      document = conn |> get(~p"/statistics") |> doc()
      row = document |> LazyHTML.query("#stats-BEL td") |> Enum.map(&LazyHTML.text/1)
      # January, then the rest of the months, then tournaments and players.
      assert hd(row) == "2"
      assert Enum.at(row, 12) == "2"
      assert has?(document, "#stats-NED")
      total = document |> LazyHTML.query("#stats-total td") |> Enum.map(&LazyHTML.text/1)
      assert Enum.at(total, 12) == "3"
    end

    test "says so when nothing is published", %{conn: conn} do
      assert conn |> get(~p"/statistics") |> doc() |> has?("#statistics-empty")
    end
  end
end
