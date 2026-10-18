defmodule OpenResults.Moderation do
  @moduledoc """
  Everything the admin panel does, and the log of it.

  The names and arities here are a contract: `docs/public-publishing.md`,
  "Moderation API". The panel is built against that section and only renders
  what these return, so a rename here is a broken panel.

  ## Actors

  `actor` is `%{email: String.t()}` - the address the panel's own
  authentication established. Anything else raises: a moderation action with
  nobody behind it is a bug in the caller, not an input to tolerate.

  ## The action log

  Every function that changes something writes one `OpenResults.Moderation.Action`
  in the same transaction as the change, so there is no change without its
  entry and no entry for a change that rolled back. Three kinds of entry are
  written from outside this module's functions, each with its own actor:

    * `break-glass` - `OpenResults.TournamentKeys`, when the operator token was
      presented where a tournament key belongs;
    * `retention` - `OpenResults.Retention`, the daily job;
    * `restore-replay` - `OpenResults.ModerationJournal`, at boot, for an
      action a restored backup had undone and that was applied again.

  ## The moderation journal

  The actions that make the site safer - `delete`, `hide`, `revoke`,
  `suspend`, `block_address`, closing registration, pausing publishing,
  `untrust`, and lowering an installation's own limits - also
  append a line to `OpenResults.ModerationJournal` once they have committed:
  a file outside the database, which a restore cannot take back.

  ## Return shapes

    * a changed tournament, installation, report or block comes back as
      `{:ok, struct}`;
    * a refusal is `{:error, atom}` - `:not_found`, `:invalid_status`,
      `:already_resolved`, `:installation_revoked`, `:unknown_setting` - or
      `{:error, %Ecto.Changeset{}}` where there is a form to redisplay
      (`block_address/4`);
    * `delete/2` returns `{:ok, counts}`, the same counts
      `DELETE /api/tournaments/:slug` answers with.

  Tournament listings carry three virtual fields filled from other tables:
  `name` (from the current snapshot, `nil` before the first publish),
  `last_published_at` and `open_reports`. Installation listings carry
  `tournament_count` (`pending` plus `listed`, the number the limit counts).
  """

  import Ecto.Query, warn: false

  require Logger

  alias OpenResults.AddressBlocks
  alias OpenResults.AddressBlocks.Block
  alias OpenResults.Installations
  alias OpenResults.Installations.Installation
  alias OpenResults.LiveBoards
  alias OpenResults.Moderation.Action
  alias OpenResults.ModerationJournal
  alias OpenResults.PublicNotice
  alias OpenResults.QueryFilters
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResults.ServerSettings
  alias OpenResults.Settings
  alias OpenResults.Snapshots.Snapshot
  alias OpenResults.Takedown
  alias OpenResults.Tournaments
  alias OpenResults.Tournaments.Tournament

  @type actor :: %{email: String.t()}

  @break_glass "break-glass"
  @retention "retention"
  @restore_replay "restore-replay"
  @tournament_key "tournament-key"
  @operator_token "operator-token"

  # For `counts/0`. Spelled out rather than converted, so no atom is ever made
  # from a stored string.
  @installation_statuses %{"active" => :active, "suspended" => :suspended, "revoked" => :revoked}
  @tournament_statuses %{"pending" => :pending, "listed" => :listed, "hidden" => :hidden}

  # ---------------------------------------------------------------------------
  # Switches

  @doc "Both runtime switches."
  @spec settings() :: %{registration_open: boolean(), public_publishing_paused: boolean()}
  def settings, do: Settings.all()

  @doc """
  Flips one switch. `{:ok, settings}` with both switches as they now stand.
  """
  @spec put_setting(atom(), boolean(), actor()) :: {:ok, map()} | {:error, atom()}
  def put_setting(key, value, actor) do
    email = actor!(actor)

    cond do
      key not in Settings.keys() ->
        {:error, :unknown_setting}

      not is_boolean(value) ->
        {:error, :invalid_value}

      true ->
        transaction(fn ->
          {:ok, settings} = Settings.put(key, value, email)
          action = log!(email, "put_setting", "setting", Atom.to_string(key), %{value: value})
          {settings, action}
        end)
        |> committed(fn {settings, action} ->
          # Closing registration and pausing publishing only - the journal
          # never keeps the other direction. See `OpenResults.ModerationJournal`.
          ModerationJournal.record_setting(key, value, action.inserted_at)
          settings
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tournaments

  @doc """
  Tournaments, newest first. Filters: `status`, `installation_id`,
  `reported?` (only those with an open report), `search` (slug or name),
  `limit`, `offset`.
  """
  @spec list_tournaments(map() | keyword()) :: [Tournament.t()]
  def list_tournaments(filters \\ %{}) do
    filters = filters(filters, [:status, :installation_id, :reported?, :search, :limit, :offset])

    tournament_query()
    |> tournament_filter(:status, filters)
    |> tournament_filter(:installation_id, filters)
    |> tournament_filter(:reported?, filters)
    |> tournament_filter(:search, filters)
    |> QueryFilters.paginate(filters)
    |> Repo.all()
  end

  @doc "One tournament, with its installation preloaded, or `nil`."
  @spec get_tournament(String.t()) :: Tournament.t() | nil
  def get_tournament(slug) when is_binary(slug) do
    tournament_query()
    |> where([t], t.slug == ^slug)
    |> Repo.one()
    |> Repo.preload(:installation)
  end

  def get_tournament(_not_a_slug), do: nil

  defp tournament_query do
    latest =
      from s in Snapshot,
        group_by: s.tournament_slug,
        select: %{slug: s.tournament_slug, id: max(s.id)}

    open_reports =
      from r in Report,
        where: r.status == "open",
        group_by: r.tournament_slug,
        select: %{slug: r.tournament_slug, count: count(r.id)}

    from t in Tournament,
      as: :tournament,
      left_join: l in subquery(latest),
      on: l.slug == t.slug,
      left_join: s in Snapshot,
      as: :snapshot,
      on: s.id == l.id,
      left_join: r in subquery(open_reports),
      as: :reports,
      on: r.slug == t.slug,
      order_by: [desc: t.inserted_at, asc: t.slug],
      select_merge: %{
        name: fragment("json_extract(?, '$.tournament.name')", s.payload),
        # SQLite's json_extract turns JSON false into 0 and true into 1;
        # absent means listed, as `OpenResultsWeb.Tournament.listed?/1` reads it.
        front_page: fragment("coalesce(json_extract(?, '$.tournament.listed'), 1)", s.payload),
        last_published_at: s.received_at,
        open_reports: coalesce(r.count, 0)
      }
  end

  defp tournament_filter(query, :status, %{status: status}) when not is_nil(status),
    do: where(query, [tournament: t], t.status == ^to_string(status))

  defp tournament_filter(query, :installation_id, %{installation_id: id}) when is_binary(id),
    do: where(query, [tournament: t], t.installation_id == ^id)

  defp tournament_filter(query, :reported?, %{reported?: reported})
       when reported in [true, "true"],
       do: where(query, [reports: r], not is_nil(r.count))

  defp tournament_filter(query, :search, %{search: search})
       when is_binary(search) and search != "" do
    pattern = QueryFilters.like_pattern(search)

    where(
      query,
      [tournament: t, snapshot: s],
      fragment("? LIKE ? ESCAPE '\\'", t.slug, ^pattern) or
        fragment("json_extract(?, '$.tournament.name') LIKE ? ESCAPE '\\'", s.payload, ^pattern)
    )
  end

  defp tournament_filter(query, _key, _filters), do: query

  @doc "`pending` to `listed`."
  @spec approve(String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def approve(slug, actor), do: set_status(slug, ["pending"], "listed", "approve", actor)

  @doc "`pending` or `listed` to `hidden`."
  @spec hide(String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def hide(slug, actor), do: set_status(slug, ["pending", "listed"], "hidden", "hide", actor)

  @doc "`hidden` to `listed`."
  @spec unhide(String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def unhide(slug, actor), do: set_status(slug, ["hidden"], "listed", "unhide", actor)

  defp set_status(slug, from_statuses, to, action, actor) do
    email = actor!(actor)

    result =
      transaction(fn ->
        case Tournaments.transition(slug, from_statuses, to) do
          {:ok, tournament} ->
            row = log!(email, action, "tournament", slug, %{from: from_statuses, to: to})
            {tournament, row}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> committed(fn {tournament, row} ->
        if action == "hide", do: ModerationJournal.record_hide(slug, row.inserted_at)
        tournament
      end)

    # Once more after the commit, so the read path holds what was committed
    # rather than what the transaction saw.
    if is_binary(slug), do: Tournaments.forget(slug)
    result
  end

  @doc """
  Deletes everything held for a tournament - `OpenResults.Takedown.purge/1`.
  Idempotent, like the API route: `{:ok, counts}` even when nothing was there.
  """
  @spec delete(String.t(), actor()) :: {:ok, Takedown.counts()}
  def delete(slug, actor) when is_binary(slug) do
    email = actor!(actor)

    transaction(fn ->
      counts = Takedown.purge(slug)
      row = log!(email, "delete", "tournament", slug, counts)
      {counts, row}
    end)
    |> committed(fn {counts, row} ->
      ModerationJournal.record_delete(slug, "admin", row.inserted_at)
      counts
    end)
    |> tap(fn _ -> Tournaments.forget(slug) end)
  end

  @doc """
  Sets how far behind the game spectators see a tournament's live boards - see
  `OpenResults.LiveBoards`. Minutes; `0` removes the delay. Logged with the
  value it replaced.
  """
  @spec set_live_delay(String.t(), term(), actor()) ::
          {:ok, non_neg_integer()} | {:error, :not_found | :invalid}
  def set_live_delay(slug, minutes, actor) when is_binary(slug) do
    email = actor!(actor)

    if Tournaments.get(slug) == nil do
      {:error, :not_found}
    else
      before = LiveBoards.delay_minutes(slug)

      transaction(fn ->
        case LiveBoards.put_delay(slug, minutes, email) do
          {:ok, minutes} ->
            log!(email, "live_delay", "tournament", slug, %{from: before, to: minutes})
            minutes

          {:error, :invalid} ->
            Repo.rollback(:invalid)
        end
      end)
    end
  end

  @doc """
  Makes a relay key for a tournament - `OpenResults.RelayKeys`. Returns the
  key, the only time it is available. Logged with the key's id and label; the
  secret is never in the log.
  """
  @spec create_relay_key(String.t(), term(), actor()) ::
          {:ok, %{relay_key: OpenResults.RelayKeys.RelayKey.t(), key: String.t()}}
          | {:error, :not_found | :too_many}
  def create_relay_key(slug, label, actor) when is_binary(slug) do
    email = actor!(actor)

    if Tournaments.get(slug) == nil do
      {:error, :not_found}
    else
      transaction(fn ->
        label = relay_label(label)

        case OpenResults.RelayKeys.create(slug, label, email) do
          {:ok, %{relay_key: relay_key} = made} ->
            log!(email, "relay_key_create", "tournament", slug, %{
              id: relay_key.id,
              label: label,
              hint: relay_key.hint
            })

            made

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  The tournament's publisher making a relay key for it, over the API -
  `OpenResultsWeb.RelayKeyController`, which has already checked that the
  caller may publish to `slug`. Any key the publisher made earlier under the
  same label is revoked in the same transaction (`OpenResults.RelayKeys`,
  "Two makers"). Logged like the panel's, with the publisher as the actor.
  """
  @spec publisher_relay_key(
          String.t(),
          String.t(),
          {:installation, String.t()} | :operator_token
        ) ::
          {:ok,
           %{
             relay_key: OpenResults.RelayKeys.RelayKey.t(),
             key: String.t(),
             replaced: [integer()]
           }}
          | {:error, :too_many}
  def publisher_relay_key(slug, label, actor) when is_binary(slug) and is_binary(label) do
    who = api_actor(actor)

    transaction(fn ->
      replaced = OpenResults.RelayKeys.revoke_publisher_keys(slug, label, who)

      case OpenResults.RelayKeys.create(slug, label, who, "publisher") do
        {:ok, %{relay_key: relay_key} = made} ->
          log!(who, "relay_key_create", "tournament", slug, %{
            id: relay_key.id,
            label: label,
            hint: relay_key.hint,
            origin: "publisher",
            replaced: Enum.map(replaced, & &1.id)
          })

          Map.put(made, :replaced, Enum.map(replaced, & &1.id))

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  The publisher withdrawing the relay keys it made for `slug` - under one
  label, or all of them for `nil`. An admin's keys are not its to withdraw.
  Returns how many went; logged when any did.
  """
  @spec publisher_revoke_relay_keys(
          String.t(),
          String.t() | nil,
          {:installation, String.t()} | :operator_token
        ) :: {:ok, non_neg_integer()}
  def publisher_revoke_relay_keys(slug, label, actor) when is_binary(slug) do
    who = api_actor(actor)

    transaction(fn ->
      revoked = OpenResults.RelayKeys.revoke_publisher_keys(slug, label, who)

      for relay_key <- revoked do
        log!(who, "relay_key_revoke", "tournament", slug, %{
          id: relay_key.id,
          label: relay_key.label,
          hint: relay_key.hint,
          origin: "publisher"
        })
      end

      length(revoked)
    end)
  end

  @doc "Revokes a relay key of a tournament. Logged; the key stops working at once."
  @spec revoke_relay_key(String.t(), term(), actor()) ::
          {:ok, OpenResults.RelayKeys.RelayKey.t()} | {:error, :not_found | :already_revoked}
  def revoke_relay_key(slug, id, actor) when is_binary(slug) do
    email = actor!(actor)

    transaction(fn ->
      case OpenResults.RelayKeys.revoke(slug, id, email) do
        {:ok, relay_key} ->
          log!(email, "relay_key_revoke", "tournament", slug, %{
            id: relay_key.id,
            label: relay_key.label,
            hint: relay_key.hint
          })

          relay_key

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp relay_label(label) when is_binary(label) do
    case label |> String.trim() |> String.slice(0, 80) do
      "" -> nil
      text -> text
    end
  end

  defp relay_label(_not_text), do: nil

  @doc """
  Rebinds a tournament to another installation and clears its stored
  tournament key, so that installation's next keyed publish claims it - what
  break-glass is used for today when an arbiter's laptop dies. Status is
  unchanged. Refused for a revoked target, and for a suspended one for the
  reason `transfer_all/3` gives: a tournament moved to a key that cannot
  publish stops updating.
  """
  @spec transfer(String.t(), String.t(), actor()) :: {:ok, Tournament.t()} | {:error, atom()}
  def transfer(slug, installation_id, actor) do
    email = actor!(actor)

    case Repo.get(Installation, to_string(installation_id)) do
      nil ->
        {:error, :not_found}

      %Installation{status: status} = installation when status in ["revoked", "suspended"] ->
        can_receive(installation)

      %Installation{id: target} ->
        transaction(fn ->
          previous = Tournaments.get(slug)

          case Tournaments.transfer(slug, target) do
            {:ok, tournament} ->
              # A new owner starts without the old owner's hall relays.
              # `transfer_all/3` (the same organiser, restored from backup)
              # keeps them; it does not come through here.
              revoked = OpenResults.RelayKeys.revoke_all_for(slug, email)

              log!(email, "transfer", "tournament", slug, %{
                from: previous && previous.installation_id,
                to: target,
                relay_keys_revoked: revoked
              })

              tournament

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
    end
  end

  @doc """
  Moves every tournament an installation owns - pending, listed and hidden -
  to another installation, in one transaction, each exactly as `transfer/3`
  moves one: ownership rebound, stored tournament key released, status
  unchanged. Writes one `transfer` row per tournament (the same row
  `transfer/3` writes) and one `transfer_all` row for the whole move, targeted
  at the installation the tournaments left.

  The restore case: an OpenPairings backup never carries the installation
  key, so a laptop restored from backup registers as a new installation, and
  its tournaments have to follow it.

  `{:ok, %{from: id, to: id, slugs: [slug]}}`, or `{:error, reason}` with
  nothing moved and nothing logged:

    * `:same_installation` - `from` and `to` are one installation;
    * `:not_found` - either installation does not exist;
    * `:installation_revoked` - `to` is revoked, as `transfer/3` refuses;
    * `:installation_suspended` - `to` is suspended: moving tournaments to
      a key that cannot publish would stop every one of them updating, which
      is never what a restore wants. Unsuspend it first. `transfer/3`
      refuses the same;
    * `:no_tournaments` - `from` owns none, so there is nothing to move and
      nothing worth a log row.

  All or nothing: a failure on any one tournament rolls back every move and
  every row.
  """
  @spec transfer_all(String.t(), String.t(), actor()) :: {:ok, map()} | {:error, atom()}
  def transfer_all(from_id, to_id, actor) do
    email = actor!(actor)
    from_id = to_string(from_id)
    to_id = to_string(to_id)

    with :ok <- different(from_id, to_id),
         {%Installation{}, %Installation{} = target} <-
           {Repo.get(Installation, from_id), Repo.get(Installation, to_id)},
         :ok <- can_receive(target) do
      transaction(fn ->
        slugs =
          from(t in Tournament,
            where: t.installation_id == ^from_id,
            order_by: [asc: t.inserted_at, asc: t.slug],
            select: t.slug
          )
          |> Repo.all()

        if slugs == [], do: Repo.rollback(:no_tournaments)

        for slug <- slugs do
          case Tournaments.transfer(slug, to_id) do
            {:ok, _tournament} ->
              log!(email, "transfer", "tournament", slug, %{from: from_id, to: to_id})

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end

        log!(email, "transfer_all", "installation", from_id, %{to: to_id, slugs: slugs})

        %{from: from_id, to: to_id, slugs: slugs}
      end)
    else
      {:error, reason} -> {:error, reason}
      {_from, _to} -> {:error, :not_found}
    end
  end

  defp different(same, same), do: {:error, :same_installation}
  defp different(_from, _to), do: :ok

  defp can_receive(%Installation{status: "revoked"}), do: {:error, :installation_revoked}
  defp can_receive(%Installation{status: "suspended"}), do: {:error, :installation_suspended}
  defp can_receive(%Installation{}), do: :ok

  # ---------------------------------------------------------------------------
  # Installations

  @doc "Installations, newest first. Filters: `status`, `search`, `limit`, `offset`."
  @spec list_installations(map() | keyword()) :: [Installation.t()]
  def list_installations(filters \\ %{}) do
    filters |> filters([:status, :search, :limit, :offset]) |> Installations.list()
  end

  @doc "One installation, with its tournaments preloaded, or `nil`."
  @spec get_installation(String.t()) :: Installation.t() | nil
  def get_installation(id), do: Installations.get(id)

  @doc "`active` to `suspended`: may still delete its own tournaments, nothing else."
  @spec suspend(String.t(), actor()) :: {:ok, Installation.t()} | {:error, atom()}
  def suspend(id, actor),
    do: set_installation_status(id, ["active"], "suspended", "suspend", actor)

  @doc "`suspended` to `active`."
  @spec unsuspend(String.t(), actor()) :: {:ok, Installation.t()} | {:error, atom()}
  def unsuspend(id, actor),
    do: set_installation_status(id, ["suspended"], "active", "unsuspend", actor)

  @doc """
  Revokes an installation's key for good. `hide_tournaments: true` also hides
  every `pending` and `listed` tournament it holds; without it they stay as
  they are, and the key can still delete them.
  """
  @spec revoke(String.t(), actor(), keyword()) :: {:ok, Installation.t()} | {:error, atom()}
  def revoke(id, actor, opts) do
    email = actor!(actor)
    hide? = Keyword.get(opts, :hide_tournaments, false) == true

    result =
      transaction(fn ->
        was_trusted = trusted?(to_string(id))

        # `transition/3` clears trust with the status - see `trust/3`.
        case Installations.transition(to_string(id), ["active", "suspended"], "revoked") do
          {:ok, installation} ->
            hidden = if hide?, do: Tournaments.hide_all_for(installation.id), else: []

            # The boxes go with the publisher: a key it minted for a hall
            # relay is a way to keep writing after the right to was taken.
            relay_keys_revoked =
              OpenResults.RelayKeys.revoke_all_for_installation(installation.id, email)

            row =
              log!(email, "revoke", "installation", installation.id, %{
                hide_tournaments: hide?,
                hidden: hidden,
                relay_keys_revoked: relay_keys_revoked,
                was_trusted: was_trusted
              })

            {installation, hidden, row}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {installation, hidden, row}} ->
        ModerationJournal.record_revoke(installation.id, hide?, row.inserted_at)
        Enum.each(hidden, &Tournaments.forget/1)
        {:ok, Installations.get(installation.id)}

      error ->
        error
    end
  end

  defp trusted?(id) do
    from(i in Installation, where: i.id == ^id, select: i.trusted) |> Repo.one() == true
  end

  @doc """
  Trusts an installation: tournaments it mints from now on start `listed`
  instead of `pending`, so they are on the cross-tournament player pages at
  once. `list_pending: true` also lists every tournament of its that is
  pending now, each with its own `approve` row; without it they stay pending.

  `{:ok, installation}`, or `{:error, :not_found}`, or
  `{:error, :invalid_status}` when it is already trusted or is revoked.
  Suspending leaves trust as it is (a suspended key publishes nothing
  anyway); revoking clears it.
  """
  @spec trust(String.t(), actor(), keyword()) :: {:ok, Installation.t()} | {:error, atom()}
  def trust(id, actor, opts) do
    email = actor!(actor)
    list? = Keyword.get(opts, :list_pending, false) == true

    result =
      transaction(fn ->
        case Installations.set_trusted(to_string(id), true) do
          {:ok, installation} ->
            listed = if list?, do: Tournaments.list_pending_for(installation.id), else: []

            for slug <- listed do
              log!(email, "approve", "tournament", slug, %{
                from: ["pending"],
                to: "listed",
                via: "trust"
              })
            end

            log!(email, "trust", "installation", installation.id, %{
              list_pending: list?,
              listed: listed
            })

            {installation, listed}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {installation, listed}} ->
        Enum.each(listed, &Tournaments.forget/1)
        {:ok, Installations.get(installation.id)}

      error ->
        error
    end
  end

  @doc """
  Ends an installation's trust: its next tournaments start `pending` again.
  The ones it already has keep their status. `{:error, :invalid_status}` when
  it is not trusted.
  """
  @spec untrust(String.t(), actor()) :: {:ok, Installation.t()} | {:error, atom()}
  def untrust(id, actor) do
    email = actor!(actor)

    transaction(fn ->
      case Installations.set_trusted(to_string(id), false) do
        {:ok, installation} ->
          row = log!(email, "untrust", "installation", installation.id, %{})
          {installation, row}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> committed(fn {installation, row} ->
      # Ending trust makes the site safer, so a restore must not bring it
      # back - see `OpenResults.ModerationJournal`.
      ModerationJournal.record_untrust(installation.id, row.inserted_at)
      installation
    end)
  end

  @doc """
  An installation's own limits, validated as `put_installation_limits/3`
  would and not stored. Blank is the server's value.
  """
  @spec change_installation_limits(Installation.t(), map()) :: Ecto.Changeset.t()
  def change_installation_limits(%Installation{} = installation, attrs),
    do: Installations.limits_changeset(installation, attrs)

  @doc """
  Sets an installation's own limits - `max_tournaments`,
  `max_snapshot_bytes`, `publishes_per_minute`, `max_versions` (string keys,
  as the form sends them) - each a whole number in the range of the server
  setting it overrides, or blank for the server's value. Every field is
  written, so a field left out goes back to the server's value.

  `{:ok, installation}`, `{:error, :not_found}`, or `{:error, changeset}`
  naming the fields out of range, with nothing stored.
  """
  @spec put_installation_limits(String.t(), map(), actor()) ::
          {:ok, Installation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_installation_limits(id, attrs, actor) when is_map(attrs) do
    email = actor!(actor)

    case Repo.get(Installation, to_string(id)) do
      nil ->
        {:error, :not_found}

      installation ->
        changeset = Installations.limits_changeset(installation, attrs)

        if changeset.valid? do
          before = Map.take(installation, Installation.limits())

          transaction(fn ->
            updated = Installations.update_limits!(changeset)

            row =
              log!(email, "set_installation_limits", "installation", installation.id, %{
                from: stringify(before),
                to: stringify(Map.take(updated, Installation.limits()))
              })

            {updated, row}
          end)
          |> committed(fn {updated, row} ->
            # Only the limits that went DOWN in effect - the safer direction -
            # are journalled; a raise stays as a restored backup had it.
            lowered = lowered_limits(before, Map.take(updated, Installation.limits()))

            if lowered != %{},
              do: ModerationJournal.record_lower_limits(updated.id, lowered, row.inserted_at)

            Installations.get(updated.id)
          end)
        else
          {:error, changeset}
        end
    end
  end

  @doc "The labels of the given installation ids, `%{id => label}`; see `Installations.labels/1`."
  @spec installation_labels([String.t() | nil]) :: %{String.t() => String.t()}
  def installation_labels(ids), do: Installations.labels(ids)

  @doc """
  An installation's label, validated as `put_installation_label/3` would and
  not stored.
  """
  @spec change_installation_label(Installation.t(), map()) :: Ecto.Changeset.t()
  def change_installation_label(%Installation{} = installation, attrs),
    do: Installations.label_changeset(installation, attrs)

  @doc """
  Gives an installation the operator's own name, or clears it (blank).
  Trimmed, at most #{Installation.label_max()} characters. The label is for the panel
  alone: nothing public and nothing an installation receives carries it. It
  is not journalled - a restore has nothing to re-apply that makes the site
  safer.

  `{:ok, installation}`, `{:error, :not_found}`, or `{:error, changeset}`.
  """
  @spec put_installation_label(String.t(), String.t() | nil, actor()) ::
          {:ok, Installation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_installation_label(id, label, actor) do
    email = actor!(actor)

    case Repo.get(Installation, to_string(id)) do
      nil ->
        {:error, :not_found}

      installation ->
        changeset = Installations.label_changeset(installation, %{"label" => label})

        if changeset.valid? do
          transaction(fn ->
            updated = Installations.update_label!(changeset)

            log!(email, "label", "installation", installation.id, %{
              from: installation.label,
              to: updated.label
            })

            updated
          end)
          |> committed(& &1)
        else
          {:error, changeset}
        end
    end
  end

  # Each limit whose value in force is now lower than before, with the
  # installation's own value after the change (`nil` for the server's). The
  # server's value stands in for a blank on both sides, read now.
  defp lowered_limits(before, after_change) do
    for field <- Installation.limits(),
        global = ServerSettings.get(OpenResults.PublicPublishing.global_for(field)),
        (after_change[field] || global) < (before[field] || global),
        into: %{},
        do: {field, after_change[field]}
  end

  # ---------------------------------------------------------------------------
  # Server settings and the public notice

  @doc """
  Every server setting the panel can change, described:
  `%{key, value, source: :panel | :environment | :default, panel, environment,
  default, variable}` - see `OpenResults.ServerSettings.describe/1`.
  """
  @spec server_settings() :: [map()]
  def server_settings, do: ServerSettings.all()

  @doc """
  Saves a server setting in the panel, where it wins over the environment.
  `raw` is checked exactly as the boot checks the environment variable
  (`OpenResults.ServerSettings.validate/2`).

  `{:ok, described}`, `{:error, :unknown_setting}`, or
  `{:error, {:invalid_value, sentence}}` with nothing stored.
  """
  @spec put_server_setting(atom() | String.t(), term(), actor()) ::
          {:ok, map()} | {:error, :unknown_setting | {:invalid_value, String.t()}}
  def put_server_setting(key, raw, actor) do
    email = actor!(actor)

    with {:ok, key} <- setting_key(key),
         {:ok, value} <- valid_setting(key, raw) do
      before = ServerSettings.describe(key)

      transaction(fn ->
        ServerSettings.put(key, ServerSettings.encode(value), email)

        log!(email, "put_server_setting", "setting", Atom.to_string(key), %{
          from: before.value,
          from_source: Atom.to_string(before.source),
          to: value
        })
      end)
      |> committed(fn _row ->
        ServerSettings.refresh()
        ServerSettings.describe(key)
      end)
    end
  end

  @doc """
  Removes the panel's value, so the environment's - or the default - is in
  force again. `{:ok, described}`, `{:error, :unknown_setting}`, or
  `{:error, :not_set}` when the panel holds no value for it.
  """
  @spec reset_server_setting(atom() | String.t(), actor()) ::
          {:ok, map()} | {:error, :unknown_setting | :not_set}
  def reset_server_setting(key, actor) do
    email = actor!(actor)

    with {:ok, key} <- setting_key(key) do
      before = ServerSettings.describe(key)

      transaction(fn ->
        if ServerSettings.delete(key) == 0, do: Repo.rollback(:not_set)
        after_reset = ServerSettings.fallback(key)

        log!(email, "reset_server_setting", "setting", Atom.to_string(key), %{
          from: before.panel,
          to: after_reset.value,
          to_source: Atom.to_string(after_reset.source)
        })
      end)
      |> tap(fn _ -> ServerSettings.refresh() end)
      |> committed(fn _row -> ServerSettings.describe(key) end)
    end
  end

  defp setting_key(key) do
    case ServerSettings.key(key) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :unknown_setting}
    end
  end

  defp valid_setting(key, raw) do
    case ServerSettings.validate(key, raw) do
      {:ok, value} -> {:ok, value}
      {:error, sentence} -> {:error, {:invalid_value, sentence}}
    end
  end

  @doc "The stored public notice, expired or not, or `nil` - see `OpenResults.PublicNotice`."
  @spec public_notice() :: PublicNotice.t() | nil
  def public_notice, do: PublicNotice.stored()

  @doc "A notice checked as `set_public_notice/2` would check it, stored nowhere."
  @spec change_public_notice(map()) :: Ecto.Changeset.t()
  def change_public_notice(attrs), do: PublicNotice.changeset(attrs)

  @doc """
  Sets the public notice, replacing any. `attrs` has string keys `en`
  (required), `nl`, `fr`, `level` (`info` | `warning`) and `expires_at` (an
  ISO 8601 instant in the future, or blank). `{:ok, notice}` or
  `{:error, changeset}` with nothing stored.
  """
  @spec set_public_notice(map(), actor()) ::
          {:ok, PublicNotice.t()} | {:error, Ecto.Changeset.t()}
  def set_public_notice(attrs, actor) when is_map(attrs) do
    email = actor!(actor)
    now = DateTime.utc_now()
    changeset = PublicNotice.changeset(attrs, now)

    if changeset.valid? do
      before = PublicNotice.stored()
      document = PublicNotice.to_document(changeset, email, now)

      transaction(fn ->
        ServerSettings.put(ServerSettings.notice_key(), Jason.encode!(document), email)

        log!(email, "set_notice", "setting", ServerSettings.notice_key(), %{
          from: PublicNotice.log_details(before),
          to: PublicNotice.log_details(PublicNotice.from_document(document))
        })
      end)
      |> committed(fn _row ->
        ServerSettings.refresh()
        PublicNotice.stored()
      end)
    else
      {:error, changeset}
    end
  end

  @doc """
  Clears the public notice. `{:ok, previous}`, or `{:error, :not_set}` when
  there is none - an expired notice still counts as set until it is cleared.
  """
  @spec clear_public_notice(actor()) :: {:ok, PublicNotice.t()} | {:error, :not_set}
  def clear_public_notice(actor) do
    email = actor!(actor)
    before = PublicNotice.stored()

    transaction(fn ->
      if ServerSettings.delete(ServerSettings.notice_key()) == 0, do: Repo.rollback(:not_set)

      log!(email, "clear_notice", "setting", ServerSettings.notice_key(), %{
        from: PublicNotice.log_details(before)
      })
    end)
    |> tap(fn _ -> ServerSettings.refresh() end)
    |> committed(fn _row -> before end)
  end

  defp set_installation_status(id, from_statuses, to, action, actor) do
    email = actor!(actor)

    transaction(fn ->
      case Installations.transition(to_string(id), from_statuses, to) do
        {:ok, installation} ->
          row =
            log!(email, action, "installation", installation.id, %{from: from_statuses, to: to})

          {installation, row}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> committed(fn {installation, row} ->
      if action == "suspend",
        do: ModerationJournal.record_suspend(installation.id, row.inserted_at)

      installation
    end)
  end

  # ---------------------------------------------------------------------------
  # Reports

  @doc """
  Reports, newest first. `filters` is `:open`, `:resolved`, or a map/keyword
  with `status` (`open` | `resolved`), `slug`, `limit`, `offset`.
  """
  @spec list_reports(atom() | map() | keyword()) :: [Report.t()]
  def list_reports(status) when status in [:open, :resolved, "open", "resolved"],
    do: Reports.list(%{status: status})

  def list_reports(filters),
    do: filters |> filters([:status, :slug, :limit, :offset]) |> Reports.list()

  @doc "Marks a report resolved, with a free-text resolution."
  @spec resolve_report(term(), String.t() | atom(), actor()) ::
          {:ok, Report.t()} | {:error, atom()}
  def resolve_report(id, resolution, actor) do
    email = actor!(actor)
    resolution = resolution |> to_string() |> String.slice(0, 2000)

    transaction(fn ->
      case Reports.resolve(id, resolution, email) do
        {:ok, report} ->
          log!(email, "resolve_report", "report", Integer.to_string(report.id), %{
            slug: report.tournament_slug,
            resolution: resolution
          })

          report

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Address blocks

  @doc """
  Blocks an address or CIDR range from registration, minting and publishing
  until `expires_at` - which must be in the future and at most 30 days away.
  `{:error, changeset}` when it is not.
  """
  @spec block_address(String.t(), DateTime.t(), String.t(), actor()) ::
          {:ok, Block.t()} | {:error, Ecto.Changeset.t()}
  def block_address(ip_or_cidr, expires_at, reason, actor) do
    email = actor!(actor)

    transaction(fn ->
      case AddressBlocks.create(ip_or_cidr, expires_at, reason, email) do
        {:ok, block} ->
          row =
            log!(email, "block_address", "address_block", Integer.to_string(block.id), %{
              cidr: block.cidr,
              expires_at: DateTime.to_iso8601(block.expires_at),
              reason: block.reason
            })

          {block, row}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> committed(fn {block, row} ->
      ModerationJournal.record_block(block.cidr, block.expires_at, row.inserted_at)
      block
    end)
  end

  @doc "Every block that has not expired, soonest to expire first."
  @spec list_blocks() :: [Block.t()]
  def list_blocks, do: AddressBlocks.list_active()

  @doc "Lifts a block."
  @spec unblock(term(), actor()) :: {:ok, Block.t()} | {:error, :not_found}
  def unblock(id, actor) do
    email = actor!(actor)

    transaction(fn ->
      case AddressBlocks.get(id) do
        nil ->
          Repo.rollback(:not_found)

        block ->
          {:ok, block} = AddressBlocks.delete(block)

          log!(email, "unblock", "address_block", Integer.to_string(block.id), %{
            cidr: block.cidr
          })

          block
      end
    end)
  end

  @doc """
  How many installations registered from, or were last seen from, inside
  `ip_or_cidr` - what the panel shows before a block is confirmed. Addresses
  are forgotten after 30 days, so this counts the last month at most.
  """
  @spec installations_seen_from(String.t()) :: non_neg_integer()
  def installations_seen_from(ip_or_cidr), do: Installations.seen_from(ip_or_cidr)

  @doc """
  An unsaved block, validated exactly as `block_address/4` would validate it -
  for the panel's confirmation page, which has to show the normalised range
  and `installations_seen_from/1` for it BEFORE anything is stored. Writes
  nothing and logs nothing. Its `cidr` field is the canonical range when the
  address parsed.
  """
  @spec change_block(term(), term(), term(), actor()) :: Ecto.Changeset.t()
  def change_block(ip_or_cidr, expires_at, reason, actor) do
    email = actor!(actor)

    %Block{}
    |> Block.changeset(
      %{cidr: ip_or_cidr, expires_at: expires_at, reason: reason, created_by: email},
      DateTime.utc_now()
    )
    |> Map.put(:action, :validate)
  end

  # ---------------------------------------------------------------------------
  # What the panel shows beside the lists

  @doc "One report by id, or `nil`."
  @spec get_report(term()) :: Report.t() | nil
  def get_report(id), do: Reports.get(id)

  @doc """
  The dashboard's numbers. Every status is present, zero included:

      %{
        installations: %{active: n, suspended: n, revoked: n},
        tournaments: %{pending: n, listed: n, hidden: n},
        open_reports: n,
        address_blocks: n    # live ones
      }
  """
  @spec counts() :: map()
  def counts do
    %{
      installations: by_status(Installation, @installation_statuses),
      tournaments: by_status(Tournament, @tournament_statuses),
      open_reports: Repo.aggregate(from(r in Report, where: r.status == "open"), :count),
      address_blocks: length(AddressBlocks.list_active())
    }
  end

  defp by_status(schema, statuses) do
    stored =
      from(x in schema, group_by: x.status, select: {x.status, count()})
      |> Repo.all()
      |> Map.new()

    Map.new(statuses, fn {text, atom} -> {atom, Map.get(stored, text, 0)} end)
  end

  @doc """
  What published tournaments cost in disk, server-wide:

      %{
        snapshots: n,             # stored versions, every tournament
        snapshot_bytes: n,        # their payloads, as stored
        tournaments: n,           # slugs holding at least one version
        database_bytes: n         # the SQLite file's pages, free ones included
      }

  Payload bytes are the stored JSON's length in bytes. Every version is kept,
  so this is the number public publishing grows. Reads every row's length, so
  it is for a page an admin opens, not for a request path.
  """
  @spec storage() :: map()
  def storage do
    {snapshots, bytes, tournaments} =
      from(s in Snapshot,
        select:
          {count(s.id), coalesce(sum(fragment("length(CAST(? AS BLOB))", s.payload)), 0),
           count(s.tournament_slug, :distinct)}
      )
      |> Repo.one()

    %{
      snapshots: snapshots,
      snapshot_bytes: bytes,
      tournaments: tournaments,
      database_bytes: database_bytes(),
      # The storage bounds (docs/public-publishing.md): the version cap in
      # force, and the free-disk reading the `storage_low` refusal reads.
      max_versions: OpenResults.PublicPublishing.installation_max_versions(),
      disk: OpenResults.DiskSpace.reading()
    }
  end

  defp database_bytes do
    case Repo.query("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()") do
      {:ok, %{rows: [[bytes]]}} when is_integer(bytes) -> bytes
      _unavailable -> nil
    end
  end

  @doc """
  The stored versions of the tournaments an installation owns now:
  `%{tournaments: n, snapshots: n, snapshot_bytes: n}`. A transferred
  tournament counts for its new owner.
  """
  @spec installation_storage(String.t()) :: map()
  def installation_storage(id) when is_binary(id) do
    {snapshots, bytes, tournaments} =
      from(s in Snapshot,
        join: t in Tournament,
        on: t.slug == s.tournament_slug,
        where: t.installation_id == ^id,
        select:
          {count(s.id), coalesce(sum(fragment("length(CAST(? AS BLOB))", s.payload)), 0),
           count(s.tournament_slug, :distinct)}
      )
      |> Repo.one()

    %{tournaments: tournaments, snapshots: snapshots, snapshot_bytes: bytes}
  end

  @doc """
  One tournament's publishing record, for its detail page and its delete
  confirmation:

      %{
        snapshots: n,                  # stored versions
        snapshot_bytes: n,             # all of them
        current_bytes: n | nil,        # the version the public sees
        first_published_at: DateTime | nil,
        last_published_at: DateTime | nil,
        registrations: n               # entries waiting, with email addresses
      }

  First and last are the first and newest stored versions by insertion, as
  everywhere else here, so a clock that stepped backwards cannot swap them.
  """
  @spec tournament_stats(String.t()) :: map()
  def tournament_stats(slug) when is_binary(slug) do
    {snapshots, bytes, first_id, last_id} =
      from(s in Snapshot,
        where: s.tournament_slug == ^slug,
        select:
          {count(s.id), coalesce(sum(fragment("length(CAST(? AS BLOB))", s.payload)), 0),
           min(s.id), max(s.id)}
      )
      |> Repo.one()

    {first_at, _} = version(first_id)
    {last_at, current_bytes} = version(last_id)

    %{
      snapshots: snapshots,
      snapshot_bytes: bytes,
      current_bytes: current_bytes,
      first_published_at: first_at,
      last_published_at: last_at,
      registrations:
        Repo.aggregate(from(r in Registration, where: r.tournament_slug == ^slug), :count)
    }
  end

  defp version(nil), do: {nil, nil}

  defp version(id) do
    from(s in Snapshot,
      where: s.id == ^id,
      select: {s.received_at, fragment("length(CAST(? AS BLOB))", s.payload)}
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # The log

  @doc """
  The action log, newest first. Filters: `actor`, `action`, `target_type`,
  `target`, `limit` (default 100), `offset`.

  `actor` matches any part of the actor - an `installation:<id>` actor is not
  something anyone can type whole - and the other three match exactly.
  """
  @spec list_actions(map() | keyword()) :: [Action.t()]
  def list_actions(filters \\ %{}) do
    filters =
      filters
      |> filters([:actor, :action, :target_type, :target, :limit, :offset])
      |> Map.put_new(:limit, 100)

    Enum.reduce([:actor, :action, :target_type, :target], from(a in Action), fn key, query ->
      case {key, Map.get(filters, key)} do
        {_key, nil} ->
          query

        {:actor, value} ->
          pattern = QueryFilters.like_pattern(to_string(value))
          where(query, [a], fragment("? LIKE ? ESCAPE '\\'", a.actor, ^pattern))

        {key, value} ->
          where(query, [a], field(a, ^key) == ^to_string(value))
      end
    end)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> QueryFilters.paginate(filters)
    |> Repo.all()
  end

  @doc false
  # For `OpenResults.TournamentKeys`: a use of the operator token in the
  # tournament-key position. Never raises - an audit entry that failed to write
  # must not turn the recovery it records into a 500 - but logs if it fails.
  @spec log_break_glass(String.t(), atom(), String.t()) :: :ok
  def log_break_glass(slug, action, detail) do
    log!(@break_glass, "break_glass_#{action}", "tournament", slug, %{detail: detail})
    :ok
  rescue
    error ->
      Logger.error(
        "could not write the break-glass action log entry: #{Exception.message(error)}"
      )

      :ok
  end

  @doc false
  # For `OpenResultsWeb.SnapshotController`: an API delete succeeding for a
  # caller other than the admin panel and other than break-glass, which logs
  # itself and must never be logged twice. `counts` is `Takedown.purge/1`'s
  # map - integers, nothing personal. Never raises, for the same reason as
  # `log_break_glass/3`: the delete has already happened.
  @spec log_api_delete(
          {:installation, String.t()} | :tournament_key | :operator_token,
          String.t(),
          map()
        ) :: :ok
  def log_api_delete(actor, slug, counts) do
    log!(api_actor(actor), "delete", "tournament", slug, counts)
    :ok
  rescue
    error ->
      Logger.error("could not write the API delete action log entry: #{Exception.message(error)}")

      :ok
  end

  defp api_actor({:installation, id}), do: "installation:#{id}"
  defp api_actor(:tournament_key), do: @tournament_key
  defp api_actor(:operator_token), do: @operator_token

  @doc false
  # For `OpenResults.Retention`: forgets the address range in `block_address`
  # and `unblock` entries once the block has been over for `days`. A block
  # ended at its `expires_at`, or - lifted early - at the `unblock` entry's own
  # time. The rest of the entry stays: that a block happened, when, and why.
  @spec forget_expired_block_addresses(DateTime.t(), pos_integer()) :: non_neg_integer()
  def forget_expired_block_addresses(%DateTime{} = now, days) when is_integer(days) do
    from(a in Action,
      where:
        a.target_type == "address_block" and a.action in ["block_address", "unblock"] and
          fragment("json_extract(?, '$.cidr') IS NOT NULL", a.details)
    )
    |> Repo.all()
    |> Enum.filter(fn action ->
      case block_ended_at(action) do
        nil -> false
        ended -> DateTime.compare(now, DateTime.add(ended, days * 86_400, :second)) != :lt
      end
    end)
    |> Enum.reduce(0, fn action, count ->
      action
      |> Ecto.Changeset.change(details: Map.put(action.details, "cidr", nil))
      |> Repo.update!()

      count + 1
    end)
  end

  defp block_ended_at(%Action{action: "unblock", inserted_at: at}), do: at

  defp block_ended_at(%Action{action: "block_address", details: details}) do
    with at when is_binary(at) <- details["expires_at"],
         {:ok, ended, _offset} <- DateTime.from_iso8601(at) do
      ended
    else
      _unparseable -> nil
    end
  end

  @doc false
  # For `OpenResults.Retention`.
  @spec log_retention(map()) :: :ok
  def log_retention(details) do
    log!(@retention, "retention", nil, nil, details)
    :ok
  end

  @doc false
  # For `OpenResults.ModerationJournal`: an action a restore had undone, applied
  # again at boot. Written inside the replay's own transaction, so there is no
  # re-applied action without its row - and the row is what the next boot
  # reads to know it was.
  @spec log_replay(String.t(), String.t(), String.t(), map()) :: Action.t()
  def log_replay(action, target_type, target, details),
    do: log!(@restore_replay, action, target_type, target, details)

  @doc false
  def restore_replay_actor, do: @restore_replay

  defp log!(actor, action, target_type, target, details) do
    Repo.insert!(%Action{
      actor: actor,
      action: action,
      target_type: target_type,
      target: target,
      details: stringify(details),
      inserted_at: DateTime.utc_now()
    })
  end

  # JSON round-trips string keys only; storing them that way means a row
  # reads back the same as it was written.
  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp actor!(%{email: email}) when is_binary(email) and email != "", do: email

  defp actor!(other) do
    raise ArgumentError, "a moderation actor is %{email: String.t()}, got: #{inspect(other)}"
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  # After the commit and only after it: the journal must never hold an action
  # that rolled back, or a restore would apply one that never happened.
  defp committed({:ok, value}, fun), do: {:ok, fun.(value)}
  defp committed(error, _fun), do: error

  # Filters arrive from a panel, so they may be a keyword list or a map, with
  # atom or string keys. Only the known keys survive, as atoms - never
  # `String.to_atom/1` on whatever was sent.
  defp filters(filters, allowed) when is_list(filters) or is_map(filters) do
    by_name = Map.new(allowed, &{Atom.to_string(&1), &1})

    Enum.reduce(filters, %{}, fn {key, value}, acc ->
      case key do
        key when is_atom(key) ->
          if key in allowed, do: Map.put(acc, key, value), else: acc

        key when is_binary(key) ->
          case Map.fetch(by_name, key) do
            {:ok, atom} -> Map.put(acc, atom, value)
            :error -> acc
          end

        _other ->
          acc
      end
    end)
  end

  defp filters(_nothing, _allowed), do: %{}
end
