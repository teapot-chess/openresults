import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/openresults start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :openresults, OpenResultsWeb.Endpoint, server: true
end

# Outside the prod block on purpose, so a dev or staging box can point a real
# OpenPairings at it by exporting one variable. Absent, whatever the
# environment's config file set stands - and in prod that is nil, so publishing
# is refused until someone sets this. Refusing to ingest is a better failure
# than refusing to boot: the read side keeps serving the tournaments already
# published while the token is sorted out.
if ingest_token = System.get_env("OPENRESULTS_INGEST_TOKEN") do
  config :openresults, :ingest_token, ingest_token
end

# The FIDE rating list this server keeps for the entry form's search - see
# `OpenResults.FideList`. On unless switched off; an hour of the day (UTC) for
# the daily look; and an address to fetch it from other than FIDE's, for a
# host whose network range FIDE refuses. Anything that is not a clear on/off
# or an hour stops the boot rather than being guessed at.
case System.get_env("OPENRESULTS_FIDE_LIST_SYNC") do
  nil ->
    :ok

  value ->
    case String.downcase(String.trim(value)) do
      on when on in ~w(on true 1 yes enabled) ->
        config :openresults, :fide_list_sync, true

      off when off in ~w(off false 0 no disabled) ->
        config :openresults, :fide_list_sync, false

      _other ->
        raise "OPENRESULTS_FIDE_LIST_SYNC is on or off, got: #{inspect(value)}"
    end
end

if hour = System.get_env("OPENRESULTS_FIDE_LIST_HOUR") do
  case Integer.parse(hour) do
    {h, ""} when h in 0..23 ->
      config :openresults, :fide_list_hour, h

    _ ->
      raise "OPENRESULTS_FIDE_LIST_HOUR is an hour of the day in UTC, 0 to 23, got: #{inspect(hour)}"
  end
end

if list_url = System.get_env("FIDE_LIST_URL") do
  config :openresults, :fide_list_url, list_url
end

# Backups - see `OpenResults.Backup`. Nothing in this database is
# reproducible: the snapshots are a published record, `/history?at=` answers a
# question that cannot be recomputed, the queue holds entries nobody has
# reviewed, and the keys decide who may withdraw a tournament.
#
# BACKUP_DIR defaults to a `backups/` directory beside the database.
# OPENRESULTS_BACKUP_PASSPHRASE encrypts them, which is worth doing: the
# registration queue carries the email addresses people gave the entry form.
if backup_dir = System.get_env("BACKUP_DIR") do
  config :openresults, :backup_dir, backup_dir
end

if passphrase = System.get_env("OPENRESULTS_BACKUP_PASSPHRASE") do
  config :openresults, :backup_passphrase, passphrase
end

if keep = System.get_env("BACKUP_RETENTION") do
  # DAYS - how long a backup is kept - and a whole number of at least one, or
  # the app does not start. It was a count of files until 2026-09-13, which
  # every boot spent (see `OpenResults.Backup.prune/1`). 0 used to delete every
  # backup - the one just written included - on every run, and a negative
  # count deleted the NEWEST ones; `prune/1` keeps at least a day's worth and
  # always the newest regardless, and this says so at boot instead of quietly
  # doing something else.
  case Integer.parse(keep) do
    {days, ""} when days >= 1 ->
      config :openresults, :backup_retention, days

    _ ->
      raise "BACKUP_RETENTION is a number of days, a whole number of at least 1, got: #{inspect(keep)}"
  end
end

# Off-site backups - `OpenResults.Ops.OffsiteBackup`, docs/deployment.md
# "Off-site backups". The same variable names as OpenPairings'. Off unless
# every required one is set; half a configuration refuses to boot rather than
# quietly sending nothing. Not read in test, where an operator's shell must
# not decide what the suite does.
#
#   OFFSITE_BACKUP_RECIPIENTS            age public keys (age1...), comma-separated
#   OFFSITE_BACKUP_S3_ENDPOINT           https://<s3-compatible endpoint>
#   OFFSITE_BACKUP_S3_BUCKET             bucket name (path-style requests)
#   OFFSITE_BACKUP_S3_ACCESS_KEY_ID      a write-only key for that bucket, ideally
#   OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY
#   OFFSITE_BACKUP_S3_REGION             optional, default us-east-1
#   OFFSITE_BACKUP_S3_PREFIX             optional, default openresults
#   OFFSITE_BACKUP_STALE_HOURS           optional, default 36
if config_env() != :test do
  case OpenResults.Ops.OffsiteBackup.from_env() do
    {:ok, offsite} -> config :openresults, :offsite_backup, offsite
    :disabled -> :ok
    {:error, message} -> raise message
  end
