defmodule OpenResultsWeb.VisibilityTest do
  @moduledoc """
  The contract's visibility table, on every public read surface this app has.

  | | pending | listed | hidden |
  |---|---|---|---|
  | reachable at its URL | yes | yes | no - 404, same as an unknown slug |
  | homepage and any listing | yes | yes | no |
  | cross-tournament player pages | no | yes | no |
  | entry form | yes | yes | no |

  The surfaces, found by reading the router: the four tournament pages
  (standings, cross-table, round, player card), the entry form and its FIDE
  search, the report form, the hall display, the open JSON read, the front
  page and the cross-tournament player page. There is no sitemap, feed or other listing.
  """

  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.Reports

  # Player 1 in the swiss fixture.
  @fide_id 1_503_014

  setup do
    RateLimit.reset()

    {installation, key} = installation!()

    pending = mint!(installation)
    pending |> current_payload() |> publish(key, random_key()) |> json_response(200)

    hidden = mint!(installation)
    hidden |> current_payload() |> publish(key, random_key()) |> json_response(200)
    {:ok, _} = Moderation.hide(hidden, admin())

    listed = unique_slug("listed")
    listed |> current_payload() |> publish(operator_token()) |> json_response(200)

    # The same length as a minted slug, so a body that echoes the slug is the
    # same length either way.
    unknown = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    {:ok, pending: pending, listed: listed, hidden: hidden, unknown: unknown}
  end

  @pages [
    {:get, "/t/SLUG"},
    {:get, "/t/SLUG/crosstable"},
    {:get, "/t/SLUG/round/1"},
    {:get, "/t/SLUG/player/1"},
    {:get, "/t/SLUG/register"},
    {:get, "/t/SLUG/fide?q=mu"},
    {:get, "/t/SLUG/report"},
    {:get, "/t/SLUG/hall"},
    {:get, "/t/SLUG/events"},
    {:get, "/api/tournaments/SLUG"}
  ]

  defp request({method, template}, slug, conn \\ build_conn()) do
    path = String.replace(template, "SLUG", slug)

    case method do
      :get -> get(conn, path)
    end
  end

  defp entry,
    do: %{"name" => "De Vos, Ilse", "email" => "ilse@example.invalid", "requested_byes" => []}

  defp report, do: %{"reason" => "wrong_or_fake_results", "details" => "Invented."}

  describe "a hidden tournament" do
    test "404s on every public surface exactly like a slug that never published", %{
      hidden: hidden,
      unknown: unknown
    } do
      for page <- @pages do
        a = request(page, hidden)
        b = request(page, unknown)

        assert a.status == 404, "#{inspect(page)} answered #{a.status} for a hidden tournament"
        assert_same(a, hidden, b, unknown, page)
      end
    end

    test "refuses an entry and a report the same way, and stores neither", %{
      hidden: hidden,
      unknown: unknown
    } do
      for {path, params} <- [
            {"/t/SLUG/register", [registration: entry()]},
            {"/t/SLUG/report", [report: report()]}
          ] do
        RateLimit.reset()
        a = post(build_conn(), String.replace(path, "SLUG", hidden), params)
        b = post(build_conn(), String.replace(path, "SLUG", unknown), params)

        assert a.status == 404
        assert_same(a, hidden, b, unknown, path)
      end

      assert Registrations.list_for_tournament(hidden) == []
      assert Reports.list(slug: hidden) == []
    end

    test "is absent from the front page and from player pages", %{hidden: hidden, listed: listed} do
      index = html_response(get(build_conn(), "/"), 200)
      refute index =~ hidden
      assert index =~ listed

      history = html_response(get(build_conn(), "/players/#{@fide_id}"), 200)
      refute history =~ hidden
      assert history =~ listed
    end

    test "a browser holding its page from before it was hidden gets the 404, not a 304", %{
      listed: listed
    } do
      first = get(build_conn(), "/t/#{listed}")
      [etag] = get_resp_header(first, "etag")

      # And the page is in the cache, so this also proves the cache is not
      # consulted for it.
      assert get(build_conn(), "/t/#{listed}").status == 200

      {:ok, _} = Moderation.hide(listed, admin())

      conn = build_conn() |> put_req_header("if-none-match", etag) |> get("/t/#{listed}")
      assert conn.status == 404
      assert get_resp_header(conn, "etag") == []
    end

    test "comes back when unhidden, as listed", %{hidden: hidden} do
      {:ok, _} = Moderation.unhide(hidden, admin())

      conn = get(build_conn(), "/t/#{hidden}")
      assert html_response(conn, 200)
      assert get_resp_header(conn, "x-robots-tag") == []
      assert html_response(get(build_conn(), "/"), 200) =~ hidden
    end
  end

  describe "a minted slug that has not published" do
    test "404s exactly like an unknown slug - no noindex, nothing to say it was minted", %{
      unknown: unknown
    } do
      {installation, _key} = installation!()
      minted = mint!(installation)

      for page <- @pages do
        assert_same(request(page, minted), minted, request(page, unknown), unknown, page)
      end
    end

    test "probing slugs nobody published leaves nothing behind in the status cache", %{
      unknown: unknown
    } do
      before = :ets.info(OpenResults.Tournaments.StatusCache, :size)

      for n <- 1..25, do: get(build_conn(), "/t/#{unknown}#{n}")

      assert :ets.info(OpenResults.Tournaments.StatusCache, :size) == before
    end
  end

  describe "a pending tournament" do
    # The admin upgrade, 2026-09-13: pending withholds the cross-tournament
    # player pages and nothing else.
    test "is reachable on every page, and no response carries noindex", %{pending: pending} do
      for page <- @pages -- [{:get, "/t/SLUG/fide?q=mu"}] do
        conn = request(page, pending)

        assert conn.status == 200,
               "#{inspect(page)} answered #{conn.status} for a pending tournament"

        unless page == {:get, "/t/SLUG/report"} do
          assert get_resp_header(conn, "x-robots-tag") == [], "#{inspect(page)}"
          if html?(conn), do: assert(robots_meta(conn) == [], "#{inspect(page)} has noindex")
        end
      end
    end

    test "the cached page and the 304 carry no noindex either", %{pending: pending} do
      first = get(build_conn(), "/t/#{pending}")
      [etag] = get_resp_header(first, "etag")

      cached = get(build_conn(), "/t/#{pending}")
      assert cached.status == 200
      assert get_resp_header(cached, "x-robots-tag") == []
      assert robots_meta(cached) == []

      revalidated = build_conn() |> put_req_header("if-none-match", etag) |> get("/t/#{pending}")
      assert revalidated.status == 304
      assert get_resp_header(revalidated, "x-robots-tag") == []
    end

    test "is on the front page straight away, and in its search", %{
      pending: pending,
      listed: listed
    } do
      index = html_response(get(build_conn(), "/"), 200)
      assert index =~ pending
      assert index =~ listed

      # The front page is cached and revalidated like a tournament page, under
      # a generation every publish moves: a browser holding it gets a 304
      # until something new is published, and then a 200 with the newcomer.
      conn = get(build_conn(), "/")
      [etag] = get_resp_header(conn, "etag")
      assert (build_conn() |> put_req_header("if-none-match", etag) |> get("/")).status == 304

      {installation, key} = installation!()
      fresh = mint!(installation)
      fresh |> current_payload() |> publish(key, random_key()) |> json_response(200)

      again = build_conn() |> put_req_header("if-none-match", etag) |> get("/")
      assert html_response(again, 200) =~ fresh
    end

    test "a tournament appears on the front page the moment it first publishes" do
      {installation, key} = installation!()
      slug = mint!(installation)

      refute html_response(get(build_conn(), "/"), 200) =~ slug

      slug |> current_payload() |> publish(key, random_key()) |> json_response(200)

      assert html_response(get(build_conn(), "/"), 200) =~ slug
    end

    test "is absent from player pages", %{pending: pending, listed: listed} do
      history = html_response(get(build_conn(), "/players/#{@fide_id}"), 200)
      refute history =~ pending
      assert history =~ listed

      # Every player in the fixture, not only the first: no aggregate across
      # tournaments may show a pending tournament's results.
      for %{"fide_id" => fide_id} <- payload(pending)["players"], is_integer(fide_id) do
        refute html_response(get(build_conn(), "/players/#{fide_id}"), 200) =~ pending,
               "player #{fide_id}'s history shows a pending tournament"
      end

      assert OpenResultsWeb.PlayerHistory.for_fide_id(@fide_id) |> Enum.map(& &1.slug) ==
               [listed]
    end

    test "takes entries and reports", %{pending: pending} do
      assert html_response(
               post(build_conn(), "/t/#{pending}/register", registration: entry()),
               200
             )

      assert [_entry] = Registrations.list_for_tournament(pending)

      assert html_response(post(build_conn(), "/t/#{pending}/report", report: report()), 200)
      assert [_report] = Reports.list(slug: pending)
    end

    test "approving it puts it on player pages, keeps it on the front page, and changes the ETag",
         %{pending: pending} do
      pages =
        for lang <- ~w(en nl fr) do
          conn = get(build_conn(), "/t/#{pending}?lang=#{lang}")
          # Twice, so the second is served from the page cache.
          assert get(build_conn(), "/t/#{pending}?lang=#{lang}").status == 200
          {lang, conn |> get_resp_header("etag") |> hd()}
        end

      {:ok, _} = Moderation.approve(pending, admin())

      for {lang, etag} <- pages do
        conn =
          build_conn()
          |> put_req_header("if-none-match", etag)
          |> get("/t/#{pending}?lang=#{lang}")

        assert conn.status == 200, "#{lang}: a validator from the pending page still answered 304"
        assert get_resp_header(conn, "x-robots-tag") == []
        refute get_resp_header(conn, "etag") == [etag]
      end

      assert html_response(get(build_conn(), "/"), 200) =~ pending
      assert html_response(get(build_conn(), "/players/#{@fide_id}"), 200) =~ pending
    end
  end

  describe "a listed tournament" do
    test "carries no noindex anywhere", %{listed: listed} do
      for page <- @pages -- [{:get, "/t/SLUG/fide?q=mu"}] do
        conn = request(page, listed)
        assert conn.status == 200
        assert get_resp_header(conn, "x-robots-tag") == [] or page == {:get, "/t/SLUG/report"}

        if html?(conn) and page != {:get, "/t/SLUG/report"},
          do: assert(robots_meta(conn) == [])
      end
    end
  end

  describe "the report link" do
    test "is on every page of a pending or listed tournament", %{pending: pending, listed: listed} do
      for slug <- [pending, listed],
          path <- [
            "/t/#{slug}",
            "/t/#{slug}/crosstable",
            "/t/#{slug}/round/1",
            "/t/#{slug}/player/1"
          ] do
        assert report_links(get(build_conn(), path)) == ["/t/#{slug}/report"], path
      end
    end

    test "is on a withheld page and a missing round, which are still that tournament's", %{
      listed: listed
    } do
      assert report_links(get(build_conn(), "/t/#{listed}/round/99")) == ["/t/#{listed}/report"]
    end

    test "is not on a 404 for a slug nobody published, nor for a hidden one", %{
      unknown: unknown,
      hidden: hidden
    } do
      assert report_links(get(build_conn(), "/t/#{unknown}")) == []
      assert report_links(get(build_conn(), "/t/#{hidden}")) == []
    end

    test "is translated", %{listed: listed} do
      for {lang, text} <- [
            {"en", "Report this page"},
            {"nl", "Deze pagina melden"},
            {"fr", "Signaler cette page"}
          ] do
        html = html_response(get(build_conn(), "/t/#{listed}?lang=#{lang}"), 200)

        assert html
               |> LazyHTML.from_document()
               |> LazyHTML.query("a.report-link")
               |> LazyHTML.text()
               |> String.trim() ==
                 text
      end
    end
  end

  # Everything a visitor or a crawler could tell the two responses apart by:
  # status, body (with each slug written as the same placeholder, since both
  # pages echo the address they were asked for), and the headers a cache or a
  # crawler reads.
  defp assert_same(a, slug_a, b, slug_b, label) do
    assert a.status == b.status, "#{inspect(label)}: #{a.status} vs #{b.status}"

    assert String.replace(a.resp_body, slug_a, "SLUG") ==
             String.replace(b.resp_body, slug_b, "SLUG"),
           "#{inspect(label)}: the hidden tournament's body differs from an unknown slug's"

    for header <- ~w(content-type etag cache-control x-robots-tag retry-after vary) do
      assert get_resp_header(a, header) == get_resp_header(b, header),
             "#{inspect(label)}: #{header} differs"
    end
  end

  defp html?(conn),
    do:
      conn |> get_resp_header("content-type") |> Enum.any?(&String.starts_with?(&1, "text/html"))

  defp robots_meta(conn) do
    conn.resp_body
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(meta[name="robots"]))
    |> LazyHTML.attribute("content")
  end

  defp report_links(conn) do
    conn.resp_body
    |> LazyHTML.from_document()
    |> LazyHTML.query("a.report-link")
    |> LazyHTML.attribute("href")
  end
end
