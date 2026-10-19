defmodule OpenResultsWeb.RelayKeyTest do
  @moduledoc """
  The relay key as the live endpoint sees it: accepted for its own
  tournament's `POST /api/tournaments/:slug/live`, and refused everywhere
  else, by every other slug, and once revoked. The admin side is
  `AdminRelayKeysTest`.
  """

  use OpenResultsWeb.ConnCase, async: false

  @moduletag :capture_log

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.LiveBoards
  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.RelayKeys
  alias OpenResults.Snapshots

  @admin %{email: "arbiter@example.org"}
  @unauthorized %{"error" => "unauthorized", "detail" => "a valid credential is required"}

  setup do
    RateLimit.reset()
    slug = unique_slug("relay")
    tournament_key = random_key()
    {:ok, _} = Snapshots.ingest(payload(slug), key: tournament_key)
    {:ok, %{relay_key: relay_key, key: key}} = Moderation.create_relay_key(slug, "box", @admin)
    {:ok, slug: slug, key: key, relay_key: relay_key, tournament_key: tournament_key}
  end

  defp post_live(slug, bearer, body \\ %{"round" => 5, "board" => 1, "moves" => ["e4"]}) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> post("/api/tournaments/#{slug}/live", Jason.encode!(body))
  end

  test "works for its own tournament's live endpoint, with no tournament key", %{
    slug: slug,
    key: key
  } do
    # The tournament is claimed, and the relay does not hold its key.
    conn = post_live(slug, key)

    assert json_response(conn, 200) == %{"status" => "ok", "applied" => true, "ply" => 1}
    assert [%{ply_count: 1}] = LiveBoards.games(slug)
  end

  test "a batch works too", %{slug: slug, key: key} do
    body = %{"boards" => [%{"round" => 5, "board" => 1, "moves" => ["e4"]}]}

    assert %{"status" => "ok", "results" => [_]} =
             slug |> post_live(key, body) |> json_response(200)
  end

  test "records its use, and leaves the secret out of the log", %{
    slug: slug,
    key: key,
    relay_key: relay_key
  } do
    assert is_nil(relay_key.last_used_at)
    post_live(slug, key) |> json_response(200)

    assert %{last_used_at: %DateTime{}} = RelayKeys.get(slug, relay_key.id)

    log = Moderation.list_actions(%{limit: 20}) |> inspect()
    assert log =~ "relay_key_create"
    refute log =~ key
  end

  test "is refused for another tournament, even one published", %{key: key} do
    other = unique_slug("relay-other")
    {:ok, _} = Snapshots.ingest(payload(other))

    conn = post_live(other, key)
    assert %{"error" => "relay_key_wrong_tournament"} = json_response(conn, 403)
    assert LiveBoards.games(other) == []
  end

  test "is refused on publish, history, registrations, delete and the admin panel", %{
    slug: slug,
    key: key
  } do
    before = Snapshots.latest(slug)

    publish = payload(slug) |> publish(key)
    assert json_response(publish, 401) == @unauthorized
    assert Snapshots.latest(slug) == before

    assert json_response(history(slug, key), 401) == @unauthorized
    assert json_response(registrations(slug, key), 401) == @unauthorized

    for conn <- [
          takedown(slug, key),
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> bearer(key)
          |> post("/api/tournaments", "{}"),
          build_conn() |> bearer(key) |> get("/admin/tournaments"),
          build_conn() |> bearer(key) |> post("/admin/tournaments/#{slug}/delete", %{})
        ] do
      assert conn.status in [400, 401, 403, 404], "#{conn.request_path} => #{conn.status}"
      refute conn.status in [200, 201, 302]
    end

    assert Snapshots.latest(slug) == before
    assert RelayKeys.active_count(slug) == 1
  end

  test "a revoked key is refused, and stores nothing", %{
    slug: slug,
    key: key,
    relay_key: relay_key
  } do
    assert post_live(slug, key).status == 200
    {:ok, _} = Moderation.revoke_relay_key(slug, relay_key.id, @admin)

    conn = post_live(slug, key, %{"round" => 6, "board" => 2, "moves" => ["d4"]})
    assert %{"error" => "relay_key_revoked"} = json_response(conn, 403)
    assert Enum.map(LiveBoards.games(slug), & &1.round) == [5]
  end

  describe "a key whose tournament an installation owns" do
    setup do
      {installation, ikey} = installation!({198, 51, 100, 41})
      slug = mint!(installation)
      assert json_response(publish(payload(slug), ikey, random_key()), 200)
      {:ok, %{key: key}} = Moderation.create_relay_key(slug, "box", @admin)
      {:ok, installation: installation, slug: slug, key: key}
    end

    test "is refused while the installation is suspended, and works again after", %{
      installation: installation,
      slug: slug,
      key: key
    } do
      {:ok, _} = Moderation.suspend(installation.id, @admin)

      assert %{"error" => "owner_suspended"} = slug |> post_live(key) |> json_response(403)
      assert LiveBoards.games(slug) == []

      {:ok, _} = Moderation.unsuspend(installation.id, @admin)
      assert slug |> post_live(key) |> json_response(200)
    end

    test "is refused once the installation is revoked, even if the key itself was not", %{
      installation: installation,
      slug: slug,
      key: key
    } do
      # A revoke revokes the keys too; this is the state a revoke without that
      # leaves behind - what a restore used to.
      {:ok, _} = OpenResults.Installations.transition(installation.id, ["active"], "revoked")

      assert %{"error" => "owner_revoked"} = slug |> post_live(key) |> json_response(403)
      assert LiveBoards.games(slug) == []
    end
  end

  test "a made-up key, a truncated key and another tournament's key are the anonymous 401", %{
    slug: slug,
    key: key
  } do
    other = unique_slug("relay-third")
    {:ok, _} = Snapshots.ingest(payload(other))

    for bearer <- ["orrk_" <> String.duplicate("a", 43), String.slice(key, 0, 20), "orrk_"] do
      assert json_response(post_live(slug, bearer), 401) == @unauthorized
    end
  end

  test "has a budget of its own, per key", %{slug: slug, key: key, relay_key: relay_key} do
    for _ <- 1..1200,
        do: RateLimit.take({:relay_key, relay_key.id}, limit: 1200, window_ms: :timer.minutes(1))

    conn = post_live(slug, key)
    assert %{"error" => "rate_limited"} = json_response(conn, 429)
    assert get_resp_header(conn, "retry-after") != []

    # Another key of the same tournament is not starved by it.
    {:ok, %{key: second}} = Moderation.create_relay_key(slug, "second", @admin)
    assert post_live(slug, second).status == 200
  end

  test "the existing credentials still work on the live endpoint", %{
    slug: slug,
    tournament_key: tournament_key
  } do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> bearer(operator_token())
      |> tournament_key(tournament_key)
      |> post(
        "/api/tournaments/#{slug}/live",
        Jason.encode!(%{"round" => 1, "board" => 1, "moves" => ["e4"]})
      )

    assert json_response(conn, 200)["status"] == "ok"
  end

  test "a takedown takes the keys with it", %{slug: slug} do
    OpenResults.Takedown.purge(slug)
    assert RelayKeys.list(slug) == []
  end

  test "stored as a digest, never the key", %{key: key, relay_key: relay_key} do
    row = OpenResults.Repo.get!(OpenResults.RelayKeys.RelayKey, relay_key.id)
    refute row.key_hash == key
    assert row.key_hash == :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    refute inspect(row) =~ row.key_hash
  end
end