end

# How long `OpenResults.Retention` keeps personal data that has served its
# purpose - see docs/privacy-retention.md. DAYS, a whole number of at least one,
# or the app does not start, like BACKUP_RETENTION above: 0 would delete an
# entry queue the moment its tournament ended.
for {variable, key} <- [
      {"OPENRESULTS_REGISTRATION_RETENTION_DAYS", :registration_retention_days},
      {"OPENRESULTS_REPORT_CONTACT_RETENTION_DAYS", :report_contact_retention_days},
      {"OPENRESULTS_BLOCK_ADDRESS_RETENTION_DAYS", :block_address_retention_days}
    ],
    value = System.get_env(variable) do
  case Integer.parse(value) do
    {days, ""} when days >= 1 ->
      config :openresults, key, days

    _ ->
      raise "#{variable} is a number of days, a whole number of at least 1, got: #{inspect(value)}"
  end
end

# Who may put these pages in an iframe - a CSP `frame-ancestors` source list.
# Default `*`: this site has no login and no session, so a framing page gains
# nothing it could not get by fetching the same URL itself, and a club showing
# its own tournament's standings on its front page is the ordinary case.
# Set to a space-separated origin list to restrict it, or `'none'` to switch
# embedding off. See `OpenResultsWeb.Framing`.
config :openresults,
       :public_frame_ancestors,
       System.get_env("PUBLIC_FRAME_ANCESTORS") || "*"

# Public publishing - `docs/public-publishing.md`. Nothing here is required.
# Only the exact value `enabled` switches the feature on: a typo leaves it off,
# which is the safe direction for a switch that opens the server to anybody.
if public_publishing = System.get_env("OPENRESULTS_PUBLIC_PUBLISHING") do
  config :openresults, :public_publishing, public_publishing == "enabled"
end

# The operator's name, the terms link, the contact email and the limits below can also be saved
# in the admin panel, where a saved value wins over these - see
# `OpenResults.ServerSettings`. The panel checks its input with the SAME rules
# as the checks here, and `test/openresults/server_settings_test.exs` holds the
# two together: change a range in one place and change it in the other.
#
# Blank is unset for both texts, as it always was.
if operator_name = System.get_env("OPENRESULTS_OPERATOR_NAME") do
  name = String.trim(operator_name)

  if String.length(name) > 100 or Regex.match?(~r/[\x00-\x1F\x7F]/u, name) do
    raise "OPENRESULTS_OPERATOR_NAME is one line of plain text of at most 100 characters, " <>
            "got: #{inspect(operator_name)}"
  end

  config :openresults, :operator_name, operator_name
end

