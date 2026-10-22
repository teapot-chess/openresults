defmodule OpenResultsWeb.Admin.ReportHTML do
  @moduledoc """
  Report pages of the admin panel. English only, not wrapped in gettext - see
  `OpenResultsWeb.Admin.Layouts`.

  Everything a report carries was typed by a stranger. It is rendered as text
  and nothing else - HEEx escapes it, and the panel's CSP runs no script even
  if something ever slipped through.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  alias OpenResultsWeb.Admin.TournamentController

  def index(assigns) do
    ~H"""
    <h1>Reports</h1>

    <nav class="admin-tabs" aria-label="Queues">
      <a
        href={~p"/admin/reports?#{[status: "open"]}"}
        class={[@status == "open" && "is-current"]}
        aria-current={@status == "open" && "page"}
      >
        Open ({@open_count})
      </a>
      <a
        href={~p"/admin/reports?#{[status: "resolved"]}"}
        class={[@status == "resolved" && "is-current"]}
        aria-current={@status == "resolved" && "page"}
      >
        Resolved
      </a>
    </nav>

    <.reports_table reports={@reports} id="reports" />

    <.pager path={~p"/admin/reports"} params={%{"status" => @status}} page={@page} more?={@more?} />
    """
  end

  def show(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/reports"}>Reports</a></p>
    <h1>Report {@report.id}</h1>
    <p class="details">
      <span>{reason_label(@report.reason)}</span>
      <span><.status value={@report.status} /></span>
    </p>

    <nav class="admin-actions-bar" id="report-actions" aria-label="Actions">
      <a :if={@report.status == "open"} href={~p"/admin/reports/#{@report.id}/resolve"}>
        Resolve
      </a>
      <a
        :if={@tournament && @tournament.status in ["pending", "listed"]}
        href={~p"/admin/tournaments/#{@tournament.slug}/hide"}
      >
        Hide the tournament
      </a>
      <a :if={@tournament} href={~p"/admin/tournaments/#{@tournament.slug}/delete"} class="is-danger">
        Delete the tournament
      </a>
    </nav>

    <dl class="admin-facts" id="report-facts">
      <dt>Tournament</dt>
      <dd id="report-tournament">
        <%= if @tournament do %>
          <a href={~p"/admin/tournaments/#{@tournament.slug}"}>
            {TournamentController.label(@tournament)}
          </a>
          <span class="quiet">{@tournament.slug}, <.status value={@tournament.status} /></span>
          <a
            :if={@tournament.status != "hidden" and not is_nil(@tournament.last_published_at)}
            href={~p"/t/#{@tournament.slug}"}
          >
            public page
          </a>
        <% else %>
          {@report.tournament_slug} <span class="quiet">- deleted since</span>
        <% end %>
      </dd>

      <dt>Reference</dt>
      <dd id="report-reference">
        {OpenResults.Reports.format_reference(@report.reference) || "none (sent before references)"}
      </dd>

      <dt>Received</dt>
      <dd>{at(@report.inserted_at)}</dd>

      <dt>Reason</dt>
      <dd>{reason_label(@report.reason)}</dd>

      <dt>Details</dt>
      <dd class="admin-prose" id="report-details">{@report.details || "none given"}</dd>

      <dt>Contact</dt>
      <dd>
        <a :if={@report.contact_email} href={"mailto:" <> @report.contact_email}>
          {@report.contact_email}
        </a>
        <span :if={is_nil(@report.contact_email)} class="quiet">none given</span>
      </dd>

      <dt>Sent from</dt>
      <dd>{sent_from(@report)}</dd>

      <dt :if={@report.status == "resolved"}>Resolution</dt>
      <dd :if={@report.status == "resolved"} class="admin-prose" id="report-resolution">
        {@report.resolution}
      </dd>

      <dt :if={@report.status == "resolved"}>Resolved</dt>
      <dd :if={@report.status == "resolved"}>
        {at(@report.resolved_at)} by {@report.resolved_by}
      </dd>
    </dl>
    """
  end

  def resolve(assigns) do
    ~H"""
    <.confirmation
      title={"Resolve report #{@report.id}?"}
      action={~p"/admin/reports/#{@report.id}/resolve"}
      button="Resolve report"
      cancel={~p"/admin/reports/#{@report.id}"}
      danger={false}
      error={@error}
    >
      <p class="admin-consequence">
        {reason_label(@report.reason)}, about {@report.tournament_slug}, received {at(
          @report.inserted_at
        )}.
      </p>
      <p class="admin-consequence">
        It leaves the open queue, and the resolution is recorded with your address.
      </p>
      <p class="admin-consequence">
        Resolving changes nothing about the tournament itself: hide or delete it separately.
      </p>

      <div class={["field", @error && "field-wrong"]}>
        <label for="report-resolution-input">Resolution</label>
        <textarea
          id="report-resolution-input"
          name="resolution"
          rows="4"
          maxlength={@max_resolution}
        >{@resolution}</textarea>
        <p class="hint">
          What was done, or why nothing was: "Hid the tournament", "Results confirmed with the arbiter".
        </p>
      </div>
    </.confirmation>
    """
  end

  defp sent_from(%{client_address: address}) when is_binary(address), do: address

  defp sent_from(%{inserted_at: at}) do
    if DateTime.diff(DateTime.utc_now(), at, :second) >= 30 * 86_400,
      do: "forgotten after 30 days",
      else: "not recorded"
  end
end
