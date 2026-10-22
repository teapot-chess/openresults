defmodule OpenResultsWeb.AccessibilityTest do
  @moduledoc """
  Every page this site renders, held to the invariants in
  `OpenResultsWeb.A11y` - the decidable half of the accessibility pass of
  2026-09-13 (`docs/accessibility-2026-09-13.md`).

  The public pages are walked from the router rather than listed by hand, so
  a page added later is audited the day it is routed: a browser GET route
  with no entry in `pages/2` fails "every page is walked" and says which one.
  Each page is rendered in every state that changes its markup - before round
  1 and after, Keizer and swiss, the projector, a form sent back with its
  errors - because a label that only goes missing on the error render is the
  one nobody tests by hand.

  JavaScript does not run here, so what the scripts do with focus, with the
  live region and with the dialog is the manual checklist's job. What IS
  asserted is the markup those scripts depend on.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures, only: [unique_slug: 1]
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.{RateLimit, SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.{A11y, AdminWorld}

  # The one browser GET route that answers JSON, for the entry form's
  # script. Not a page.
  @not_pages [
    "/t/:slug/fide",
    "/t/:slug/player/:no/board",
    "/t/:slug/feed.xml",
    "/t/:slug/events",
    "/sitemap.xml",
    # A PGN file, not a document.
    "/t/:slug/live/:round/:board/pgn",
    "/t/:slug/live/:round/pgn"
  ]

  setup do
    RateLimit.reset()

    swiss = publish(SnapshotPayloads.swiss(), unique_slug("swiss"))
    keizer = publish(SnapshotPayloads.keizer(), unique_slug("keizer"))

    before_round_one =
      SnapshotPayloads.swiss()
      |> put_in(["standings", "rows"], [])
      |> publish(unique_slug("before"))

    closed =
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "registration_open"], false)
      |> publish(unique_slug("closed"))

    # A game in progress on board 1 of round 5, and one finished on board 2:
    # the live pages are walked with something on them.
    {:ok, _} =
      OpenResults.LiveBoards.ingest(swiss, %{
        "round" => 5,
        "board" => 1,
        "moves" => ~w(e4 e5 Nf3 Nc6),
        "white_ms" => 300_000,
        "black_ms" => 290_000,
        "running" => "white"
      })

    {:ok, _} =
      OpenResults.LiveBoards.ingest(swiss, %{
        "round" => 5,
        "board" => 2,
        "moves" => ~w(f3 e5 g4 Qh4#),
        "status" => "finished",
        "result" => "0-1"
      })

    # Two sections of one event, so the tab strip, the event page and the
    # front page's gathered entry are walked with something in them.
    event = "a11y" <> Integer.to_string(System.unique_integer([:positive]))
    event_open = unique_slug("event-open")
    event_u20 = unique_slug("event-u20")

    for {slug, label, position, other, other_label} <- [
          {event_open, "Open", 1, event_u20, "U20"},
          {event_u20, "U20", 2, event_open, "Open"}
        ] do
      SnapshotPayloads.swiss()
      |> put_in(["tournament", "group"], %{
        "id" => event,
        "name" => "Spring Festival",
        "label" => label,
        "position" => position,
        "siblings" => [%{"slug" => other, "label" => other_label, "name" => other_label}]
      })
      |> publish(slug)
    end

    team_rr = publish(SnapshotPayloads.team_round_robin(), unique_slug("team-rr"))
    team_swiss = publish(SnapshotPayloads.team_swiss(), unique_slug("team-swiss"))

    %{"fide_id" => fide_id} =
      Enum.find(SnapshotPayloads.swiss()["players"], & &1["fide_id"])

    team_no = SnapshotPayloads.team_round_robin()["teams"] |> hd() |> Map.get("no")

    {:ok,
     world: %{
       swiss: swiss,
       keizer: keizer,
       before_round_one: before_round_one,
       closed: closed,
       team_rr: team_rr,
       team_swiss: team_swiss,
       team_no: team_no,
       fide_id: fide_id,
       event: event,
       event_open: event_open
     }}
  end

  defp publish(payload, slug) do
    {:ok, _} = Snapshots.ingest(put_in(payload, ["tournament", "slug"], slug))
    slug
  end

  # Every concrete page behind one route, in each state that changes its
  # markup.
  defp pages(%{path: path}, world) do
    case path do
      "/" ->
        ["/", "/?lang=nl", "/?lang=fr"]

      "/t/:slug" ->
        for slug <- [
              world.swiss,
              world.keizer,
              world.before_round_one,
              world.team_rr,
              world.team_swiss
            ],
            lang <- ["en", "nl", "fr"],
            do: "/t/#{slug}?lang=#{lang}"

      "/t/:slug/crosstable" ->
        [
          "/t/#{world.swiss}/crosstable",
          "/t/#{world.keizer}/crosstable",
          "/t/#{world.before_round_one}/crosstable",
          "/t/#{world.team_swiss}/crosstable",
          "/t/#{world.team_swiss}/crosstable?lang=nl"
        ]

      "/t/:slug/round/:n" ->
        [
          "/t/#{world.swiss}/round/1",
          "/t/#{world.swiss}/round/5",
          "/t/#{world.swiss}/round/5?display=1",
          "/t/#{world.keizer}/round/1",
          "/t/#{world.swiss}/round/4",
          "/t/#{world.team_rr}/round/1",
          "/t/#{world.team_rr}/round/1?team=#{world.team_no}",
          "/t/#{world.team_swiss}/round/1",
          "/t/#{world.team_swiss}/round/2",
          "/t/#{world.team_swiss}/round/3?lang=fr"
        ]

      # The static render of each state; the views the cycle turns to are
      # the same markup, and `HallLiveTest` walks them.
      "/t/:slug/hall" ->
        [
          "/t/#{world.swiss}/hall",
          "/t/#{world.swiss}/hall?lang=nl&theme=light",
          "/t/#{world.swiss}/hall?views=names&lang=fr",
          "/t/#{world.swiss}/hall?theme=ultra",
          "/t/#{world.swiss}/hall?views=standings",
          "/t/#{world.keizer}/hall?views=standings",
          "/t/#{world.before_round_one}/hall",
          "/t/#{world.team_rr}/hall",
          "/t/#{world.team_rr}/hall?views=standings",
          "/t/#{world.team_swiss}/hall",
          "/t/#{world.team_swiss}/hall?views=names",
          "/t/#{world.team_swiss}/hall?views=results",
          "/t/no-such-tournament/hall"
        ]

      "/t/:slug/projector" ->
        [
          "/t/#{world.swiss}/projector",
          "/t/#{world.swiss}/projector?lang=fr&theme=ultra",
          "/t/#{world.swiss}/projector?theme=white",
          "/t/#{world.team_rr}/projector",
          "/t/#{world.team_swiss}/projector",
          "/t/#{world.before_round_one}/projector",
          "/t/no-such-tournament/projector"
        ]

      "/t/:slug/player/:no" ->
        [
          "/t/#{world.swiss}/player/1",
          "/t/#{world.keizer}/player/1",
          "/t/#{world.before_round_one}/player/1"
        ]

      "/t/:slug/team/:no" ->
        [
          "/t/#{world.team_rr}/team/#{world.team_no}",
          "/t/#{world.team_swiss}/team/1",
          "/t/#{world.team_swiss}/team/3?lang=nl",
          "/t/#{world.team_rr}/team/999"
        ]

      "/t/:slug/teams" ->
        [
          "/t/#{world.team_rr}/teams",
          "/t/#{world.team_swiss}/teams",
          "/t/#{world.team_swiss}/teams?lang=fr",
          "/t/#{world.swiss}/teams"
        ]

      "/t/:slug/board-prizes" ->
        ["/t/#{world.team_rr}/board-prizes", "/t/#{world.team_swiss}/board-prizes"]

      # The event page, and - listed here because it is the same feature - a
      # tournament page with the event's tab strip on it.
      "/e/:id" ->
        [
          "/e/#{world.event}",
          "/e/#{world.event}?lang=nl",
          "/e/#{world.event}?lang=fr",
          "/e/nobody-claims-this",
          "/t/#{world.event_open}",
          "/t/#{world.event_open}/round/1?lang=nl"
        ]

      "/players/:fide_id" ->
        ["/players/#{world.fide_id}", "/players/999999999"]

      "/changelog" ->
        ["/changelog"]

      "/terms" ->
        ["/terms", "/terms?lang=nl", "/terms?lang=fr"]

      # A published round redirects to it (the broadcast, walked below), so
      # what renders here is the 404.
      "/t/:slug/live" ->
        ["/t/no-such-tournament/live"]

      "/t/:slug/live/:round/all" ->
        [
          "/t/#{world.swiss}/live/5/all",
          "/t/#{world.swiss}/live/5/all?lang=nl&theme=night",
          "/t/#{world.before_round_one}/live/5/all",
          "/t/#{world.team_swiss}/live/2/all?lang=fr",
          "/t/#{world.swiss}/live/4/all"
        ]

      "/t/:slug/live/:round/projector" ->
        [
          "/t/#{world.swiss}/live/5/projector",
          "/t/#{world.swiss}/live/5/projector?boards=1,3&auto=0&lang=nl&theme=night",
          "/t/#{world.team_swiss}/live/2/projector?lang=fr",
          "/t/#{world.swiss}/live/1/projector",
          "/t/#{world.swiss}/live/42/projector"
        ]

      "/t/:slug/live/:round" ->
        [
          "/t/#{world.swiss}/live/5",
          "/t/#{world.swiss}/live/5?lang=nl&theme=night",
          "/t/#{world.team_swiss}/live/2?lang=fr",
          "/t/#{world.swiss}/live/1",
          "/t/#{world.swiss}/live/4",
          "/t/#{world.team_swiss}/live/2"
        ]

      "/t/:slug/live/:round/:board" ->
        [
          "/t/#{world.swiss}/live/5/1",
          "/t/#{world.swiss}/live/5/2?lang=fr",
          "/t/#{world.swiss}/live/5/3?lang=nl",
          "/t/#{world.swiss}/live/5/99",
          "/t/#{world.team_swiss}/live/1/1"
        ]

      "/t/:slug/register" ->
        [
          "/t/#{world.swiss}/register",
          "/t/#{world.swiss}/register?lang=fr",
          "/t/#{world.closed}/register",
          "/t/no-such-tournament/register"
        ]

      "/report/status" ->
        ["/report/status", "/report/status?ref=AAAAAAAA", "/report/status?lang=nl"]

      "/t/:slug/report" ->
        ["/t/#{world.swiss}/report", "/t/#{world.swiss}/report?lang=nl"]

      other ->
        flunk("#{other} is a browser page nobody walks - add it to pages/2")
    end
  end

  # `__routes__/0` does not say which pipeline a route runs through, so the
  # public pages are every GET that is neither the API nor the admin panel.
  defp browser_routes do
    for %{verb: :get, path: path} = route <- OpenResultsWeb.Router.__routes__(),
        not String.starts_with?(path, ["/api/", "/admin"]),
        path not in @not_pages,
        do: route
  end

  # The changelog's tables come from CHANGELOG.md, and markdown has no way to
  # write a caption. Their header cells are still scoped - see
  # `OpenResults.Markdown`.
  defp skips("/changelog" <> _), do: [:table_name]
  defp skips(_path), do: []

  defp locale_of(path) do
    case Regex.run(~r/[?&]lang=(\w+)/, path) do
      [_, lang] -> lang
      nil -> "en"
    end
  end

  defp assert_clean(html, path, opts \\ []) do
    violations = A11y.audit(html, Keyword.put_new(opts, :lang, locale_of(path)))
    assert violations == [], "#{path}\n#{A11y.explain(violations)}"
  end

  describe "every public page" do
    test "is walked, and passes the audit in every state", %{world: world} do
      with_fide_search(fn ->
        results =
          for route <- browser_routes(), path <- pages(route, world) do
            conn = get(build_conn(), path)
            assert conn.status in [200, 403, 404], "#{path} answered #{conn.status}"
            {path, A11y.audit(conn.resp_body, lang: locale_of(path), skip: skips(path))}
          end

        failures = for {path, violations} <- results, violations != [], do: {path, violations}

        assert failures == [],
               Enum.map_join(failures, "\n\n", fn {path, v} -> "#{path}\n#{A11y.explain(v)}" end)

        assert length(results) >= 30
      end)
    end

    # The 2026-10-19 sweep: the public pages had no script policy at all.
    # Walked from the same router as the audit, so a page added later, or a
    # script edited without the hash following it, fails here and not in a
    # reader's console.
    test "runs only scripts its Content-Security-Policy allows", %{world: world} do
      with_fide_search(fn ->
        checked =
          for route <- browser_routes(), path <- pages(route, world) do
            conn = get(build_conn(), path)
            [policy] = get_resp_header(conn, "content-security-policy")
            html = conn.resp_body

            for directive <- [
                  "object-src 'none'",
                  "base-uri 'self'",
                  "frame-ancestors *",
                  "default-src 'self'"
                ],
                do: assert(policy =~ directive, "#{path}: no #{directive} in #{policy}")

            for [attrs, body] <- Regex.scan(~r{<script([^>]*)>(.*?)</script>}s, html) do
              if attrs =~ "src=" do
                assert body == "", "#{path}: a script with both src and a body"
              else
                hash = "'sha256-" <> Base.encode64(:crypto.hash(:sha256, body)) <> "'"
                assert policy =~ hash, "#{path}: an inline script the policy does not allow"
              end
            end

            # The policy has no 'unsafe-hashes', so these would not run.
            refute html =~ ~r/<[^>]+\son[a-z]+\s*=/i, "#{path}: an inline event handler"
            refute html =~ ~r/href\s*=\s*"javascript:/i, "#{path}: a javascript: link"
            path
          end

        assert length(checked) >= 30
      end)
    end

    test "the entry form, sent back with its errors, in every language", %{world: world} do
      for lang <- ["en", "nl", "fr"] do
        path = "/t/#{world.swiss}/register?lang=#{lang}"

        html =
          build_conn()
          |> post(path, registration: %{"name" => "x", "email" => "not an address"})
          |> html_response(422)

        assert_clean(html, path)
      end
    end

    test "the report form, sent back with its errors", %{world: world} do
      path = "/t/#{world.swiss}/report"
      html = build_conn() |> post(path, report: %{}) |> html_response(422)

      assert_clean(html, path)
    end

    test "the refusal a flood of entries gets", %{world: world} do
      conn =
        Enum.reduce_while(1..10, nil, fn _, _ ->
          conn =
            build_conn()
            |> put_req_header("cf-connecting-ip", "192.0.2.77")
            |> post("/t/#{world.swiss}/register", registration: %{})

          if conn.status == 429, do: {:halt, conn}, else: {:cont, conn}
        end)

      assert conn.status == 429
      assert_clean(conn.resp_body, "/t/#{world.swiss}/register")
    end
  end

  describe "the markup the page scripts rely on" do
    test "the announcer sits outside the region the refresher replaces", %{world: world} do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("#announcer[aria-live=polite]") |> Enum.count() == 1
      assert document |> LazyHTML.query("#live-region #announcer") |> Enum.empty?()
    end

    test "the filter bar is a real GET form with labelled controls and a visible submit button",
         %{world: world} do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      forms = LazyHTML.query(document, "form[data-filter-form]")
      assert Enum.count(forms) == 1

      assert LazyHTML.query(document, ~s(form[data-filter-form][method="get"])) != []

      # A `<fieldset>`/`<legend>` grouping, the site's existing convention
      # for a form's own controls (see `registration_html.ex`), and every
      # control wrapped in its own `<label>` - so this works by keyboard and
      # is read sensibly by a screen reader with no `aria-*` wiring of its
      # own required.
      assert LazyHTML.query(document, "form[data-filter-form] fieldset > legend") != []
      selects = LazyHTML.query(document, "form[data-filter-form] label > select")
      inputs = LazyHTML.query(document, "form[data-filter-form] label > input")
      assert Enum.count(selects) + Enum.count(inputs) > 0

      # A real, visible submit button - not hidden behind `html.has-js`, so
      # the form works exactly the same with the script switched off.
      assert LazyHTML.query(document, ~s(form[data-filter-form] button[type="submit"])) != []

      # The middle controls collapse behind a real `<details>`/`<summary>` on
      # a narrow screen - no script required to open it.
      assert LazyHTML.query(document, "details.filter-disclosure > summary") != []
    end

    test "the filter chips are links with accessible names, not bare icons", %{world: world} do
      document =
        build_conn()
        |> get("/t/#{world.swiss}?category=A")
        |> html_response(200)
        |> LazyHTML.from_document()

      chips = LazyHTML.query(document, ".filter-chip a")
      assert chips != []

      for chip <- chips do
        # Either an `aria-label` or real text content names the chip - never
        # only the aria-hidden "✕".
        aria = chip |> LazyHTML.attribute("aria-label") |> List.first()
        text = chip |> LazyHTML.text() |> String.trim()
        assert (is_binary(aria) and aria != "") or text != ""
      end

      # The "✕" glyph itself is hidden from assistive tech - the accessible
      # name comes from the label text/aria-label, not the mark.
      assert LazyHTML.query(document, ".filter-chip a span[aria-hidden]") != []
    end

    test "every tie-break working a reader can open is keyed, so a refresh can reopen it", %{
      world: world
    } do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      details = LazyHTML.query(document, "details.tb-detail")
      keys = details |> LazyHTML.attribute("data-detail") |> Enum.reject(&is_nil/1)

      assert Enum.count(details) > 0
      assert length(keys) == Enum.count(details)
      assert keys == Enum.uniq(keys)
    end

    test "the player card dialog can take focus", %{world: world} do
      document =
        build_conn() |> get("/t/#{world.swiss}") |> html_response(200) |> LazyHTML.from_document()

      assert document
             |> LazyHTML.query(
               ~s(#card-overlay [role="dialog"][aria-modal="true"][tabindex="-1"])
             )
             |> Enum.count() == 1
    end
  end

  describe "the admin panel" do
    setup do
      reset_admin_access()
      configure_access()
      {:ok, admin_world: AdminWorld.build()}
    end

    test "every page passes the audit", %{admin_world: world} do
      routes =
        for %{verb: :get, path: "/admin" <> _} = route <- OpenResultsWeb.Router.__routes__(),
            do: route

      failures =
        for route <- routes,
            path <- admin_pages(route, world),
            conn = admin_get(path),
            conn.status == 200,
            violations = A11y.audit(conn.resp_body, lang: "en"),
            violations != [] do
          "#{path}\n#{A11y.explain(violations)}"
        end

      assert failures == [], Enum.join(failures, "\n\n")
    end
  end

  # The same fan-out `admin_pages_test.exs` uses: every state an item can be in.
  defp admin_pages(route, world) do
    case route.path do
      "/admin/tournaments/:slug" <> rest ->
        for slug <- [world.pending, world.listed, world.hidden, world.unpublished],
            do: "/admin/tournaments/#{slug}" <> rest

      "/admin/installations/:id" <> rest ->
        for installation <- [world.active, world.suspended, world.revoked],
            do: "/admin/installations/#{installation.id}" <> rest

      "/admin/reports/:id" <> rest ->
        for report <- [world.open_report, world.resolved_report],
            do: "/admin/reports/#{report.id}" <> rest

      "/admin/address-blocks/:id" <> rest ->
        ["/admin/address-blocks/#{world.block.id}" <> rest]

      "/admin/switches/:key" ->
        ["/admin/switches/registration_open", "/admin/switches/public_publishing_paused"]

      "/admin/settings/:key" <> rest ->
        for key <- OpenResults.ServerSettings.keys(), do: "/admin/settings/#{key}" <> rest

      path ->
        [path]
    end
  end

  # The FIDE search panel renders only where this server has a FIDE list,
  # and it is the one part of the entry form with a script behind it - so
  # the walk renders it, against the fixture list in a database of its own.
  defp with_fide_search(fun) do
    context = OpenResults.FideListCase.setup_fide_list(%{})
    OpenResults.FideListCase.import_fixture!(context)
    fun.()
  end
end
