defmodule OpenResultsWeb.Admin.StatsHTML do
  @moduledoc """
  The stats page's markup. English only, not wrapped in gettext - see
  `OpenResultsWeb.Admin.Layouts`. Charts are `OpenResultsWeb.Admin.Charts`;
  every figure a chart draws is also written out as text.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components, only: [bytes: 1, thousands: 1]
  import OpenResultsWeb.Admin.Charts, only: [chart: 1]

  alias OpenResults.Stats
  alias OpenResults.Stats.Report

  @group_labels %{
    public: "Public pages",
    static: "Static assets",
    api_read: "API reads",
    api_write: "API writes (publish, mint, registration, delete)",
    admin: "Admin"
  }

  # The refusals `docs/public-publishing.md` defines for publishing, always
  # listed, zeros included; any other code counted is added after them.
  @refusal_codes ~w(rate_limited storage_low publishing_paused address_blocked snapshot_too_large
                    not_owner tournament_hidden tournament_limit registration_closed
                    installation_suspended installation_revoked installation_key_required)a

  def show(%{report: nil} = assigns) do
    ~H"""
    <h1>Stats</h1>

    <p class="alarm" id="stats-unavailable">
      The stats collector is not running on this server, so there is nothing to show.
    </p>
    """
  end

  def show(assigns) do
    %{hour: hour, day: day} = assigns.report
    {current, full_hour} = List.pop_at(hour, -1)
    {_t, current} = current
    last_full = full_hour |> List.last() |> elem(1)
    # "Last hour" figures include the minute in progress, so the page shows a
    # request at once; the per-minute charts draw finished minutes only.
    hour_total = Report.total(hour)
    day_total = Report.total(day)

    # `Map.merge`, not `assign`: a controller renders this without the change
    # tracking `assign/2` insists on.
    assigns =
      Map.merge(assigns, %{
        current: current,
        last_full: last_full,
        full_hour: full_hour,
        hourly: Report.hourly(day),
        hour_total: hour_total,
        day_total: day_total,
        groups: Stats.groups(),
        group_labels: @group_labels,
        refusals: refusals(day_total),
        readers: assigns[:readers]
      })

    ~H"""
    <h1>Stats</h1>

    <p class="quiet" id="stats-scope">
      Counted in memory by this server since <strong>{hhmm(@report.since)} UTC</strong>
      on {date(@report.since)}, and reset by every restart; the readers section below is kept in
      the database. No addresses, user agents or query strings are recorded. Figures as of {hhmm(
        @report.now
      )} UTC; this page reloads every {@refresh_seconds} seconds.
    </p>
    <.readers readers={@readers} />
    <section class="admin-section" id="traffic">
      <h2>Traffic</h2>

      <div class="admin-charts">
        <.chart
          id="chart-requests-minute"
          title="Requests per minute, last 60 minutes"
          values={Report.series(@full_hour, &Report.requests(&1, :all))}
          now={"#{thousands(Report.requests(@last_full, :all))} in the last full minute"}
          from="60 min ago"
        />
        <.chart
          id="chart-requests-hour"
          kind={:bars}
          title="Requests per hour, last 24 hours"
          values={Report.series(@hourly, &Report.requests(&1, :all))}
          now={"#{thousands(Report.requests(@day_total, :all))} in 24 hours"}
          from="24 h ago"
        />
        <.chart
          :for={group <- @groups}
          id={"chart-requests-#{group}"}
          title={"#{@group_labels[group]}, per minute"}
          values={Report.series(@full_hour, &Report.requests(&1, group))}
          now={"#{thousands(Report.requests(@last_full, group))} in the last full minute"}
          from="60 min ago"
        />
      </div>

      <h3>By route group</h3>

      <div class="scroller">
        <table class="admin-table" id="stats-groups">
          <caption class="visually-hidden">Requests and response times by route group</caption>

          <thead>
            <tr>
              <th scope="col">Route group</th>

              <th scope="col">This minute so far</th>

              <th scope="col">Last hour</th>

              <th scope="col">Last 24 hours</th>

              <th scope="col">p50 / p95 / p99, last hour</th>

              <th scope="col">p50 / p95 / p99, last 24 hours</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={group <- @groups ++ [:all]} id={"stats-group-#{group}"}>
              <th scope="row">{Map.get(@group_labels, group, "All requests")}</th>

              <td class="num">{thousands(Report.requests(@current, group))}</td>

              <td class="num">{thousands(Report.requests(@hour_total, group))}</td>

              <td class="num">{thousands(Report.requests(@day_total, group))}</td>

              <td class="num">{latency(Report.latency(@hour_total, group))}</td>

              <td class="num">{latency(Report.latency(@day_total, group))}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p class="quiet">
        Response times are read from fixed buckets (0.1, 0.2, 0.5, 1, 2, 5 ms and so on up to 5 s),
        so each is the top of the bucket the percentile falls in: "2 ms" means at most 2 ms.
      </p>

      <h3>Status classes</h3>

      <div class="scroller">
        <table class="admin-table" id="stats-status">
          <caption class="visually-hidden">Responses by status class</caption>

          <thead>
            <tr>
              <th scope="col">Status</th>

              <th scope="col">Last hour</th>

              <th scope="col">Share</th>

              <th scope="col">Last 24 hours</th>

              <th scope="col">Share</th>
            </tr>
          </thead>

          <tbody>
            <tr
              :for={
                {{class, hour_n}, {_class, day_n}} <-
                  Enum.zip(Report.status_classes(@hour_total), Report.status_classes(@day_total))
              }
              id={"stats-status-#{class}"}
            >
              <th scope="row">{class}</th>

              <td class="num">{thousands(hour_n)}</td>

              <td class="num">{pct(Report.percent(hour_n, Report.requests(@hour_total, :all)))}</td>

              <td class="num">{thousands(day_n)}</td>

              <td class="num">{pct(Report.percent(day_n, Report.requests(@day_total, :all)))}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3>Page cache</h3>

      <dl class="admin-facts" id="stats-cache">
        <dt>Hit rate, last hour</dt>

        <dd>{cache_line(Report.cache(@hour_total))}</dd>

        <dt>Hit rate, last 24 hours</dt>

        <dd>{cache_line(Report.cache(@day_total))}</dd>

        <dt>Answered 304 from the ETag</dt>

        <dd>
          {pct(Report.cache(@hour_total).revalidation_share)} of tournament page requests in the last hour, {pct(
            Report.cache(@day_total).revalidation_share
          )} in 24 hours
        </dd>
      </dl>

      <div class="admin-charts">
        <.chart
          id="chart-cache-hit-rate"
          title="Page cache hit rate per minute"
          values={Report.series(@full_hour, &Report.cache(&1).hit_rate)}
          max={100}
          format={&"#{&1}%"}
          now={last_minute(pct(Report.cache(@last_full).hit_rate))}
          from="60 min ago"
        />
        <.chart
          id="chart-latency-p95"
          title="p95 response time per minute, all requests"
          values={Report.series(@full_hour, &ms_value(Report.latency(&1, :all).p95))}
          format={&"#{&1} ms"}
          now={last_minute(ms(Report.latency(@last_full, :all).p95))}
          from="60 min ago"
        />
      </div>

      <h3>Busiest tournaments</h3>

      <p class="quiet">
        Real page loads of a published tournament - a browser navigating to it, including inside
        another site's embed - not the auto-refresh an open page polls with every 20 seconds; see
        "Refreshes" below for that. At most {thousands(Stats.slug_cap())} different tournaments are counted per minute; any more are added to the last row.
      </p>

      <div class="admin-columns">
        <.top_slugs
          id="stats-top-hour"
          caption="Busiest tournaments, last hour"
          bucket={@hour_total}
          statuses={@statuses}
        />
        <.top_slugs
          id="stats-top-day"
          caption="Busiest tournaments, last 24 hours"
          bucket={@day_total}
          statuses={@statuses}
        />
      </div>

      <h3>Refreshes</h3>

      <p class="quiet">
        An open tournament page polls for updates roughly every 20 seconds; these are that
        polling, not visitors - do not read them as traffic. At most {thousands(Stats.slug_cap())} different tournaments are counted per minute; any more are added to the last row.
      </p>

      <dl class="admin-facts" id="stats-live-followers">
        <dt>Live followers, estimated</dt>

        <dd>{live_followers(Report.live_followers(Enum.take(@full_hour, -3)))}</dd>
      </dl>

      <p class="quiet">
        Not a visitor count: one open page polls about 3 times a minute, so this is refreshes in
        the last few minutes divided by 3 - a rough, constantly-adjusting estimate of how many
        tournament pages are open somewhere right now, across every tournament.
      </p>

      <div class="admin-columns">
        <.top_refreshes
          id="stats-refreshes-hour"
          caption="Most-refreshed tournaments, last hour"
          bucket={@hour_total}
          statuses={@statuses}
        />
        <.top_refreshes
          id="stats-refreshes-day"
          caption="Most-refreshed tournaments, last 24 hours"
          bucket={@day_total}
          statuses={@statuses}
        />
      </div>
    </section>

    <section class="admin-section" id="health">
      <h2>Server health</h2>
      <.health system={@report.system} />
      <div class="admin-charts">
        <.chart
          id="chart-cpu"
          title="CPU busy, per minute"
          values={Report.series(@full_hour, &Report.gauge(&1, :cpu))}
          max={100}
          format={&"#{&1}%"}
          now={cpu_now(@report.system)}
          from="60 min ago"
        />
        <.chart
          id="chart-load"
          title="Load average (1 minute), per minute"
          values={Report.series(@full_hour, &Report.gauge(&1, :load))}
          format={&Float.to_string(&1 / 1)}
          now={load_now(@report.system)}
          from="60 min ago"
        />
      </div>
    </section>

    <section class="admin-section" id="publishing">
      <h2>Publishing, last 24 hours</h2>

      <dl class="admin-facts" id="stats-publishing">
        <dt>Publishes with the operator token</dt>

        <dd>{thousands(Report.event(@day_total, {:publish, :operator}))}</dd>

        <dt>Publishes with installation keys</dt>

        <dd>{thousands(Report.event(@day_total, {:publish, :installation}))}</dd>

        <dt>Tournaments minted</dt>

        <dd>{thousands(Report.event(@day_total, :mint))}</dd>

        <dt>Installations registered</dt>

        <dd>{thousands(Report.event(@day_total, :registration))}</dd>
      </dl>

      <div class="admin-charts">
        <.chart
          id="chart-publish-operator"
          kind={:bars}
          title="Operator-token publishes per hour"
          values={Report.series(@hourly, &Report.event(&1, {:publish, :operator}))}
          now={"#{Report.event(List.last(@hourly) |> elem(1), {:publish, :operator})} this hour"}
          from="24 h ago"
        />
        <.chart
          id="chart-publish-installation"
          kind={:bars}
          title="Installation-key publishes per hour"
          values={Report.series(@hourly, &Report.event(&1, {:publish, :installation}))}
          now={"#{Report.event(List.last(@hourly) |> elem(1), {:publish, :installation})} this hour"}
          from="24 h ago"
        />
      </div>

      <h3>Refusals by code</h3>

      <div class="scroller">
        <table class="admin-table" id="stats-refusals">
          <caption class="visually-hidden">API refusals by error code, last 24 hours</caption>

          <thead>
            <tr>
              <th scope="col">Code</th>

              <th scope="col">Last hour</th>

              <th scope="col">Last 24 hours</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={{code, day_n} <- @refusals} id={"stats-refused-#{code}"}>
              <th scope="row"><code>{code}</code></th>

              <td class="num">{thousands(Report.event(@hour_total, {:refused, code}))}</td>

              <td class="num">{thousands(day_n)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="admin-section" id="database">
      <h2>Database</h2>

      <dl class="admin-facts" id="stats-database">
        <dt>Database file</dt>

        <dd>{bytes(@files.database_bytes)} <span class="quiet">{@files.path}</span></dd>

        <dt>Write-ahead log</dt>

        <dd>{if @files.wal_bytes, do: bytes(@files.wal_bytes), else: "none"}</dd>

        <dt>Free disk space</dt>

        <dd id="stats-disk">
          <%= if @disk.status == :unknown do %>
            not measured <span class="quiet">({@disk.error})</span>
          <% else %>
            <strong>{pct(@disk.free_percent)}</strong>
            <span class="quiet">
              ({bytes(@disk.available_bytes)} of {bytes(@disk.total_bytes)} on {@disk.path}; floor {@disk.floor_percent}%)
            </span>
          <% end %>
        </dd>

        <dt>Queries, last hour</dt>

        <dd>
          {thousands(Report.repo(@hour_total).queries)}; query time p95 {ms(
            Report.repo(@hour_total).query.p95
          )}, pool queue p95 {ms(Report.repo(@hour_total).queue.p95)}
        </dd>

        <dt>Queries, last 24 hours</dt>

        <dd>
          {thousands(Report.repo(@day_total).queries)}; query time p95 {ms(
            Report.repo(@day_total).query.p95
          )}, pool queue p95 {ms(Report.repo(@day_total).queue.p95)}
        </dd>
      </dl>

      <div class="admin-charts">
        <.chart
          id="chart-pool-queue"
          title="Pool queue time p95 per minute"
          values={Report.series(@full_hour, &ms_value(Report.repo(&1).queue.p95))}
          format={&"#{&1} ms"}
          now={last_minute(ms(Report.repo(@last_full).queue.p95))}
          from="60 min ago"
        />
      </div>

      <h3>Rows</h3>

      <p :if={@report.db == nil} class="quiet" id="stats-rows-pending">
        Not counted yet: rows are counted once a minute.
      </p>

      <div :if={@report.db} class="scroller">
        <table class="admin-table" id="stats-rows">
          <caption>Rows, counted at {hhmm(@report.db_at)} UTC (once a minute)</caption>

          <thead>
            <tr>
              <th scope="col">Table</th>

              <th scope="col">Rows</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={{label, value} <- row_counts(@report.db)}>
              <th scope="row">{label}</th>

              <td class="num">{value}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :readers, :any, required: true

  defp readers(%{readers: nil} = assigns) do
    ~H"""
    <section class="admin-section" id="readers">
      <h2>Readers</h2>

      <p class="quiet" id="stats-readers-unavailable">
        The daily totals could not be read from the database.
      </p>
    </section>
    """
  end

  defp readers(assigns) do
    [today | _] = assigns.readers.days
    assigns = assign(assigns, today: today)

    ~H"""
    <section class="admin-section" id="readers">
      <h2>Readers</h2>

      <p class="quiet" id="stats-readers-scope">
        Real readers, kept in the database so they survive a restart. A reader is a salted hash of
        address and user agent that changes every day (UTC) and is thrown away with the day; the
        figures below are totals only. A page view is a person loading an HTML page; bots,
        crawlers and link previews, auto-refreshes, static files, the API and this panel are not
        views. A reader who returns after a restart on the same day is counted twice.
      </p>

      <dl class="admin-facts" id="stats-readers-today">
        <dt>Unique readers today so far ({Date.to_iso8601(@today.day)})</dt>

        <dd>{thousands(@today.unique_viewers)}</dd>

        <dt>Real page views today</dt>

        <dd>{thousands(@today.page_views)}</dd>

        <dt>Refreshes today</dt>

        <dd>{thousands(@today.refreshes)}</dd>

        <dt>Bot hits today</dt>

        <dd>{thousands(@today.bot_hits)}</dd>
      </dl>

      <h3>Last 30 days</h3>

      <div class="scroller">
        <table class="admin-table" id="stats-readers-days">
          <caption class="visually-hidden">Readers, views, refreshes and bot hits per day</caption>

          <thead>
            <tr>
              <th scope="col">Day (UTC)</th>

              <th scope="col">Unique readers</th>

              <th scope="col">Real views</th>

              <th scope="col">Refreshes</th>

              <th scope="col">Bot hits</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={row <- @readers.days} id={"stats-readers-day-#{Date.to_iso8601(row.day)}"}>
              <th scope="row">{Date.to_iso8601(row.day)}</th>

              <td class="num">{thousands(row.unique_viewers)}</td>

              <td class="num">{thousands(row.page_views)}</td>

              <td class="num">{thousands(row.refreshes)}</td>

              <td class="num">{thousands(row.bot_hits)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h3>Top tournaments by unique readers</h3>

      <p class="quiet">
        Over several days a tournament's figure is its daily unique readers added up: the same
        person on two days counts twice.
      </p>

      <div class="admin-columns">
        <.top_readers id="stats-readers-top-today" caption="Today" rows={@readers.top.today} />
        <.top_readers id="stats-readers-top-week" caption="Last 7 days" rows={@readers.top.week} />
        <.top_readers id="stats-readers-top-month" caption="Last 30 days" rows={@readers.top.month} />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :rows, :list, required: true

  defp top_readers(assigns) do
    ~H"""
    <div>
      <p :if={@rows == []} class="quiet" id={@id}>{@caption}: none counted.</p>

      <table :if={@rows != []} class="admin-table" id={@id}>
        <caption>{@caption}</caption>

        <thead>
          <tr>
            <th scope="col">Tournament</th>

            <th scope="col">Unique readers</th>

            <th scope="col">Views</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows}>
            <th scope="row"><a href={"/admin/tournaments/#{row.slug}"}>{row.slug}</a></th>

            <td class="num">{thousands(row.unique_viewers)}</td>

            <td class="num">{thousands(row.page_views)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :bucket, :map, required: true
  attr :statuses, :map, required: true

  defp top_slugs(assigns) do
    {top, rest} = Report.top_slugs(assigns.bucket, 10)
    assigns = assign(assigns, top: top, rest: rest)

    ~H"""
    <div>
      <p :if={@top == []} class="quiet" id={@id}>{@caption}: none counted.</p>

      <table :if={@top != []} class="admin-table" id={@id}>
        <caption>{@caption}</caption>

        <thead>
          <tr>
            <th scope="col">Tournament</th>

            <th scope="col">Requests</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={{slug, count} <- @top}>
            <th scope="row">
              <a href={"/admin/tournaments/#{slug}"}>{slug}</a>
              <span
                :if={@statuses[slug] in [:hidden, :pending]}
                class={"admin-status admin-status-#{@statuses[slug]}"}
              >
                {@statuses[slug]}
              </span>
            </th>

            <td class="num">{thousands(count)}</td>
          </tr>

          <tr :if={@rest > 0}>
            <th scope="row">Every other tournament</th>

            <td class="num">{thousands(@rest)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :bucket, :map, required: true
  attr :statuses, :map, required: true

  defp top_refreshes(assigns) do
    {top, rest} = Report.top_refreshes(assigns.bucket, 10)
    assigns = assign(assigns, top: top, rest: rest)

    ~H"""
    <div>
      <p :if={@top == []} class="quiet" id={@id}>{@caption}: none counted.</p>

      <table :if={@top != []} class="admin-table" id={@id}>
        <caption>{@caption}</caption>

        <thead>
          <tr>
            <th scope="col">Tournament</th>

            <th scope="col">Refreshes</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={{slug, count} <- @top}>
            <th scope="row">
              <a href={"/admin/tournaments/#{slug}"}>{slug}</a>
              <span
                :if={@statuses[slug] in [:hidden, :pending]}
                class={"admin-status admin-status-#{@statuses[slug]}"}
              >
                {@statuses[slug]}
              </span>
            </th>

            <td class="num">{thousands(count)}</td>
          </tr>

          <tr :if={@rest > 0}>
            <th scope="row">Every other tournament</th>

            <td class="num">{thousands(@rest)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :system, :map, default: nil

  defp health(%{system: nil} = assigns) do
    ~H"""
    <p class="quiet" id="stats-health">Not sampled yet: the first sample is taken within seconds.</p>
    """
  end

  defp health(assigns) do
    ~H"""
    <dl class="admin-facts" id="stats-health">
      <dt>CPU</dt>

      <dd id="stats-cpu">{cpu_now(@system)}</dd>

      <dt>Load average</dt>

      <dd id="stats-load">
        <%= case @system.load do %>
          <% {one, five, fifteen} -> %>
            {one} (1 min), {five} (5 min), {fifteen} (15 min)
          <% nil -> %>
            not measured <span class="quiet">(no /proc/loadavg on this system)</span>
        <% end %>
      </dd>

      <dt>System memory</dt>

      <dd id="stats-memory">
        <%= case @system.memory do %>
          <% %{total_bytes: total, available_bytes: available} -> %>
            {bytes(available)} available of {bytes(total)}
            <span class="quiet">({pct(Report.percent(available, total))} available)</span>
          <% nil -> %>
            not measured <span class="quiet">(no /proc/meminfo on this system)</span>
        <% end %>
      </dd>

      <dt>BEAM memory</dt>

      <dd id="stats-beam-memory">
        {bytes(@system.beam.memory.total)} total: {bytes(@system.beam.memory.processes)} processes, {bytes(
          @system.beam.memory.ets
        )} ETS, {bytes(@system.beam.memory.binary)} binaries
      </dd>

      <dt>Schedulers</dt>

      <dd id="stats-schedulers">
        {@system.beam.schedulers_online} online of {@system.beam.schedulers}, on {cpus(@system.beam)}
      </dd>

      <dt>Run queue</dt>

      <dd id="stats-run-queue">
        {@system.beam.run_queue} waiting
        <span class="quiet">(per scheduler: {Enum.join(@system.beam.run_queues, ", ")})</span>
      </dd>

      <dt>Processes</dt>

      <dd>{thousands(@system.beam.process_count)}</dd>

      <dt>Open HTTP connections</dt>

      <dd id="stats-connections">
        <%= case @system.connections do %>
          <% {:ok, n} -> %>
            {thousands(n)}
          <% _ -> %>
            not measured <span class="quiet">(the endpoint is not serving in this environment)</span>
        <% end %>
      </dd>

      <dt>Up for</dt>

      <dd>{duration(@system.beam.uptime_ms)}</dd>

      <dt>Version</dt>

      <dd id="stats-version">
        {OpenResults.Build.long()}; Elixir {System.version()}, Erlang/OTP {System.otp_release()} (erts {:erlang.system_info(
          :version
        )})
      </dd>
    </dl>
    """
  end

  ## ---------- formatting ----------

  defp refusals(day_total) do
    counted = Map.new(Report.refusals(day_total))
    extra = counted |> Map.drop(@refusal_codes) |> Enum.sort()
    Enum.map(@refusal_codes, &{&1, Map.get(counted, &1, 0)}) ++ extra
  end

  defp row_counts(db) do
    statuses = fn pairs -> Enum.map_join(pairs, ", ", fn {s, n} -> "#{thousands(n)} #{s}" end) end

    [
      {"Tournaments", statuses.(db.tournaments)},
      {"Snapshot versions", thousands(db.snapshots)},
      {"Installations", statuses.(db.installations)},
      {"Registrations (entry forms)", thousands(db.registrations)},
      {"Reports", statuses.(db.reports)}
    ]
  end

  defp cache_line(%{hit_rate: nil}), do: "no cacheable page requests"

  defp cache_line(cache) do
    "#{pct(cache.hit_rate)} (#{count(cache.hits, "hit", "hits")}, #{count(cache.misses, "miss", "misses")})"
  end

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{thousands(n)} #{many}"

  defp last_minute("-"), do: "nothing in the last full minute"
  defp last_minute(value), do: value <> " in the last full minute"

  defp latency(%{count: 0}), do: "-"
  defp latency(l), do: "#{ms(l.p50)} / #{ms(l.p95)} / #{ms(l.p99)}"

  @doc false
  # A percentile's bucket edge as text.
  def ms(nil), do: "-"
  def ms(:overflow), do: "over 5 s"
  def ms(us) when us >= 1_000_000, do: "#{div(us, 1_000_000)} s"
  def ms(us) when us >= 1_000, do: "#{div(us, 1_000)} ms"
  def ms(us), do: "#{us / 1_000} ms"

  # A percentile's bucket edge in milliseconds, for a chart.
  defp ms_value(nil), do: nil
  defp ms_value(:overflow), do: 5_000
  defp ms_value(us), do: us / 1_000

  defp pct(nil), do: "-"
  defp pct(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  defp live_followers(nil), do: "not enough data yet"
  defp live_followers(n), do: "≈ #{round(n)}"

  defp cpu_now(%{cpu_percent: cpu}) when is_number(cpu), do: pct(cpu) <> " busy, last 5 seconds"
  defp cpu_now(%{load: nil}), do: "not measured (no /proc/stat on this system)"
  defp cpu_now(_first_sample), do: "measuring"

  defp load_now(%{load: {one, _five, _fifteen}}), do: "#{one} now"
  defp load_now(_), do: "not measured"

  defp cpus(%{logical_processors: nil}), do: "an unknown number of logical CPUs"

  defp cpus(%{logical_processors: n, logical_processors_available: available}) do
    if available && available != n,
      do: "#{n} logical CPUs, #{available} available to this process",
      else: "#{n} logical CPUs"
  end

  defp hhmm(nil), do: "-"
  defp hhmm(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp duration(ms) do
    minutes = div(ms, 60_000)
    days = div(minutes, 1_440)
    hours = div(rem(minutes, 1_440), 60)

    cond do
      days > 0 -> "#{days} d #{hours} h"
      hours > 0 -> "#{hours} h #{rem(minutes, 60)} min"
      true -> "#{minutes} min"
    end
  end
end
