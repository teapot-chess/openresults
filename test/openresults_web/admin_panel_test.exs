defmodule OpenResultsWeb.AdminPanelTest do
  @moduledoc """
  What an admin response is, once the gate has let it through - and what the
  public site stays while the panel exists beside it.

  The public site is cookie-free, cacheable-with-revalidation and embeddable
  on purpose. The panel is the opposite on all three. Those two sets of
  properties now live in one app, so every test here that checks an admin
  response checks a public one next to it.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.{SnapshotPayloads, Snapshots}
  alias OpenResultsWeb.Admin.{Confirmation, Layouts}
  alias OpenResultsWeb.Plugs.AdminSession
  alias OpenResultsWeb.Plugs.Revalidate.Page

  setup do
    reset_admin_access()
    configure_access()

    swiss = SnapshotPayloads.swiss()
    {:ok, _} = Snapshots.ingest(swiss)
    {:ok, slug: swiss["tournament"]["slug"]}
  end

  # `admin_conn/0`, `next_request/1` and `csrf_token/1` come from
  # `OpenResultsWeb.AdminAccessHelpers`, which also explains why every admin
  # request in these tests switches CSRF protection back ON: the first run of
  # this file showed a CSRF test passing with the check removed.

  # An admin route's path with its parameters filled in: the published
  # tournament for `:slug`, which is what `Revalidate` and the page cache key
  # on, and a placeholder for anything else.
  defp fill(path, slug) do
    path
    # LiveDashboard's pages take a page name and a node, not an id.
    |> String.replace("/admin/dashboard/:node/:page", "/admin/dashboard/#{node()}/home")
    |> String.replace("/admin/dashboard/:page", "/admin/dashboard/home")
    |> String.replace(~r/:slug\b/, slug)
    |> String.replace(~r/[:*]\w+/, "1")
  end

  defp admin_routes,
    do: for(%{path: "/admin" <> _} = route <- OpenResultsWeb.Router.__routes__(), do: route)

  defp set_cookies(conn), do: get_resp_header(conn, "set-cookie")

  # Rendered pages the cache holds for one tournament, in any language.
  defp cached_pages(slug) do
    :ets.select_count(:openresults_page_cache, [{{{slug, :_, :_, :_}, :_}, [], [true]}])
  rescue
    # The table is created lazily; not existing means holding nothing.
    ArgumentError -> 0
  end

  describe "never stored" do
    test "every admin response is no-store, with no validator to revalidate against" do
      conn = admin_conn() |> put_req_header("if-none-match", "*") |> get(~p"/admin")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "etag") == []
    end

    test "while a public read page keeps its revalidation and its cache", %{slug: slug} do
      Page.clear()
      conn = get(build_conn(), ~p"/t/#{slug}")

      assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
      assert [_etag] = get_resp_header(conn, "etag")
      # Which also shows the count the admin test below relies on can see a
      # stored page when there is one.
      assert cached_pages(slug) > 0
    end

    test "no admin page reaches Revalidate or the page cache", %{slug: slug} do
      # `Revalidate` keys its ETag and the page cache on a `slug` parameter,
      # and the moderation pages have `/admin/tournaments/:slug` and six
      # routes beneath it. A route added to the wrong scope would put a
      # moderator's page in the cache that hands pages to strangers - so this
      # requests every admin GET route the router has, including ones added
      # after this test was written, with the slug of a tournament that really
      # is published.
      Page.clear()
      routes = for %{verb: :get} = route <- admin_routes(), do: route
      walked = Enum.map(routes, & &1.path)

      # The walk reaches every section and the pages beneath them, so it
      # really is the management pages being checked and not only the gate.
      for {_label, path} <- Layouts.sections(), do: assert(path in walked, path)
      assert "/admin/tournaments/:slug/delete" in walked
      assert "/admin/installations/:id/move-tournaments" in walked
      assert "/admin/address-blocks/new" in walked

      for route <- routes do
        conn = get(admin_conn(), fill(route.path, slug))

        assert get_resp_header(conn, "etag") == [], "#{route.path} was revalidated"
        assert get_resp_header(conn, "cache-control") == ["no-store"], route.path
      end

      assert cached_pages(slug) == 0
    end

    test "every admin route, present and future, is behind the gate", %{slug: slug} do
      Application.delete_env(:openresults, :admin_emails)

      for route <- admin_routes() do
        method = route.verb |> to_string() |> String.upcase()

        conn =
          build_conn() |> enforce_csrf() |> dispatch(@endpoint, method, fill(route.path, slug))

        assert {conn.status, conn.resp_body} == {404, unknown_route_body()},
               "#{method} #{route.path}"
      end
    end

    test "and the error an admin can hit on the way is no-store too" do
      # A POST without its CSRF token is refused inside the pipeline, which
      # is exactly where an exception would otherwise lose the admin headers.
      {403, headers, _body} =
        assert_error_sent(403, fn -> admin_conn() |> post(~p"/admin/confirmation-probe", %{}) end)

      assert {"cache-control", "no-store"} in headers
      assert {"x-frame-options", "DENY"} in headers
    end
  end

  describe "never framed" do
    test "the admin panel refuses every frame, both ways of saying it", %{slug: slug} do
      admin = get(admin_conn(), ~p"/admin")
      [policy] = get_resp_header(admin, "content-security-policy")

      assert policy =~ "frame-ancestors 'none'"
      refute policy =~ "frame-ancestors *"
      assert get_resp_header(admin, "x-frame-options") == ["DENY"]

      # Beside it, a public page stays embeddable exactly as before.
      [public_policy] =
        build_conn() |> get(~p"/t/#{slug}") |> get_resp_header("content-security-policy")

      assert public_policy =~ "frame-ancestors *"
    end

    test "and runs no script" do
      [policy] = admin_conn() |> get(~p"/admin") |> get_resp_header("content-security-policy")

      assert policy =~ "script-src 'none'"
    end

    test "and asks not to be indexed" do
      conn = get(admin_conn(), ~p"/admin")

      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert html_response(conn, 200) =~ ~s(<meta name="robots" content="noindex, nofollow">)
    end
  end

  describe "the session: /admin only" do
    test "a public page and an admin page, side by side", %{slug: slug} do
      admin = get(admin_conn(), ~p"/admin/confirmation-probe")
      assert [cookie] = set_cookies(admin)
      assert cookie =~ "_openresults_admin="

      for path <- ["/", "/t/#{slug}", "/t/#{slug}/round/1", "/t/#{slug}/register", "/changelog"] do
        public = get(build_conn(), path)

        assert public.status == 200, path
        assert set_cookies(public) == [], "#{path} set a cookie"
        # Not merely unset: there is no session on a public request at all,
        # so nothing on one could set a cookie by fetching it.
        refute public.private[:plug_session_fetch], "#{path} carries a session"
      end
    end

    test "even when a public request arrives carrying the admin cookie", %{slug: slug} do
      admin = get(admin_conn(), ~p"/admin/confirmation-probe")
      public = admin |> next_request() |> get(~p"/t/#{slug}")

      assert public.req_cookies["_openresults_admin"]
      assert set_cookies(public) == []
    end

    test "the admin cookie is its own, scoped to /admin, Secure, HttpOnly, SameSite=Strict" do
      [cookie] = admin_conn() |> get(~p"/admin/confirmation-probe") |> set_cookies()

      [name_value | attributes] = String.split(cookie, "; ")
      attributes = Enum.map(attributes, &String.downcase/1)

      assert String.starts_with?(name_value, "_openresults_admin=")
      assert "path=/admin" in attributes
      assert "secure" in attributes
      assert "httponly" in attributes
      assert "samesite=strict" in attributes
      # A browser-session cookie; Access decides how long a sign-in lasts.
      refute Enum.any?(attributes, &String.starts_with?(&1, "max-age"))
      refute Enum.any?(attributes, &String.starts_with?(&1, "domain"))
    end

    test "a page with nothing to protect sets no cookie at all" do
      # The dashboard has no form, so no CSRF token is generated and there
      # is nothing to put in a session.
      assert admin_conn() |> get(~p"/admin") |> set_cookies() == []
    end

    test "the options behind that cookie say the same" do
      options = AdminSession.session_options()

      assert options[:key] == "_openresults_admin"
      assert options[:path] == "/admin"
      assert options[:secure] == true
      assert options[:http_only] == true
      assert options[:same_site] == "Strict"
    end
  end

  describe "a destructive action: confirmation page, then a CSRF-checked POST" do
    test "the confirmation page is a plain form with a token and its marker" do
      html = admin_conn() |> get(~p"/admin/confirmation-probe") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert [form] = doc |> LazyHTML.query("#confirmation-form") |> Enum.to_list()
      assert LazyHTML.attribute(form, "action") == ["/admin/confirmation-probe"]
      assert LazyHTML.attribute(form, "method") == ["post"]

      assert doc
             |> LazyHTML.query(~s(input[name="confirm"]))
             |> LazyHTML.attribute("value") == ["/admin/confirmation-probe"]

      assert csrf_token(html) != ""
      assert html =~ "Run the probe?"
      assert html =~ "Nothing happens except that the test hears about it."

      assert doc |> LazyHTML.query("#confirmation-cancel") |> LazyHTML.attribute("href") == [
               "/admin"
             ]

      # No JavaScript involved anywhere.
      refute html =~ "<script"
    end

    test "confirming carries it out, then redirects with a flash" do
      page = get(admin_conn(), ~p"/admin/confirmation-probe")
      token = page |> html_response(200) |> csrf_token()

      done =
        page
        |> next_request()
        |> post(~p"/admin/confirmation-probe", %{
          "_csrf_token" => token,
          "confirm" => "/admin/confirmation-probe",
          "note" => "carried through"
        })

      assert redirected_to(done) == "/admin"

      assert_received {:confirmation_probe_ran, %{email: "arbiter@example.org"},
                       "carried through"}

      dashboard = done |> next_request() |> get(~p"/admin") |> html_response(200)
      assert dashboard =~ "Probe ran."
    end

    test "a POST without a CSRF token is refused and does nothing" do
      page = get(admin_conn(), ~p"/admin/confirmation-probe")

      assert_error_sent 403, fn ->
        page
        |> next_request()
        |> post(~p"/admin/confirmation-probe", %{"confirm" => "/admin/confirmation-probe"})
      end

      refute_received {:confirmation_probe_ran, _, _}
    end

    test "a token from somebody else's session is refused and does nothing" do
      # The shape of a forged cross-site post: a real token, lifted from one
      # session, sent without that session's cookie.
      token =
        admin_conn() |> get(~p"/admin/confirmation-probe") |> html_response(200) |> csrf_token()

      assert_error_sent 403, fn ->
        post(admin_conn(), ~p"/admin/confirmation-probe", %{
          "_csrf_token" => token,
          "confirm" => "/admin/confirmation-probe"
        })
      end

      refute_received {:confirmation_probe_ran, _, _}
    end

    test "a valid CSRF token without the confirmation marker changes nothing" do
      page = get(admin_conn(), ~p"/admin/confirmation-probe")
      token = page |> html_response(200) |> csrf_token()

      for marker <- [nil, "", "/admin/some-other-action"] do
        params = %{"_csrf_token" => token}
        params = if marker, do: Map.put(params, "confirm", marker), else: params

        refused = page |> next_request() |> post(~p"/admin/confirmation-probe", params)

        assert html_response(refused, 400) =~ "Not confirmed"
        assert get_resp_header(refused, "cache-control") == ["no-store"]
      end

      refute_received {:confirmation_probe_ran, _, _}
    end

    test "without a valid Access token the POST is an unknown route, before CSRF is even looked at" do
      page = get(admin_conn(), ~p"/admin/confirmation-probe")
      token = page |> html_response(200) |> csrf_token()

      stranger =
        page
        |> recycle()
        |> post(~p"/admin/confirmation-probe", %{
          "_csrf_token" => token,
          "confirm" => "/admin/confirmation-probe"
        })

      assert stranger.status == 404
      assert stranger.resp_body == unknown_route_body()
      refute_received {:confirmation_probe_ran, _, _}
    end

    test "the plug lets asking through and only stops acting" do
      get_conn = Plug.Test.conn(:get, "/admin/anything")
      assert Confirmation.call(get_conn, []) == get_conn

      post_conn = %{
        Plug.Test.conn(:post, "/admin/x", %{})
        | body_params: %{"confirm" => "/admin/x"}
      }

      assert Confirmation.confirmed?(post_conn)
      refute Confirmation.confirmed?(%{post_conn | body_params: %{"confirm" => "/admin/y"}})
      refute Confirmation.confirmed?(%{post_conn | body_params: %{}})
    end
  end

  describe "the layout" do
    test "says who is signed in and offers Cloudflare Access's sign-out" do
      html = admin_conn() |> get(~p"/admin") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query("#admin-signed-in") |> LazyHTML.text() =~
               "Signed in as arbiter@example.org"

      assert doc |> LazyHTML.query("#admin-sign-out") |> LazyHTML.attribute("href") == [
               "/cdn-cgi/access/logout"
             ]
    end

    test "keeps every email address out of Cloudflare's email obfuscation, which needs a script the panel forbids" do
      html = admin_conn() |> get(~p"/admin") |> html_response(200)

      # Cloudflare skips everything between these two HTML comments. Without
      # them "Signed in as" read "[email protected]" in production, because
      # the decoder is a script and the admin CSP is script-src 'none'.
      [_before, inside] = String.split(html, "<!--email_off-->", parts: 2)
      [wrapped, _after] = String.split(inside, "<!--/email_off-->", parts: 2)

      assert wrapped =~ "Signed in as"
      assert wrapped =~ "arbiter@example.org"
      refute html |> String.replace(wrapped, "") =~ "arbiter@example.org"
    end

    test "is visibly not a public page, and carries none of the public page's scripts or pickers" do
      html = admin_conn() |> get(~p"/admin") |> html_response(200)

      assert html =~ ~s(class="admin-badge")
      refute html =~ "<script"
      refute html =~ "theme-picker"
      refute html =~ "lang-picker"
    end

    test "links only to sections that exist: no dead links" do
      conn = get(admin_conn(), ~p"/admin")
      doc = conn |> html_response(200) |> LazyHTML.from_document()

      hrefs = doc |> LazyHTML.query(".admin-nav a") |> LazyHTML.attribute("href")

      # Every section the contract lists has its page now, in order.
      assert hrefs == [
               "/admin",
               "/admin/tournaments",
               "/admin/installations",
               "/admin/reports",
               "/admin/address-blocks",
               "/admin/players",
               "/admin/action-log",
               "/admin/stats",
               "/admin/system",
               "/admin/settings"
             ]

      # And every link anywhere on the page leads to a route (query string
      # aside), or is the one address Cloudflare's edge answers itself. The
      # skip link points within the page, which `AccessibilityTest` checks.
      for href <- doc |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href"),
          href != "/cdn-cgi/access/logout",
          not String.starts_with?(href, "#") do
        path = URI.parse(href).path

        assert %{} =
                 Phoenix.Router.route_info(OpenResultsWeb.Router, "GET", path, "www.example.com"),
               "#{href} leads nowhere"
      end
    end

    test "every planned section appears exactly when its page is routed" do
      conn = %{admin_conn() | request_path: "/admin", host: "www.example.com"}
      rendered = Layouts.nav_items(conn) |> Enum.map(& &1.path)

      for {_label, path} <- Layouts.sections() do
        routed? =
          match?(
            %{},
            Phoenix.Router.route_info(OpenResultsWeb.Router, "GET", path, "www.example.com")
          )

        assert path in rendered == routed?, path
      end
    end

    test "marks the current section, and a page beneath one marks that one" do
      current = fn path ->
        %{admin_conn() | request_path: path, host: "www.example.com"}
        |> Layouts.nav_items()
        |> Enum.filter(& &1.current?)
        |> Enum.map(& &1.path)
      end

      assert current.("/admin/") == ["/admin"]
      assert current.("/admin/tournaments") == ["/admin/tournaments"]
      assert current.("/admin/tournaments/some-slug/hide") == ["/admin/tournaments"]
      assert current.("/admin/address-blocks/new") == ["/admin/address-blocks"]
      # A switch's confirmation belongs to no section of its own.
      assert current.("/admin/switches/registration_open") == []
    end
  end
end
