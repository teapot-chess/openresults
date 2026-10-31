defmodule OpenResultsWeb.AdminSystemTest do
  @moduledoc """
  `/admin/system` and `/admin/dashboard`: both behind the admin gate, the
  System page's three confirmed actions, and the dashboard's two halves -
  the scripts its CSP allows by nonce on its pages and nowhere else, and the
  session stamp its socket is admitted by.

  The walks in `admin_panel_test.exs`, `admin_pages_test.exs` and
  `accessibility_test.exs` read the router, so they also hold these routes to
  the gate's 404, `no-store` and (for the System page) the audit.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers
  import Phoenix.LiveViewTest, only: [live: 2]

  alias OpenResults.Ops.{Age, ErrorReports, OffsiteBackup}
  alias OpenResultsWeb.AdminAccess.LiveDashboard

  setup do
    reset_admin_access()
    configure_access()
    :ok
  end

  defp put_env_for_test(key, value) do
    previous = Application.fetch_env(:openresults, key)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:openresults, key, v)
        :error -> Application.delete_env(:openresults, key)
      end
    end)

    Application.put_env(:openresults, key, value)
  end

  defp crash!(kind \\ "RuntimeError") do
    {:new, row} =
      ErrorReports.record(%{
        fingerprint: "fp-#{System.unique_integer([:positive])}",
        kind: kind,
        message: "it broke",
        location: "OpenResults.Thing.run/0",
        stacktrace: "OpenResults.Thing.run/0 (lib/thing.ex:1)"
      })

    row
  end

  defp flash_after(conn) do
    conn
    |> next_request()
    |> dispatch(@endpoint, :get, redirected_to(conn), nil)
    |> html_response(200)
  end

  describe "the gate" do
    test "a stranger gets the unknown-route 404 on both pages" do
      for path <- ["/admin/system", "/admin/dashboard", "/admin/dashboard/home"] do
        conn = get(build_conn(), path)
        assert {conn.status, conn.resp_body} == {404, unknown_route_body()}, path
      end
    end

    test "a signed-in address not on the list gets the 403" do
      conn = get(admin_conn("someone@example.org"), "/admin/dashboard")
      assert conn.status == 403
    end
  end

  describe "the System page" do
    test "shows health, the off-site state and the crashes" do
      row = crash!()
      doc = admin_get("/admin/system") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#health-status") |> LazyHTML.text() == "ok"
      assert doc |> LazyHTML.query("#health-database") |> LazyHTML.text() == "ok"
      assert doc |> LazyHTML.query("#health-backup") |> LazyHTML.text() == "disabled"
      assert LazyHTML.query(doc, "#offsite-disabled") |> Enum.count() == 1
      assert LazyHTML.query(doc, "#error-#{row.id}") |> Enum.count() == 1
      assert LazyHTML.query(doc, "#system-dashboard-link") |> Enum.count() == 1
      # In the navigation, as a section of its own.
      assert doc |> LazyHTML.query(".admin-nav a[href='/admin/system']") |> Enum.count() == 1
    end

    test "forgetting one crash, then all of them, each from its confirmation" do
      a = crash!()
      _b = crash!("ArgumentError")

      conn = confirm_and_post("/admin/system/errors/#{a.id}/forget")
      assert redirected_to(conn) == "/admin/system"
      assert flash_after(conn) =~ "Forgot the RuntimeError report."
      assert [%{kind: "ArgumentError"}] = ErrorReports.list()

      conn = confirm_and_post("/admin/system/errors/clear")
      assert flash_after(conn) =~ "Forgot 1 error report(s)."
      assert ErrorReports.list() == []
    end

    test "a forget without its confirmation changes nothing" do
      row = crash!()
      conn = post_with_token("/admin/system/errors/clear")

      assert conn.status == 400
      assert [%{id: id}] = ErrorReports.list()
      assert id == row.id
    end

    test "an error report that does not exist is the panel's own 404" do
      assert admin_get("/admin/system/errors/999999/forget") |> html_response(404) =~ "Not found"
      assert admin_get("/admin/system/errors/abc/forget") |> html_response(404) =~ "Not found"
    end

    test "sending now without a configuration goes back to the page and says so" do
      conn = admin_get("/admin/system/offsite-backup")
      assert redirected_to(conn) == "/admin/system"
    end

    test "sending now, configured: the newest local backup goes, and the run is shown" do
      dir = Path.join(System.tmp_dir!(), "system-send-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      put_env_for_test(:backup_dir, dir)
      {:ok, _path} = OpenResults.Backup.create(dir: dir)

      {_secret, public} = Age.generate_identity()

      put_env_for_test(:offsite_backup,
        recipients: [public],
        stale_hours: 36,
        s3: [
          endpoint: "https://objects.example.test",
          bucket: "backups",
          prefix: "openresults",
          access_key_id: "AKIDEXAMPLE",
          secret_access_key: "never-shown"
        ]
      )

      Req.Test.stub(OffsiteBackup, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      html = admin_get("/admin/system") |> html_response(200)
      assert html =~ "objects.example.test"
      refute html =~ "never-shown"
      refute html =~ "AKIDEXAMPLE"
      refute html =~ public

      conn = confirm_and_post("/admin/system/offsite-backup")
      assert redirected_to(conn) == "/admin/system"
      page = flash_after(conn)
      assert page =~ "Sent off-site as openresults/"
      assert [%{status: "ok"}] = OffsiteBackup.runs()
      assert page =~ ~s(id="offsite-run-)
    end
  end

  describe "LiveDashboard" do
    test "renders for the admin, its scripts allowed by this request's nonce only" do
      conn = admin_get("/admin/dashboard/home")
      html = html_response(conn, 200)

      [policy] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/script-src 'nonce-([^']+)'/, policy)
      assert html =~ ~s(nonce="#{nonce}")
      refute policy =~ "unsafe-eval"
      assert policy =~ "frame-ancestors 'none'"
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      # Its socket is the admin one, under the Access application.
      assert html =~ ~s(phx-socket="/admin/live")

      # And a second request gets a different nonce.
      [again] = admin_get("/admin/dashboard/home") |> get_resp_header("content-security-policy")
      refute again == policy
    end

    test "every other admin page keeps script-src 'none'" do
      [policy] = admin_get("/admin/system") |> get_resp_header("content-security-policy")
      assert policy =~ "script-src 'none'"
    end

    test "the socket mounts behind a page that passed the gate" do
      {:ok, _view, html} = live(admin_conn(), "/admin/dashboard/home")
      assert html =~ "Phoenix LiveDashboard" or html =~ "System information"
    end

    test "the on_mount check: a fresh stamp for a listed admin, and nothing else" do
      now = System.system_time(:second)
      admin = admin_email()

      assert LiveDashboard.admitted?(%{"email" => admin, "at" => now}, now)
      refute LiveDashboard.admitted?(%{"email" => admin, "at" => now - 13 * 3600}, now)
      refute LiveDashboard.admitted?(%{"email" => "someone@example.org", "at" => now}, now)
      refute LiveDashboard.admitted?(nil, now)
      refute LiveDashboard.admitted?(%{"email" => admin}, now)

      # An address removed from the list closes the dashboard at the next mount.
      configure_access(emails: "someone-else@example.org")
      refute LiveDashboard.admitted?(%{"email" => admin, "at" => now}, now)
    end

    test "a mount without the stamp is sent back to the panel" do
      assert {:halt, _socket} =
               LiveDashboard.on_mount(:admin, %{}, %{}, %Phoenix.LiveView.Socket{})
    end
  end
end
