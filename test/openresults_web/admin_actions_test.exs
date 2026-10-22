defmodule OpenResultsWeb.AdminActionsTest do
  @moduledoc """
  Every admin action, done the only way the panel allows: its confirmation
  page, then a CSRF-checked POST from that page - and each one leaves an
  action-log entry carrying the signed-in admin's email.

  Then the same actions refused: without the confirmation marker, without a
  CSRF token, and with input that cannot be used, which comes back to the
  form with a sentence rather than a 500.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.AddressBlocks.Block
  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.Reports.Report
  alias OpenResults.Snapshots
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament
  alias OpenResultsWeb.Admin.Components
  alias OpenResultsWeb.AdminWorld

  @admin "arbiter@example.org"

  setup do
    reset_admin_access()
    configure_access()
    {:ok, world: AdminWorld.build()}
  end

  defp action_count, do: length(Moderation.list_actions(%{limit: 100_000}))

  defp assert_logged(action, target) do
    assert %Action{actor: @admin, action: ^action, target: ^target} = last_action()
  end

  defp flash_after(conn) do
    conn
    |> next_request()
    |> dispatch(@endpoint, :get, redirected_to(conn), nil)
    |> html_response(200)
  end

  describe "switches" do
    test "open registration, then pause and resume publishing" do
      conn = confirm_and_post("/admin/switches/registration_open", %{"value" => "true"})

      assert redirected_to(conn) == "/admin"
      assert Moderation.settings().registration_open
      assert_logged("put_setting", "registration_open")
      assert flash_after(conn) =~ "Registration is open."

      confirm_and_post("/admin/switches/public_publishing_paused", %{"value" => "true"})
      assert Moderation.settings().public_publishing_paused
      assert %Action{actor: @admin, details: %{"value" => true}} = last_action()

      confirm_and_post("/admin/switches/public_publishing_paused", %{"value" => "false"})
      refute Moderation.settings().public_publishing_paused
      assert %Action{actor: @admin, details: %{"value" => false}} = last_action()
    end

    test "the confirmation offers the flip, as an explicit value" do
      html = admin_get("/admin/switches/registration_open") |> html_response(200)

      assert html =~ ~s(name="value" value="true")
    end

    test "a value the switch does not take re-renders the confirmation, changing nothing" do
      before = action_count()

      for value <- [nil, "", "yes", "1"] do
        params = if value, do: %{"value" => value}, else: %{}
        conn = confirm_and_post("/admin/switches/registration_open", params)

        assert html_response(conn, 422) =~ "not a value this switch takes"
      end

      refute Moderation.settings().registration_open
      assert action_count() == before
    end

    test "a switch that does not exist is a 404, not a crash" do
      conn =
        post_with_token("/admin/switches/open_the_floodgates", %{
          "confirm" => "/admin/switches/open_the_floodgates",
          "value" => "true"
        })

      assert html_response(conn, 404) =~ "no switch called"
    end
  end

  describe "tournaments" do
    test "approve", %{world: world} do
      conn = confirm_and_post("/admin/tournaments/#{world.pending}/approve")

      assert redirected_to(conn) == "/admin/tournaments/#{world.pending}"
      assert Tournaments.status(world.pending) == :listed
      assert_logged("approve", world.pending)
      assert flash_after(conn) =~ "Approved"
    end

    test "hide, then unhide", %{world: world} do
      confirm_and_post("/admin/tournaments/#{world.listed}/hide")
      assert Tournaments.status(world.listed) == :hidden
      assert_logged("hide", world.listed)

      confirm_and_post("/admin/tournaments/#{world.listed}/unhide")
      assert Tournaments.status(world.listed) == :listed
      assert_logged("unhide", world.listed)
    end

    test "delete removes every snapshot and says what went", %{world: world} do
      conn = confirm_and_post("/admin/tournaments/#{world.pending}/delete")

      assert redirected_to(conn) == "/admin/tournaments"
      assert Snapshots.history(world.pending) == []
      assert Moderation.get_tournament(world.pending) == nil

      assert %Action{actor: @admin, action: "delete", details: %{"snapshots" => 1}} =
               last_action()

      assert flash_after(conn) =~ "1 stored version"
    end

    test "transfer to another installation", %{world: world} do
      {target, _key} = OpenResults.PublicPublishingFixtures.installation!()

      conn =
        confirm_and_post("/admin/tournaments/#{world.pending}/transfer", %{
          "installation_id" => " #{target.id} "
        })

      assert redirected_to(conn) == "/admin/tournaments/#{world.pending}"
      assert %Tournament{installation_id: id} = Tournaments.get(world.pending)
      assert id == target.id
      assert %Action{actor: @admin, action: "transfer", details: %{"to" => ^id}} = last_action()
      assert flash_after(conn) =~ "next publish claims it"
    end

    test "transfer refuses an unknown, a revoked, a suspended or a missing installation id on the form",
         %{
           world: world
         } do
      before = action_count()
      path = "/admin/tournaments/#{world.pending}/transfer"

      for {id, message} <- [
            {"in_nobody", "No installation has the id in_nobody."},
            {world.revoked.id, "is revoked"},
            {world.suspended.id, "is suspended, so its key cannot publish"},
            {"", "Enter the id of the installation"},
            {"   ", "Enter the id of the installation"}
          ] do
        conn = confirm_and_post(path, %{"installation_id" => id})
        html = html_response(conn, 422)

        assert html =~ message, inspect(id)
        # Still the form, ready to try again.
        assert html =~ ~s(name="installation_id")
      end

      assert Tournaments.get(world.pending).installation_id == world.active.id
      assert action_count() == before
    end

    test "an action that no longer applies changes nothing and says why", %{world: world} do
      page = admin_get("/admin/tournaments/#{world.pending}/approve")
      token = page |> html_response(200) |> csrf_token()

      # Somebody else approves it in the meantime...
      {:ok, _} = Moderation.approve(world.pending, %{email: "other@example.invalid"})
      before = action_count()

      # ...and this confirmation arrives second.
      conn =
        page
        |> next_request()
        |> post("/admin/tournaments/#{world.pending}/approve", %{
          "_csrf_token" => token,
          "confirm" => "/admin/tournaments/#{world.pending}/approve"
        })

      assert redirected_to(conn) == "/admin/tournaments/#{world.pending}"
      assert flash_after(conn) =~ "Nothing changed"
      assert action_count() == before
    end
  end

  describe "installations" do
    test "suspend, then unsuspend", %{world: world} do
      id = world.active.id

      confirm_and_post("/admin/installations/#{id}/suspend")
      assert %Installation{status: "suspended"} = Moderation.get_installation(id)
      assert_logged("suspend", id)

      confirm_and_post("/admin/installations/#{id}/unsuspend")
      assert %Installation{status: "active"} = Moderation.get_installation(id)
      assert_logged("unsuspend", id)
    end

    test "revoke, hiding its tournaments", %{world: world} do
      id = world.active.id

      conn =
        confirm_and_post("/admin/installations/#{id}/revoke", %{"hide_tournaments" => "true"})

      assert redirected_to(conn) == "/admin/installations/#{id}"
      assert %Installation{status: "revoked"} = Moderation.get_installation(id)
      assert Tournaments.status(world.pending) == :hidden

      assert %Action{actor: @admin, action: "revoke", details: %{"hide_tournaments" => true}} =
               last_action()
    end

    test "revoke, leaving its tournaments as they are", %{world: world} do
      id = world.suspended.id
      confirm_and_post("/admin/installations/#{id}/revoke", %{"hide_tournaments" => "false"})

      assert %Installation{status: "revoked"} = Moderation.get_installation(id)

      assert %Action{actor: @admin, action: "revoke", details: %{"hide_tournaments" => false}} =
               last_action()
    end

    test "revoke without a choice about its tournaments re-renders the form, changing nothing", %{
      world: world
    } do
      before = action_count()

      for choice <- [nil, "", "maybe"] do
        params = if choice, do: %{"hide_tournaments" => choice}, else: %{}
        conn = confirm_and_post("/admin/installations/#{world.active.id}/revoke", params)

        assert html_response(conn, 422) =~ "Choose what happens to its tournaments"
      end

      assert %Installation{status: "active"} = Moderation.get_installation(world.active.id)
      assert Tournaments.status(world.pending) == :pending
      assert action_count() == before
    end
  end

  describe "moving every tournament to another installation" do
    setup %{world: world} do
      # The restored laptop, registered anew and seen since.
      {restored, _key} = OpenResults.PublicPublishingFixtures.installation!({198, 51, 100, 77})
      :ok = OpenResults.Installations.touch(restored, {198, 51, 100, 78})

      {:ok,
       restored: restored,
       path: "/admin/installations/#{world.active.id}/move-tournaments",
       moving: Enum.sort([world.pending, world.hidden, world.unpublished])}
    end

    test "the form lists what would move; checking shows which laptop it would move to", %{
      world: world,
      restored: restored,
      path: path,
      moving: moving
    } do
      form = admin_get(path) |> html_response(200)
      for slug <- moving, do: assert(form =~ slug)
      assert form =~ ~s(name="to")

      confirmation = admin_get(path <> "?to=#{restored.id}") |> html_response(200)
      doc = LazyHTML.from_document(confirmation)

      assert confirmation =~ "Move 3 tournaments from #{world.active.id} to #{restored.id}?"

      listed = doc |> LazyHTML.query("#moving-tournaments li code") |> Enum.map(&LazyHTML.text/1)
      assert Enum.sort(listed) == moving

      target = doc |> LazyHTML.query("#move-target") |> LazyHTML.text()
      assert target =~ "OpenPairings"
      assert target =~ "0.61.0"
      assert target =~ Components.at(Moderation.get_installation(restored.id).last_seen_at)
      assert target =~ "198.51.100.78"

      assert doc |> LazyHTML.query(~s(input[name="to"])) |> LazyHTML.attribute("value") == [
               restored.id
             ]
    end

    test "confirming moves them all and logs each move and the whole, as the admin", %{
      world: world,
      restored: restored,
      path: path,
      moving: moving
    } do
      page = admin_get(path <> "?to=#{restored.id}")
      token = page |> html_response(200) |> csrf_token()
      before = action_count()

      conn =
        page
        |> next_request()
        |> post(path, %{"_csrf_token" => token, "confirm" => path, "to" => restored.id})

      assert redirected_to(conn) == "/admin/installations/#{restored.id}"
      assert flash_after(conn) =~ "Moved 3 tournaments"

      for slug <- moving, do: assert(Tournaments.get(slug).installation_id == restored.id)

      rows = Moderation.list_actions(%{limit: action_count() - before})
      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.actor == @admin))

      from = world.active.id

      assert [%Action{action: "transfer_all", target: ^from} | transfers] = rows
      assert transfers |> Enum.map(& &1.target) |> Enum.sort() == moving
    end

    test "a target that cannot receive them is refused on the form, before and after confirming",
         %{
           world: world,
           path: path
         } do
      {suspended_target, _key} = OpenResults.PublicPublishingFixtures.installation!()
      {:ok, _} = Moderation.suspend(suspended_target.id, %{email: "other@example.invalid"})
      before = action_count()

      cases = [
        {world.active.id, "That is this installation."},
        {"in_nobody", "No installation has the id in_nobody."},
        {world.revoked.id, "is revoked"},
        {suspended_target.id, "is suspended, so its key cannot publish"},
        {"", "Enter the id of the installation"}
      ]

      for {to, message} <- cases do
        # Checking it...
        checked = admin_get(path <> "?" <> URI.encode_query(%{"to" => to}))
        assert html_response(checked, 422) =~ message, inspect(to)
        assert html_response(checked, 422) =~ ~s(id="move-form")

        # ...and posting it anyway, as a crafted confirmation would.
        posted = post_with_token(path, %{"confirm" => path, "to" => to})
        assert html_response(posted, 422) =~ message, inspect(to)
      end

      assert Tournaments.get(world.pending).installation_id == world.active.id
      assert action_count() == before
    end

    test "an installation with nothing to move offers nothing to move", %{world: world} do
      conn = admin_get("/admin/installations/#{world.suspended.id}/move-tournaments")

      assert redirected_to(conn) == "/admin/installations/#{world.suspended.id}"
      assert flash_after(conn) =~ "nothing to move"

      refute admin_get("/admin/installations/#{world.suspended.id}") |> html_response(200) =~
               "move-tournaments"
    end
  end

  describe "reports" do
    test "resolve with a resolution", %{world: world} do
      id = world.open_report.id

      conn =
        confirm_and_post("/admin/reports/#{id}/resolve", %{"resolution" => "Hid the tournament."})

      assert redirected_to(conn) == "/admin/reports"

      assert %Report{status: "resolved", resolution: "Hid the tournament.", resolved_by: @admin} =
               Moderation.get_report(id)

      assert_logged("resolve_report", Integer.to_string(id))
    end

    test "an empty or overlong resolution re-renders the form, changing nothing", %{world: world} do
      before = action_count()
      path = "/admin/reports/#{world.open_report.id}/resolve"

      assert html_response(confirm_and_post(path, %{"resolution" => "  "}), 422) =~
               "Write what was done"

      assert html_response(confirm_and_post(path, %{}), 422) =~ "Write what was done"

      long = String.duplicate("x", 2001)
      html = html_response(confirm_and_post(path, %{"resolution" => long}), 422)
      assert html =~ "2000 characters"
      # What was typed is kept for editing rather than thrown away.
      assert html =~ long

      assert %Report{status: "open"} = Moderation.get_report(world.open_report.id)
      assert action_count() == before
    end
  end

  describe "address blocks" do
    defp preview(block) do
      page = admin_get("/admin/address-blocks/new")
      token = page |> html_response(200) |> csrf_token()

      page
      |> next_request()
      |> post("/admin/address-blocks/new", %{"_csrf_token" => token, "block" => block})
    end

    test "check shows who it reaches, then the confirmed block is stored and logged", %{
      world: world
    } do
      before = action_count()

      checked =
        preview(%{
          "address" => "203.0.113.77/24",
          "duration" => "2",
          "unit" => "days",
          "reason" => "Minting flood"
        })

      html = html_response(checked, 200)
      doc = LazyHTML.from_document(html)

      # The normalised range, and how many installations it reaches -
      # the world's active installation registered from 203.0.113.9.
      assert html =~ "Block 203.0.113.0/24?"
      assert Moderation.installations_seen_from("203.0.113.0/24") == 1
      assert doc |> LazyHTML.query("#block-reach") |> LazyHTML.text() =~ "1 installation"
      # Checking stores nothing.
      assert action_count() == before
      assert length(Moderation.list_blocks()) == 1

      hidden = fn name ->
        doc
        |> LazyHTML.query(~s(input[name="#{name}"]))
        |> LazyHTML.attribute("value")
        |> List.first()
      end

      assert hidden.("confirm") == "/admin/address-blocks"
      assert hidden.("block[address]") == "203.0.113.0/24"

      done =
        checked
        |> next_request()
        |> post("/admin/address-blocks", %{
          "_csrf_token" => hidden.("_csrf_token"),
          "confirm" => hidden.("confirm"),
          "block" => %{
            "address" => hidden.("block[address]"),
            "expires_at" => hidden.("block[expires_at]"),
            "reason" => hidden.("block[reason]")
          }
        })

      assert redirected_to(done) == "/admin/address-blocks"

      assert %Block{cidr: "203.0.113.0/24", reason: "Minting flood", created_by: @admin} =
               Enum.find(Moderation.list_blocks(), &(&1.cidr == "203.0.113.0/24"))

      assert %Action{
               actor: @admin,
               action: "block_address",
               details: %{"cidr" => "203.0.113.0/24"}
             } =
               last_action()

      assert world.block
    end

    test "a single address is counted as the address it is" do
      html =
        preview(%{
          "address" => "192.0.2.50",
          "duration" => "6",
          "unit" => "hours",
          "reason" => "x"
        })
        |> html_response(200)

      assert html =~ "Block 192.0.2.50/32?"
      assert html =~ "No installation"
      assert html =~ "this address"
    end

    test "input that cannot be a block comes back to the form, never a 500", %{world: _world} do
      before = action_count()

      for {block, message} <- [
            {%{
               "address" => "not an address",
               "duration" => "1",
               "unit" => "days",
               "reason" => "x"
             }, "not an IP address or a CIDR range"},
            {%{
               "address" => "203.0.113.1/33",
               "duration" => "1",
               "unit" => "days",
               "reason" => "x"
             }, "not an IP address or a CIDR range"},
            {%{"address" => "", "duration" => "1", "unit" => "days", "reason" => "x"},
             "Enter an IP address or a CIDR range."},
            {%{"address" => "203.0.113.1", "duration" => "31", "unit" => "days", "reason" => "x"},
             "at most 30 days"},
            {%{
               "address" => "203.0.113.1",
               "duration" => "9999999999999",
               "unit" => "hours",
               "reason" => "x"
             }, "at most 30 days"},
            {%{
               "address" => "203.0.113.1",
               "duration" => "two",
               "unit" => "days",
               "reason" => "x"
             }, "a whole number of hours or days"},
            {%{"address" => "203.0.113.1", "duration" => "0", "unit" => "days", "reason" => "x"},
             "a whole number of hours or days"},
            {%{"address" => "203.0.113.1", "duration" => "1", "unit" => "weeks", "reason" => "x"},
             "a whole number of hours or days"},
            {%{"address" => "203.0.113.1", "duration" => "1", "unit" => "days", "reason" => "  "},
             "Give a reason."}
          ] do
        conn = preview(block)
        html = html_response(conn, 422)

        assert html =~ message, inspect(block)
        assert html =~ "Nothing has been blocked."
        assert html =~ ~s(id="block-form")
      end

      # A request with no block at all.
      assert html_response(preview(nil), 422) =~ "Enter an IP address"

      assert action_count() == before
    end

    test "a confirmation whose fields were tampered with is checked again, and refused on the form" do
      before = action_count()
      now = DateTime.utc_now()

      for {expires_at, message} <- [
            {"not-a-time", "a whole number of hours or days"},
            {DateTime.to_iso8601(DateTime.add(now, 40 * 86_400, :second)), "at most 30 days"},
            {DateTime.to_iso8601(DateTime.add(now, -60, :second)), "in the future"}
          ] do
        conn =
          post_with_token("/admin/address-blocks", %{
            "confirm" => "/admin/address-blocks",
            "block" => %{
              "address" => "203.0.113.0/24",
              "expires_at" => expires_at,
              "reason" => "x"
            }
          })

        assert html_response(conn, 422) =~ message
      end

      conn =
        post_with_token("/admin/address-blocks", %{
          "confirm" => "/admin/address-blocks",
          "block" => %{
            "address" => "rubbish",
            "expires_at" => DateTime.to_iso8601(DateTime.add(now, 3600, :second)),
            "reason" => "x"
          }
        })

      assert html_response(conn, 422) =~ "not an IP address or a CIDR range"
      assert action_count() == before
    end

    test "unblock", %{world: world} do
      id = world.block.id
      conn = confirm_and_post("/admin/address-blocks/#{id}/unblock")

      assert redirected_to(conn) == "/admin/address-blocks"
      assert Moderation.list_blocks() == []
      assert_logged("unblock", Integer.to_string(id))
    end

    test "unblocking a block that is already gone says so", %{world: world} do
      path = "/admin/address-blocks/#{world.block.id}/unblock"
      page = admin_get(path)
      token = page |> html_response(200) |> csrf_token()
      {:ok, _} = Moderation.unblock(world.block.id, %{email: "other@example.invalid"})

      conn =
        page
        |> next_request()
        |> post(path, %{"_csrf_token" => token, "confirm" => path})

      assert redirected_to(conn) == "/admin/address-blocks"
      assert flash_after(conn) =~ "already expired or been lifted"
    end
  end

  describe "fields that arrive in a shape no form sends" do
    test "a map or a list where text belongs re-renders the form, never a 500", %{world: world} do
      before = action_count()

      assert html_response(
               confirm_and_post("/admin/tournaments/#{world.pending}/transfer", %{
                 "installation_id" => %{"x" => "in_nobody"}
               }),
               422
             ) =~ "Enter the id of the installation"

      assert html_response(
               confirm_and_post("/admin/reports/#{world.open_report.id}/resolve", %{
                 "resolution" => ["Hid it"]
               }),
               422
             ) =~ "Write what was done"

      assert html_response(
               confirm_and_post("/admin/installations/#{world.active.id}/revoke", %{
                 "hide_tournaments" => %{"a" => "true"}
               }),
               422
             ) =~ "Choose what happens"

      assert html_response(
               confirm_and_post("/admin/switches/registration_open", %{"value" => ["true"]}),
               422
             ) =~ "not a value this switch takes"

      page = admin_get("/admin/address-blocks/new")
      token = page |> html_response(200) |> csrf_token()

      preview =
        page
        |> next_request()
        |> post("/admin/address-blocks/new", %{
          "_csrf_token" => token,
          "block" => %{
            "address" => %{"x" => "203.0.113.1"},
            "duration" => ["1"],
            "unit" => %{},
            "reason" => ["x"]
          }
        })

      assert html_response(preview, 422) =~ "Nothing has been blocked."

      created =
        post_with_token("/admin/address-blocks", %{
          "confirm" => "/admin/address-blocks",
          "block" => %{"address" => %{"a" => "b"}, "expires_at" => %{}, "reason" => []}
        })

      assert html_response(created, 422) =~ "Nothing has been blocked."

      assert action_count() == before
    end

    test "and so does a query string", %{world: _world} do
      for path <- [
            "/admin/tournaments?page[x]=1&status[]=pending&search[a]=b&reported[]=true",
            "/admin/installations?status[a]=b&search[]=x",
            "/admin/reports?status[]=open&page[]=2",
            "/admin/action-log?actor[a]=b&action[]=hide&target_type[x]=y&target[]=z"
          ] do
        assert admin_get(path).status == 200, path
      end
    end
  end

  describe "every POST route under /admin, including ones added later" do
    setup %{world: world} do
      posts =
        for %{verb: :post, path: "/admin" <> _ = path} <- OpenResultsWeb.Router.__routes__() do
          path
          |> String.replace(":slug", world.pending)
          |> String.replace(
            ~r"^/admin/installations/:id",
            "/admin/installations/#{world.active.id}"
          )
          |> String.replace(~r"^/admin/reports/:id", "/admin/reports/#{world.open_report.id}")
          |> String.replace(
            ~r"^/admin/address-blocks/:id",
            "/admin/address-blocks/#{world.block.id}"
          )
          |> String.replace(":key", "registration_open")
        end

      {:ok, posts: posts}
    end

    # The one POST that changes nothing: it checks a block and renders the
    # confirmation page for it.
    @checks_only ["/admin/address-blocks/new"]

    test "acts only from its own confirmation page", %{posts: posts} do
      before = action_count()
      snapshot = Moderation.counts()

      for path <- posts, path not in @checks_only do
        for marker <- [nil, "", "/admin/somewhere-else"] do
          params = %{"hide_tournaments" => "true", "value" => "true", "resolution" => "x"}
          params = if marker, do: Map.put(params, "confirm", marker), else: params

          conn = post_with_token(path, params)

          assert html_response(conn, 400) =~ "Not confirmed", "#{path} acted without confirmation"
        end
      end

      assert action_count() == before
      assert Moderation.counts() == snapshot
    end

    test "is refused without a CSRF token", %{posts: posts} do
      before = action_count()

      for path <- posts do
        {status, _headers, _body} =
          assert_error_sent(403, fn ->
            admin_conn()
            |> post(path, %{"confirm" => path, "hide_tournaments" => "true", "value" => "true"})
          end)

        assert status == 403, path
      end

      assert action_count() == before
    end

    test "writes nothing when the admin panel is not configured", %{posts: posts} do
      Application.delete_env(:openresults, :admin_emails)
      before = action_count()

      for path <- posts do
        conn = admin_conn() |> post(path, %{"confirm" => path, "value" => "true"})
        assert {conn.status, conn.resp_body} == {404, unknown_route_body()}, path
      end

      assert action_count() == before
    end
  end
end
