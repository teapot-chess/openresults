defmodule OpenResultsWeb.AdminInstallationLabelTest do
  @moduledoc """
  The operator's private name for an installation: its changeset, the form
  and its POST, where the panel shows it, and that nothing outside the panel
  does.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures, only: [installation!: 0, mint!: 1, payload: 1]
  import OpenResultsWeb.AdminAccessHelpers

  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResultsWeb.AdminWorld

  @admin "arbiter@example.org"

  setup do
    reset_admin_access()
    configure_access()
    {:ok, world: AdminWorld.build()}
  end

  defp doc(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  describe "the changeset" do
    test "trims, turns blank into nil and refuses more than 80 characters" do
      cs = &Installation.label_changeset(%Installation{label: "old"}, %{"label" => &1})

      assert Ecto.Changeset.get_field(cs.("  Club X laptop \n"), :label) == "Club X laptop"
      assert Ecto.Changeset.get_field(cs.("   "), :label) == nil
      assert Ecto.Changeset.get_field(cs.(""), :label) == nil
      assert cs.(String.duplicate("a", 80)).valid?

      refute cs.(String.duplicate("a", 81)).valid?

      assert {_, [count: 80, validation: :length, kind: :max, type: :string]} =
               cs.(String.duplicate("a", 81)).errors[:label]
    end

    test "the create changeset does not take a label" do
      cs =
        Installation.create_changeset(%Installation{}, %{
          "id" => "in_x",
          "key_hash" => "h",
          "label" => "sneaky"
        })

      assert Ecto.Changeset.get_field(cs, :label) == nil
    end
  end

  describe "Moderation.put_installation_label/3" do
    test "stores it, logs from and to, and clears it with a blank", %{world: world} do
      id = world.active.id

      assert {:ok, %{label: "Club X laptop"}} =
               Moderation.put_installation_label(id, " Club X laptop ", %{email: @admin})

      assert %Action{actor: @admin, action: "label", target_type: "installation", target: ^id} =
               action = last_action()

      assert action.details == %{"from" => nil, "to" => "Club X laptop"}

      assert {:ok, %{label: nil}} = Moderation.put_installation_label(id, "", %{email: @admin})
      assert last_action().details == %{"from" => "Club X laptop", "to" => nil}
    end

    test "too long or unknown stores nothing", %{world: world} do
      assert {:error, %Ecto.Changeset{}} =
               Moderation.put_installation_label(
                 world.active.id,
                 String.duplicate("a", 81),
                 %{email: @admin}
               )

      assert Moderation.get_installation(world.active.id).label == nil

      assert {:error, :not_found} =
               Moderation.put_installation_label("in_nope", "x", %{email: @admin})
    end
  end

  describe "the panel" do
    test "the form renders, the post saves, and the label shows on the pages that name the installation",
         %{world: world} do
      id = world.active.id
      path = "/admin/installations/#{id}/label"

      page = admin_get(path) |> doc()
      assert LazyHTML.query(page, "#label-form input#installation-label") |> Enum.count() == 1

      assert LazyHTML.query(page, ~s(#label-form input[name="confirm"][value="#{path}"]))
             |> Enum.count() == 1

      show = admin_get("/admin/installations/#{id}") |> doc()
      assert show |> LazyHTML.query("#installation-label-link") |> LazyHTML.text() =~ "Name it"

      conn = confirm_and_post(path, %{"label" => "Club X laptop"})
      assert redirected_to(conn) == "/admin/installations/#{id}"
      assert %Action{actor: @admin, action: "label"} = last_action()

      show = admin_get("/admin/installations/#{id}") |> doc()
      assert show |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Club X laptop"
      assert show |> LazyHTML.query("#installation-id") |> LazyHTML.text() =~ id
      assert show |> LazyHTML.query("#installation-label-link") |> LazyHTML.text() =~ "Rename"

      index = admin_get("/admin/installations") |> doc()

      assert index |> LazyHTML.query("#installations .installation-label") |> LazyHTML.text() =~
               "Club X laptop"

      filtered = admin_get("/admin/installations?search=laptop") |> doc()
      assert filtered |> LazyHTML.query("#installations") |> LazyHTML.text() =~ id
      missed = admin_get("/admin/installations?search=zzzz") |> doc()
      assert LazyHTML.query(missed, "#installations-empty") |> Enum.count() == 1

      tournaments = admin_get("/admin/tournaments") |> doc()
      assert tournaments |> LazyHTML.text() =~ "Club X laptop"

      tournament = admin_get("/admin/tournaments/#{world.pending}") |> doc()
      assert tournament |> LazyHTML.query("#owner-label") |> LazyHTML.text() =~ "Club X laptop"
    end

    test "too long comes back to the form with a sentence and nothing stored", %{world: world} do
      id = world.active.id
      path = "/admin/installations/#{id}/label"

      conn = confirm_and_post(path, %{"label" => String.duplicate("a", 81)})

      assert conn
             |> html_response(422)
             |> LazyHTML.from_document()
             |> LazyHTML.query("#label-error")
             |> Enum.count() == 1

      assert Moderation.get_installation(id).label == nil
    end

    test "an unknown installation is not found" do
      assert admin_get("/admin/installations/in_nope/label").status == 404
    end
  end

  describe "outside the panel" do
    test "no public page, API answer or registration response carries the label" do
      {installation, key} = installation!()
      slug = mint!(installation)
      label = "Club X laptop 7731"

      assert {:ok, _} =
               Moderation.put_installation_label(installation.id, label, %{email: @admin})

      published = OpenResults.PublicPublishingFixtures.publish(payload(slug), key)
      assert published.status == 200
      refute published.resp_body =~ label

      page = get(build_conn(), "/t/#{slug}")
      assert html_response(page, 200)
      refute page.resp_body =~ label

      history = OpenResults.PublicPublishingFixtures.history(slug, key)
      refute history.resp_body =~ label

      server = get(build_conn(), "/api/server")
      refute server.resp_body =~ label

      home = get(build_conn(), "/")
      refute home.resp_body =~ label
    end
  end
end
