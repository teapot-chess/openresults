defmodule OpenResultsWeb.ResultsHubTest do
  @moduledoc """
  The results hub's public pages - the federation listings, search and the
  cross-tournament player page - and the admin's player-page removal.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.FideListCase, only: [setup_fide_list: 1, import_fixture!: 1]
  import OpenResultsWeb.AdminAccessHelpers
  import OpenResults.PublicPublishingFixtures, except: [payload: 1]

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.ResultsIndex
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.PlayerHistoryController

  setup :setup_fide_list

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

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp has?(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count() > 0

  defp ids(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("id")

  describe "the front page" do
    test "shows what is current, and points to the listings for the rest", %{conn: conn} do
      publish!(tournament("hub-now"))
      publish!(tournament("hub-old", starts_in: -400))

      document = conn |> get(~p"/") |> doc()
      assert has?(document, ~s(a[href="/t/hub-now"]))
      refute LazyHTML.text(document) =~ "Hub hub-old"
      assert has?(document, ~s(#front-more a[href="/federations"]))
      assert has?(document, "#front-search")
    end
  end

  describe "/federations" do
    test "lists each federation with how many tournaments it has", %{conn: conn} do
      publish!(tournament("hub-b1"))
      publish!(tournament("hub-b2", starts_in: -200))
      publish!(tournament("hub-n1", federation: "NED"))

      document = conn |> get(~p"/federations") |> doc()

      assert has?(document, ~s(#fed-BEL a[href="/f/BEL"]))
      assert LazyHTML.text(LazyHTML.query(document, "#fed-BEL")) =~ "2"
      assert has?(document, "#fed-NED")
      refute has?(document, "#fed-FRA")
    end
  end

  describe "/f/:code" do
    test "sorts a federation's tournaments into live, upcoming, recent and the archive", %{
      conn: conn
    } do
      publish!(tournament("hub-live"))
      "hub-soon" |> tournament(starts_in: 10) |> Map.put("rounds", []) |> publish!()

      "hub-done"
      |> tournament(starts_in: -10, days: 2)
      |> SnapshotPayloads.decided()
      |> publish!()

      publish!(tournament("hub-past", starts_in: -100, days: 2))
      publish!(tournament("hub-elsewhere", federation: "NED"))

      document = conn |> get(~p"/f/BEL") |> doc()

      assert has?(document, "#federation-live #t-hub-live")
      assert has?(document, "#federation-upcoming #t-hub-soon")
      assert has?(document, "#federation-finished #t-hub-done")
      assert has?(document, "#federation-archive-list #t-hub-past")
      refute has?(document, "#t-hub-elsewhere")
    end

    test "pages its archive and filters it by year", %{conn: conn} do
      for n <- 1..55, do: publish!(tournament("hub-arch-#{n}", starts_in: -100 - n, days: 1))

      first = conn |> get(~p"/f/BEL") |> doc()
      assert length(ids(first, "#federation-archive-list li")) == 50
      assert has?(first, ~s(#archive-next[href="/f/BEL?page=2"]))

      second = build_conn() |> get(~p"/f/BEL?page=2") |> doc()
      assert length(ids(second, "#federation-archive-list li")) == 5
      assert has?(second, "#archive-prev")
    end

    test "a lower-case code is sent to the upper-case one; a non-code is a 404", %{conn: conn} do
      assert redirected_to(get(conn, "/f/bel"), 301) == "/f/BEL"
      assert html_response(get(build_conn(), "/f/B3L"), 404)
      assert html_response(get(build_conn(), "/f/none"), 200)
    end

    test "a shell that never published a round and is long past is left out", %{conn: conn} do
      "hub-shell"
      |> tournament(starts_in: -100, days: 1)
      |> Map.put("rounds", [])
      |> publish!()

      refute conn |> get(~p"/f/BEL") |> html_response(200) =~ "hub-shell"
    end

    test "marks an unapproved tournament, and drops a hidden one", %{conn: conn} do
      {installation, key} = installation!()
      pending = mint!(installation)
      hidden = mint!(installation)

      for slug <- [pending, hidden] do
        slug |> tournament() |> publish(key, random_key()) |> json_response(200)
      end

      {:ok, _} = Moderation.hide(hidden, admin())

      document = conn |> get(~p"/f/BEL") |> doc()
      assert has?(document, "#t-#{pending} .badge-unapproved")
      refute has?(document, "#t-#{hidden}")
    end

    test "is cached, and a publish in that federation, and only that one, moves it", %{
      conn: conn
    } do
      publish!(tournament("hub-c1"))
      first = get(conn, ~p"/f/BEL")
      [bel] = get_resp_header(first, "etag")
      [ned] = build_conn() |> get(~p"/f/NED") |> get_resp_header("etag")

      revalidate = fn path, etag ->
        build_conn() |> put_req_header("if-none-match", etag) |> get(path)
      end

      assert revalidate.("/f/BEL", bel).status == 304

      publish!(tournament("hub-c2"))
      assert revalidate.("/f/NED", ned).status == 304
      fresh = revalidate.("/f/BEL", bel)
      assert fresh.status == 200
      assert html_response(fresh, 200) =~ "hub-c2"
    end
  end

  describe "/search" do
    test "finds tournaments, and says when the query is too short", %{conn: conn} do
      publish!(tournament("hub-s1", name: "Brugse Zomer Open"))

      document = conn |> get(~p"/search?q=zomer") |> doc()
      assert has?(document, "#search-tournaments #t-hub-s1")

      assert has?(build_conn() |> get(~p"/search?q=zo") |> doc(), "#search-too-short")
      assert has?(build_conn() |> get(~p"/search?q=qqqzzz") |> doc(), "#search-nothing")
    end

    test "is not indexed", %{conn: conn} do
      conn = get(conn, ~p"/search?q=gent")
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "is rate-limited per address", %{conn: conn} do
      for _ <- 1..30, do: assert(get(build_conn(), ~p"/search?q=gent").status == 200)
      assert get(conn, ~p"/search?q=gent").status == 429
    end
  end

  describe "/players/:fide_id" do
    setup context do
      import_fixture!(context)

      "hub-p"
      |> tournament(starts_in: -100)
      |> update_in(["players"], fn [first, second, third | rest] ->
        [
          first |> Map.put("fide_id", 901_001) |> Map.put("name", "De Vos, Ilse"),
          second |> Map.put("fide_id", 901_005) |> Map.put("name", "Peeters, Anna"),
          # Ilse's id under somebody else's name: a mistyped id.
          third |> Map.put("fide_id", 901_001) |> Map.put("name", "Janssens, Lucas")
          | rest
        ]
      end)
      |> publish!()

      :ok
    end

    test "heads with the FIDE list's name and current rating, and drops a mistyped id", %{
      conn: conn
    } do
      conn = get(conn, ~p"/players/901001")
      document = doc(conn)

      assert LazyHTML.text(LazyHTML.query(document, "h1")) =~ "De Vos, Ilse"
      assert LazyHTML.text(document) =~ "2105"
      assert ids(document, "#player-history li") == ["history-hub-p"]
      refute LazyHTML.text(LazyHTML.query(document, "#player-history")) =~ "Janssens"
      assert has?(document, ~s(#player-removal a[href="/terms#terms-player-pages"]))

      # An adult on the list: indexable.
      assert get_resp_header(conn, "x-robots-tag") == []
      refute has?(document, ~s(meta[name="robots"][content*="noindex"]))
    end

    test "a player who may be under 18 is never indexed", %{conn: conn} do
      conn = get(conn, ~p"/players/901005")
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
      assert has?(doc(conn), ~s(meta[name="robots"][content*="noindex"]))
    end

    test "an unknown birth year counts as a minor" do
      today = ~D[2026-10-31]
      assert PlayerHistoryController.minor?(nil, today)
      assert PlayerHistoryController.minor?(%{birth_year: nil}, today)
      assert PlayerHistoryController.minor?(%{birth_year: 0}, today)
      # Born in 2008: 18 by the end of 2026, but maybe not yet.
      assert PlayerHistoryController.minor?(%{birth_year: 2008}, today)
      refute PlayerHistoryController.minor?(%{birth_year: 2007}, today)
      refute PlayerHistoryController.minor?(%{birth_year: 1994}, today)
    end

    test "is in the sitemap only for an adult", %{conn: conn} do
      xml = conn |> get("/sitemap.xml") |> response(200)
      assert xml =~ "/players/901001"
      refute xml =~ "/players/901005"
    end

    test "the admin hides it on request, and restores it", %{conn: _conn} do
      reset_admin_access()
      configure_access()

      confirm = admin_get("/admin/players/hide?fide_id=901001")
      html = html_response(confirm, 200)
      assert html =~ "Hide the player page of FIDE 901001"

      hidden =
        confirm
        |> next_request()
        |> post("/admin/players/hide", %{
          "_csrf_token" => csrf_token(html),
          "fide_id" => "901001",
          "confirm" => "/admin/players/hide"
        })

      assert redirected_to(hidden) == "/admin/players"
      assert ResultsIndex.suppressed?(901_001)

      assert html_response(get(build_conn(), ~p"/players/901001"), 404)
      assert {:ok, %{players: []}} = ResultsIndex.search("de vos")
      # The tournament keeps the name.
      assert html_response(get(build_conn(), ~p"/t/hub-p"), 200) =~ "De Vos, Ilse"

      document = "/admin/players" |> admin_get() |> doc()
      assert has?(document, "#suppression-901001")

      restored = confirm_and_post("/admin/players/901001/restore")
      assert redirected_to(restored) == "/admin/players"
      refute ResultsIndex.suppressed?(901_001)
      assert html_response(get(build_conn(), ~p"/players/901001"), 200)
    end
  end
end
