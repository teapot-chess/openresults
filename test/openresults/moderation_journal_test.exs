defmodule OpenResults.ModerationJournalTest do
  @moduledoc """
  A restore must not undo moderation (restore drill, finding 2): after the
  backup the drill's operator revoked a key, closed registration, paused
  publishing, blocked a range and deleted a tournament, and an arbiter withdrew
  one - and the restored site had undone every one of them.

  `OpenResults.ModerationJournal` keeps those actions outside the database and
  applies them again at boot. The test that carries the weight does what the
  drill did: a real database, a real backup, every kind of action through
  `OpenResults.Moderation` (and an owner's withdrawal through the API's own
  path), a real `Backup.restore/1`, and the boot's replay run against the
  restored file through the app's own Repo.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.{AddressBlocks, Backup, Installations, Moderation, ModerationJournal}
  alias OpenResults.{Repo, Settings, Takedown, Tournaments}

  @moduletag :capture_log

  @ops %{email: "ops@example.org"}

  setup do
    dir =
      System.tmp_dir!()
      |> Path.join("or-journal-#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(dir)
    journal = Path.join(dir, "openresults-moderation.jsonl")

    previous = Application.get_env(:openresults, :moderation_journal)
    Application.put_env(:openresults, :moderation_journal, journal)
    Application.delete_env(:openresults, :backup_passphrase)

    on_exit(fn ->
      Application.put_env(:openresults, :moderation_journal, previous)
      File.rm_rf(dir)
      database = Application.get_env(:openresults, OpenResults.Repo)[:database]
      for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> ".restored" <> suffix)
    end)

    {:ok, dir: dir, journal: journal}
  end

  defp lines(journal) do
    case File.read(journal) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp with_repo(database, fun) do
    repo =
      start_supervised!(
        %{
          id: {:repo, database},
          start:
            {OpenResults.Repo, :start_link,
             [[name: nil, database: database, pool: DBConnection.ConnectionPool, pool_size: 1]]}
        },
        restart: :temporary
      )

    previous = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
      stop_supervised!({:repo, database})
    end
  end

  describe "a restored backup, booted" do
    test "every removal made after the backup is back in force; approve and unhide are not replayed",
         %{dir: dir, journal: journal} do
      live = live_database(dir)
      {:ok, backup} = Backup.create(dir: Path.join(dir, "backups"), source: live)

      # After the backup, on the live site: every kind of action the journal
      # keeps, two it must not, and an arbiter's withdrawal over the API.
      with_repo(live, fn ->
        {:ok, _} = Moderation.hide("to-hide", @ops)
        {:ok, _} = Moderation.delete("to-delete", @ops)
        {:ok, _} = Moderation.revoke("in_revokeme", @ops, hide_tournaments: false)
        {:ok, _} = Moderation.suspend("in_suspendme", @ops)

        {:ok, _} =
          Moderation.block_address(
            "192.0.2.0/24",
            DateTime.add(DateTime.utc_now(), 7 * 86_400, :second),
            "abuse",
            @ops
          )

        {:ok, _} = Moderation.put_setting(:registration_open, false, @ops)
        {:ok, _} = Moderation.put_setting(:public_publishing_paused, true, @ops)

        # Never journalled.
        {:ok, _} = Moderation.approve("to-approve", @ops)
        {:ok, _} = Moderation.unhide("to-unhide", @ops)

        # What `DELETE /api/tournaments/:slug` does for an owner.
        Takedown.purge("owner-withdrew")
        ModerationJournal.record_delete("owner-withdrew", "owner", DateTime.utc_now())
      end)

      assert Enum.map(lines(journal), &{&1["action"], &1["target"] || &1["cidr"]}) == [
               {"hide", "to-hide"},
               {"delete", "to-delete"},
               {"revoke", "in_revokeme"},
               {"suspend", "in_suspendme"},
               {"block_address", "192.0.2.0/24"},
               {"put_setting", "registration_open"},
               {"put_setting", "public_publishing_paused"},
               {"delete", "owner-withdrew"}
             ]

      # A boot that follows no restore: every line is already known.
      assert with_repo(live, fn -> ModerationJournal.replay() end) == 0

      # The restore, and the boot's replay against the restored file.
      {:ok, restored} = Backup.restore(backup)

      with_repo(restored, fn ->
        # Exactly what the drill saw come back.
        assert %{status: "listed"} = Tournaments.get("to-hide")
        assert Tournaments.get("to-delete")
        assert %{status: "active"} = Installations.get("in_revokeme")
        assert Settings.all() == %{registration_open: true, public_publishing_paused: false}

        assert ModerationJournal.replay() == 8

        assert %{status: "hidden"} = Tournaments.get("to-hide")
        assert Tournaments.get("to-delete") == nil
        assert OpenResults.Snapshots.history("to-delete") == []
        refute OpenResults.TournamentKeys.claimed?("to-delete")
        assert Tournaments.get("owner-withdrew") == nil
        assert OpenResults.Snapshots.history("owner-withdrew") == []
        assert %{status: "revoked"} = Installations.get("in_revokeme")
        assert %{status: "suspended"} = Installations.get("in_suspendme")

        assert [%{cidr: "192.0.2.0/24", created_by: "restore-replay"}] =
                 AddressBlocks.list_active()

        assert Settings.all() == %{registration_open: false, public_publishing_paused: true}

        # Approve and unhide happened after the backup and are NOT replayed:
        # both stay as the backup had them.
        assert %{status: "pending"} = Tournaments.get("to-approve")
        assert %{status: "hidden"} = Tournaments.get("to-unhide")

        # One action log row per re-applied action, by the replay.
        replayed = Moderation.list_actions(actor: "restore-replay")
        assert length(replayed) == 8
        assert Enum.all?(replayed, &is_binary(&1.details["journal_at"]))

        # The next boot: nothing to do, nothing written.
        assert ModerationJournal.replay() == 0
        assert length(Moderation.list_actions(actor: "restore-replay")) == 8

        # The operator reverses some of it on purpose; a boot does not undo that.
        {:ok, _} = Moderation.unhide("to-hide", @ops)
        {:ok, _} = Moderation.unsuspend("in_suspendme", @ops)
        [block] = AddressBlocks.list_active()
        {:ok, _} = Moderation.unblock(block.id, @ops)
        {:ok, _} = Moderation.put_setting(:registration_open, true, @ops)

        assert ModerationJournal.replay() == 0
        assert %{status: "listed"} = Tournaments.get("to-hide")
        assert %{status: "active"} = Installations.get("in_suspendme")
        assert AddressBlocks.list_active() == []
        assert Settings.get(:registration_open) == true
      end)
    end
  end

  describe "trust and per-installation limits, after a restore" do
    test "ending trust and lowering limits come back; granting trust and raising limits do not",
         %{dir: dir, journal: journal} do
      live = live_database(dir)

      # Before the backup: in_revokeme trusted with a generous tournament
      # limit, in_suspendme untrusted with a tight snapshot cap, and in_owner
      # untrusted with its own version cap above the server's 20.
      with_repo(live, fn ->
        {:ok, _} =
          Repo.query(
            "UPDATE installations SET trusted = 1, max_tournaments = 200 WHERE id = 'in_revokeme'"
          )

        {:ok, _} =
          Repo.query(
            "UPDATE installations SET max_snapshot_bytes = 1000 WHERE id = 'in_suspendme'"
          )

        {:ok, _} = Repo.query("UPDATE installations SET max_versions = 50 WHERE id = 'in_owner'")
      end)

      {:ok, backup} = Backup.create(dir: Path.join(dir, "backups"), source: live)

      with_repo(live, fn ->
        # Safer: journalled.
        {:ok, _} = Moderation.untrust("in_revokeme", @ops)

        {:ok, _} =
          Moderation.put_installation_limits("in_revokeme", %{"max_tournaments" => "5"}, @ops)

        # Clearing an override that was above the server's value is lowering.
        {:ok, _} = Moderation.put_installation_limits("in_owner", %{}, @ops)

        # Less safe: never journalled.
        {:ok, _} = Moderation.trust("in_suspendme", @ops, list_pending: false)
        {:ok, _} = Moderation.put_installation_limits("in_suspendme", %{}, @ops)
      end)

      assert Enum.map(lines(journal), &{&1["action"], &1["target"], &1["limits"]}) == [
               {"untrust", "in_revokeme", nil},
               {"lower_limits", "in_revokeme", %{"max_tournaments" => 5}},
               {"lower_limits", "in_owner", %{"max_versions" => nil}}
             ]

      # No restore: all known.
      assert with_repo(live, fn -> ModerationJournal.replay() end) == 0

      {:ok, restored} = Backup.restore(backup)

      with_repo(restored, fn ->
        assert %{trusted: true, max_tournaments: 200} = Installations.get("in_revokeme")
        assert %{max_versions: 50} = Installations.get("in_owner")

        assert ModerationJournal.replay() == 3

        assert %{trusted: false, max_tournaments: 5} = Installations.get("in_revokeme")
        assert %{max_versions: nil} = Installations.get("in_owner")

        # Granting trust and raising the cap happened after the backup and are
        # NOT replayed.
        assert %{trusted: false, max_snapshot_bytes: 1000} = Installations.get("in_suspendme")

        replayed = Moderation.list_actions(actor: "restore-replay")

        assert Enum.map(replayed, &{&1.action, &1.target}) |> Enum.sort() == [
                 {"set_installation_limits", "in_owner"},
                 {"set_installation_limits", "in_revokeme"},
                 {"untrust", "in_revokeme"}
               ]

        assert Enum.all?(replayed, &is_binary(&1.details["journal_at"]))
        assert ModerationJournal.replay() == 0

        # The operator trusts it again on purpose; the next boot keeps that.
        {:ok, _} = Moderation.trust("in_revokeme", @ops, list_pending: false)
        assert ModerationJournal.replay() == 0
        assert %{trusted: true} = Installations.get("in_revokeme")
      end)
    end

    test "two lines about one installation with the same timestamp are both re-applied" do
      # An untrust and a lowered limit in the same clock tick. Before
      # `journal_action`, the first line's replay row carried that same time
      # and so made the second line look known: the limit stayed high.
      at = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, %{installation: installation}} =
        Installations.register(%{"client" => "OpenPairings"}, nil)

      {:ok, _} = Moderation.trust(installation.id, @ops, [])

      {:ok, _} =
        Moderation.put_installation_limits(installation.id, %{"max_versions" => "50"}, @ops)

      ModerationJournal.record_untrust(installation.id, at)
      ModerationJournal.record_lower_limits(installation.id, %{max_versions: 5}, at)

      assert ModerationJournal.replay() == 2
      assert %{trusted: false, max_versions: 5} = Installations.get(installation.id)
      assert ModerationJournal.replay() == 0
    end

    test "a limit already as low as the journal's is left alone, and an unknown installation too" do
      now = DateTime.utc_now()

      {:ok, %{installation: installation}} =
        Installations.register(%{"client" => "OpenPairings"}, nil)

      {:ok, _} =
        Moderation.put_installation_limits(installation.id, %{"max_versions" => "2"}, @ops)

      # Lines newer than anything the database knows: a limit the installation
      # is already below changes nothing, and an installation that does not
      # exist is passed over.
      ModerationJournal.record_lower_limits(
        installation.id,
        %{max_versions: 5},
        DateTime.add(now, 3600, :second)
      )

      ModerationJournal.record_untrust("in_nobody", DateTime.add(now, 3600, :second))

      assert ModerationJournal.replay() == 0
      assert %{max_versions: 2} = Installations.get(installation.id)
    end
  end

  describe "what is written" do
    test "DELETE /api/tournaments/:slug is journalled, by the operator or by the owner", %{
      journal: journal
    } do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer test-ingest-token")
        |> delete(~p"/api/tournaments/nothing-here")

      assert %{"status" => "deleted"} = json_response(conn, 200)

      # And an installation withdrawing its own tournament, with its key.
      {installation, key} = OpenResults.PublicPublishingFixtures.installation!()
      slug = OpenResults.PublicPublishingFixtures.mint!(installation)
      tournament_key = OpenResults.PublicPublishingFixtures.random_key()

      assert %{"status" => "ok"} =
               slug
               |> OpenResults.PublicPublishingFixtures.payload()
               |> OpenResults.PublicPublishingFixtures.publish(key, tournament_key)
               |> json_response(200)

      assert %{"status" => "deleted"} =
               slug
               |> OpenResults.PublicPublishingFixtures.takedown(key, tournament_key)
               |> json_response(200)

      assert [
               %{"action" => "delete", "target" => "nothing-here", "by" => "operator"},
               %{"action" => "delete", "target" => ^slug, "by" => "owner"}
             ] = lines(journal)
    end

    test "a refused DELETE writes nothing", %{journal: journal} do
      slug = OpenResults.PublicPublishingFixtures.unique_slug()
      payload = OpenResults.PublicPublishingFixtures.payload(slug)
      OpenResults.PublicPublishingFixtures.publish(payload, "test-ingest-token", "the-real-key")

      conn =
        OpenResults.PublicPublishingFixtures.takedown(slug, "test-ingest-token", "not-the-key")

      assert json_response(conn, 403)
      assert lines(journal) == []
    end

    test "the other direction of each switch writes nothing", %{journal: journal} do
      {:ok, _} = Moderation.put_setting(:registration_open, true, @ops)
      {:ok, _} = Moderation.put_setting(:public_publishing_paused, false, @ops)
      assert lines(journal) == []
    end

    test "an action that did not happen writes nothing", %{journal: journal} do
      assert {:error, :not_found} = Moderation.hide("no-such-tournament", @ops)
      assert {:error, :not_found} = Moderation.suspend("in_nobody", @ops)
      assert lines(journal) == []
    end

    test "a torn line is skipped, the others still read", %{journal: journal} do
      ModerationJournal.record_hide("a-slug", ~U[2026-09-13 10:00:00.000000Z])
      File.write!(journal, ~s({"v":1,"at":"2026-09-13T10), [:append])
      File.write!(journal, "\n", [:append])
      ModerationJournal.record_suspend("in_x", ~U[2026-09-13 10:01:00.000000Z])

      assert [%{"action" => "hide"}, %{"action" => "suspend"}] =
               ModerationJournal.entries(journal)
    end
  end

  describe "the replay's other refusals" do
    test "a block whose expiry has passed is not re-created" do
      ModerationJournal.record_block(
        "198.51.100.0/24",
        ~U[2026-09-01 00:00:00.000000Z],
        ~U[2026-08-25 00:00:00.000000Z]
      )

      assert ModerationJournal.replay() == 0
      assert AddressBlocks.list_active() == []
    end

    test "a hide passed over when a later line deleted the slug, and republished since" do
      {:ok, _} =
        %OpenResults.Tournaments.Tournament{slug: "republished", status: "listed"}
        |> Repo.insert()

      ModerationJournal.record_hide(
        "republished",
        DateTime.add(DateTime.utc_now(), -120, :second)
      )

      ModerationJournal.record_delete(
        "republished",
        "owner",
        DateTime.add(DateTime.utc_now(), -60, :second)
      )

      # The tournament row is newer than the delete (inserted now): a
      # republish after it. Neither line touches it.
      assert ModerationJournal.replay() == 0
      assert %{status: "listed"} = Tournaments.get("republished")
    end
  end

  describe "relay keys, after a restore (2026-10-19 sweep)" do
    import OpenResults.PublicPublishingFixtures

    alias OpenResults.RelayKeys.RelayKey

    # What a restore does to a revoked key: the backup holds it unrevoked.
    defp unrevoke(id) do
      import Ecto.Query

      Repo.update_all(from(k in RelayKey, where: k.id == ^id),
        set: [revoked_at: nil, revoked_by: nil]
      )
    end

    defp revoked?(id), do: Repo.get!(RelayKey, id).revoked_at != nil

    defp published!(prefix) do
      slug = unique_slug(prefix)
      assert json_response(publish(payload(slug), operator_token(), random_key()), 200)
      slug
    end

    test "a revoked key is journalled by fingerprint, and revoked again by the replay",
         %{journal: journal} do
      slug = published!("relay")
      {:ok, %{relay_key: relay_key, key: key}} = Moderation.create_relay_key(slug, "hall", @ops)
      {:ok, _} = Moderation.revoke_relay_key(slug, relay_key.id, @ops)

      assert [%{"action" => "revoke_relay_keys", "target" => ^slug, "keys" => [fingerprint]}] =
               lines(journal)

      assert fingerprint == relay_key.key_hash
      refute File.read!(journal) =~ key

      unrevoke(relay_key.id)
      assert ModerationJournal.replay() == 1
      assert revoked?(relay_key.id)
      assert ModerationJournal.replay() == 0
    end

    test "the publisher's withdrawals and a transfer are journalled too", %{journal: journal} do
      slug = published!("relay-pub")
      {:ok, %{relay_key: first}} = Moderation.publisher_relay_key(slug, "hall", :operator_token)
      # Replaces `first` under the same label.
      {:ok, %{relay_key: second}} = Moderation.publisher_relay_key(slug, "hall", :operator_token)
      {:ok, 1} = Moderation.publisher_revoke_relay_keys(slug, nil, :operator_token)

      other = published!("relay-moved")
      {:ok, %{relay_key: third}} = Moderation.create_relay_key(other, "hall", @ops)
      {installation, _key} = installation!()
      {:ok, _} = Moderation.transfer(other, installation.id, @ops)

      assert Enum.map(lines(journal), & &1["keys"]) ==
               [[first.key_hash], [second.key_hash], [third.key_hash]]

      Enum.each([first, second, third], &unrevoke(&1.id))
      assert ModerationJournal.replay() == 3
      assert Enum.all?([first, second, third], &revoked?(&1.id))
    end

    test "a replayed installation revoke revokes its relay keys, as the live one does", %{
      journal: journal
    } do
      {installation, key} = installation!({198, 51, 100, 31})
      slug = mint!(installation)
      assert json_response(publish(payload(slug), key, random_key()), 200)
      {:ok, %{relay_key: relay_key}} = Moderation.create_relay_key(slug, "hall", @ops)

      line = %{
        "v" => 1,
        "action" => "revoke",
        "target" => installation.id,
        "hide_tournaments" => false,
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      File.write!(journal, [Jason.encode!(line), "\n"])

      assert ModerationJournal.replay() == 1
      assert Installations.get(installation.id).status == "revoked"
      assert revoked?(relay_key.id)
    end

    test "a line with something other than fingerprints in it is skipped", %{journal: journal} do
      slug = published!("relay-torn")
      {:ok, %{relay_key: relay_key, key: key}} = Moderation.create_relay_key(slug, "hall", @ops)

      line = %{
        "v" => 1,
        "action" => "revoke_relay_keys",
        "target" => slug,
        "keys" => [key],
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      File.write!(journal, [Jason.encode!(line), "\n"])

      assert ModerationJournal.replay() == 0
      refute revoked?(relay_key.id)
    end
  end

  describe "trimming" do
    test "drops what no backup can bring back, keeps the rest", %{journal: journal} do
      now = ~U[2026-09-13 12:00:00Z]
      ModerationJournal.record_hide("ancient", ~U[2026-07-01 00:00:00.000000Z])
      ModerationJournal.record_hide("recent", ~U[2026-09-10 00:00:00.000000Z])

      # Thirty days of retention and a week's margin.
      assert ModerationJournal.trim(now: now, backups: []) == 1
      assert [%{"target" => "recent"}] = lines(journal)
    end

    test "never past the oldest backup still on disk, however old" do
      now = ~U[2026-09-13 12:00:00Z]
      stale = [%{created_at: ~U[2026-06-01 00:00:00Z]}]

      # The newest backup is kept whatever its age, so a restore could still
      # bring back June: the cutoff goes back with it.
      assert DateTime.compare(ModerationJournal.cutoff(now, stale), ~U[2026-06-01 00:00:00Z]) ==
               :lt
    end
  end

  # A live database with this app's schema and the state before the backup.
  defp live_database(dir) do
    path = Path.join(dir, "live.db")
    database = Application.get_env(:openresults, OpenResults.Repo)[:database]

    {:ok, conn} = Exqlite.Sqlite3.open(database)
    :ok = Exqlite.Sqlite3.execute(conn, "VACUUM INTO '#{path}'")
    :ok = Exqlite.Sqlite3.close(conn)

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    for table <- ~w(snapshots registrations tournament_keys installations tournaments reports
                    address_blocks settings moderation_actions) do
      :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM #{table}")
    end

    old = "2026-09-01T00:00:00.000000Z"
    hash = &OpenResults.Installations.hash/1

    installation = fn id ->
      """
      INSERT INTO installations (id, key_hash, client, client_version, status, inserted_at, updated_at)
      VALUES ('#{id}', '#{hash.(id)}', 'OpenPairings', '0.60.0', 'active', '#{old}', '#{old}')
      """
    end

    tournament = fn slug, status, owner ->
      owner = if owner, do: "'#{owner}'", else: "NULL"

      """
      INSERT INTO tournaments (slug, status, installation_id, inserted_at, updated_at)
      VALUES ('#{slug}', '#{status}', #{owner}, '#{old}', '#{old}')
      """
    end

    snapshot = fn slug ->
      """
      INSERT INTO snapshots (tournament_slug, version, source_app, source_version, published_at, received_at, payload)
      VALUES ('#{slug}', 1, 'openpairings', '0.60.0', '#{old}', '#{old}', '{"tournament":{"slug":"#{slug}"}}')
      """
    end

    for sql <- [
          installation.("in_revokeme"),
          installation.("in_suspendme"),
          installation.("in_owner"),
          tournament.("to-hide", "listed", nil),
          tournament.("to-delete", "listed", nil),
          snapshot.("to-delete"),
          """
          INSERT INTO registrations (tournament_slug, version, received_at, payload)
          VALUES ('to-delete', 1, '#{old}', '{"name":"Entrant, Anna","email":"anna@example.org"}')
          """,
          "INSERT INTO tournament_keys (tournament_slug, key_hash, claimed_at) VALUES ('to-delete', 'k', '#{old}')",
          tournament.("owner-withdrew", "listed", "in_owner"),
          snapshot.("owner-withdrew"),
          tournament.("to-approve", "pending", "in_owner"),
          tournament.("to-unhide", "hidden", nil),
          """
          INSERT INTO settings (key, value, updated_by, inserted_at, updated_at)
          VALUES ('registration_open', 1, 'ops@example.org', '#{old}', '#{old}')
          """
        ] do
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    end

    :ok = Exqlite.Sqlite3.close(conn)
    path
  end
end
