defmodule OpenResults.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Before anything else starts: a production node with the admin panel's
    # development bypass configured must not come up at all, because it would
    # come up with an admin panel anyone can open. See
    # `OpenResultsWeb.AdminAccess.Config.check_boot!/0`.
    OpenResultsWeb.AdminAccess.Config.check_boot!()
    OpenResultsWeb.AdminAccess.Config.log_boot_state()

    # A run that does not migrate (`mix phx.server`, which is how the service
    # runs) refuses to start on a database that is behind the code - see
    # `refuse_pending_migrations!/0`.
    if skip_migrations?() and Application.get_env(:openresults, :refuse_pending_migrations, false),
      do: refuse_pending_migrations!()

    # The value every page's ETag is keyed with. Drawn here rather than
    # lazily, so it is one value for the whole node from before the first
    # request instead of whichever of two racing requests got there first -
    # and a tag that changed under a reader would answer 200 to every
    # revalidation. See `OpenResultsWeb.Plugs.Revalidate`.
    OpenResultsWeb.Plugs.Revalidate.new_secret()

    # The stats page's request and query counters. Attached before anything
    # serves or queries; until the collector has created their table an
    # increment is a no-op. See `OpenResultsWeb.StatsTelemetry`.
    OpenResultsWeb.StatsTelemetry.attach()

    children = [
      OpenResultsWeb.Telemetry,
      OpenResults.Repo,
      # The FIDE list's own database file - see `OpenResults.FideList.Repo`
      # for why it is not the main one.
      OpenResults.FideList.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:openresults, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:openresults, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OpenResults.PubSub},
      # Counts the open event streams, so there is a ceiling on them - see
      # `OpenResultsWeb.EventsController`. A registry rather than a counter
      # because it forgets a process the moment it dies, however it dies.
      {Registry, keys: :duplicate, name: OpenResults.EventStreams},
      # Owns the ETS table behind the entry form's rate limit. Before the
      # endpoint, so the table exists before anything can be posted at it.
      OpenResults.RateLimit,
      # Owns the ETS table behind `Snapshots.latest_id/1`. Before the
      # endpoint for the same reason as the rate limiter above: the table
      # must exist before the first request, not be created lazily by
      # whichever request happens to arrive first. See
      # `OpenResults.Snapshots.LatestIdCache`.
      OpenResults.Snapshots.LatestIdCache,
      # Own the ETS tables behind the decoded-snapshot cache and the
      # rendered-page cache, for the same reason and by the same fix as
      # LatestIdCache just above - see `OpenResults.Snapshots.BodyCache`'s
      # moduledoc for the load-test-confirmed failure this closes: left
      # lazy, either table's lifetime was tied to whichever connection
      # process happened to create it, and that process exiting (an
      # ordinary event under load) silently reopened the exact DB-pool
      # exhaustion LatestIdCache exists to prevent.
      OpenResults.Snapshots.BodyCache,
      OpenResultsWeb.Plugs.Revalidate.PageTable,
      # Owns the ETS table behind `Tournaments.status/1` - visibility, asked by
      # every public page before it may answer. Before the endpoint for the
      # same reason as the caches above. See
      # `OpenResults.Tournaments.StatusCache`.
      OpenResults.Tournaments.StatusCache,
      # Owns the ETS table of per-slug epochs that `Revalidate` folds into a
      # grouped tournament's ETag. Before the endpoint, like the caches
      # above. See `OpenResults.TournamentGroups.Epochs`.
      OpenResults.TournamentGroups.Epochs,
      # The server settings saved in the admin panel, and the public notice,
      # in ETS: limits are read on every publish, and the notice on every
      # page. Before the endpoint, like the caches above, and before
      # `DiskSpace`, which reads the free-disk floor from it. See
      # `OpenResults.ServerSettings`.
      OpenResults.ServerSettings,
      # Free space on the database's volume, measured on a timer so the
      # `storage_low` check is an ETS read. Before the endpoint, like the
      # caches above. See `OpenResults.DiskSpace`.
      OpenResults.DiskSpace,
      # The admin stats page's counters: owns their table and folds finished
      # minutes into history. Before the endpoint, like the caches above. See
      # `OpenResults.Stats`.
      {OpenResults.Stats.Collector,
       connections: &OpenResultsWeb.StatsTelemetry.open_connections/0},
      # Distinct readers per day, from a daily-salted hash, flushed to daily
      # totals in the database. After the Repo it writes to, before the
      # endpoint. See `OpenResults.Stats.Viewers`.
      OpenResults.Stats.Viewers,

      # Cloudflare Access's signing keys for the admin gate. Owns its table
      # and does every fetch itself, so a burst of admin requests with an
      # unknown key waits on one fetch instead of each making its own.
      OpenResultsWeb.AdminAccess.KeyCache,
      # After the migrations and the caches it clears, before the endpoint,
      # and it finishes before anything after it starts: a restored backup can
      # bring back a revoked key, closed registration, a lifted block or a
      # withdrawn tournament, and the first request after the boot would
      # already be served by it. This applies again what the journal kept -
      # see `OpenResults.ModerationJournal`.
      OpenResults.ModerationJournal,
      # Start to serve requests, typically the last entry
      OpenResults.Backup.Scheduler,
      # Forgets old client addresses, releases minted slugs that never
      # published, and removes expired address blocks - once a day.
      OpenResults.Retention.Scheduler,
      # Looks for a new FIDE list once a day and imports it in a process of
      # its own; a fresh install's first import starts a minute after boot.
      # Nothing waits for it - the entry form says "not yet" until it is done.
      OpenResults.FideList.Sync,
      OpenResultsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OpenResults.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpenResultsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  # The service is not a release: it runs `mix phx.server` with MIX_ENV=prod,
  # so the Migrator above skips, and the deploy migrates as its own step. The
  # restore drill of 2026-09-13 restored a backup from before 2026-09-12 by the
  # old instructions: the app booted, answered `/changelog`, and 500'd every
  # tournament page, `GET /api/server` and every publish. The moderation
  # journal's replay reads those tables at boot too, so on such a database the
  # boot would now fail anyway - with an error about a missing table instead
  # of the reason. So a run that does not migrate checks first and says what
  # to do. Configured in `config/prod.exs`, as OpenPairings does it: dev has
  # Phoenix's own pending-migrations page, tests migrate in their alias.
  # Migrations recorded that this code has no file for (a rollback) are logged,
  # not refused.
  defp refuse_pending_migrations! do
    for repo <- Application.fetch_env!(:openresults, :ecto_repos) do
      {:ok, migrations, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.migrations/1, pool_size: 1)

      case migration_refusal(migrations) do
        :ok ->
          :ok

        {:error, message} ->
          Logger.error(message)
          raise message
      end
    end
  end

  @doc false
  # The decision, apart from the database - for `OpenResults.ApplicationTest`.
  def migration_refusal(migrations) do
    unknown = for {:up, version, "** FILE NOT FOUND **"} <- migrations, do: version

    if unknown != [] do
      Logger.warning(
        "The database records #{length(unknown)} migration(s) this code has no file for " <>
          "(#{Enum.join(unknown, ", ")}): it is newer than the code."
      )
    end

    case for({:down, version, name} <- migrations, do: "#{version}_#{name}") do
      [] ->
        :ok

      pending ->
        {:error,
         """
         The database is #{length(pending)} migration(s) behind this code, and OpenResults \
         will not start on it.

         This run does not migrate at boot (it is `mix phx.server`, not a release), and \
         serving a database that is behind the code answers some pages and 500s the rest - \
         which is what a backup older than the code did in the 2026-09-13 restore drill.

         Migrate it first, as the service account and with the service's environment \
         (docs/deployment.md, "Restoring a backup"):

             mix ecto.migrate

         then start again. Pending: #{Enum.join(pending, ", ")}
         """}
    end
  end
end
