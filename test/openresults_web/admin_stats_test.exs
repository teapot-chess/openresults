defmodule OpenResultsWeb.AdminStatsTest do
  @moduledoc """
  `/admin/stats`: it renders with nothing counted and with something counted,
  it reloads itself without a script, the request handler sorts requests into
  the right groups and counts only real tournament pages, and no address ever
  reaches the counters.

  The walks that hold every admin route to `no-store`, no ETag, the gate's
  404 and the accessibility audit (`admin_panel_test.exs`,
  `admin_pages_test.exs`, `accessibility_test.exs`) read the router, so they
  cover this page without being told about it.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.Stats
  alias OpenResults.Stats.Collector
  alias OpenResults.Stats.Report
  alias OpenResultsWeb.Admin.StatsHTML
  alias OpenResultsWeb.StatsTelemetry

  @address {203, 0, 113, 77}
  @address_text "203.0.113.77"

  setup do
    reset_admin_access()
    configure_access()
    :ok
  end

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_document()
  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  # What Bandit's `[:bandit, :request, :stop]` would hand the handler for this
  # response. ConnTest calls the endpoint directly, so Bandit never runs here.
  defp served(conn, us \\ 400) do
    StatsTelemetry.handle_request(
      [:bandit, :request, :stop],
      %{duration: native(us)},
      %{conn: conn},
      nil
    )

    conn
  end

  defp native(us), do: System.convert_time_unit(us, :microsecond, :native)

  # The day rather than the hour: a minute ending between two readings moves
  # the hour's window, and could drop an earlier test's requests from it.
  defp counted, do: Report.total(Stats.report().day)

  defp spectator do
    build_conn()
    |> Map.put(:remote_ip, @address)
    |> put_req_header("cf-connecting-ip", @address_text)
    |> put_req_header("x-forwarded-for", @address_text)
    |> put_req_header("user-agent", "Mozilla/5.0 (Stats test phone)")
  end

  describe "the page" do
    test "renders, links from the navigation and reloads itself every 30 seconds" do
      doc = doc(admin_get("/admin/stats"))

      assert text(doc, "h1") == "Stats"

      assert [_] =
               doc
               |> LazyHTML.query(~s(meta[http-equiv="refresh"][content="30"]))
               |> Enum.to_list()

      assert doc |> LazyHTML.query("script") |> Enum.to_list() == []

      assert [_] =
               doc
               |> LazyHTML.query(~s(nav a[href="/admin/stats"][aria-current="page"]))
               |> Enum.to_list()

      assert text(doc, "#stats-scope") =~ "reset by every restart"

      for id <- ~w(traffic health publishing database) do
        assert [_] = doc |> LazyHTML.query("section##{id}") |> Enum.to_list(), id
      end

      # Every chart says what it shows and its latest value in words.
      charts = doc |> LazyHTML.query(".admin-chart svg") |> Enum.to_list()
      assert length(charts) >= 12

      for svg <- charts do
        assert LazyHTML.attribute(svg, "role") == ["img"]
        assert [label] = LazyHTML.attribute(svg, "aria-label")
        assert label =~ "latest"
      end
    end

    test "shows the readers: today so far, thirty days and the top tournaments" do
      doc = doc(admin_get("/admin/stats"))

      assert [_] = doc |> LazyHTML.query("section#readers") |> Enum.to_list()
      assert [_] = doc |> LazyHTML.query("#stats-readers-today") |> Enum.to_list()

      assert doc
             |> LazyHTML.query("#stats-readers-days tbody tr")
             |> Enum.count() == 30

      for id <- ~w(today week month) do
        assert [_] = doc |> LazyHTML.query("#stats-readers-top-#{id}") |> Enum.to_list()
      end
    end

    test "other admin pages do not reload themselves" do
      doc = doc(admin_get("/admin"))
      assert doc |> LazyHTML.query(~s(meta[http-equiv="refresh"])) |> Enum.to_list() == []
    end

    test "shows what was counted" do
      slug = unique_slug("busy")
      assert json_response(publish(payload(slug), operator_token()), 200)

      for _ <- 1..3, do: build_conn() |> get("/t/#{slug}") |> served()

      OpenResultsWeb.ApiError.send(build_conn(), :publishing_paused)
      :ok = Collector.refresh_db_counts()

      doc = doc(admin_get("/admin/stats"))

      assert text(doc, "#stats-top-hour") =~ slug
      assert text(doc, "#stats-refused-publishing_paused") =~ ~r/[1-9]/
      assert text(doc, "#stats-group-public") =~ ~r/[1-9]/
      assert text(doc, "#stats-rows") =~ "Snapshot versions"
      assert text(doc, "#stats-schedulers") =~ "#{System.schedulers_online()} online"
      assert text(doc, "#stats-version") =~ System.version()
    end

    test "renders an empty report, and says what it could not measure" do
      table = :"stats_page_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Collector,
           name: nil,
           table: table,
           tick: :manual,
           db_interval: :manual,
           proc_root: "/no/such/proc"},
          id: table
        )

      :ok = Collector.tick(pid)

      html =
        [
          report: Collector.report(pid),
          refresh_seconds: 30,
          files: %{path: "/data/openresults.db", database_bytes: nil, wal_bytes: nil},
          disk: OpenResults.DiskSpace.reading(),
          statuses: %{}
        ]
        |> Map.new()
        |> StatsHTML.show()
        |> Phoenix.LiveViewTest.rendered_to_string()

      doc = LazyHTML.from_fragment(html)

      assert text(doc, "#stats-cpu") =~ "not measured"
      assert text(doc, "#stats-load") =~ "not measured"
      assert text(doc, "#stats-memory") =~ "not measured"
      assert text(doc, "#stats-connections") =~ "not measured"
      assert text(doc, "#stats-top-hour") =~ "none counted"
      assert text(doc, "#stats-rows-pending") =~ "Not counted yet"
      assert text(doc, "#stats-group-all") =~ "0"

      assert StatsHTML.show(%{report: nil}) |> Phoenix.LiveViewTest.rendered_to_string() =~
               "not running"
    end
  end

  describe "the request handler" do
    test "sorts requests into route groups by their first path segment" do
      group = fn method, path -> StatsTelemetry.group(build_conn(method, path)) end

      assert group.(:get, "/t/x") == :public
      assert group.(:get, "/") == :public
      assert group.(:get, "/players/1234") == :public
      assert group.(:get, "/assets/css/app-abc.css") == :static
      assert group.(:get, "/favicon.svg") == :static
      assert group.(:get, "/api/tournaments/x") == :api_read
      assert group.(:post, "/api/snapshots") == :api_write
      assert group.(:delete, "/api/tournaments/x") == :api_write
      assert group.(:get, "/admin/stats") == :admin
      # Not "starts with admin": a public path that happens to begin so.
      assert group.(:get, "/administrator") == :public
    end

    test "counts no connections where the endpoint is not serving" do
      assert StatsTelemetry.open_connections() == :error
    end

    test "counts each response under its group and status class" do
      before = counted()
      slug = unique_slug("classes")

      assert json_response(publish(payload(slug), operator_token()), 200) |> Map.get("status") ==
               "ok"

      build_conn() |> get("/t/#{slug}") |> served()
      build_conn() |> get("/t/no-such-#{slug}") |> served()
      build_conn() |> get("/api/tournaments/#{slug}") |> served()
      publish(payload(slug), "wrong-token") |> served()
      admin_get("/admin/stats") |> served()

      after_ = counted()
      delta = fn group -> Report.requests(after_, group) - Report.requests(before, group) end

      assert delta.(:public) == 2
      assert delta.(:api_read) == 1
      assert delta.(:api_write) == 1
      assert delta.(:admin) == 1

      classes = fn total -> Map.new(Report.status_classes(total)) end
      assert classes.(after_)["2xx"] - classes.(before)["2xx"] == 3
      assert classes.(after_)["4xx"] - classes.(before)["4xx"] == 2
    end

    test "counts a published tournament's pages, 304s included, and never an unknown slug" do
      slug = unique_slug("views")
      assert json_response(publish(payload(slug), operator_token()), 200)

      first = build_conn() |> get("/t/#{slug}") |> served()
      [etag] = get_resp_header(first, "etag")
      build_conn() |> put_req_header("if-none-match", etag) |> get("/t/#{slug}") |> served()
      build_conn() |> get("/t/#{slug}/crosstable") |> served()

      unknown = "never-published-#{System.unique_integer([:positive])}"
      assert build_conn() |> get("/t/#{unknown}") |> served() |> Map.get(:status) == 404

      slugs = counted().slugs
      assert slugs[slug] == 3
      refute Map.has_key?(slugs, unknown)
    end

    test "recognises publishes by credential, and the page cache's decisions" do
      before = counted()
      slug = unique_slug("pub")

      publish(payload(slug), operator_token()) |> served()
      build_conn() |> get("/t/#{slug}") |> served()
      build_conn() |> put_req_header("accept-encoding", "gzip") |> get("/t/#{slug}") |> served()

      after_ = counted()

      assert Report.event(after_, {:publish, :operator}) -
               Report.event(before, {:publish, :operator}) == 1

      assert Report.cache(after_).misses - Report.cache(before).misses >= 1
      assert Report.cache(after_).hits - Report.cache(before).hits >= 1
    end

    test "no address, user agent or query string reaches the counters" do
      slug = unique_slug("private")
      assert json_response(publish(payload(slug), operator_token()), 200)

      spectator() |> get("/t/#{slug}?display=1&who=#{@address_text}") |> served()
      spectator() |> get("/t/not-#{slug}") |> served()

      spectator()
      |> put_req_header("content-type", "application/json")
      |> post("/api/installations", "{}")
      |> served()

      publish(payload(slug), "wrong", nil, spectator()) |> served()

      :ok = Collector.tick(Collector)

      stored = {:ets.tab2list(Stats.table()), :sys.get_state(Collector)}
      dump = inspect(stored, limit: :infinity, printable_limit: :infinity)

      refute dump =~ @address_text
      refute dump =~ "Stats test phone"
      refute dump =~ "display=1"
      refute contains?(stored, @address)
    end
  end

  describe "views against refreshes" do
    test "a navigating request counts a view" do
      slug = unique_slug("nav")
      assert json_response(publish(payload(slug), operator_token()), 200)

      build_conn()
      |> put_req_header("sec-fetch-mode", "navigate")
      |> put_req_header("sec-fetch-dest", "document")
      |> get("/t/#{slug}")
      |> served()

      bucket = counted()
      assert bucket.slugs[slug] == 1
      refute Map.has_key?(bucket.refreshes, slug)
    end

    test "a request with no Sec-Fetch header at all counts a view too" do
      slug = unique_slug("legacy")
      assert json_response(publish(payload(slug), operator_token()), 200)

      build_conn() |> get("/t/#{slug}") |> served()

      bucket = counted()
      assert bucket.slugs[slug] == 1
      refute Map.has_key?(bucket.refreshes, slug)
    end

    test "a same-origin fetch (Sec-Fetch-Mode: cors) counts a refresh, not a view" do
      slug = unique_slug("poll")
      assert json_response(publish(payload(slug), operator_token()), 200)

      build_conn()
      |> put_req_header("sec-fetch-mode", "cors")
      |> put_req_header("sec-fetch-dest", "empty")
      |> get("/t/#{slug}")
      |> served()

      bucket = counted()
      assert bucket.refreshes[slug] == 1
      refute Map.has_key?(bucket.slugs, slug)
    end

    test "the refresh marker counts a refresh even on a request that says it navigated" do
      slug = unique_slug("marked")
      assert json_response(publish(payload(slug), operator_token()), 200)

      build_conn()
      |> put_req_header("sec-fetch-mode", "navigate")
      |> put_req_header("x-openresults-refresh", "1")
      |> get("/t/#{slug}")
      |> served()

      bucket = counted()
      assert bucket.refreshes[slug] == 1
      refute Map.has_key?(bucket.slugs, slug)
    end

    test "the stats page shows both counters and the live-followers estimate" do
      slug = unique_slug("shown")
      assert json_response(publish(payload(slug), operator_token()), 200)

      build_conn()
      |> put_req_header("sec-fetch-mode", "navigate")
      |> get("/t/#{slug}")
      |> served()

      build_conn()
      |> put_req_header("sec-fetch-mode", "cors")
      |> get("/t/#{slug}")
      |> served()

      doc = doc(admin_get("/admin/stats"))

      assert text(doc, "#stats-top-hour") =~ slug
      assert text(doc, "#stats-refreshes-hour") =~ slug
      assert text(doc, "#stats-live-followers") =~ ~r/Live followers/
    end
  end

  defp contains?(term, term), do: true

  defp contains?(tuple, target) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> contains?(target)

  defp contains?(list, target) when is_list(list), do: Enum.any?(list, &contains?(&1, target))

  defp contains?(%{} = map, target),
    do: map |> Map.to_list() |> contains?(target)

  defp contains?(_other, _target), do: false
end
