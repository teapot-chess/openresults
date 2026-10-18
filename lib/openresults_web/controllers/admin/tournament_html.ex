defmodule OpenResultsWeb.Admin.TournamentHTML do
  @moduledoc """
  Tournament pages of the admin panel. English only, not wrapped in gettext -
  see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  alias OpenResultsWeb.Admin.TournamentController

  def index(assigns) do
    ~H"""
    <h1>Tournaments</h1>

    <form method="get" action={~p"/admin/tournaments"} class="admin-filters" id="tournament-filters">
      <label>
        Status
        <select name="status">
          <option value="">Any</option>

          <option
            :for={status <- ~w(pending listed hidden)}
            value={status}
            selected={@filters["status"] == status}
          >
            {status}
          </option>
        </select>
      </label>

      <label class="admin-check">
        <input type="checkbox" name="reported" value="true" checked={@filters["reported"] == "true"} />
        With open reports
      </label>

      <label>
        Search
        <input type="search" name="search" value={@filters["search"]} placeholder="slug or name" />
      </label>
      <button type="submit">Filter</button>
    </form>

    <p :if={@tournaments == []} class="empty" id="tournaments-empty">No tournament matches.</p>

    <div :if={@tournaments != []} class="scroller">
      <table class="admin-table" id="tournaments">
        <caption class="visually-hidden">Tournaments</caption>

        <thead>
          <tr>
            <th scope="col">Tournament</th>

            <th scope="col">Status</th>

            <th scope="col">Front page</th>

            <th scope="col">Owner</th>

            <th scope="col">Last publish</th>

            <th class="num" scope="col">Open reports</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={tournament <- @tournaments}>
            <td>
              <a href={~p"/admin/tournaments/#{tournament.slug}"}>
                {tournament.name || "(nothing published yet)"}
              </a>
              <span class="quiet">{tournament.slug}</span>
            </td>

            <td><.status value={tournament.status} /></td>

            <td><.front_page tournament={tournament} /></td>

            <td>
              <.owner
                installation_id={tournament.installation_id}
                label={@labels[tournament.installation_id]}
                owner_email={tournament.owner_email}
              />
            </td>

            <td>{at(tournament.last_published_at, "not yet")}</td>

            <td class="num">{tournament.open_reports}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <.pager path={~p"/admin/tournaments"} params={@filters} page={@page} more?={@more?} />
    """
  end

  def show(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/tournaments"}>Tournaments</a></p>

    <h1>{@tournament.name || "(nothing published yet)"}</h1>

    <p class="details">
      <span>{@tournament.slug}</span> <span><.status value={@tournament.status} /></span>
      <span>front page: <.front_page tournament={@tournament} /></span>
    </p>

    <nav class="admin-actions-bar" id="tournament-actions" aria-label="Actions">
      <a
        :if={@tournament.status == "pending"}
        href={~p"/admin/tournaments/#{@tournament.slug}/approve"}
      >
        Show on player pages
      </a>

      <a
        :if={@tournament.status in ["pending", "listed"]}
        href={~p"/admin/tournaments/#{@tournament.slug}/hide"}
      >
        Hide
      </a>

      <a :if={@tournament.status == "hidden"} href={~p"/admin/tournaments/#{@tournament.slug}/unhide"}>
        Unhide
      </a>
      <a href={~p"/admin/tournaments/#{@tournament.slug}/live-delay"}>Live board delay</a>
      <a href={~p"/admin/tournaments/#{@tournament.slug}/relay-keys"}>Relay keys</a>
      <a href={~p"/admin/tournaments/#{@tournament.slug}/transfer"}>Transfer</a>
      <a href={~p"/admin/tournaments/#{@tournament.slug}/delete"} class="is-danger">Delete</a>
    </nav>

    <dl class="admin-facts" id="tournament-facts">
      <dt>Public page</dt>

      <dd>
        <%= cond do %>
          <% @tournament.status == "hidden" -> %>
            <span class="quiet">hidden: it answers "not found" to the public</span>
          <% is_nil(@stats.last_published_at) -> %>
            <span class="quiet">nothing published yet</span>
          <% true -> %>
            <a href={~p"/t/#{@tournament.slug}"}>/t/{@tournament.slug}</a>
        <% end %>
      </dd>

      <dt>Owner</dt>

      <dd>
        <%= if @tournament.installation do %>
          <span :if={@tournament.installation.label} id="owner-label">
            {@tournament.installation.label}
          </span>
          <a href={~p"/admin/installations/#{@tournament.installation.id}"}>
            {@tournament.installation.id}
          </a>

          <span class="quiet">
            {client_label(@tournament.installation)},
            <.status value={@tournament.installation.status} />
          </span>
        <% else %>
          <span class="quiet">nobody: published with the operator token</span>
        <% end %>

        <%= if @tournament.owner_email do %>
          <br />
          <span class="quiet">
            published by {@tournament.owner_email}
            <%= if @tournament.owner_host do %>
              ({@tournament.owner_host})
            <% end %>
          </span>
        <% end %>
      </dd>

      <dt :if={@tournament.minted_at}>Minted</dt>

      <dd :if={@tournament.minted_at}>{at(@tournament.minted_at)}</dd>

      <%!-- Past the version cap, the oldest versions of an installation's
            tournament are pruned, so the first stored one is no longer the
            first publish. --%>
      <dt :if={pruned?(@tournament, @stats)}>Oldest kept version</dt>

      <dt :if={not pruned?(@tournament, @stats)}>First publish</dt>

      <dd>{at(@stats.first_published_at, "not yet")}</dd>

      <dt>Last publish</dt>

      <dd>{at(@stats.last_published_at, "not yet")}</dd>

      <dt>Current snapshot</dt>

      <dd id="tournament-current-bytes">
        {bytes(@stats.current_bytes)}
        <span :if={@stats.current_bytes} class="quiet">({thousands(@stats.current_bytes)} bytes)</span>
      </dd>

      <dt>Stored versions</dt>

      <dd>{@stats.snapshots}, {bytes(@stats.snapshot_bytes)} in all</dd>

      <dt>Entries waiting</dt>

      <dd>{@stats.registrations}</dd>

      <dt>Live board delay</dt>

      <dd id="tournament-live-delay">
        <%= if @live_delay == 0 do %>
          <span class="quiet">none: spectators see the game as it is played</span>
        <% else %>
          {@live_delay} minutes behind the game
        <% end %>
      </dd>
    </dl>

    <section class="admin-section" id="tournament-reports">
      <h2>Reports about it</h2>
      <.reports_table reports={@reports} show_tournament={false} id="tournament-reports-table" />
    </section>

    <section class="admin-section">
      <h2>What has been done to it</h2>
      <.actions_table actions={@actions} id="tournament-actions-table" />
    </section>
    """
  end

  def transfer(assigns) do
    ~H"""
    <.confirmation
      title={"Transfer #{TournamentController.label(@tournament)} to another installation?"}
      action={~p"/admin/tournaments/#{@tournament.slug}/transfer"}
      button="Transfer tournament"
      cancel={~p"/admin/tournaments/#{@tournament.slug}"}
      error={@error}
    >
      <p class="admin-consequence">
        <%= if @tournament.installation_id do %>
          Owned now by {@tournament.installation_id}.
        <% else %>
          Owned now by nobody: it was published with the operator token.
        <% end %>
      </p>

      <p class="admin-consequence">
        It is rebound to the installation you name, and its stored tournament key is cleared,
        so that installation's next publish with its own key claims it.
      </p>

      <p class="admin-consequence">
        The current owner can no longer publish to it. Its status, {@tournament.status}, does not
        change. A revoked installation cannot receive it.
      </p>

      <div class="field">
        <label for="transfer-installation-id">Installation id</label>
        <input
          type="text"
          id="transfer-installation-id"
          name="installation_id"
          value={@installation_id}
          placeholder="in_..."
          autocomplete="off"
          spellcheck="false"
        />
        <p class="hint">As it appears on the installation's page in this panel.</p>
      </div>
    </.confirmation>
    """
  end

  def live_delay(assigns) do
    ~H"""
    <.confirmation
      title={"Delay the live boards of #{TournamentController.label(@tournament)}?"}
      action={~p"/admin/tournaments/#{@tournament.slug}/live-delay"}
      button="Set the delay"
      cancel={~p"/admin/tournaments/#{@tournament.slug}"}
      error={@error}
    >
      <p class="admin-consequence">
        <%= if @current == 0 do %>
          There is no delay now: spectators see each move as the relay reports it.
        <% else %>
          The delay now is {@current} minutes.
        <% end %>
      </p>

      <p class="admin-consequence">
        Spectators see the live boards - moves, clocks and results - this many minutes behind
        the game, on every page and in the PGN download. Organisers may need this under
        anti-cheating rules. The relay's reports are stored as they arrive, so changing the
        delay takes effect at once and in both directions; nothing is rewritten.
      </p>

      <div class="field">
        <label for="live-delay-minutes">Minutes</label>
        <input
          type="text"
          inputmode="numeric"
          id="live-delay-minutes"
          name="minutes"
          value={@minutes || @current}
          autocomplete="off"
        />
        <p class="hint">0 for no delay; at most {OpenResults.LiveBoards.max_delay_minutes()}.</p>
      </div>
    </.confirmation>
    """
  end

  defp pruned?(tournament, stats),
    do:
      not is_nil(tournament.installation_id) and
        stats.snapshots >= OpenResults.PublicPublishing.installation_max_versions()

  attr :installation_id, :string, default: nil
  attr :label, :string, default: nil
  attr :owner_email, :string, default: nil

  # The owner column. `owner_email` only ever accompanies a `nil`
  # `installation_id` - an installation-key publish never carries the
  # `publisher` field (see docs/snapshot-schema.md) - so the two are shown
  # together only in that combination: "operator" alone, an installation id
  # alone, or "operator · email" for a hosted account's own publish.
  defp owner(assigns) do
    ~H"""
    <span :if={@label} class="installation-label">{@label}</span>
    <a :if={@installation_id} href={~p"/admin/installations/#{@installation_id}"}>
      {@installation_id}
    </a>
    <span :if={is_nil(@installation_id) and is_nil(@owner_email)} class="quiet">operator</span>
    <span :if={is_nil(@installation_id) and @owner_email} class="quiet">
      operator · {@owner_email}
    </span>
    """
  end
end
