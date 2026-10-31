defmodule OpenResultsWeb.Admin.SystemHTML do
  @moduledoc """
  The System page's markup. English only, not wrapped in gettext - see
  `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components, only: [at: 1, bytes: 1]

  def show(assigns) do
    ~H"""
    <h1>System</h1>

    <section class="admin-section" id="system-health">
      <h2>Health</h2>
      <p class="quiet">
        The answer <code>/healthz</code>
        gives a monitor. Only the database decides whether that is a 200 or a 503;
        the off-site backup is reported beside it and never takes the site down with it.
      </p>
      <dl class="admin-facts">
        <dt>Status</dt>
        <dd><.state id="health-status" value={@health.status} /></dd>
        <dt>Database</dt>
        <dd><.state id="health-database" value={@health.checks.database} /></dd>
        <dt>Off-site backup</dt>
        <dd><.state id="health-backup" value={@health.checks.backup} /></dd>
        <dt>Version</dt>
        <dd id="health-version">{@health.version}</dd>
      </dl>
      <nav class="admin-actions-bar" aria-label="System tools">
        <a href={~p"/admin/system"} id="system-refresh">Check again</a>
        <a href={~p"/admin/dashboard"} id="system-dashboard-link">Open LiveDashboard</a>
      </nav>
    </section>

    <section class="admin-section" id="system-offsite">
      <h2>Off-site backup</h2>
      <%= if @offsite_enabled? do %>
        <p class="quiet" id="offsite-summary">
          The newest local backup is encrypted to {@offsite.recipients} public key(s) and sent to
          <strong>{@offsite.bucket}</strong>
          on <strong>{@offsite.host}</strong>, under <code>{@offsite.prefix}/</code>. This server
          holds no key that can decrypt what it sends. Stale after {@offsite.stale_hours} hours
          without a successful send.
        </p>
        <nav class="admin-actions-bar" aria-label="Off-site backup">
          <a href={~p"/admin/system/offsite-backup"} id="offsite-send-now">
            Send the newest backup now
          </a>
        </nav>
      <% else %>
        <p class="quiet" id="offsite-disabled">
          Not configured: backups stay on this machine only. The <code>OFFSITE_BACKUP_*</code>
          variables in the deployment guide switch it on.
        </p>
      <% end %>

      <p :if={@runs == []} class="quiet" id="offsite-no-runs">Nothing has been sent yet.</p>
      <div :if={@runs != []} class="scroller">
        <table class="admin-table" id="offsite-runs">
          <caption class="visually-hidden">Off-site backup runs</caption>
          <thead>
            <tr>
              <th scope="col">When</th>
              <th scope="col">Result</th>
              <th scope="col">Object</th>
              <th scope="col" class="num">Size</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @runs} id={"offsite-run-#{run.id}"}>
              <td>{at(run.finished_at)}</td>
              <td>
                <.state value={if run.status == "ok", do: "ok", else: "failing"} />
                <span :if={run.error} class="quiet">{run.error}</span>
              </td>
              <td><code :if={run.object_key}>{run.object_key}</code></td>
              <td class="num">{bytes(run.bytes)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="admin-section" id="system-errors">
      <h2>Errors</h2>
      <p class="quiet">
        Crashes this server has logged, one row per kind, most recently seen first, at most {OpenResults.Ops.ErrorReports.max_rows()}. Kept here, sent nowhere. Messages are cut
        short and stack traces carry no arguments, so no visitor's data ends up on this page;
        the server log has the rest.
      </p>
      <p :if={@errors == []} id="errors-empty" class="quiet">Nothing has crashed.</p>
      <nav :if={@errors != []} class="admin-actions-bar" aria-label="Error reports">
        <a href={~p"/admin/system/errors/clear"} id="errors-forget-all" class="is-danger">
          Forget them all
        </a>
      </nav>
      <article :for={error <- @errors} id={"error-#{error.id}"} class="admin-error">
        <h3>
          {error.kind} <span class="quiet">{times(error.count)}</span>
        </h3>
        <p class="admin-error-message">{error.message}</p>
        <p class="quiet">
          {error.location || "?"} &middot; first {at(error.first_seen_at)}, last {at(
            error.last_seen_at
          )} &middot;
          <a href={~p"/admin/system/errors/#{error.id}/forget"} id={"error-forget-#{error.id}"}>Forget</a>
        </p>
        <details :if={error.stacktrace != ""}>
          <summary>Stack trace</summary>
          <pre class="admin-stack">{error.stacktrace}</pre>
        </details>
      </article>
    </section>
    """
  end

  defp times(1), do: "once"
  defp times(n), do: "#{n} times"

  attr :value, :string, required: true
  attr :id, :string, default: nil

  # A health word as the panel's status pill: the word carries the meaning,
  # the colour only helps a scanning eye.
  defp state(assigns) do
    ~H"""
    <span id={@id} class={["admin-status", "admin-status-#{@value}"]}>{@value}</span>
    """
  end
end
