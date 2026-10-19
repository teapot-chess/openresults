defmodule OpenResultsWeb.Components.FilterBar do
  @moduledoc """
  The one filter/sort bar shared by the standings, round pairings and
  cross-table pages - see `OpenResultsWeb.Tournament.Filter` for what it
  actually filters and sorts, and `OpenResultsWeb.FilterParams` for the
  query string it reads and writes.

  ## Why a plain `<form method="get">` and nothing cleverer

  Every control here is a real `<select>` or `<input>`, inside one form,
  submitted by a visible button. That is not a fallback for JavaScript
  being off - it is the only mechanism this bar has. A GET form is
  shareable and bookmarkable by construction (the browser puts the values
  in the address bar for free), works from a cold load with no script
  having run yet, and needs nothing from this app beyond rendering the
  controls with the request's own values already selected - which is what
  makes a plain `Phoenix.ConnTest` GET with query params a complete test of
  it, no browser required.

  The small inline `<script>` at the bottom of `filter_bar/1` is the ONLY
  optional enhancement on top of this - the same pattern
  `index.html.heex`'s own search box already uses on this site, inline
  rather than a bundled asset, kept in `inline_scripts/filter_bar.js` and
  allowed by its hash (`OpenResultsWeb.InlineScripts`)
  (unlike the admin panel - see `OpenResultsWeb.Plugs.AdminHeaders`, which
  is `script-src 'none'` on purpose and nowhere near this bar). It submits
  the form on a control's `change` event and debounces the search box, so a
  reader with JavaScript rarely has to find the button - but it always does
  a real navigation (`form.requestSubmit()`), never a fetch-and-patch, and
  it re-registers itself on `openresults:updated` exactly like the other
  two, so it keeps working across the 20-second refresher's swap - see the
  root layout's own comment on that event. It also stamps `js-auto` on the
  form the moment it runs, which is the ONLY thing that hides the Apply
  button (`.filter-form.js-auto .filter-submit { display: none }` in
  `app.css`) - with no script the class is never added and the button stays
  the only way to submit.

  ## The chips, the count, and the phone disclosure

  Everything below the toolbar - the removable chips, the "N of M players"
  count, and the `<details>` that folds the middle controls away on a
  narrow screen - is built from the exact same `filters` struct the form
  itself renders from, so a chip's `href` always agrees with what the form
  would have submitted: `chip_href/2` starts from `FilterParams.to_params/1`
  (the same helper every page's own nav links use) and removes one key,
  never hand-builds a query string.

  The `<details>` a phone folds the middle controls into is real, not a
  script-driven show/hide: it opens and closes with no JavaScript at all,
  and CSS is the only thing that ever forces it open on a wide screen (see
  `.filter-disclosure` in `app.css`) - overriding a `<details>` element's own
  closed state for its content is standard, supported behaviour in every
  browser this site targets. It starts OPEN when a filter or a non-default
  sort is already active and CLOSED otherwise: a reader arriving from a
  shared filtered link should see what is applied without an extra tap, and
  a reader arriving at the plain page should see the compact bar first.
  """

  use Phoenix.Component
  use Gettext, backend: OpenResultsWeb.Gettext

  alias OpenResultsWeb.FilterParams

  @doc """
  Renders the bar.

  `action` is the page's own path (the controller renders this same page
  for a GET with query params, so the form submits back to exactly where
  it is). `categories`/`federations`/`clubs` are the option lists this
  TOURNAMENT actually offers - `[]` omits that one control entirely, per
  `Tournament.Filter.categories/1` and `player_values/2`. `sort?` is false
  on the round and cross-table pages, which filter their rows but do not
  reorder them - see `Tournament.Filter`'s own moduledoc on `round_boards/3`
  and `crosstable_rows/3` for why.

  `total`/`shown` and `unit` build the result count ("12 of 86 players") -
  `total` is `nil` on a page that never wants one rendered at all (there is
  currently none, but the attr stays optional rather than required so a
  future caller with nothing sensible to count is not forced to invent a
  number).
  """
  attr :action, :string, required: true
  attr :filters, FilterParams, required: true
  attr :categories, :list, default: []
  attr :federations, :list, default: []
  attr :clubs, :list, default: []
  attr :teams, :list, default: []
  attr :sort?, :boolean, default: true

  # Whether this tournament publishes the rounds-present count, which decides
  # whether the bar offers sorting by it. Offering a sort for a column that is
  # not on the page would reorder the table by a number nobody can see.
  attr :rounds_played?, :boolean, default: false
  attr :empty?, :boolean, default: false
  attr :total, :integer, default: nil
  attr :shown, :integer, default: nil
  attr :unit, :atom, default: :players, values: [:players, :boards, :teams]

  def filter_bar(assigns) do
    assigns =
      assigns
      |> assign(
        :any_control?,
        assigns.categories != [] or assigns.federations != [] or assigns.clubs != [] or
          assigns.teams != []
      )
      |> assign(:chips, chips(assigns.filters, assigns.action, assigns.sort?, assigns.teams))
      |> assign(:count_text, count_text(assigns.total, assigns.shown, assigns.unit))

    assigns =
      assigns
      |> assign(
        :active_count,
        Enum.count(assigns.chips, & &1.in_disclosure?) +
          if(assigns.sort? and assigns.filters.sort != "rank", do: 1, else: 0)
      )
      |> assign(
        :disclosure_open?,
        FilterParams.active?(assigns.filters) or assigns.filters.sort != "rank"
      )
      |> assign(:show_meta?, assigns.chips != [] or assigns.count_text != nil)

    ~H"""
    <%!-- Always rendered, even with nothing to filter by or sort: the
          search box is how a player in the hall finds their own name - on
          a round page, their board - and a tournament that publishes no
          club, federation or category still has names. On a phone the bar
          stays at the top of the screen while the table scrolls under it
          (`.filter-bar` in app.css). --%>
    <div class="filter-bar" id="filter-bar">
      <form
        method="get"
        action={@action}
        class="filter-form"
        data-filter-form
        data-live-count={
          gettext("Rows matching: %{shown} of %{total}", shown: "{shown}", total: "{total}")
        }
      >
        <fieldset class="filter-toolbar">
          <legend class="visually-hidden">{gettext("Filter and sort")}</legend>

          <label class="filter-search">
            <span class="visually-hidden">{gettext("Search player")}</span>
            <svg
              class="filter-search-icon"
              aria-hidden="true"
              viewBox="0 0 20 20"
              xmlns="http://www.w3.org/2000/svg"
            >
              <circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="1.6" />
              <line
                x1="17"
                y1="17"
                x2="12.6"
                y2="12.6"
                stroke="currentColor"
                stroke-width="1.6"
                stroke-linecap="round"
              />
            </svg>
            <input
              type="search"
              name="q"
              id="player-search"
              enterkeyhint="search"
              value={@filters.q}
              placeholder={gettext("Search player")}
              maxlength="100"
              autocomplete="off"
              class="filter-search-input"
            />
          </label>

          <details
            :if={@any_control? or @sort?}
            class="filter-disclosure"
            open
            data-keep-open={to_string(@disclosure_open?)}
          >
            <summary class="filter-summary">
              {gettext("Filters")}
              <span :if={@active_count > 0} class="filter-count-badge">({@active_count})</span>
            </summary>

            <div class="filter-controls">
              <label :if={@categories != []} class={["filter-pill", @filters.category && "is-active"]}>
                <span class="visually-hidden">{gettext("Category")}</span>
                <select name="category">
                  <option value="">{gettext("Category")}</option>
                  <option
                    :for={category <- @categories}
                    value={category}
                    selected={@filters.category == category}
                  >
                    {category}
                  </option>
                </select>
              </label>

              <label :if={@federations != []} class={["filter-pill", @filters.fed && "is-active"]}>
                <span class="visually-hidden">{gettext("Federation")}</span>
                <select name="fed">
                  <option value="">{gettext("Federation")}</option>
                  <option
                    :for={federation <- @federations}
                    value={federation}
                    selected={@filters.fed == federation}
                  >
                    {federation}
                  </option>
                </select>
              </label>

              <label :if={@clubs != []} class={["filter-pill", @filters.club && "is-active"]}>
                <span class="visually-hidden">{gettext("Club")}</span>
                <select name="club">
                  <option value="">{gettext("Club")}</option>
                  <option :for={club <- @clubs} value={club} selected={@filters.club == club}>
                    {club}
                  </option>
                </select>
              </label>

              <label :if={@teams != []} class={["filter-pill", @filters.team && "is-active"]}>
                <span class="visually-hidden">{gettext("Team")}</span>
                <select name="team">
                  <option value="">{gettext("Team")}</option>
                  <option
                    :for={{no, label} <- @teams}
                    value={no}
                    selected={@filters.team == to_string(no)}
                  >
                    {label}
                  </option>
                </select>
              </label>

              <label
                :if={@sort?}
                class={["filter-pill", "filter-sort", @filters.sort != "rank" && "is-active"]}
              >
                <span class="visually-hidden">{gettext("Sort by")}</span>
                <select name="sort">
                  <option value="rank" selected={@filters.sort == "rank"}>
                    {gettext("Sort: Rank")}
                  </option>
                  <option value="rating" selected={@filters.sort == "rating"}>
                    {gettext("Sort: Rating")}
                  </option>
                  <option value="name" selected={@filters.sort == "name"}>
                    {gettext("Sort: Name")}
                  </option>
                  <option value="federation" selected={@filters.sort == "federation"}>
                    {gettext("Sort: Federation")}
                  </option>
                  <option
                    :if={@rounds_played?}
                    value="rounds_played"
                    selected={@filters.sort == "rounds_played"}
                  >
                    {gettext("Sort: Rounds present")}
                  </option>
                </select>
              </label>
            </div>
          </details>

          <div class="filter-actions">
            <button type="submit" class="filter-submit">{gettext("Apply")}</button>
          </div>
        </fieldset>
      </form>

      <div :if={@show_meta?} class="filter-meta">
        <ul :if={@chips != []} class="filter-chips">
          <li :for={chip <- @chips} class="filter-chip">
            <a href={chip.href} aria-label={chip.remove_label}>
              {chip.label}
              <span aria-hidden="true">✕</span>
            </a>
          </li>
          <li class="filter-chip filter-chip-clear">
            <a href={@action}>{gettext("Clear all")}</a>
          </li>
        </ul>

        <p :if={@count_text} class="filter-count">{@count_text}</p>
      </div>

      <p :if={@empty?} class="empty filter-empty">
        {gettext("No players match these filters.")}
        <a href={@action}>{gettext("Clear filters")}</a>
      </p>
    </div>

    <%!-- Progressive enhancement only - see the moduledoc. Registered on
          `document`, from whichever render of this component happens to run
          first (a real page load always runs it; an innerHTML swap from the
          20-second refresher never does - see the root layout), so it
          survives every later swap without needing to run again itself: the
          listener re-queries the live DOM each time, the same pattern
          `index.html.heex`'s own search script uses for the same reason. --%>
    {OpenResultsWeb.InlineScripts.tag("filter_bar")}
    """
  end

  # One chip per active filter/sort key, in a fixed reading order, each
  # carrying the same page's URL with only that one key removed -
  # `FilterParams.to_params/1` (the same helper every nav link on this site
  # already uses) is what actually builds the query string, so a chip's
  # `href` can never drift from what the rest of the app considers "this
  # filter, minus this key". `in_disclosure?` says whether this chip's
  # control lives inside the phone disclosure - the search box does not, so
  # its chip does not count toward the "Filters (N)" badge.
  defp chips(filters, action, sort?, teams) do
    [
      chip(filters, action, :category, filters.category, filters.category, true),
      chip(filters, action, :fed, filters.fed, filters.fed, true),
      chip(filters, action, :club, filters.club, filters.club, true),
      chip(filters, action, :team, filters.team, team_label(filters.team, teams), true),
      chip(filters, action, :q, filters.q, filters.q && gettext("\"%{q}\"", q: filters.q), false),
      sort_chip(filters, action, sort?)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp team_label(nil, _teams), do: nil

  defp team_label(wanted, teams) do
    case Enum.find(teams, fn {no, _label} -> to_string(no) == wanted end) do
      {_no, label} -> label
      nil -> wanted
    end
  end

  defp chip(_filters, _action, _key, nil, _label, _in_disclosure?), do: nil

  defp chip(filters, action, key, _value, label, in_disclosure?) do
    %{
      label: label,
      href: chip_href(filters, action, key),
      remove_label: remove_label(key, label),
      in_disclosure?: in_disclosure?
    }
  end

  defp sort_chip(%FilterParams{sort: "rank"}, _action, _sort?), do: nil
  defp sort_chip(_filters, _action, false), do: nil

  defp sort_chip(filters, action, true) do
    %{
      label: gettext("Sorted by %{sort}", sort: sort_label(filters.sort)),
      href: chip_href(filters, action, :sort),
      remove_label: gettext("Remove sort: %{sort}", sort: sort_label(filters.sort)),
      in_disclosure?: true
    }
  end

  defp sort_label("rating"), do: gettext("rating")
  defp sort_label("name"), do: gettext("name")
  defp sort_label("federation"), do: gettext("federation")
  defp sort_label(_rank), do: gettext("rank")

  defp remove_label(:category, value),
    do: gettext("Remove filter: category %{value}", value: value)

  defp remove_label(:fed, value), do: gettext("Remove filter: federation %{value}", value: value)
  defp remove_label(:club, value), do: gettext("Remove filter: club %{value}", value: value)
  defp remove_label(:team, value), do: gettext("Remove filter: team %{value}", value: value)
  defp remove_label(:q, value), do: gettext("Remove search: %{value}", value: value)

  defp chip_href(filters, action, key) do
    cleared = Map.put(filters, key, default_for(key))
    query = FilterParams.to_params(cleared)

    if query == %{}, do: action, else: "#{action}?#{URI.encode_query(query)}"
  end

  defp default_for(:sort), do: "rank"
  defp default_for(_other), do: nil

  # "12 of 86 players", or just "86 players" when nothing is filtered out -
  # `nil` when the caller passed no `total` at all, which renders nothing.
  defp count_text(nil, _shown, _unit), do: nil

  defp count_text(total, shown, unit) do
    noun = unit_noun(unit, total)

    if shown == total do
      gettext("%{total} %{noun}", total: total, noun: noun)
    else
      gettext("%{shown} of %{total} %{noun}", shown: shown, total: total, noun: noun)
    end
  end

  defp unit_noun(:players, n), do: ngettext("player", "players", n)
  defp unit_noun(:boards, n), do: ngettext("board", "boards", n)
  defp unit_noun(:teams, n), do: ngettext("team", "teams", n)
end