if terms_url = System.get_env("OPENRESULTS_TERMS_URL") do
  url = String.trim(terms_url)

  valid? =
    url == "" or
      (match?(
         {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "",
         URI.new(url)
       ) and byte_size(url) <= 2000 and not String.match?(url, ~r/\s/))

  unless valid? do
    raise "OPENRESULTS_TERMS_URL is a full https:// address, got: #{inspect(terms_url)}"
  end

  config :openresults, :terms_url, terms_url
end

# The address the public /terms page offers for reaching the operator. The
# panel's rule, `OpenResults.ServerSettings.email_pattern/0`, repeated here
# because this file runs before the application's modules are loaded.
if contact_email = System.get_env("OPENRESULTS_CONTACT_EMAIL") do
  email = String.trim(contact_email)

  valid? =
    email == "" or
      (String.length(email) <= 254 and
         Regex.match?(
           ~r/\A[^\s\x00-\x1F\x7F@<>"'(),;:\x5C\[\]?#&%]+@[^\s\x00-\x1F\x7F@<>"'(),;:\x5C\[\]?#&%]+\.[^\s\x00-\x1F\x7F@<>"'(),;:\x5C\[\]?#&%]+\z/u,
           email
         ))

  unless valid? do
    raise "OPENRESULTS_CONTACT_EMAIL is one email address, got: #{inspect(contact_email)}"
  end

  config :openresults, :contact_email, contact_email
end

# {variable, key, least, most or nil}
for {variable, key, least, most} <- [
      {"OPENRESULTS_REGISTRATIONS_PER_ADDRESS", :registrations_per_address, 0, nil},
      {"OPENRESULTS_REGISTRATIONS_PER_DAY", :registrations_per_day, 0, nil},
      {"OPENRESULTS_INSTALLATION_PUBLISHES_PER_MINUTE", :installation_publishes_per_minute, 1,
       nil},
      {"OPENRESULTS_INSTALLATION_MAX_TOURNAMENTS", :installation_max_tournaments, 0, nil},
      # At most the parser's own limit: a larger cap could never be reached.
      {"OPENRESULTS_INSTALLATION_MAX_SNAPSHOT_BYTES", :installation_max_snapshot_bytes, 1,
       8_000_000}
    ],
    value = System.get_env(variable) do
  # Raises at boot on something that is not a number in range, like
  # BACKUP_RETENTION above: a limit silently read as something else is worse
  # than a loud start.
  case Integer.parse(String.trim(value)) do
    {n, ""} when n >= least and (is_nil(most) or n <= most) ->
      config :openresults, key, n

    _ ->
      range = if most, do: "from #{least} to #{most}", else: "of at least #{least}"
      raise "#{variable} is a whole number #{range}, got: #{inspect(value)}"
  end
end

# The storage bounds - docs/public-publishing.md, "Storage bounds". Checked
# for range as well as for being a number, like BACKUP_RETENTION: a version
# cap of 0 would prune the version the public is reading, and a floor above
# 100 would refuse every installation for ever.
if max_versions = System.get_env("OPENRESULTS_INSTALLATION_MAX_VERSIONS") do
  case Integer.parse(String.trim(max_versions)) do
    {versions, ""} when versions >= 1 ->
      config :openresults, :installation_max_versions, versions

    _ ->
      raise "OPENRESULTS_INSTALLATION_MAX_VERSIONS is how many versions an installation's " <>
              "tournament keeps, a whole number of at least 1, got: #{inspect(max_versions)}"
  end
end

if free_percent = System.get_env("OPENRESULTS_MIN_FREE_DISK_PERCENT") do
  case Integer.parse(String.trim(free_percent)) do
    {percent, ""} when percent in 0..100 ->
      config :openresults, :min_free_disk_percent, percent

    _ ->
      raise "OPENRESULTS_MIN_FREE_DISK_PERCENT is a whole percentage from 0 (off) to 100, " <>
              "got: #{inspect(free_percent)}"
  end
end

# The admin panel - see `OpenResultsWeb.Plugs.AdminAuth` and docs/admin.md.
# All three or the panel does not exist: any one missing and every `/admin`
# path answers 404, the same as a route that was never written. Outside the
# prod block like the ingest token, so a dev box can be pointed at a real
# Access application.
if team_domain = System.get_env("OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN") do
  config :openresults, :admin_access_team_domain, team_domain
end

if access_aud = System.get_env("OPENRESULTS_ADMIN_ACCESS_AUD") do
  config :openresults, :admin_access_aud, access_aud
end

if admin_emails = System.get_env("OPENRESULTS_ADMIN_EMAILS") do
  config :openresults, :admin_emails, admin_emails
end

config :openresults, OpenResultsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :openresults, OpenResultsWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/openresults_web/router\.ex$"E,
        ~r"lib/openresults_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/openresults/openresults.db
      """

  # POOL_SIZE default, raised from 5 to 10 after the 2026-09-12 load test
  # (`docs/load-test-2026-09-12.md`). That test found `pool_size: 5`
  # exhausted between 200 and 400 concurrent readers on a 2 vCPU box -
  # `DBConnection.ConnectionError`, queue waits up to 2.7s - but the actual
  # cause was `Plugs.Revalidate` running a real query on EVERY request,
  # including a bare `304`. That is fixed separately (see
  # `OpenResults.Snapshots.LatestIdCache`): a request that only needs "is my
  # copy current" now costs an ETS lookup, not a connection checkout, so the
  # pool is no longer on the hot path for ordinary read traffic at all.
  #
  # This is not "therefore leave it at 5". What is left on the pool once the
  # hot path is gone is a burst of genuine cache misses (many tournaments'
  # ids all cold at once - a restart, mid-event) plus actual writes
  # (publishes, registrations, backups), and those deserve headroom without
  # over-provisioning a small box: SQLite has exactly one writer regardless
  # of pool size, so a bigger pool buys more concurrent READERS in flight,
  # not more write throughput, and a 2 vCPU box gets little from a pool far
  # past its core count. 10 - double the old default, five times the box's
  # vCPUs - covers a multi-tournament cold-cache burst comfortably while
  # staying a small, cheap number for a read-mostly app that (with the fix
  # above) spends almost none of its request volume on the database at all.
  config :openresults, OpenResults.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The FIDE list's own file, beside the main database unless told otherwise
  # - which puts it inside whatever directory the service may already write
  # to, and outside the backups, which copy the main file only. About 200 MB
  # with the list in it, twice that for the minutes an import has the old
  # and the new side by side. The zip being read goes into a directory
  # beside it (`OpenResults.FideList.work_dir/0`).
  config :openresults, OpenResults.FideList.Repo,
    database:
      System.get_env("FIDE_LIST_DATABASE_PATH") ||
        Path.join(Path.dirname(database_path), "fide_list.db")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :openresults, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Hostnames. PHX_HOST is the canonical one - every link, feed entry, sitemap
  # line and og:url is built from it. During a domain move these matter too,
  # all comma-separated and empty by default, which keeps today's behaviour:
  #
  #   * PHX_ALLOWED_HOSTS - further hosts whose pages may open the hall
  #     display's websocket (`check_origin`). PHX_HOST is always allowed.
  #   * PHX_REDIRECT_HOSTS - old hosts whose GET/HEAD requests are answered with
  #     a 301 to PHX_HOST (`OpenResultsWeb.Plugs.CanonicalHost`). Each is also
  #     an allowed origin, so a hall display left open across the switch keeps
  #     its socket.
  #   * PHX_SHORT_HOST - the short-link host (one name, e.g. pairings.cloud):
  #     `/` and `/t/...` there 301 to the same path on PHX_HOST, everything
  #     else is a 404 (`OpenResultsWeb.Plugs.ShortHost`).
  #
  # Something that does not look like a hostname stops the boot: a typo here
  # would otherwise quietly refuse every websocket from the real site.
  parse_hosts = fn variable ->
    (System.get_env(variable) || "")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn entry ->
      if entry =~ ~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/ do
        entry
      else
        raise "#{variable} has an entry that is not a hostname: #{inspect(entry)}. " <>
                "Use bare names separated by commas, e.g. old.example.org,www.example.org."
      end
    end)
    |> Enum.uniq()
  end

  canonical_host = String.downcase(host)
  allowed_hosts = parse_hosts.("PHX_ALLOWED_HOSTS")
  redirect_hosts = parse_hosts.("PHX_REDIRECT_HOSTS") -- [canonical_host]

  short_host =
    case parse_hosts.("PHX_SHORT_HOST") do
      [] -> nil
      [one] -> one
      _many -> raise "PHX_SHORT_HOST takes exactly one hostname."
    end

  if short_host == canonical_host do
    raise "PHX_SHORT_HOST is the same as PHX_HOST; the short host would redirect to itself."
  end

  config :openresults, :host_policy,
    canonical: canonical_host,
    redirect_hosts: redirect_hosts,
    short_host: short_host

  config :openresults, OpenResultsWeb.Endpoint,
    check_origin: Enum.map(Enum.uniq([host | allowed_hosts ++ redirect_hosts]), &("//" <> &1)),
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :openresults, OpenResultsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :openresults, OpenResultsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
