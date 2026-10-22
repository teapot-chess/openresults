defmodule OpenResultsWeb.Admin.Components do
  @moduledoc """
  The pieces every admin page shares: how a time, a size and a status are
  written, the pager, the table of logged actions, and the admin's own
  not-found page.

  English only, not wrapped in gettext - see `OpenResultsWeb.Admin.Layouts`.
  Times are UTC and say so: the two people using this panel may be in
  different places, and the action log is compared against server logs.
  """
  use OpenResultsWeb, :html

  alias OpenResults.Moderation.Action

  @per_page 50

  # ---------------------------------------------------------------------------
  # Text

  @doc "`2026-09-12 14:03 UTC`, or `fallback` for no time at all."
  def at(datetime, fallback \\ "never")
  def at(%DateTime{} = dt, _fallback), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  def at(nil, fallback), do: fallback

  @doc "A byte count people can read: `1.4 MiB`. Binary units, as the contract's cap is written."
  def bytes(nil), do: "-"
  def bytes(n) when is_integer(n) and n < 1024, do: "#{n} B"

  def bytes(n) when is_integer(n) do
    {value, unit} =
      Enum.reduce_while([{"KiB", 1}, {"MiB", 2}, {"GiB", 3}, {"TiB", 4}], nil, fn {unit, power},
                                                                                  _acc ->
        value = n / Integer.pow(1024, power)
        if value < 1024 or unit == "TiB", do: {:halt, {value, unit}}, else: {:cont, nil}
      end)

    "#{:erlang.float_to_binary(value, decimals: 1)} #{unit}"
  end

  @doc "`1,496,391` - the exact figure beside a rounded one."
  def thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "The first line or so of a longer text, for a table cell."
  def excerpt(nil), do: ""

  def excerpt(text) when is_binary(text) do
    if String.length(text) > 120, do: String.slice(text, 0, 117) <> "...", else: text
  end

  @doc "`OpenPairings 0.61.0`, from what an installation said about itself."
  def client_label(%{client: client, client_version: version}) do
    case [client, version] |> Enum.reject(&is_nil/1) |> Enum.join(" ") do
      "" -> "unknown client"
      text -> text
    end
  end

  @doc "What a report's stored reason means."
  def reason_label("wrong_or_fake_results"), do: "Wrong or fake results"
  def reason_label("personal_data"), do: "Personal data"
  def reason_label("spam_or_offensive"), do: "Spam or offensive"
  def reason_label("other"), do: "Other"
  def reason_label(other), do: other

  # ---------------------------------------------------------------------------
  # Status

  attr :value, :string, required: true

  def status(assigns) do
    ~H"""
    <span class={["admin-status", "admin-status-#{@value}"]}>{status_label(@value)}</span>
    """
  end

  # `pending`/`listed` are the stored words, and they are MODERATION's: since
  # 2026-09-13 they decide one thing only - whether the tournament is on the
  # cross-tournament player pages. "listed" read as "on the front page", which
  # is a different switch (the arbiter's, see `front_page/1`), so the panel
  # says what each one actually does.
  defp status_label("pending"), do: "pending: not on player pages yet"
  defp status_label("listed"), do: "listed: on player pages"
  defp status_label(value), do: value

  @doc """
  Whether a tournament appears on the public front page, as a short label.

  That is the ARBITER's choice ("show on the results site's front page" in
  OpenPairings, the snapshot's `tournament.listed`), not moderation's status:
  an event its arbiter unlisted is public by link and on player pages, but
  not advertised on the front page. A hidden tournament is on no page at all.
  """
  attr :tournament, :map, required: true

  def front_page(assigns) do
    ~H"""
    <span class="admin-front-page">{front_page_label(@tournament)}</span>
    """
  end

  defp front_page_label(%{status: "hidden"}), do: "no: hidden"
  defp front_page_label(%{name: nil}), do: "nothing published yet"
  defp front_page_label(%{front_page: 0}), do: "no: unlisted by the arbiter"
  defp front_page_label(_), do: "yes"

  # ---------------------------------------------------------------------------
  # Paging

  @doc "How many rows a list page shows."
  def per_page, do: @per_page

  @doc """
  The page a request asks for (1 when it asks for nothing sensible), and the
  `limit`/`offset` that fetch it plus one row - the extra row is how the
  page knows there is a next one without counting the table.
  """
  def page_window(params) do
    page =
      with text when is_binary(text) <- params["page"],
           {n, ""} when n >= 1 and n <= 100_000 <- Integer.parse(text) do
        n
      else
        # Absent, not a number, out of range - or `page[x]=1`, which arrives
        # as a map.
        _ -> 1
      end

    {page, %{limit: @per_page + 1, offset: (page - 1) * @per_page}}
  end

  @doc "The rows to show and whether another page follows."
  def page_rows(rows), do: {Enum.take(rows, @per_page), length(rows) > @per_page}

  attr :path, :string, required: true
  attr :params, :map, default: %{}, doc: "the filters to carry to the other pages"
  attr :page, :integer, required: true
  attr :more?, :boolean, required: true

  def pager(assigns) do
    ~H"""
    <nav :if={@page > 1 or @more?} class="admin-pager" aria-label="Pages">
      <a :if={@page > 1} href={page_href(@path, @params, @page - 1)} rel="prev">Newer</a>
      <span>Page {@page}</span>
      <a :if={@more?} href={page_href(@path, @params, @page + 1)} rel="next">Older</a>
    </nav>
    """
  end

  defp page_href(path, params, page) do
    query =
      params
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()
      |> Map.put("page", page)
      |> URI.encode_query()

    path <> "?" <> query
  end

  # ---------------------------------------------------------------------------
  # Reports

  attr :reports, :list, required: true
  attr :show_tournament, :boolean, default: true
  attr :id, :string, default: "reports"
  attr :caption, :string, default: "Reports", doc: "what a screen reader hears the table called"

  def reports_table(assigns) do
    ~H"""
    <p :if={@reports == []} class="quiet">No reports.</p>
    <div :if={@reports != []} class="scroller">
      <table class="admin-table" id={@id}>
        <caption class="visually-hidden">{@caption}</caption>
        <thead>
          <tr>
            <th scope="col">Received</th>
            <th scope="col">Reference</th>
            <th :if={@show_tournament} scope="col">Tournament</th>
            <th scope="col">Reason</th>
            <th scope="col">Details</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={report <- @reports}>
            <td><a href={~p"/admin/reports/#{report.id}"}>{at(report.inserted_at)}</a></td>
            <td>{OpenResults.Reports.format_reference(report.reference)}</td>
            <td :if={@show_tournament}>
              <a href={~p"/admin/tournaments/#{report.tournament_slug}"}>{report.tournament_slug}</a>
            </td>
            <td>{reason_label(report.reason)}</td>
            <td class="admin-excerpt">{excerpt(report.details)}</td>
            <td><.status value={report.status} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # The action log

  attr :actions, :list, required: true
  attr :id, :string, default: "admin-actions"
  attr :caption, :string, default: "Actions", doc: "what a screen reader hears the table called"

  def actions_table(assigns) do
    ~H"""
    <p :if={@actions == []} class="quiet">Nothing logged.</p>
    <div :if={@actions != []} class="scroller">
      <table id={@id} class="admin-table">
        <caption class="visually-hidden">{@caption}</caption>
        <thead>
          <tr>
            <th scope="col">When</th>
            <th scope="col">Who</th>
            <th scope="col">Action</th>
            <th scope="col">Target</th>
            <th scope="col">Details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={action <- @actions}>
            <td>{at(action.inserted_at)}</td>
            <td>{action.actor}</td>
            <td>{action.action}</td>
            <td><.target action={action} /></td>
            <td class="admin-details">{details(action.details)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :action, Action, required: true

  defp target(assigns) do
    ~H"""
    <%= case target_path(@action) do %>
      <% nil -> %>
        {target_text(@action)}
      <% path -> %>
        <a href={path}>{target_text(@action)}</a>
    <% end %>
    """
  end

  defp target_text(%Action{target_type: nil, target: nil}), do: "-"
  defp target_text(%Action{target_type: type, target: target}), do: "#{type} #{target}"

  defp target_path(%Action{target_type: "tournament", target: slug}) when is_binary(slug),
    do: ~p"/admin/tournaments/#{slug}"

  defp target_path(%Action{target_type: "installation", target: id}) when is_binary(id),
    do: ~p"/admin/installations/#{id}"

  defp target_path(%Action{target_type: "report", target: id}) when is_binary(id),
    do: ~p"/admin/reports/#{id}"

  defp target_path(_action), do: nil

  @doc "An action's details map as one line: `from: [\"pending\"], to: \"listed\"`."
  def details(details) when details == %{} or is_nil(details), do: ""

  def details(%{} = details) do
    details
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{value(value)}" end)
  end

  defp value(value) when is_binary(value), do: value
  defp value(value), do: Jason.encode!(value)

  # ---------------------------------------------------------------------------
  # Not found, inside the panel

  @doc """
  The panel's own 404, for a slug, id or switch that does not exist. Only an
  admin who passed the gate ever sees it, so unlike the gate's 404 it can say
  what was not found.
  """
  def render_not_found(conn, message) do
    conn
    |> Plug.Conn.put_status(:not_found)
    |> Phoenix.Controller.put_view(html: __MODULE__)
    |> Phoenix.Controller.render(:not_found, page_title: "Not found", message: message)
  end

  def not_found(assigns) do
    ~H"""
    <section id="admin-not-found">
      <h1>Not found</h1>
      <p>{@message}</p>
    </section>
    """
  end
end
