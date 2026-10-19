defmodule OpenResults.ModerationJournal do
  @moduledoc """
  A record of every moderation action that made the site safer, kept OUTSIDE
  the database, so that restoring a backup cannot undo it.

  ## Why

  The restore drill of 2026-09-13 restored a backup after the operator had
  kept working, and measured what came back (`docs/restore-drill-2026-09-13.md`,
  finding 2): a revoked installation's key minted a slug again, closed
  registration issued a key, a blocked range registered, a tournament deleted
  for personal data was back with its history, and a tournament its arbiter had
  withdrawn from OpenPairings was online again with its entry form open. The
  action log is restored to the same instant, so it could not say what to
  re-apply, and an owner's withdrawal was never in it at all.

  ## The file

  Beside the database, in the same directory, named after it:
  `/var/lib/openresults/openresults-moderation.jsonl`. Not inside the database,
  so a backup never contains it and a restore never touches it.
  `config :openresults, :moderation_journal` is a path to put it elsewhere, or
  `false` for none (the test environment).

  One JSON object per line, appended after the action committed:

      {"v":1,"at":"2026-09-13T10:02:11.123456Z","action":"hide","target":"gent-open"}
      {"v":1,"at":"...","action":"delete","target":"gent-open","by":"owner"}
      {"v":1,"at":"...","action":"revoke","target":"in_XWtJ...","hide_tournaments":true}
      {"v":1,"at":"...","action":"suspend","target":"in_XWtJ..."}
      {"v":1,"at":"...","action":"block_address","cidr":"192.0.2.0/24","expires_at":"..."}
      {"v":1,"at":"...","action":"put_setting","target":"registration_open","value":false}
      {"v":1,"at":"...","action":"put_setting","target":"public_publishing_paused","value":true}
      {"v":1,"at":"...","action":"untrust","target":"in_XWtJ..."}
      {"v":1,"at":"...","action":"lower_limits","target":"in_XWtJ...","limits":{"max_versions":5,"max_tournaments":null}}

  **Only the safer direction is journalled**: `delete` - the admin panel's,
  and an owner's or the operator's `DELETE /api/tournaments/:slug` (`by` says
  which) - `hide`, `revoke`, `suspend`, `block_address`, closing registration
  and pausing publishing, and (the admin upgrade, 2026-09-13) ending an
  installation's trust (`untrust`) and lowering its own limits
  (`lower_limits`: only the limits whose value in force went down, each with
  the installation's own value afterwards, `null` for the server's). Approve,
  unhide, unsuspend, unblock, opening registration, unpausing, granting trust
  and raising a limit are never written, so never replayed: after a
  restore they stay as the backup had them, and the operator redoes them
  deliberately. `at` is the action log row's own time where there is one.

  What a line holds: a slug, an installation id, a switch - and for a block,
  the address or range and its expiry, exactly what the action log already
  keeps for it. Not the block's reason, which is free text an operator typed;
  a replayed block says it was kept in force after a restore instead.

  ## Replay

  `replay/1` runs at every boot, after migrations, before the endpoint starts
  (`OpenResults.Application`). For every line it re-applies the action if -
  and only if - the database does not already know about it:

    * `delete`: if anything is still held for the slug that is OLDER than the
      line (a snapshot, a registration, the key claim, the tournament row),
      the database predates the delete, and the slug is purged again
      (`OpenResults.Takedown.purge/2`). A tournament published again under the
      slug after the delete is newer than the line, and stays. An admin
      delete (`by: "admin"`) also gets its tombstone back
      (`OpenResults.Tombstones`) when the database lacks it - with the
      purge, or alone when nothing at all is held for the slug - unless the
      action log shows a `lift_tombstone` at or after the line.
    * `hide`, `suspend`, and the two switches: if the action log has any row
      about the same target at or after the line's time - the action itself,
      a later reversal, an earlier replay of this line or a later one (a
      replay's row counts by its `journal_at`) - the database already reflects it,
      and nothing happens. Otherwise the change is made if it is not already
      in force. A `hide` is also passed over when a later line deleted the
      slug.
    * `revoke`: revoked is final, so an installation that is not revoked is
      revoked (hiding its tournaments too if the original did).
    * `block_address`: as the others, keyed on the range; never re-created
      once its expiry has passed, and not twice.
    * `untrust`: as `suspend` - passed over when the action log has a row
      about the installation at or after the line; otherwise a trusted
      installation's trust is cleared.
    * `lower_limits`: passed over the same way; otherwise every journalled
      limit whose value in force is still HIGHER than the journalled one
      (a blank counting as the server's value now) is set to it. A limit
      already as low or lower is left alone.

  Every re-applied action writes one action log row with the actor
  `restore-replay` and the line's time in `journal_at`, which is also what
  makes the next boot see it as known. On a boot that followed no restore,
  every line is known and nothing happens.

  ## Trimming

  `trim/1` drops lines older than the oldest backup that could still be
  restored - the retention window plus a week's margin, or the oldest backup
  on disk less that margin if it is older (the newest backup is kept whatever
  its age). A restore cannot bring back anything older, so they can only ever
  be known. It runs after each boot's replay and after each scheduled backup.
  A backup copied off the box and kept longer than that is outside what this
  covers; the deployment guide says so.
  """

  import Ecto.Query

  alias OpenResults.AddressBlocks
  alias OpenResults.Backup
  alias OpenResults.Installations
  alias OpenResults.Installations.Installation
  alias OpenResults.Moderation
  alias OpenResults.Moderation.Action
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo
  alias OpenResults.ServerSettings
  alias OpenResults.Settings
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.Takedown
  alias OpenResults.Tombstones
  alias OpenResults.TournamentKeys.TournamentKey
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament

  require Logger

  @actions ~w(delete hide revoke suspend block_address put_setting untrust lower_limits)
  @margin_days 7

  # The switch and the value that makes the site safer. The other direction is
  # never journalled - see the moduledoc.
  @safer_settings %{registration_open: false, public_publishing_paused: true}

  @doc "Where the journal is, or `nil` when it is switched off."
  @spec path() :: Path.t() | nil
  def path do
    case Application.get_env(:openresults, :moderation_journal) do
      false ->
        nil

      configured when is_binary(configured) and configured != "" ->
        configured

      _beside_the_database ->
        database = Application.get_env(:openresults, OpenResults.Repo)[:database]
        name = database |> Path.basename() |> Path.rootname()
        Path.join(Path.dirname(database), name <> "-moderation.jsonl")
    end
  end

  ## ---------- writing ----------

  @doc "A tournament deleted: `by` is `\"admin\"`, `\"owner\"` or `\"operator\"`."
  def record_delete(slug, by, %DateTime{} = at) when is_binary(slug),
    do: append(%{"action" => "delete", "target" => slug, "by" => by}, at)

  @doc "A tournament hidden."
  def record_hide(slug, %DateTime{} = at) when is_binary(slug),
    do: append(%{"action" => "hide", "target" => slug}, at)

  @doc "An installation revoked."
  def record_revoke(id, hide_tournaments, %DateTime{} = at) when is_binary(id),
    do:
      append(
        %{"action" => "revoke", "target" => id, "hide_tournaments" => hide_tournaments == true},
        at
      )

  @doc "An installation suspended."
  def record_suspend(id, %DateTime{} = at) when is_binary(id),
    do: append(%{"action" => "suspend", "target" => id}, at)

  @doc "An installation's trust ended."
  def record_untrust(id, %DateTime{} = at) when is_binary(id),
    do: append(%{"action" => "untrust", "target" => id}, at)

  @doc """
  An installation's own limits lowered: `limits` maps each limit whose value
  in force went down to the installation's own value afterwards (`nil` for
  the server's). The caller leaves out every limit that did not go down.
  """
  def record_lower_limits(id, limits, %DateTime{} = at) when is_binary(id) and is_map(limits) do
    if limits == %{},
      do: :ok,
      else:
        append(
          %{
            "action" => "lower_limits",
            "target" => id,
            "limits" => Map.new(limits, fn {k, v} -> {to_string(k), v} end)
          },
          at
        )
  end

  @doc "An address or range blocked, until `expires_at`."
  def record_block(cidr, %DateTime{} = expires_at, %DateTime{} = at) when is_binary(cidr),
    do:
      append(
        %{
          "action" => "block_address",
          "cidr" => cidr,
          "expires_at" => DateTime.to_iso8601(expires_at)
        },
        at
      )

  @doc """
  A switch flipped. Written only for the safer value - registration closed,
  publishing paused; anything else is a no-op.
  """
  def record_setting(key, value, %DateTime{} = at) do
    case Map.fetch(@safer_settings, key) do
      {:ok, ^value} ->
        append(
          %{"action" => "put_setting", "target" => Atom.to_string(key), "value" => value},
          at
        )

      _other ->
        :ok
    end
  end

  # Never raises: the action has committed by the time this runs, and failing
  # the request now would only tell somebody it did not happen. A line that
  # could not be written is logged as an error - it is the one record that
  # would have kept the action in force after a restore.
  defp append(fields, at) do
    case path() do
      nil ->
        :ok

      file ->
        line =
          fields |> Map.merge(%{"v" => 1, "at" => DateTime.to_iso8601(at)}) |> Jason.encode!()

        case locked(fn -> write_line(file, line) end) do
          :ok ->
            :ok

          {:error, reason} = error ->
            Logger.error(
              "Could not write the moderation journal (#{file}): #{inspect(reason)}. " <>
                "#{fields["action"]} #{fields["target"] || fields["cidr"]} is in force, but a " <>
                "restore of an older backup would undo it."
            )

            error
        end
    end
  rescue
    error ->
      Logger.error("Could not write the moderation journal: #{Exception.message(error)}")
      {:error, error}
  end

  defp write_line(file, line) do
    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, device} <- :file.open(file, [:append, :raw, :binary]) do
      try do
        with :ok <- :file.write(device, line <> "\n"), do: :file.sync(device)
      after
        :file.close(device)
      end
    end
  end

  # Appends and the rewrite `trim/1` does are serialised, so a line appended
  # while the file is being rewritten cannot be lost with the old copy.
  defp locked(fun), do: :global.trans({{__MODULE__, :file}, self()}, fun)

  ## ---------- reading ----------

  @doc """
  Every well-formed line, oldest first, with `at` (and a block's `expires_at`)
  parsed. A line that does not parse - the torn last line of a write a crash
  interrupted - is skipped and logged, never fatal.
  """
  @spec entries(Path.t() | nil) :: [map()]
  def entries(nil), do: []

  def entries(file) do
    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case parse(line) do
            {:ok, entry} ->
              [entry]

            :error ->
              Logger.warning("Skipped an unreadable line in the moderation journal #{file}")
              []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error("Could not read the moderation journal #{file}: #{inspect(reason)}")
        []
    end
  end

  defp parse(line) do
    with {:ok, %{"action" => action, "at" => at_text} = entry} when action in @actions <-
           Jason.decode(line),
         {:ok, at, _} <- DateTime.from_iso8601(at_text),
         {:ok, entry} <- well_formed(%{entry | "at" => at}) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp well_formed(%{"action" => "block_address", "cidr" => cidr, "expires_at" => text} = entry)
       when is_binary(cidr) and is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, expires_at, _} -> {:ok, %{entry | "expires_at" => expires_at}}
      _ -> :error
    end
  end

  defp well_formed(%{"action" => "put_setting", "target" => key, "value" => value} = entry)
       when is_boolean(value) do
    case Enum.find(Map.keys(@safer_settings), &(Atom.to_string(&1) == key)) do
      nil -> :error
      atom -> if(Map.fetch!(@safer_settings, atom) == value, do: {:ok, entry}, else: :error)
    end
  end

  defp well_formed(%{"action" => "lower_limits", "target" => id, "limits" => limits} = entry)
       when is_binary(id) and is_map(limits) do
    names = Enum.map(Installation.limits(), &Atom.to_string/1)

    parsed =
      Enum.reduce_while(limits, %{}, fn
        {name, value}, acc when is_integer(value) or is_nil(value) ->
          if name in names,
            do: {:cont, Map.put(acc, String.to_existing_atom(name), value)},
            else: {:halt, :error}

        _other, _acc ->
          {:halt, :error}
      end)

    if is_map(parsed) and parsed != %{},
      do: {:ok, %{entry | "limits" => parsed}},
      else: :error
  end

  defp well_formed(%{"action" => action, "target" => target} = entry)
       when action in ~w(delete hide revoke suspend untrust) and is_binary(target),
       do: {:ok, entry}

  defp well_formed(_entry), do: :error

  ## ---------- replaying ----------

  @doc """
  Re-applies every journalled action a restored database does not know about,
  and returns how many it changed anything for. See the moduledoc.
  """
  @spec replay(keyword()) :: non_neg_integer()
  def replay(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    entries = opts |> Keyword.get_lazy(:path, &path/0) |> entries()

    entries
    |> Enum.with_index()
    |> Enum.count(fn {entry, index} ->
      later = Enum.drop(entries, index + 1)
      reapply(entry, later, now)
    end)
  end

  defp reapply(%{"action" => "delete", "target" => slug, "at" => at} = entry, _later, _now) do
    older? = older_data?(slug, at)
    tombstone? = tombstone_owed?(entry, older?)

    cond do
      older? ->
        {:ok, counts} =
          Repo.transaction(fn ->
            counts =
              Takedown.purge(slug,
                tombstone: if(tombstone?, do: Moderation.restore_replay_actor())
              )

            replayed!(
              "delete",
              "tournament",
              slug,
              entry,
              counts |> Map.put(:by, entry["by"]) |> Map.put(:tombstone, tombstone?)
            )

            counts
          end)

        Tournaments.forget(slug)

        announce(
          entry,
          "#{counts.snapshots} snapshot(s) and #{counts.registrations} entries removed"
        )

        true

      # Nothing to purge, but the operator's delete left a tombstone the
      # restored database does not have - a backup taken between the delete
      # and the tombstones existing, or one taken before the delete of a slug
      # that held nothing older. Without it the next publish would bring the
      # tournament back.
      tombstone? ->
        Repo.transaction(fn ->
          Tombstones.put(slug, nil, Moderation.restore_replay_actor())
          replayed!("delete", "tournament", slug, entry, %{by: entry["by"], tombstone: true})
        end)
        |> applied?(entry)

      true ->
        false
    end
  end

  defp reapply(%{"action" => "hide", "target" => slug, "at" => at} = entry, later, _now) do
    cond do
      deleted_later?(slug, later) ->
        false

      known?("tournament", slug, at, "hide") ->
        false

      true ->
        result =
          Repo.transaction(fn ->
            case Tournaments.transition(slug, ["pending", "listed"], "hidden") do
              {:ok, _tournament} -> replayed!("hide", "tournament", slug, entry, %{to: "hidden"})
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        Tournaments.forget(slug)
        applied?(result, entry)
    end
  end

  defp reapply(%{"action" => "revoke", "target" => id} = entry, _later, _now) do
    hide? = entry["hide_tournaments"] == true

    result =
      Repo.transaction(fn ->
        case Installations.transition(id, ["active", "suspended"], "revoked") do
          {:ok, _installation} ->
            hidden = if hide?, do: Tournaments.hide_all_for(id), else: []

            replayed!("revoke", "installation", id, entry, %{
              hide_tournaments: hide?,
              hidden: hidden
            })

            hidden

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    with {:ok, hidden} <- result, do: Enum.each(hidden, &Tournaments.forget/1)
    applied?(result, entry)
  end

  defp reapply(%{"action" => "suspend", "target" => id, "at" => at} = entry, _later, _now) do
    if known?("installation", id, at, "suspend") do
      false
    else
      Repo.transaction(fn ->
        case Installations.transition(id, ["active"], "suspended") do
          {:ok, _installation} ->
            replayed!("suspend", "installation", id, entry, %{to: "suspended"})

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> applied?(entry)
    end
  end

  defp reapply(%{"action" => "block_address", "cidr" => cidr, "at" => at} = entry, _later, now) do
    expires_at = entry["expires_at"]

    cond do
      DateTime.compare(expires_at, now) != :gt -> false
      block_known?(cidr, at) -> false
      Enum.any?(AddressBlocks.list_active(now), &(&1.cidr == cidr)) -> false
      true -> reblock(cidr, expires_at, entry, now)
    end
  end

  defp reapply(
         %{"action" => "put_setting", "target" => key_text, "value" => value, "at" => at} = entry,
         _later,
         _now
       ) do
    key = Enum.find(Map.keys(@safer_settings), &(Atom.to_string(&1) == key_text))

    cond do
      known?("setting", key_text, at, "put_setting") ->
        false

      Settings.get(key) == value ->
        false

      true ->
        Repo.transaction(fn ->
          {:ok, _settings} = Settings.put(key, value, Moderation.restore_replay_actor())
          replayed!("put_setting", "setting", key_text, entry, %{value: value})
        end)
        |> applied?(entry)
    end
  end

  defp reapply(%{"action" => "untrust", "target" => id, "at" => at} = entry, _later, _now) do
    if known?("installation", id, at, "untrust") do
      false
    else
      Repo.transaction(fn ->
        case Installations.set_trusted(id, false) do
          {:ok, _installation} -> replayed!("untrust", "installation", id, entry, %{})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> applied?(entry)
    end
  end

  defp reapply(%{"action" => "lower_limits", "target" => id, "at" => at} = entry, _later, _now) do
    with false <- known?("installation", id, at, "lower_limits"),
         %Installation{} = installation <- Repo.get(Installation, id),
         changes when changes != %{} <- still_higher(installation, entry["limits"]) do
      Repo.transaction(fn ->
        from(i in Installation, where: i.id == ^id)
        |> Repo.update_all(set: Enum.to_list(changes) ++ [updated_at: DateTime.utc_now()])

        replayed!("set_installation_limits", "installation", id, entry, %{
          from: Map.new(changes, fn {field, _} -> {field, Map.get(installation, field)} end),
          to: changes
        })
      end)
      |> applied?(entry)
    else
      _known_gone_or_already_as_low -> false
    end
  end

  # The journalled limits the restored installation is still above, in force.
  defp still_higher(installation, limits) do
    for {field, value} <- limits,
        global = ServerSettings.get(OpenResults.PublicPublishing.global_for(field)),
        (Map.get(installation, field) || global) > (value || global),
        into: %{},
        do: {field, value}
  end

  defp reblock(cidr, expires_at, entry, now) do
    Repo.transaction(fn ->
      reason = "kept in force after a restore (blocked #{DateTime.to_iso8601(entry["at"])})"

      case AddressBlocks.create(cidr, expires_at, reason, Moderation.restore_replay_actor(), now) do
        {:ok, block} ->
          replayed!("block_address", "address_block", Integer.to_string(block.id), entry, %{
            cidr: block.cidr,
            expires_at: DateTime.to_iso8601(block.expires_at)
          })

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> applied?(entry)
  end

  defp replayed!(action, target_type, target, entry, details) do
    Moderation.log_replay(
      action,
      target_type,
      target,
      details
      |> Map.put(:journal_at, DateTime.to_iso8601(entry["at"]))
      |> Map.put(:journal_action, entry["action"])
    )
  end

  defp applied?({:ok, _}, entry) do
    announce(entry, "applied again")
    true
  end

  defp applied?({:error, _reason}, _entry), do: false

  defp announce(entry, what) do
    Logger.warning(
      "Moderation journal: #{entry["action"]} #{entry["target"] || entry["cidr"]} of " <>
        "#{DateTime.to_iso8601(entry["at"])} was not in the database - #{what}."
    )
  end

  # An admin delete's tombstone, when the database lacks it - unless it was
  # lifted (break-glass) at or after the line, which the action log records,
  # or the slug was published again after the delete and before the
  # tombstones existed: data newer than the line with none older is a page
  # somebody put back on purpose, and a tombstone under a live page would
  # refuse its next publish while leaving it up.
  defp tombstone_owed?(%{"by" => "admin", "target" => slug, "at" => at}, older?) do
    not Tombstones.tombstoned?(slug) and not lifted_since?(slug, at) and
      (older? or not held?(slug))
  end

  defp tombstone_owed?(_owner_or_operator_delete, _older?), do: false

  defp lifted_since?(slug, at) do
    Repo.exists?(
      from a in Action,
        where:
          a.target_type == "tournament" and a.target == ^slug and
            a.action == "lift_tombstone" and a.inserted_at >= ^at
    )
  end

  # Anything at all held for the slug, of any age.
  defp held?(slug) do
    Repo.exists?(from s in Snapshot, where: s.tournament_slug == ^slug) or
      Repo.exists?(from t in Tournament, where: t.slug == ^slug) or
      Repo.exists?(from k in TournamentKey, where: k.tournament_slug == ^slug)
  end

  # Anything held for the slug that is older than the delete - the database
  # predates it.
  defp older_data?(slug, at) do
    Repo.exists?(from s in Snapshot, where: s.tournament_slug == ^slug and s.received_at < ^at) or
      Repo.exists?(
        from r in Registration, where: r.tournament_slug == ^slug and r.received_at < ^at
      ) or
      Repo.exists?(
        from k in TournamentKey, where: k.tournament_slug == ^slug and k.claimed_at < ^at
      ) or
      Repo.exists?(from t in Tournament, where: t.slug == ^slug and t.inserted_at < ^at)
  end

  # A row about the target at or after the line. A replay's own row counts by
  # the time of the line it replayed (`journal_at`), not by when the replay
  # wrote it: otherwise replaying one line about an installation would make
  # every other line about it - an untrust and a lowered limit, say - look
  # known, and the second would never be applied.
  #
  # And a replay row from a line with the SAME time only covers a line of the
  # same kind (`journal_action`). Two actions on one target can share a
  # timestamp - an untrust and a lowered limit in one clock tick, which a
  # coarse clock makes easy - and with a plain `>=` the first one's replay row
  # hid the second, so a removal was silently not re-applied. A replay row
  # from a strictly later line still covers earlier ones, which is what keeps
  # a second boot a no-op. Rows written before `journal_action` existed match
  # any kind, as they did then.
  defp known?(target_type, target, at, journal_action) do
    replay = Moderation.restore_replay_actor()
    at_text = DateTime.to_iso8601(at)

    Repo.exists?(
      from a in Action,
        where:
          a.target_type == ^target_type and a.target == ^target and
            ((a.actor != ^replay and a.inserted_at >= ^at) or
               (a.actor == ^replay and
                  (fragment("json_extract(?, '$.journal_at')", a.details) > ^at_text or
                     (fragment("json_extract(?, '$.journal_at')", a.details) == ^at_text and
                        fragment(
                          "coalesce(json_extract(?, '$.journal_action'), ?)",
                          a.details,
                          ^journal_action
                        ) == ^journal_action))))
    )
  end

  # A block's action log rows are keyed by the block's id, which a re-created
  # block does not share, so they are matched on the range they name.
  defp block_known?(cidr, at) do
    Repo.exists?(
      from a in Action,
        where:
          a.target_type == "address_block" and a.action in ["block_address", "unblock"] and
            fragment("json_extract(?, '$.cidr')", a.details) == ^cidr and a.inserted_at >= ^at
    )
  end

  defp deleted_later?(slug, later),
    do: Enum.any?(later, &(&1["action"] == "delete" and &1["target"] == slug))

  ## ---------- trimming ----------

  @doc """
  Drops every line older than the oldest backup that could still be restored,
  and returns how many went. See the moduledoc.
  """
  @spec trim(keyword()) :: non_neg_integer()
  def trim(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case Keyword.get_lazy(opts, :path, &path/0) do
      nil ->
        0

      file ->
        cutoff = cutoff(now, Keyword.get_lazy(opts, :backups, &Backup.list/0))
        locked(fn -> rewrite(file, cutoff) end)
    end
  end

  @doc false
  def cutoff(now, backups) do
    margin = @margin_days * 86_400
    window = DateTime.add(now, -(Backup.retention() * 86_400 + margin), :second)

    case backups do
      [] ->
        window

      backups ->
        oldest = backups |> Enum.map(& &1.created_at) |> Enum.min(DateTime)
        Enum.min([window, DateTime.add(oldest, -margin, :second)], DateTime)
    end
  end

  defp rewrite(file, cutoff) do
    case File.read(file) do
      {:ok, contents} ->
        lines = String.split(contents, "\n", trim: true)

        kept =
          Enum.filter(lines, fn line ->
            case parse(line) do
              {:ok, %{"at" => at}} -> DateTime.compare(at, cutoff) != :lt
              :error -> false
            end
          end)

        gone = length(lines) - length(kept)
        tmp = file <> ".trimming"

        # Written beside it and renamed over it, so a crash mid-trim leaves the
        # old journal whole rather than half a new one. A failure is logged and
        # leaves the journal as it was: longer than it needs to be is harmless.
        with true <- gone > 0,
             :ok <- File.write(tmp, Enum.map(kept, &[&1, "\n"])),
             :ok <- File.rename(tmp, file) do
          gone
        else
          false ->
            0

          {:error, reason} ->
            File.rm(tmp)
            Logger.error("Could not trim the moderation journal #{file}: #{inspect(reason)}")
            0
        end

      {:error, _no_file} ->
        0
    end
  end

  ## ---------- at boot ----------

  @doc false
  # A supervision-tree entry that replays, trims and is gone: `start_link/1`
  # does the work and answers `:ignore`, so everything after it - the endpoint
  # above all - starts only once it has finished.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc false
  def start_link(_opts) do
    case replay() do
      0 -> :ok
      n -> Logger.warning("Moderation journal: re-applied #{n} action(s) a restore had undone.")
    end

    # A journal that could not be shortened is a slightly longer journal, not
    # a reason to keep the site down; the replay above is what may not fail.
    try do
      trim()
    rescue
      error -> Logger.error("Could not trim the moderation journal: #{Exception.message(error)}")
    end

    :ignore
  end
end
