defmodule OpenResultsWeb.TombstoneTest do
  @moduledoc """
  An admin delete stays a delete (`docs/public-publishing.md`, "Deleted
  tournaments"). The sweep of 2026-10-19 found the opposite: a hosted
  OpenPairings publishing with the operator token re-claimed the released
  slug with the same key on its next automatic publish, and the page was back,
  listed, with every player on it.
  """

  # Not async: moves application env and spends the node-wide rate limiter.
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.ModerationJournal
  alias OpenResults.RateLimit
  alias OpenResults.Snapshots
  alias OpenResults.Tombstones
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments

  @moduletag :capture_log

  setup do
    RateLimit.reset()
    :ok
  end

  defp error(conn, status), do: json_response(conn, status)["error"]

  describe "an operator-published tournament the admin deleted" do
    setup do
      slug = unique_slug("hosted")
      tkey = random_key()
      assert json_response(publish(payload(slug), operator_token(), tkey), 200)
      {:ok, _counts} = Moderation.delete(slug, admin())
      {:ok, slug: slug, tkey: tkey}
    end

    test "is refused on the next publish with the same key, and nothing comes back",
         %{slug: slug, tkey: tkey} do
      conn = publish(payload(slug), operator_token(), tkey)

      assert error(conn, 410) == "tournament_deleted"
      assert Snapshots.latest(slug) == nil
      refute TournamentKeys.claimed?(slug)
      assert Tournaments.get(slug) == nil
      assert Tombstones.tombstoned?(slug)
    end

    test "is refused with a fresh key, and with no key at all", %{slug: slug} do
      assert error(publish(payload(slug), operator_token(), random_key()), 410) ==
               "tournament_deleted"

      assert error(publish(payload(slug), operator_token()), 410) == "tournament_deleted"
      assert Snapshots.latest(slug) == nil
    end

    test "break-glass lifts the tombstone, publishes, and logs the lift", %{slug: slug} do
      conn = publish(payload(slug), operator_token(), operator_token())

      assert %{"status" => "ok"} = json_response(conn, 200)
      refute Tombstones.tombstoned?(slug)
      assert Snapshots.latest(slug)

      actions = Moderation.list_actions(%{target: slug}) |> Enum.map(&{&1.actor, &1.action})
      assert {"break-glass", "lift_tombstone"} in actions
      assert {"break-glass", "break_glass_publish"} in actions
    end
  end

  describe "an installation's tournament the admin deleted" do
    setup do
      {installation, key} = installation!()
      slug = mint!(installation)
      tkey = random_key()
      assert json_response(publish(payload(slug), key, tkey), 200)
      {:ok, _counts} = Moderation.delete(slug, admin())
      {:ok, key: key, slug: slug, tkey: tkey}
    end

    test "tells its own installation tournament_deleted on publish and on reads",
         %{key: key, slug: slug, tkey: tkey} do
      assert error(publish(payload(slug), key, tkey), 410) == "tournament_deleted"
      assert error(history(slug, key), 410) == "tournament_deleted"
      assert error(registrations(slug, key, tkey), 410) == "tournament_deleted"
      assert Snapshots.latest(slug) == nil
    end

    test "lets its own installation delete it again, removing nothing", %{key: key, slug: slug} do
      assert %{"status" => "deleted", "deleted" => %{"snapshots" => 0}} =
               json_response(takedown(slug, key), 200)

      assert Tombstones.tombstoned?(slug)
    end

    test "tells any other installation not_owner, as before", %{slug: slug, tkey: tkey} do
      {_other, other_key} = installation!({198, 51, 100, 21})
      assert error(publish(payload(slug), other_key, tkey), 403) == "not_owner"
    end
  end

  describe "deletes that leave no tombstone" do
    test "the arbiter's own withdrawal may be published again under the same slug" do
      slug = unique_slug("withdrawn")
      tkey = random_key()
      assert json_response(publish(payload(slug), operator_token(), tkey), 200)
      assert json_response(takedown(slug, operator_token(), tkey), 200)

      refute Tombstones.tombstoned?(slug)
      assert json_response(publish(payload(slug), operator_token(), tkey), 200)
    end
  end

  describe "a restore" do
    setup do
      file =
        System.tmp_dir!()
        |> Path.join("or-tombstone-journal-#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm(file) end)
      {:ok, journal: file}
    end

    defp journal(file, lines) do
      File.write!(file, Enum.map(lines, &[Jason.encode!(&1), "\n"]))
    end

    defp line(slug, by, at),
      do: %{"v" => 1, "action" => "delete", "target" => slug, "by" => by, "at" => at}

    test "purging an admin-deleted tournament again writes its tombstone back", %{journal: file} do
      # The restored database: the tournament as it was before the delete,
      # and no tombstone.
      slug = unique_slug("restored")
      assert json_response(publish(payload(slug), operator_token(), random_key()), 200)
      later = DateTime.utc_now() |> DateTime.add(5, :second) |> DateTime.to_iso8601()
      journal(file, [line(slug, "admin", later)])

      assert ModerationJournal.replay(path: file) == 1
      assert Snapshots.latest(slug) == nil
      assert Tombstones.tombstoned?(slug)

      assert error(publish(payload(slug), operator_token(), random_key()), 410) ==
               "tournament_deleted"
    end

    test "a tombstone missing on a slug that holds nothing is written back", %{journal: file} do
      slug = unique_slug("gone")
      journal(file, [line(slug, "admin", DateTime.to_iso8601(DateTime.utc_now()))])

      assert ModerationJournal.replay(path: file) == 1
      assert Tombstones.tombstoned?(slug)
      # A second boot knows it.
      assert ModerationJournal.replay(path: file) == 0
    end

    test "an owner's withdrawal is replayed without one", %{journal: file} do
      slug = unique_slug("owner")
      assert json_response(publish(payload(slug), operator_token(), random_key()), 200)
      later = DateTime.utc_now() |> DateTime.add(5, :second) |> DateTime.to_iso8601()
      journal(file, [line(slug, "owner", later)])

      assert ModerationJournal.replay(path: file) == 1
      assert Snapshots.latest(slug) == nil
      refute Tombstones.tombstoned?(slug)
    end

    test "a tombstone lifted after the delete is not put back", %{journal: file} do
      slug = unique_slug("lifted")
      at = DateTime.utc_now() |> DateTime.add(-60, :second)
      {:ok, _counts} = Moderation.delete(slug, admin())
      assert json_response(publish(payload(slug), operator_token(), operator_token()), 200)
      refute Tombstones.tombstoned?(slug)

      journal(file, [line(slug, "admin", DateTime.to_iso8601(at))])

      assert ModerationJournal.replay(path: file) == 0
      refute Tombstones.tombstoned?(slug)
      assert Snapshots.latest(slug)
    end
  end
end
