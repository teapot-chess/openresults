# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :openresults,
  ecto_repos: [OpenResults.Repo],
  generators: [timestamp_type: :utc_datetime]

# The bearer token an arbiter's machine publishes with. Deliberately nil here:
# a default that works is a default that reaches production. Each environment
# supplies its own, and config/runtime.exs reads OPENRESULTS_INGEST_TOKEN so a
# release never carries the real one in its build. Unset means every publish
# is refused, which is the right way for this to fail.
config :openresults, :ingest_token, nil

# Public publishing - `docs/public-publishing.md`, `OpenResults.PublicPublishing`.
# Off by default, and that default is the point: a club running this beside its
# own website must never be opened to the public by an upgrade. Each value can
# be overridden from the environment in config/runtime.exs.
config :openresults, :public_publishing, false
config :openresults, :operator_name, nil
config :openresults, :terms_url, nil
config :openresults, :contact_email, nil
config :openresults, :registrations_per_address, 10
config :openresults, :registrations_per_day, 200
config :openresults, :installation_publishes_per_minute, 30
config :openresults, :installation_max_tournaments, 50
# Measured, not guessed - the derivation is in docs/public-publishing.md under
# "Snapshot size cap". 3 MiB: about twice a 500-player, 11-round open with
# five tie-breaks' working published.
config :openresults, :installation_max_snapshot_bytes, 3_145_728
# The storage bounds - docs/public-publishing.md, "Storage bounds". An
# installation's tournament keeps its newest 20 versions (the operator's keep
# every one), and below 10% free space on the database's volume installation
# keys are refused `storage_low` on mint and publish.
config :openresults, :installation_max_versions, 20
config :openresults, :min_free_disk_percent, 10
# How often `OpenResults.DiskSpace` measures that free space.
config :openresults, :disk_space_interval, :timer.minutes(1)

# How often `OpenResults.Retention` runs. `:disabled` in test.
config :openresults, :retention_interval, :timer.hours(24)

# The FIDE rating list - `OpenResults.FideList`. On by default: a fresh
# install fetches it in the background a minute after its first boot, and
# after that looks once a day at :17 past `:fide_list_hour` (UTC), downloading
# only when FIDE has published a new one. Test and dev switch it off.
config :openresults, :fide_list_sync, true
config :openresults, :fide_list_hour, 3
config :openresults, :fide_list_boot_delay_ms, :timer.minutes(1)
# A breath between thousand-row chunks of an import, so requests arriving
# during it are not queued behind it on a two-core box.
config :openresults, :fide_list_chunk_pause_ms, 5

# Not ecto_sqlite3's defaults, which are a 64 MB page cache per connection
# and temporary storage in memory: building the name index sorts 1.9 million
# keys, and with those defaults the sort happened in RAM - measured at about
# 230 MB above the service's usual footprint, on a service whose ceiling is
# 768 MB. With these it spills to a temporary file and the import stays
# within a few tens of megabytes.
config :openresults, OpenResults.FideList.Repo,
  pool_size: 3,
  journal_mode: :wal,
  busy_timeout: 5_000,
  temp_store: :file,
  cache_size: -8_000

# Which environment this node was configured as, for the checks that must
# know at runtime - today only the admin panel's development bypass, which
# `OpenResultsWeb.AdminAccess.Config` refuses outside dev and test and which
# stops a production boot outright. Read as `:prod` when absent.
config :openresults, :environment, config_env()

# Configure the endpoint
config :openresults, OpenResultsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OpenResultsWeb.ErrorHTML, json: OpenResultsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: OpenResults.PubSub,
  live_view: [signing_salt: "cwbu1VZz"]

# No `root_tag_attribute`: the generator's `phx-r` exists for
# `Phoenix.LiveView.ColocatedCSS`, which nothing here uses, and it was stamped
# on the root tag of every component call - every player link, every
# cross-table cell - several thousand times over on a big open's pages.

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  openresults: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  openresults: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Windows cannot create the symlink LiveView wants for colocated assets
# without an elevated terminal, and this project has no colocated hooks to
# import from node_modules. The warning is noise on every compile.
config :phoenix_live_view,
  colocated_assets: [disable_symlink_warning: true]
