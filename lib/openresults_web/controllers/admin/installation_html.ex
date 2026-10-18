defmodule OpenResultsWeb.Admin.InstallationHTML do
  @moduledoc """
  Installation pages of the admin panel. English only, not wrapped in
  gettext - see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components
  import OpenResultsWeb.Admin.ConfirmationHTML, only: [confirmation: 1]

  # Addresses are nulled this long after their own timestamp - see
  # `OpenResults.Retention` and the contract's "Retention" section.
  @retained_days 30

  def index(assigns) do
    ~H"""
    <h1>Installations</h1>

    <form
      method="get"
      action={~p"/admin/installations"}
      class="admin-filters"
      id="installation-filters"
    >
      <label>
        Status
        <select name="status">
          <option value="">Any</option>
          <option
            :for={status <- ~w(active suspended revoked)}
            value={status}
            selected={@filters["status"] == status}
          >
            {status}
          </option>
        </select>
      </label>
      <label>
        Search
        <input
          type="search"
          name="search"
          value={@filters["search"]}
          placeholder="id, name, client, version or address"
        />
      </label>
      <button type="submit">Filter</button>
    </form>

    <p :if={@installations == []} class="empty" id="installations-empty">No installation matches.</p>

    <div :if={@installations != []} class="scroller">
      <table class="admin-table" id="installations">
        <caption class="visually-hidden">Installations</caption>
        <thead>
          <tr>
            <th scope="col">Installation</th>
            <th scope="col">Client</th>
            <th scope="col">Status</th>
            <th scope="col">Registered</th>
            <th scope="col">Last seen</th>
            <th class="num" scope="col">Pending and listed</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={installation <- @installations}>
            <td>
              <span :if={installation.label} class="installation-label">{installation.label}</span>
              <a href={~p"/admin/installations/#{installation.id}"}>{installation.id}</a>
            </td>
            <td>{client_label(installation)}</td>
            <td><.status value={installation.status} /></td>
            <td>{at(installation.inserted_at)}</td>
            <td>{at(installation.last_seen_at)}</td>
            <td class="num">{installation.tournament_count}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <.pager path={~p"/admin/installations"} params={@filters} page={@page} more?={@more?} />
    """
  end

  def show(assigns) do
    ~H"""
    <p class="admin-crumbs"><a href={~p"/admin/installations"}>Installations</a></p>
    <h1>{@installation.label || @installation.id}</h1>
    <p class="details">
      <span :if={@installation.label} id="installation-id">{@installation.id}</span>
      <span>{client_label(@installation)}</span>
      <span><.status value={@installation.status} /></span>
    </p>

    <nav class="admin-actions-bar" id="installation-actions" aria-label="Actions">
      <a
        :if={@installation.status == "active"}
        href={~p"/admin/installations/#{@installation.id}/suspend"}
      >
        Suspend
      </a>
      <a
        :if={@installation.status == "suspended"}
        href={~p"/admin/installations/#{@installation.id}/unsuspend"}
      >
        Unsuspend
      </a>
      <a
        :if={@installation.status != "revoked"}
        href={~p"/admin/installations/#{@installation.id}/revoke"}
        class="is-danger"
      >
        Revoke
      </a>
      <span :if={@installation.status == "revoked"} class="quiet">Revoked, which is final.</span>
      <a
        :if={@tournaments != []}
        href={~p"/admin/installations/#{@installation.id}/move-tournaments"}
        id="move-tournaments"
      >
        Move all tournaments to another installation…
      </a>
      <a
        :if={not @installation.trusted and @installation.status != "revoked"}
        href={~p"/admin/installations/#{@installation.id}/trust"}
        id="trust-installation"
      >
        Trust
      </a>
      <a
        :if={@installation.trusted}
        href={~p"/admin/installations/#{@installation.id}/untrust"}
        id="untrust-installation"
      >
        Stop trusting
      </a>
      <a href={~p"/admin/installations/#{@installation.id}/label"} id="installation-label-link">
        {if @installation.label, do: "Rename…", else: "Name it…"}
      </a>
      <a href={~p"/admin/installations/#{@installation.id}/limits"} id="installation-limits-link">
        Own limits…
      </a>
    </nav>

    <dl class="admin-facts" id="installation-facts">
      <dt>Client</dt>
      <dd>{@installation.client || "not given"}</dd>

      <dt>Version</dt>
      <dd>{@installation.client_version || "not given"}</dd>

      <dt>Registered</dt>
      <dd>{at(@installation.inserted_at)}</dd>

      <dt>Registered from</dt>
      <dd id="installation-created-from">
        {address(@installation.created_from, @installation.inserted_at)}
      </dd>

      <dt>Last seen</dt>
      <dd>{at(@installation.last_seen_at)}</dd>

      <dt>Last seen from</dt>
      <dd id="installation-last-seen-from">
        {address(@installation.last_seen_from, @installation.last_seen_at)}
      </dd>

      <dt>Trusted</dt>
      <dd id="installation-trusted">
        <%= if @installation.trusted do %>
          <strong>Yes</strong>
          <span class="quiet">- its new tournaments start listed, on player pages at once.</span>
        <% else %>
          No <span class="quiet">- its new tournaments start pending.</span>
        <% end %>
      </dd>

      <dt>Limits</dt>
      <dd id="installation-limit-values">
        <.limits_list limits={@limits} />
      </dd>

      <dt>Storage</dt>
      <dd id="installation-storage">
        <strong>{bytes(@storage.snapshot_bytes)}</strong>
        <span class="quiet">
          ({thousands(@storage.snapshot_bytes)} bytes) in {@storage.snapshots}
          {if @storage.snapshots == 1, do: "version", else: "versions"} of {@storage.tournaments}
          {if @storage.tournaments == 1, do: "tournament", else: "tournaments"}
        </span>
      </dd>
    </dl>

    <section class="admin-section" id="installation-tournaments">
      <h2>Its tournaments</h2>
      <p :if={@tournaments == []} class="quiet">None.</p>
      <div :if={@tournaments != []} class="scroller">
        <table class="admin-table" id="installation-tournaments-table">
          <caption class="visually-hidden">Its tournaments</caption>
          <thead>
            <tr>
              <th scope="col">Tournament</th>
              <th scope="col">Status</th>
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
              <td>{at(tournament.last_published_at, "not yet")}</td>
              <td class="num">{tournament.open_reports}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="admin-section">
      <h2>What has been done to it</h2>
      <.actions_table actions={@actions} id="installation-actions-table" />
    </section>
    """
  end

  def revoke(assigns) do
    ~H"""
    <.confirmation
      title={"Revoke #{@installation.id} for good?"}
      action={~p"/admin/installations/#{@installation.id}/revoke"}
      button="Revoke installation"
      cancel={~p"/admin/installations/#{@installation.id}"}
      error={@error}
    >
      <p class="admin-consequence">
        {@installation.id} ({client_label(@installation)}) is {@installation.status}.
      </p>
      <p class="admin-consequence">
        Its key is refused on every route except deleting its own tournaments, permanently: a
        revoked installation cannot be unsuspended.
      </p>
      <p class="admin-consequence">
        OpenPairings stops sending and offers the arbiter a deliberate "Register again", which
        gives that machine a new, separate installation. Its tournaments stay with this one.
      </p>
      <p :if={@installation.trusted} class="admin-consequence" id="revoke-ends-trust">
        It is trusted, and revoking ends that too.
      </p>

      <fieldset class={["field", "admin-choice", @error && "field-wrong"]} id="revoke-choice">
        <legend>
          Its {@active_tournaments} pending and listed {if @active_tournaments == 1,
            do: "tournament",
            else: "tournaments"}
        </legend>
        <label class="admin-choice-option">
          <input type="radio" name="hide_tournaments" value="true" checked={@choice == "true"} />
          <span>
            <strong>Hide them now.</strong>
            Every public page for them answers "not found" until they are unhidden.
          </span>
        </label>
        <label class="admin-choice-option">
          <input type="radio" name="hide_tournaments" value="false" checked={@choice == "false"} />
          <span>
            <strong>Leave them as they are.</strong>
            They stay up, this installation can no longer update them, and it can still delete them.
          </span>
        </label>
      </fieldset>
    </.confirmation>
    """
  end

  def move(assigns) do
    ~H"""
    <p class="admin-crumbs">
      <a href={~p"/admin/installations/#{@installation.id}"}>{@installation.id}</a>
    </p>
    <h1>Move all of {@installation.id}'s tournaments</h1>

    <p>
      For a laptop that came back as a new installation - after a restore from backup, which
      never carries the installation key. Every tournament below moves to the installation you
      name; the next page shows which laptop that is before anything moves.
    </p>

    <.tournaments_moving tournaments={@tournaments} />

    <form
      method="get"
      action={~p"/admin/installations/#{@installation.id}/move-tournaments"}
      class="admin-form"
      id="move-form"
    >
      <p :if={@error} class="alarm" role="alert" id="move-error">{@error}</p>
      <div class={["field", @error && "field-wrong"]}>
        <label for="move-to">Installation to move them to</label>
        <input
          type="text"
          id="move-to"
          name="to"
          value={@to}
          placeholder="in_..."
          autocomplete="off"
          spellcheck="false"
        />
        <p class="hint">As it appears on that installation's page in this panel.</p>
      </div>
      <div class="actions">
        <button type="submit" id="move-check">Check that installation</button>
        <a href={~p"/admin/installations/#{@installation.id}"} class="cancel">Cancel</a>
      </div>
    </form>
    """
  end

  def move_confirm(assigns) do
    ~H"""
    <.confirmation
      title={"Move #{length(@tournaments)} #{if length(@tournaments) == 1, do: "tournament", else: "tournaments"} from #{@installation.id} to #{@target.id}?"}
      action={~p"/admin/installations/#{@installation.id}/move-tournaments"}
      button={"Move #{length(@tournaments)} #{if length(@tournaments) == 1, do: "tournament", else: "tournaments"}"}
      cancel={~p"/admin/installations/#{@installation.id}"}
      hidden={%{"to" => @target.id}}
    >
      <h2>Moving to</h2>
      <dl class="admin-facts" id="move-target">
        <dt>Installation</dt>
        <dd>{@target.id} <.status value={@target.status} /></dd>

        <dt>Client</dt>
        <dd>{@target.client || "not given"}</dd>

        <dt>Version</dt>
        <dd>{@target.client_version || "not given"}</dd>

        <dt>Registered</dt>
        <dd>{at(@target.inserted_at)}</dd>

        <dt>Last seen</dt>
        <dd>
          {at(@target.last_seen_at)}
          <span :if={@target.last_seen_from} class="quiet">from {@target.last_seen_from}</span>
        </dd>
      </dl>

      <h2>
        {length(@tournaments)} {if length(@tournaments) == 1, do: "tournament", else: "tournaments"} moving
      </h2>
      <.tournaments_moving tournaments={@tournaments} />

      <p class="admin-consequence">
        Each is rebound to {@target.id} and its stored tournament key is cleared, so {@target.id}'s next publish of each, with its own key, claims it. {@installation.id} can no
        longer publish to any of them. Their statuses do not change.
      </p>
      <p class="admin-consequence">
        All of them move or none do, and each move is written to the action log.
      </p>
    </.confirmation>
    """
  end

  def trust(assigns) do
    ~H"""
    <.confirmation
      title={"Trust #{@installation.id}?"}
      action={~p"/admin/installations/#{@installation.id}/trust"}
      button="Trust installation"
      cancel={~p"/admin/installations/#{@installation.id}"}
      danger={false}
    >
      <p class="admin-consequence">
        {@installation.id} ({client_label(@installation)}) is {@installation.status}.
      </p>
      <p class="admin-consequence">
        Tournaments it creates from now on start listed instead of pending: their results appear on
        players' cross-tournament history pages straight away, with no approval. Trust a machine
        you know - a federation's or a club's laptop - not a stranger's.
      </p>
      <p class="admin-consequence">
        Its limits stay as they are, and a suspended installation still cannot publish. Revoking
        it ends the trust.
      </p>

      <fieldset :if={@pending != []} class="field admin-choice" id="trust-pending">
        <legend>
          It has {length(@pending)} pending {if length(@pending) == 1,
            do: "tournament",
            else: "tournaments"}
        </legend>
        <label class="admin-choice-option">
          <input type="checkbox" name="list_pending" value="true" id="trust-list-pending" />
          <span>
            <strong>Show them on player pages too</strong>
            (list them now). Unticked, they stay pending until you approve each one.
          </span>
        </label>
        <ul class="admin-moving">
          <li :for={tournament <- @pending}>
            <code>{tournament.slug}</code>
          </li>
        </ul>
      </fieldset>
    </.confirmation>
    """
  end

  def label(assigns) do
    ~H"""
    <p class="admin-crumbs">
      <a href={~p"/admin/installations/#{@installation.id}"}>{@installation.id}</a>
    </p>
    <h1>A name for {@installation.id}</h1>

    <p>
      Only you see it, here in this panel. It is never shown on a public page and never sent to
      the installation. Empty removes it.
    </p>

    <.form
      for={%{}}
      method="post"
      action={~p"/admin/installations/#{@installation.id}/label"}
      class="admin-form"
      id="label-form"
    >
      <input type="hidden" name="confirm" value={~p"/admin/installations/#{@installation.id}/label"} />
      <p :if={@error} class="alarm" role="alert" id="label-error">{@error}</p>
      <div class={["field", @error && "field-wrong"]}>
        <label for="installation-label">Name</label>
        <input
          type="text"
          id="installation-label"
          name="label"
          value={@value}
          placeholder="Club X laptop"
        />
      </div>
      <div class="actions">
        <button type="submit" id="label-save">Save</button>
        <a href={~p"/admin/installations/#{@installation.id}"} class="cancel">Cancel</a>
      </div>
    </.form>
    """
  end

  def limits(assigns) do
    ~H"""
    <p class="admin-crumbs">
      <a href={~p"/admin/installations/#{@installation.id}"}>{@installation.id}</a>
    </p>
    <h1>{@installation.id}'s own limits</h1>

    <p>
      Empty means the server's value, from Settings. A value here applies to this installation
      alone, in the same range as the server's.
    </p>

    <form
      method="get"
      action={~p"/admin/installations/#{@installation.id}/limits"}
      class="admin-form"
      id="limits-form"
    >
      <input type="hidden" name="check" value="1" />
      <p :if={@errors != %{}} class="alarm" role="alert" id="limits-errors">
        Nothing was changed. Fix what is marked below.
      </p>
      <div
        :for={field <- OpenResults.Installations.Installation.limits()}
        class={["field", @errors[field] && "field-wrong"]}
      >
        <label for={"limit-#{field}"}>{OpenResultsWeb.Admin.InstallationController.limit_label(field)}</label>
        <input
          type="number"
          id={"limit-#{field}"}
          name={"limits[#{field}]"}
          value={@values[Atom.to_string(field)]}
          aria-describedby={"limit-#{field}-hint"}
        />
        <p :if={@errors[field]} class="wrong" id={"limit-#{field}-error"}>{@errors[field]}</p>
        <p class="hint" id={"limit-#{field}-hint"}>
          Server's value: {thousands(server_value(field))}.
        </p>
      </div>
      <div class="actions">
        <button type="submit" id="limits-check">Check</button>
        <a href={~p"/admin/installations/#{@installation.id}"} class="cancel">Cancel</a>
      </div>
    </form>
    """
  end

  def limits_confirm(assigns) do
    ~H"""
    <.confirmation
      title={"Save #{@installation.id}'s limits?"}
      action={~p"/admin/installations/#{@installation.id}/limits"}
      button="Save limits"
      cancel={~p"/admin/installations/#{@installation.id}"}
      hidden={@hidden}
      danger={false}
    >
      <div class="scroller">
        <table class="admin-table" id="limits-change">
          <caption class="visually-hidden">Limits before and after</caption>
          <thead>
            <tr>
              <th scope="col">Limit</th>
              <th scope="col">Now</th>
              <th scope="col">After</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={field <- OpenResults.Installations.Installation.limits()}>
              <th scope="row">{OpenResultsWeb.Admin.InstallationController.limit_label(field)}</th>
              <td><.limit_value limit={@before_limits[field]} /></td>
              <td><.limit_value limit={@after_limits[field]} /></td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="admin-consequence">
        They apply from its next request. Every change is written to the action log.
      </p>
    </.confirmation>
    """
  end

  attr :limits, :map, required: true

  defp limits_list(assigns) do
    ~H"""
    <ul class="admin-limits">
      <li :for={field <- OpenResults.Installations.Installation.limits()}>
        {OpenResultsWeb.Admin.InstallationController.limit_label(field)}:
        <.limit_value limit={@limits[field]} />
      </li>
    </ul>
    """
  end

  attr :limit, :map, required: true

  defp limit_value(assigns) do
    ~H"""
    <strong>{thousands(@limit.value)}</strong>
    <span class="quiet">{if @limit.own == nil, do: "(server's)", else: "(its own)"}</span>
    """
  end

  defp server_value(field),
    do: OpenResults.PublicPublishing.global_for(field) |> OpenResults.ServerSettings.get()

  attr :tournaments, :list, required: true

  defp tournaments_moving(assigns) do
    ~H"""
    <ul class="admin-moving" id="moving-tournaments">
      <li :for={tournament <- @tournaments}>
        <code>{tournament.slug}</code>
        <span>{tournament.name || "(nothing published yet)"}</span>
        <.status value={tournament.status} />
      </li>
    </ul>
    """
  end

  # A null address is one of three things, and the page says which: never
  # recorded (a client whose address the tunnel did not pass on), forgotten by
  # retention, or - for last-seen - never seen at all.
  defp address(address, _since) when is_binary(address), do: address
  defp address(nil, nil), do: "never seen"

  defp address(nil, %DateTime{} = since) do
    if DateTime.diff(DateTime.utc_now(), since, :second) >= @retained_days * 86_400 do
      "forgotten after #{@retained_days} days"
    else
      "not recorded"
    end
  end
end
