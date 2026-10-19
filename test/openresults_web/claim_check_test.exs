defmodule OpenResultsWeb.ClaimCheckTest do
  @moduledoc """
  `GET /api/tournaments/:slug/claim` (`docs/public-publishing.md`, "Checking a
  tournament key"): what a hosted OpenPairings asks before adopting a key a
  backup file carried in. It must answer for the key and do nothing else -
  above all, never claim.
  """

  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.TournamentKeys

  @moduletag :capture_log

  setup do
    RateLimit.reset()
    :ok
  end

  defp check(slug, key, bearer \\ operator_token()) do
    build_conn() |> bearer(bearer) |> tournament_key(key) |> get("/api/tournaments/#{slug}/claim")
  end

  test "the key that claimed it, another key, and none" do
    slug = unique_slug("claimed")
    tkey = random_key()
    assert json_response(publish(payload(slug), operator_token(), tkey), 200)

    assert json_response(check(slug, tkey), 200) == %{"claim" => "tournament_key"}
    assert json_response(check(slug, random_key()), 403)["error"] == "key_mismatch"
    assert json_response(check(slug, nil), 403)["error"] == "key_required"
  end

  test "an unclaimed slug is unclaimed afterwards too" do
    slug = unique_slug("legacy")
    assert json_response(publish(payload(slug), operator_token()), 200)

    assert json_response(check(slug, random_key()), 200) == %{"claim" => "unclaimed"}
    refute TournamentKeys.claimed?(slug)
  end

  test "the operator token in the key position proves nothing, and is not break-glass" do
    slug = unique_slug("glass")
    assert json_response(publish(payload(slug), operator_token(), random_key()), 200)

    assert json_response(check(slug, operator_token()), 403)["error"] == "key_mismatch"
    refute Enum.any?(Moderation.list_actions(%{target: slug}), &(&1.actor == "break-glass"))
  end

  test "a deleted tournament says so" do
    slug = unique_slug("deleted")
    tkey = random_key()
    assert json_response(publish(payload(slug), operator_token(), tkey), 200)
    {:ok, _} = Moderation.delete(slug, admin())

    assert json_response(check(slug, tkey), 410)["error"] == "tournament_deleted"
  end

  test "an installation key and no credential are the anonymous 401" do
    {installation, key} = installation!({198, 51, 100, 61})
    slug = mint!(installation)

    assert json_response(check(slug, random_key(), key), 401)["error"] == "unauthorized"
    assert json_response(check(slug, random_key(), nil), 401)["error"] == "unauthorized"
  end
end
