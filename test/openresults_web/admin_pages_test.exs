defmodule OpenResultsWeb.AdminPagesTest do
  @moduledoc """
  Every page of the admin panel renders against a server with something on
  it, shows what the moderator needs to decide with, and links only to pages
  that exist.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.Moderation
  alias OpenResultsWeb.Admin.Components
  alias OpenResultsWeb.AdminWorld

  setup do
    reset_admin_access()
    configure_access()
    {:ok, world: AdminWorld.build()}
  end

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  defp hrefs(doc), do: doc |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href")

  # A link leads somewhere when it is a GET route of this app (query string
  # aside), Cloudflare's own logout, or a mail address.
  defp dead_links(doc) do
    for href <- hrefs(doc),
        href != "/cdn-cgi/access/logout",
        not String.starts_with?(href, "mailto:"),
        path = href |> URI.parse() |> Map.get(:path),
        Phoenix.Router.route_info(OpenResultsWeb.Router, "GET", path, "www.example.com") == :error,
        do: href
  end

  # Every concrete page for an admin GET route, with each parameter filled
  # from the world - every tournament, installation and report in each state
  # it can be in, so a template that only breaks for a hidden tournament or a
  # revoked installation breaks here.
  defp pages(route, world) do
    case route.path do
      "/admin/tournaments/:slug/relay-keys/:id" <> rest ->
        {:ok, %{relay_key: relay_key}} =
          OpenResults.Moderation.create_relay_key(world.listed, "box", %{email: "a@example.org"})

        ["/admin/tournaments/#{world.listed}/relay-keys/#{relay_key.id}" <> rest]

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

      "/admin/players/hide" ->
        ["/admin/players/hide?fide_id=1503014"]

      "/admin/players/:fide_id" <> rest ->
        ["/admin/players/1503014" <> rest]

      "/admin/switches/:key" ->
        ["/admin/switches/registration_open", "/admin/switches/public_publishing_paused"]

      "/admin/settings/:key" <> rest ->
        for key <- OpenResults.ServerSettings.keys(), do: "/admin/settings/#{key}" <> rest

      path ->
        [path]
    end
  end

  describe "every page" do
    test "renders, or redirects when the action does not apply, and has no dead links", %{
      world: world
    } do
      routes =
        for %{verb: :get, path: "/admin" <> _} = route <- OpenResultsWeb.Router.__routes__(),
            do: route

      rendered =
        for route <- routes, path <- pages(route, world) do
          conn = admin_get(path)

          case conn.status do
            200 ->
              assert dead_links(doc(conn)) == [], "#{path} links nowhere"
              path

            302 ->
              # An action that does not apply to this state - approving a
              # listed tournament - sends the admin back to the item itself.
              assert redirected_to(conn) =~ ~r{^/admin/}
              nil

            other ->
              flunk("#{path} answered #{other}")
          end
        end

      # Not a vacuous walk: most of these are real pages.
      assert length(Enum.reject(rendered, &is_nil/1)) >= 30
    end

    test "a slug, id or switch that does not exist is the panel's own 404, not a crash" do
      for path <- [
            "/admin/tournaments/no-such-slug",
            "/admin/tournaments/no-such-slug/delete",
            "/admin/installations/in_nobody",
            "/admin/installations/in_nobody/revoke",
            "/admin/reports/999999",
            "/admin/reports/not-a-number",
            "/admin/address-blocks/999999/unblock",
            "/admin/address-blocks/abc/unblock",
            "/admin/switches/open_the_floodgates"
          ] do
        conn = admin_get(path)

        assert html_response(conn, 404) =~ "Not found", path
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end

    test "filters that make no sense are ignored rather than fatal" do
      for path <- [
            "/admin/tournaments?status=bogus&page=abc&reported=maybe",
            "/admin/installations?status=%00&page=-4",
            "/admin/reports?status=everything&page=99999999999999",
            "/admin/action-log?action=drop_table&target_type=x&page=0"
          ] do
        assert admin_get(path).status == 200, path
      end
    end
  end

  describe "the dashboard" do
    test "shows both switches, the counts, storage and the latest actions", %{world: world} do
      doc = admin_get("/admin") |> doc()

      assert text(doc, "#switch-registration_open") =~ "Closed"
      assert text(doc, "#switch-registration_open") =~ "Open registration"
      assert text(doc, "#switch-public_publishing_paused") =~ "Active"
      assert text(doc, "#switch-public_publishing_paused") =~ "Pause publishing"

      counts = text(doc, "#counts")
      # The published pending tournament and the one minted but never published.
      assert counts =~ ~r/2\s+pending/
      assert counts =~ ~r/1\s+listed/
      assert counts =~ ~r/1\s+hidden/
      assert counts =~ ~r/1\s+active/
      assert counts =~ ~r/1\s+suspended/
      assert counts =~ ~r/1\s+revoked/
      assert text(doc, "#count-open-reports") == "1"

      storage = Moderation.storage()
      assert storage.snapshot_bytes > 0
      assert text(doc, "#storage-snapshot-bytes") == Components.bytes(storage.snapshot_bytes)
      assert text(doc, "#storage") =~ Components.thousands(storage.snapshot_bytes)
      assert text(doc, "#storage") =~ "Database file"

      recent = text(doc, "#recent-actions")
      assert recent =~ "earlier-moderator@example.invalid"
      assert recent =~ "block_address"
      assert world.block.cidr
    end

    test "says which FIDE list the entry form searches, and when it was last looked for" do
      context = OpenResults.FideListCase.setup_fide_list(%{})

      none = admin_get("/admin") |> doc()
      assert text(none, "#fide-list-live") =~ "none yet"
      assert text(none, "#fide-list-live") =~ "offers no search"
      assert text(none, "#fide-list-check") =~ "never"
      assert text(none, "#fide-list-sync") =~ "OPENRESULTS_FIDE_LIST_SYNC"

      OpenResults.FideListCase.import_fixture!(context)

      doc = admin_get("/admin") |> doc()
      assert text(doc, "#fide-list-live") =~ "published 2026-11-01"
      assert text(doc, "#fide-list-live") =~ ~r/10\s+players/
      assert text(doc, "#fide-list-check") =~ "a new list was imported"
      refute text(doc, "#fide-list-check") =~ "stays live"
    end

    test "says when public publishing is switched off on this server" do
      Application.put_env(:openresults, :public_publishing, false)
      on_exit(fn -> Application.put_env(:openresults, :public_publishing, true) end)

      assert admin_get("/admin") |> doc() |> text("#public-publishing-off") =~
               "OPENRESULTS_PUBLIC_PUBLISHING"
    end

    test "pausing says plainly that it takes arbiters' live updates offline mid-event" do
      html = admin_get("/admin/switches/public_publishing_paused") |> html_response(200)

      assert html =~ "Pause public publishing?"
      assert html =~ "This takes arbiters&#39; live updates offline mid-event."
      assert html =~ "operator token"
    end
  end

  describe "tournaments" do
    test "the list filters by status, open reports and search", %{world: world} do
      slugs = fn path ->
        admin_get(path) |> doc() |> text("#tournaments")
      end

      pending_only = slugs.("/admin/tournaments?status=pending")
      assert pending_only =~ world.pending
      assert pending_only =~ world.unpublished
      refute pending_only =~ world.listed

      reported = slugs.("/admin/tournaments?reported=true")
      assert reported =~ world.pending
      refute reported =~ world.listed

      assert slugs.("/admin/tournaments?search=Brugge") =~ world.listed

      assert admin_get("/admin/tournaments?search=nothing-like-this")
             |> doc()
             |> text("#tournaments-empty") =~
               "No tournament matches"
    end

    test "the front page column tells the arbiter's choice apart from moderation's status", %{
      world: world
    } do
      unlisted =
        OpenResults.SnapshotPayloads.swiss()
        |> put_in(["tournament", "slug"], "unlisted-by-arbiter")
        |> put_in(["tournament", "name"], "Unlisted Open")
        |> put_in(["tournament", "listed"], false)

      {:ok, _} = OpenResults.Snapshots.ingest(unlisted)

      rows =
        admin_get("/admin/tournaments")
        |> doc()
        |> LazyHTML.query("#tournaments tbody tr")
        |> Enum.map(&LazyHTML.text/1)

      row = fn slug -> Enum.find(rows, &(&1 =~ slug)) end

      # Moderation says "listed" for both; only one is on the front page.
      assert row.("unlisted-by-arbiter") =~ "listed: on player pages"
      assert row.("unlisted-by-arbiter") =~ "no: unlisted by the arbiter"
      assert row.(world.listed) =~ "listed: on player pages"
      assert row.(world.listed) =~ "yes"
      assert row.(world.hidden) =~ "no: hidden"
      assert row.(world.unpublished) =~ "nothing published yet"

      assert admin_get("/admin/tournaments/unlisted-by-arbiter") |> doc() |> text(".details") =~
               "front page: no: unlisted by the arbiter"
    end

    test "one tournament: owner, first and last publish, snapshot size, reports", %{world: world} do
      doc = admin_get("/admin/tournaments/#{world.pending}") |> doc()
      stats = Moderation.tournament_stats(world.pending)
      facts = text(doc, "#tournament-facts")

      assert facts =~ world.active.id
      assert facts =~ Components.at(stats.first_published_at)
      assert facts =~ Components.at(stats.last_published_at)
      assert text(doc, "#tournament-current-bytes") =~ Components.bytes(stats.current_bytes)

      assert "/admin/installations/#{world.active.id}" in hrefs(doc)
      assert "/admin/reports/#{world.open_report.id}" in hrefs(doc)
      assert text(doc, "#tournament-reports") =~ "Personal data"

      # A pending tournament offers approve and hide; not unhide.
      actions = hrefs(doc)
      assert "/admin/tournaments/#{world.pending}/approve" in actions
      assert "/admin/tournaments/#{world.pending}/hide" in actions
      refute "/admin/tournaments/#{world.pending}/unhide" in actions
    end

    test "a hidden tournament offers unhide, and says the public cannot see it", %{world: world} do
      doc = admin_get("/admin/tournaments/#{world.hidden}") |> doc()

      assert "/admin/tournaments/#{world.hidden}/unhide" in hrefs(doc)
      refute "/admin/tournaments/#{world.hidden}/approve" in hrefs(doc)
      refute "/t/#{world.hidden}" in hrefs(doc)
      assert text(doc, "#tournament-facts") =~ "not found"
    end

    test "an operator-published tournament has no owner", %{world: world} do
      assert admin_get("/admin/tournaments/#{world.listed}") |> doc() |> text("#tournament-facts") =~
               "published with the operator token"
    end

    test "a hosted publish's publisher shows in the list and on the tournament page, never on the public page or its API",
         %{world: _world} do
      payload =
        OpenResults.SnapshotPayloads.swiss()
        |> put_in(["tournament", "slug"], "hosted-with-publisher")
        |> put_in(["tournament", "name"], "Hosted With Publisher")
        |> put_in(
          ["publisher"],
          %{"email" => "jan.peeters@example.invalid", "host" => "pairings.example.org"}
        )

      {:ok, _} = OpenResults.Snapshots.ingest(payload)

      list_row =
        admin_get("/admin/tournaments")
        |> doc()
        |> LazyHTML.query("#tournaments tbody tr")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.find(&(&1 =~ "hosted-with-publisher"))

      assert list_row =~ "jan.peeters@example.invalid"

      facts =
        admin_get("/admin/tournaments/hosted-with-publisher")
        |> doc()
        |> text("#tournament-facts")

      assert facts =~ "jan.peeters@example.invalid"
      assert facts =~ "pairings.example.org"

      # The mutation-checked guard: never reaches the public page or the open API.
      public_html = get(build_conn(), "/t/hosted-with-publisher") |> html_response(200)
      refute public_html =~ "jan.peeters@example.invalid"

      public_json =
        get(build_conn(), "/api/tournaments/hosted-with-publisher") |> json_response(200)

      refute Map.has_key?(public_json, "publisher")
      refute Jason.encode!(public_json) =~ "jan.peeters@example.invalid"
    end

    test "delete says it removes every snapshot and the entry list with email addresses", %{
      world: world
    } do
      html = admin_get("/admin/tournaments/#{world.pending}/delete") |> html_response(200)

      assert html =~ "removes every snapshot"
      assert html =~ "1 stored version"
      assert html =~ "email"
      assert html =~ "cannot be undone"
    end

    test "transfer says it clears the tournament key so the target's next publish claims it", %{
      world: world
    } do
      html = admin_get("/admin/tournaments/#{world.pending}/transfer") |> html_response(200)

      assert html =~ "tournament key is cleared"
      assert html =~ "next publish with its own key claims it"
      assert html =~ ~s(name="installation_id")
      assert html =~ world.active.id
    end
  end

  describe "installations" do
    test "the list filters by status and search", %{world: world} do
      table = fn path -> admin_get(path) |> doc() |> text("#installations") end

      suspended = table.("/admin/installations?status=suspended")
      assert suspended =~ world.suspended.id
      refute suspended =~ world.active.id

      assert table.("/admin/installations?search=203.0.113.9") =~ world.active.id
    end

    test "one installation: client, version, addresses, storage and its tournaments", %{
      world: world
    } do
      doc = admin_get("/admin/installations/#{world.active.id}") |> doc()
      storage = Moderation.installation_storage(world.active.id)

      facts = text(doc, "#installation-facts")
      assert facts =~ "OpenPairings"
      assert facts =~ "0.61.0"
      assert String.trim(text(doc, "#installation-created-from")) == "203.0.113.9"
      assert text(doc, "#installation-last-seen-from") =~ "203.0.113.9"

      assert storage.snapshots == 2
      assert text(doc, "#installation-storage") =~ Components.bytes(storage.snapshot_bytes)

      tournaments = text(doc, "#installation-tournaments")
      assert tournaments =~ world.pending
      assert tournaments =~ world.hidden
      assert tournaments =~ world.unpublished

      assert "/admin/installations/#{world.active.id}/suspend" in hrefs(doc)
      assert "/admin/installations/#{world.active.id}/revoke" in hrefs(doc)
    end

    test "a revoked installation offers nothing, because revoking is final", %{world: world} do
      doc = admin_get("/admin/installations/#{world.revoked.id}") |> doc()

      assert text(doc, "#installation-actions") =~ "final"
      refute Enum.any?(hrefs(doc), &String.ends_with?(&1, "/revoke"))
    end

    test "revoke asks what happens to its tournaments, with no answer chosen for you", %{
      world: world
    } do
      doc = admin_get("/admin/installations/#{world.active.id}/revoke") |> doc()

      radios = LazyHTML.query(doc, ~s(input[name="hide_tournaments"]))
      assert radios |> LazyHTML.attribute("value") |> Enum.sort() == ["false", "true"]
      assert radios |> LazyHTML.attribute("checked") == []
      # Its published pending tournament and the one it minted but never
      # published; the hidden one is not a revoke's to hide.
      assert text(doc, "#revoke-choice") =~ ~r/Its 2 pending and listed\s+tournaments/
    end
  end

  describe "reports" do
    test "the open and resolved queues", %{world: world} do
      open = admin_get("/admin/reports") |> doc()
      assert "/admin/reports/#{world.open_report.id}" in hrefs(open)
      refute "/admin/reports/#{world.resolved_report.id}" in hrefs(open)

      resolved = admin_get("/admin/reports?status=resolved") |> doc()
      assert "/admin/reports/#{world.resolved_report.id}" in hrefs(resolved)
    end

    test "one report links to its tournament and shows what was sent", %{world: world} do
      doc = admin_get("/admin/reports/#{world.open_report.id}") |> doc()

      assert "/admin/tournaments/#{world.pending}" in hrefs(doc)
      assert text(doc, "#report-details") =~ "My email address is on the standings page."
      assert "mailto:player@example.org" in hrefs(doc)
      assert text(doc, "#report-facts") =~ "192.0.2.50"
      assert "/admin/reports/#{world.open_report.id}/resolve" in hrefs(doc)
    end

    test "a report about a deleted tournament says so", %{world: world} do
      {:ok, _} = Moderation.delete(world.pending, %{email: "someone@example.invalid"})

      assert admin_get("/admin/reports/#{world.open_report.id}")
             |> doc()
             |> text("#report-tournament") =~
               "deleted"
    end

    test "a resolved report shows the resolution and who resolved it", %{world: world} do
      doc = admin_get("/admin/reports/#{world.resolved_report.id}") |> doc()

      assert text(doc, "#report-resolution") =~ "Fine"
      assert text(doc, "#report-facts") =~ "earlier-moderator@example.invalid"
    end
  end

  describe "address blocks" do
    test "the list shows live blocks with a way to lift each", %{world: world} do
      doc = admin_get("/admin/address-blocks") |> doc()

      assert text(doc, "#blocks") =~ "192.0.2.0/24"
      assert text(doc, "#blocks") =~ "Registration flood"
      assert "/admin/address-blocks/#{world.block.id}/unblock" in hrefs(doc)
      assert "/admin/address-blocks/new" in hrefs(doc)
    end
  end

  describe "the action log" do
    test "filters by who and what", %{world: world} do
      by_action = admin_get("/admin/action-log?action=suspend") |> doc() |> text("#action-log")
      assert by_action =~ world.suspended.id
      refute by_action =~ "block_address"

      by_target =
        admin_get("/admin/action-log?target_type=installation&target=#{world.revoked.id}")
        |> doc()
        |> text("#action-log")

      assert by_target =~ "revoke"
      refute by_target =~ "suspend"

      assert admin_get("/admin/action-log?actor=nobody@example.invalid") |> html_response(200) =~
               "Nothing logged."
    end

    test "pages through a long log, newest first" do
      actor = %{email: "busy@example.invalid"}

      for n <- 1..(Components.per_page() + 5) do
        {:ok, _} = Moderation.put_setting(:registration_open, rem(n, 2) == 0, actor)
      end

      first = admin_get("/admin/action-log?actor=busy@example.invalid") |> doc()
      rows = LazyHTML.query(first, "#action-log tbody tr") |> Enum.count()
      assert rows == Components.per_page()

      [older] =
        first
        |> LazyHTML.query(~s(.admin-pager a[rel="next"]))
        |> LazyHTML.attribute("href")

      assert older =~ "actor=busy%40example.invalid"
      assert older =~ "page=2"

      second = admin_get(older) |> doc()
      assert LazyHTML.query(second, "#action-log tbody tr") |> Enum.count() == 5
      assert LazyHTML.query(second, ~s(.admin-pager a[rel="next"])) |> Enum.count() == 0
      assert LazyHTML.query(second, ~s(.admin-pager a[rel="prev"])) |> Enum.count() == 1
    end
  end
end
