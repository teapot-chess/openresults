defmodule OpenResults.TrustedInstallationsTest do
  @moduledoc """
  Trusted installations and per-installation limits (the admin upgrade,
  2026-09-13): a trusted installation's mints start listed, so its results
  are on the homepage and the player pages at once; an untrusted one's stay
  pending; each of the four limits can be its own, and blank is the server's.
  Through HTTP where the property is about what an installation key gets.
  """
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Installations
  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.RateLimit
  alias OpenResults.Snapshots
  alias OpenResults.Tournaments

  @admin %{email: "trust-admin@example.org"}
  # Player 1 in the swiss fixture.
  @fide_id 1_503_014

  setup do
    RateLimit.reset()
    {installation, key} = installation!()
    {:ok, installation: installation, key: key}
  end

  defp minted_slug(key) do
    conn = mint(key)
    json_response(conn, 201)["slug"]
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:openresults, key)
    Application.put_env(:openresults, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:openresults, key, v)
        :error -> Application.delete_env(:openresults, key)
      end
    end)
  end

  defp last_action, do: hd(Moderation.list_actions(%{limit: 1}))

  describe "a trusted installation" do
    test "mints listed tournaments, on the homepage and the player pages as soon as they publish",
         %{installation: installation, key: key} do
      {:ok, trusted} = Moderation.trust(installation.id, @admin, list_pending: false)
      assert trusted.trusted

      slug = minted_slug(key)
      assert Tournaments.status(slug) == :listed

      slug |> current_payload() |> publish(key, random_key()) |> json_response(200)

      assert html_response(get(build_conn(), "/"), 200) =~ slug
      assert html_response(get(build_conn(), "/players/#{@fide_id}"), 200) =~ slug
    end

    test "an untrusted installation's tournament stays pending: homepage yes, player pages no", %{
      key: key
    } do
      slug = minted_slug(key)
      assert Tournaments.status(slug) == :pending

      slug |> current_payload() |> publish(key, random_key()) |> json_response(200)

      assert html_response(get(build_conn(), "/"), 200) =~ slug
      refute html_response(get(build_conn(), "/players/#{@fide_id}"), 200) =~ slug
    end

    test "trusting can list what is pending now, or leave it pending", %{
      installation: installation,
      key: key
    } do
      first = minted_slug(key)
      second = minted_slug(key)

      {:ok, _} = Moderation.trust(installation.id, @admin, list_pending: false)
      assert Tournaments.status(first) == :pending

      {:ok, _} = Moderation.untrust(installation.id, @admin)
      {:ok, _} = Moderation.trust(installation.id, @admin, list_pending: true)

      assert Tournaments.status(first) == :listed
      assert Tournaments.status(second) == :listed

      assert %Action{
               actor: "trust-admin@example.org",
               action: "trust",
               target_type: "installation",
               details: %{"list_pending" => true, "listed" => listed}
             } = last_action()

      # Both were minted within the same second, so creation time ties and the
      # slugs (random) break it: the logged order is stable but not mint order.
      assert Enum.sort(listed) == Enum.sort([first, second])

      approvals =
        Moderation.list_actions(%{action: "approve", limit: 10})
        |> Enum.map(& &1.target)
        |> Enum.sort()

      assert approvals == Enum.sort([first, second])
    end

    test "untrusting puts its next tournaments back to pending, and leaves the rest", %{
      installation: installation,
      key: key
    } do
      {:ok, _} = Moderation.trust(installation.id, @admin, list_pending: false)
      listed = minted_slug(key)

      {:ok, untrusted} = Moderation.untrust(installation.id, @admin)
      refute untrusted.trusted
      assert %Action{action: "untrust", target: id} = last_action()
      assert id == installation.id

      assert Tournaments.status(listed) == :listed
      assert Tournaments.status(minted_slug(key)) == :pending
    end

    test "trust twice, untrust an untrusted one, or trust a revoked one: :invalid_status", %{
      installation: installation
    } do
      assert {:error, :invalid_status} = Moderation.untrust(installation.id, @admin)
      {:ok, _} = Moderation.trust(installation.id, @admin, list_pending: false)
      assert {:error, :invalid_status} = Moderation.trust(installation.id, @admin, [])

      {:ok, _} = Moderation.revoke(installation.id, @admin, hide_tournaments: false)
      assert {:error, :invalid_status} = Moderation.trust(installation.id, @admin, [])
      assert {:error, :not_found} = Moderation.trust("in_nobody", @admin, [])
    end

    test "revoking clears trust, and says it did", %{installation: installation} do
      {:ok, _} = Moderation.trust(installation.id, @admin, list_pending: false)
      {:ok, revoked} = Moderation.revoke(installation.id, @admin, hide_tournaments: false)

      refute revoked.trusted
      assert %Action{action: "revoke", details: %{"was_trusted" => true}} = last_action()
    end

    test "suspending keeps the flag, and a suspended trusted installation still cannot publish",
         %{installation: installation, key: key} do
      {:ok, _} = Moderation.trust(installation.id, @admin, list_pending: false)
      slug = minted_slug(key)
      {:ok, suspended} = Moderation.suspend(installation.id, @admin)

      assert suspended.trusted
      assert %{"error" => "installation_suspended"} = mint(key) |> json_response(403)

      assert %{"error" => "installation_suspended"} =
               slug |> payload() |> publish(key, random_key()) |> json_response(403)
    end
  end

  describe "its own limits" do
    test "max tournaments: its own applies, blank falls back to the server's", %{
      installation: installation,
      key: key
    } do
      put_env(:installation_max_tournaments, 3)

      {:ok, _} =
        Moderation.put_installation_limits(installation.id, %{"max_tournaments" => "1"}, @admin)

      minted_slug(key)
      assert %{"error" => "tournament_limit", "limit" => 1} = mint(key) |> json_response(403)

      {:ok, _} =
        Moderation.put_installation_limits(installation.id, %{"max_tournaments" => ""}, @admin)

      minted_slug(key)
      minted_slug(key)
      assert %{"error" => "tournament_limit", "limit" => 3} = mint(key) |> json_response(403)
    end

    test "snapshot bytes: its own applies, blank falls back", %{
      installation: installation,
      key: key
    } do
      slug = minted_slug(key)
      put_env(:installation_max_snapshot_bytes, 2000)

      {:ok, _} =
        Moderation.put_installation_limits(
          installation.id,
          %{"max_snapshot_bytes" => "1000"},
          @admin
        )

      assert %{"limit_bytes" => 1000} =
               slug |> payload() |> publish(key, random_key()) |> json_response(413)

      {:ok, _} = Moderation.put_installation_limits(installation.id, %{}, @admin)

      assert %{"limit_bytes" => 2000} =
               slug |> payload() |> publish(key, random_key()) |> json_response(413)
    end

    test "publishes per minute: its own applies, blank falls back", %{
      installation: installation,
      key: key
    } do
      put_env(:installation_publishes_per_minute, 3)

      {:ok, _} =
        Moderation.put_installation_limits(
          installation.id,
          %{"publishes_per_minute" => "1"},
          @admin
        )

      minted_slug(key)
      assert mint(key).status == 429

      RateLimit.reset()
      {:ok, _} = Moderation.put_installation_limits(installation.id, %{}, @admin)

      for _ <- 1..3, do: minted_slug(key)
      assert mint(key).status == 429
    end

    test "versions kept: its own applies, blank falls back", %{
      installation: installation,
      key: key
    } do
      put_env(:installation_max_versions, 3)
      slug = minted_slug(key)
      tkey = random_key()

      {:ok, installation} =
        Moderation.put_installation_limits(installation.id, %{"max_versions" => "1"}, @admin)

      republish = fn n ->
        slug
        |> payload()
        |> put_in(["standings", "after_round"], n)
        |> Snapshots.ingest(installation: installation, key: tkey)
      end

      for n <- 1..3, do: {:ok, _} = republish.(n)
      assert length(Snapshots.history(slug)) == 1

      {:ok, installation} = Moderation.put_installation_limits(installation.id, %{}, @admin)

      republish = fn n ->
        slug
        |> payload()
        |> put_in(["standings", "after_round"], n)
        |> Snapshots.ingest(installation: installation, key: tkey)
      end

      for n <- 4..8, do: {:ok, _} = republish.(n)
      assert length(Snapshots.history(slug)) == 3
    end

    test "are validated with the server settings' ranges, and nothing is stored when one is out",
         %{installation: installation} do
      before = length(Moderation.list_actions(%{limit: 10_000}))

      for {field, raw} <- [
            {"max_tournaments", "-1"},
            {"max_snapshot_bytes", "0"},
            {"max_snapshot_bytes", "8000001"},
            {"publishes_per_minute", "0"},
            {"max_versions", "0"},
            {"max_versions", "lots"},
            {"max_versions", %{"a" => "b"}}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Moderation.put_installation_limits(
                   installation.id,
                   %{"max_tournaments" => "5", field => raw},
                   @admin
                 )

        assert Keyword.has_key?(changeset.errors, String.to_existing_atom(field))
      end

      assert Installations.get(installation.id).max_tournaments == nil
      assert length(Moderation.list_actions(%{limit: 10_000})) == before
      assert {:error, :not_found} = Moderation.put_installation_limits("in_nobody", %{}, @admin)
    end

    test "a change is logged from and to", %{installation: installation} do
      {:ok, _} =
        Moderation.put_installation_limits(
          installation.id,
          %{"max_tournaments" => "4", "max_versions" => "2"},
          @admin
        )

      assert %Action{
               action: "set_installation_limits",
               target_type: "installation",
               details: %{
                 "from" => %{"max_tournaments" => nil, "max_versions" => nil},
                 "to" => %{"max_tournaments" => 4, "max_versions" => 2}
               }
             } = last_action()
    end
  end
end
