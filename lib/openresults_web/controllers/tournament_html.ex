defmodule OpenResultsWeb.TournamentHTML do
  @moduledoc """
  The public pages' markup, and the few presentational decisions above it.

  Nothing here works out what a value should be - `OpenResultsWeb.Tournament`
  reads the payload and this module decides how a number is printed and how a
  forfeit is worded. The one rule both share: a value nobody recognises is
  shown as it arrived rather than dropped, so a newer OpenPairings publishing
  a tiebreak or a result token this server has never heard of still produces a
  page an arbiter can read.
  """

  use OpenResultsWeb, :html

  alias OpenResultsWeb.Components.FilterBar
  alias OpenResultsWeb.Format
  alias OpenResultsWeb.Tournament
  alias OpenResultsWeb.Tournament.Filter

  embed_templates "tournament_html/*"

  @doc """
  The tabs of an event's tournaments, at the top of each one's pages - see
  `OpenResultsWeb.EventGroup.strip/3`. The current tournament is text, not a
  link to the page already open.
  """
  attr :event, :map, required: true

  def event_tabs(assigns) do
    ~H"""
    <nav
      id="event-tabs"
      class="event-tabs"
      aria-label={gettext("Tournaments of %{event}", event: @event.name)}
    >
      <a id="event-link" class="event-name" href={~p"/e/#{@event.id}"}>{@event.name}</a>
      <ul>
        <li :for={tab <- @event.tabs}>
          <span :if={tab.current?} class="event-tab current" aria-current="true" title={tab.name}>
            {tab.label}
          </span>

          <a :if={not tab.current?} class="event-tab" href={tab.href} title={tab.name}>
            {tab.label}
          </a>
        </li>
      </ul>
    </nav>
    """
  end

  @doc """
  The mark a finished tournament's pages carry so their refreshers stop
  polling. Derived from the snapshot alone, so the page cache keyed by
  snapshot stays right; the next poll of a tournament that has just finished
  carries it, and the page stops by itself.
  """
  attr :payload, :map, required: true

  def finished_marker(assigns) do
    ~H"""
    <span :if={Tournament.settled?(@payload)} data-results-finished hidden></span>
    """
  end

  @doc """
  The tournament's name, its details, and the round strip.

  The strip lists every round the tournament has and not only the published
  ones. A withheld round appears as a number that is not a link, so a reader
  can see that round 4 exists and has not been posted rather than wondering
  whether they misremembered the schedule.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  attr :current, :any,
    required: true,
    doc: ":standings, :crosstable, :register, {:round, n} or {:player, no}"

  attr :query, :map,
    default: %{},
    doc: """
    the active filter bar query (`OpenResultsWeb.FilterParams.to_params/1`),
    carried onto the standings/cross-table/round links below so a reader
    moving between those three pages keeps their filter and sort - see
    `OpenResultsWeb.Tournament.Filter`. `%{}` (the default) on any page that
    does not offer the bar, which renders exactly as before this existed.
    """

  def masthead(assigns) do
    payload = assigns.payload

    # One index, then a lookup per slot. `Tournament.round/2` re-sorts the
    # whole round list on every call, so calling it once per slot was
    # quadratic in the payload's own `rounds_count`.
    by_number = Tournament.rounds_by_number(payload)

    slots = Enum.map(Tournament.round_slots(payload), &{&1, Map.has_key?(by_number, &1)})

    assigns =
      assigns
      |> assign(:info, Tournament.info(payload))
      |> assign(:slots, slots)
      |> assign(:show, display_rules(payload))
      # Read here rather than handed in by eleven templates: the strip is
      # part of the masthead, and which page this is (`current`) is known
      # only where the masthead is drawn. It reads other tournaments, which
      # a component otherwise never does - `Revalidate`'s epoch is what keeps
      # the cached page honest about that.
      |> assign(:event, OpenResultsWeb.EventGroup.strip(payload, assigns.slug, assigns.current))

    ~H"""
    <header class="masthead">
      <.event_tabs :if={@event} event={@event} />
      <%!-- Read by the root layout's refresher: while any round's results
            are coming in it polls twice as often. Derived from the snapshot
            alone, so the page cache keyed by snapshot stays right. --%>
      <span :if={Tournament.live?(@payload)} data-results-live hidden></span>
      <.finished_marker payload={@payload} />
      <h1>{Tournament.name(@payload)}</h1>

      <%!-- Facts a printed pairing sheet carries as a matter of course, each
            behind its own tick. Terse and only when present, because club play
            is mostly missing fields. --%>
      <p class="details">
        <span :if={@show.city && @info["city"]}>{@info["city"]}</span>
        <span :if={@show.federation && @info["federation"]}>{@info["federation"]}</span>
        <span :if={@show.dates && dates(@info)}>{dates(@info)}</span>
        <span :if={@show.arbiter && @info["arbiter"]}>
          {gettext("Arbiter: %{name}", name: @info["arbiter"])}
        </span>

        <span :if={@show.deputy && @info["deputy"]}>
          {gettext("Deputy: %{name}", name: @info["deputy"])}
        </span>

        <span :if={@show.time_control && @info["time_control"]}>
          {gettext("Tempo: %{time_control}", time_control: @info["time_control"])}
        </span>
        <span :if={@show.fide_badge && @info["fide_rated"] == true}>{gettext("FIDE rated")}</span>
      </p>

      <%!-- A navigation strip with nothing to navigate to is furniture, so it
            goes entirely when both pages behind it are off. --%>
      <%!-- `aria-current` says which of these is the page you are on - the
            accent and the weight said it only to the eye - and a round's
            accessible name is "Round 3" rather than a bare "3". --%>
      <nav :if={@show.standings or @show.pairings} class="rounds" aria-label={gettext("Rounds")}>
        <a
          :if={@show.standings}
          href={~p"/t/#{@slug}?#{@query}"}
          class={["chip", @current == :standings && "current"]}
          aria-current={@current == :standings && "page"}
        >
          {gettext("Standings")}
        </a>

        <%!-- The grid, beside the pages it is made of. Behind the pairings
              tick as well as its own, because it IS the pairings - see
              `Tournament.crosstable?/1`. --%>
        <a
          :if={@show.pairings and @show.crosstable}
          href={~p"/t/#{@slug}/crosstable?#{@query}"}
          class={["chip", @current == :crosstable && "current"]}
          aria-current={@current == :crosstable && "page"}
        >
          {gettext("Cross-table")}
        </a>

        <a
          :if={
            @show.standings and Tournament.team_event?(@payload) and Tournament.teams(@payload) != []
          }
          id="teams-link"
          href={~p"/t/#{@slug}/teams"}
          class={["chip", @current == :teams && "current"]}
          aria-current={@current == :teams && "page"}
        >
          {gettext("Teams")}
        </a>

        <a
          :if={
            @show.standings and Tournament.team_event?(@payload) and
              Tournament.board_stats(@payload) != []
          }
          href={~p"/t/#{@slug}/board-prizes"}
          class={["chip", @current == :board_prizes && "current"]}
          aria-current={@current == :board_prizes && "page"}
        >
          {gettext("Board prizes")}
        </a>

        <%!-- The rounds in a wrapper of their own, which on a desktop is no
              box at all (`display: contents`) and on a phone is one line
              that swipes sideways, the current or newest round scrolled
              into view - see `.round-strip` in app.css. Nine rounds wrapped
              into three lines of 44px chips put the table a whole screen
              below the tournament's name. --%>
        <span :if={@show.pairings and @slots != []} id="round-strip" class="round-strip">
          <%= for {n, published?} <- @slots do %>
            <a
              :if={published?}
              href={~p"/t/#{@slug}/round/#{n}?#{@query}"}
              class={["chip", @current == {:round, n} && "current"]}
              aria-current={@current == {:round, n} && "page"}
              aria-label={round_link_label(@payload, n)}
            >
              {Tournament.round_label(@payload, n)}
            </a>

            <span :if={not published?} class="chip withheld" title={gettext("not published")}>
              {Tournament.round_label(@payload, n)}<span class="visually-hidden">{gettext(
                ", not published"
              )}</span>
            </span>
          <% end %>
        </span>

        <%!-- Beside the rounds, on the arbiter's word alone - see
              `Tournament.live_boards?/1` for why not on whether a game has
              been reported. It leaves this page for a live one, which is not
              part of the cached set. --%>
        <a
          :if={@show.pairings and Tournament.live_boards?(@payload)}
          id="live-boards-link"
          href={~p"/t/#{@slug}/live"}
          class="chip"
        >
          {gettext("Live boards")}
        </a>
      </nav>

      <%!--
        Outside the round strip, which is about rounds. Taken down on
        2026-08-29 while the form was unfinished and put back on 2026-09-30
        with the rest of the workflow: the review queue on the arbiter's
        Players page, the window, the cap and the entry list.

        Gated on the arbiter's switch alone, not on the window or the cap,
        and that is deliberate: this header is part of pages cached per
        snapshot, and a link that depended on the clock would be stale in the
        cache the moment the window opened. The form page itself says
        "opens on ..." or "the field is full" - and it enforces all of it,
        because a link is a courtesy and a bookmarked URL is not.

        And on an EXPLICIT `true` - see `Tournament.entry_link?/1` for why
        this is the one reader of the switch that does not read silence as
        open.
      --%>
      <p :if={Tournament.entry_link?(@payload)} class="entry">
        <a
          href={~p"/t/#{@slug}/register"}
          id="enter-tournament"
          class={["chip", @current == :register && "current"]}
          aria-current={@current == :register && "page"}
        >
          {gettext("Enter this tournament")}
        </a>
      </p>
    </header>
    """
  end

  @doc """
  The two screens for the hall, as link cards at the FOOT of the overview
  pages (standings, cross-table, a round): the table people came for comes
  first. Renders nothing on a player's card or a form, or where neither page
  the screens show is public.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :current, :any, required: true

  def screen_cards(assigns) do
    assigns = assign(assigns, :show, display_rules(assigns.payload))

    ~H"""
    <%!-- The two screens for the hall, once per tournament and at the foot of the
          page, after the table people came for - not on each round. Both follow
          the newest round by themselves. Offered only where the pages they
          show are public: the projector view is pairings, the hall display
          is pairings or standings, and a screen left open on a tournament
          that later hides them says so rather than showing it. Only on the
          overview pages, not on a player's card or a form. The arbiter's
          `screen_links` tick hides the cards only; the routes stay open. --%>
    <div
      :if={
        screens?(@current) and (@show.pairings or @show.standings) and
          Tournament.show?(@payload, "screen_links")
      }
      id="screens"
      class="screens"
    >
      <a
        :if={@show.pairings}
        id="projector-link"
        class="screen-card"
        href={~p"/t/#{@slug}/projector"}
      >
        <svg class="screen-card-icon" viewBox="0 0 24 24" aria-hidden="true">
          <rect
            x="3"
            y="4"
            width="18"
            height="12"
            rx="1.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          />
          <path
            d="M8 20h8M12 16v4"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
          />
        </svg>

        <span class="screen-card-text">
          <span class="screen-card-title">{gettext("Projector view")}</span>
          <span class="screen-card-desc">
            {gettext("Large boards for the newest round, updating by themselves")}
          </span>
        </span>
      </a>

      <a id="hall-display-link" class="screen-card" href={~p"/t/#{@slug}/hall"}>
        <svg class="screen-card-icon" viewBox="0 0 24 24" aria-hidden="true">
          <rect
            x="3"
            y="3"
            width="18"
            height="18"
            rx="1.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          /> <path d="M3 9h18M9 9v12" fill="none" stroke="currentColor" stroke-width="2" />
        </svg>

        <span class="screen-card-text">
          <span class="screen-card-title">{gettext("Hall display")}</span>
          <span class="screen-card-desc">
            {gettext("Pairings, results and standings in turn, always the newest round")}
          </span>
        </span>
      </a>
    </div>
    """
  end

  # The overview pages carry the hall-screen cards; a player's card and the
  # forms do not.
  defp screens?(current), do: current in [:standings, :crosstable] or match?({:round, _}, current)

  @doc """
  The tournament's dates, as one span or two.

  `en` renders exactly as it always has - the ISO string or strings,
  verbatim. `nl` and `fr` go through `OpenResultsWeb.Format`, which is
  where the day-month-year form and the idiomatic range come from; see
  its moduledoc for why a date it cannot parse still renders rather than
  crashing the page.
  """
  def dates(info) do
    case {info["start_date"], info["end_date"]} do
      {nil, nil} -> nil
      {start, nil} -> date(start)
      {nil, finish} -> date(finish)
      {same, same} -> date(same)
      {start, finish} -> Format.date_range(start, finish)
    end
  end

  @doc """
  One date on its own - a round's date, the entry form's start date -
  formatted the same way `dates/1` formats the tournament's own range.
  """
  def date(iso), do: Format.date(iso)

  @doc """
  The standings table's caption: which standings these are.

  Visually hidden - the section heading above the table already says it to
  the eye - and there for a screen reader, which announces a table's caption
  as it enters the table and not the heading somewhere above it. The same
  sentences a shared link's preview uses (`OpenResultsWeb.Meta`), so no new
  wording to translate.
  """
  def standings_caption(payload) do
    case Tournament.after_round(payload) do
      nil ->
        gettext("Standings of %{tournament}.", tournament: Tournament.name(payload))

      round ->
        gettext("Standings after round %{round} of %{tournament}.",
          round: round,
          tournament: Tournament.name(payload)
        )
    end
  end

  @doc """
  A front-page group's own heading - see `Tournament.status/2` for how a
  tournament ends up in one.
  """
  def group_title(:live), do: gettext("Live now")
  def group_title(:upcoming), do: gettext("Upcoming")
  def group_title(:finished), do: gettext("Finished")

  @doc """
  An anchor as one gettext binding, for a sentence with a link inside it.

  A translator moving the link to the other end of a Dutch sentence must not
  have to move a tag with it, and chopping the sentence into fragments around
  the tag would leave them ordering words they cannot see together. So the
  sentence stays whole in the catalogue and the anchor arrives as `%{...}`.

  The result is raw HTML and its caller has to `raw/1` it, which is the whole
  reason this escapes both halves itself. Never hand it anything from a
  payload: it is for this app's own routes and its own strings.
  """
  def anchor(href, text) do
    ~s(<a href="#{escaped(href)}">#{escaped(text)}</a>)
  end

  @doc """
  One value, escaped and back to a string, for interpolating into a gettext
  binding that will be rendered raw.
  """
  def escaped(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # A column header that sorts the standings: a plain link to the same page
  # with `sort` set (every other filter kept), so it works without
  # JavaScript and can be shared. Clicking the active column again goes back
  # to rank order. Rank and rating sort highest-first; name and federation
  # alphabetically - the same orders the Sort control offers.
  attr :slug, :string, required: true
  attr :filters, :any, required: true
  attr :key, :string, required: true
  slot :inner_block, required: true

  defp sort_link(assigns) do
    next = if assigns.filters.sort == assigns.key, do: "rank", else: assigns.key
    params = assigns.filters |> Map.put(:sort, next) |> OpenResultsWeb.FilterParams.to_params()

    assigns =
      assign(assigns,
        href: ~p"/t/#{assigns.slug}?#{params}",
        # Rank is the default order, so it is never marked as a chosen sort.
        active?: assigns.filters.sort == assigns.key and assigns.key != "rank"
      )

    ~H"""
    <a href={@href} class={["sort-link", @active? && "is-sorted"]}>
      {render_slot(@inner_block)}<span :if={@active?} class="sort-mark" aria-hidden="true">▾</span>
    </a>
    """
  end

  defp aria_sort(filters, key) do
    cond do
      filters.sort != key -> nil
      key in ["name", "federation"] -> "ascending"
      true -> "descending"
    end
  end

  # See `standings_table/1`: the most rows a standings table carries every
  # tie-break's per-round working for.
  @inline_working_rows 100

  @doc false
  def inline_working_rows, do: @inline_working_rows

  @doc """
  The standings, filtered and sorted per the filter bar's own query string -
  see `OpenResultsWeb.Tournament.Filter.standings/2` for what decides which
  rows show and in what order, and `OpenResultsWeb.Components.FilterBar` for
  the form itself.

  `rank` is always the arbiter's own placing, printed in its own column,
  whatever `filters.sort` reorders the rows to - never recomputed here, and
  never affected by which rows are hidden: this page exists to agree with
  the printed crosstable, not to re-rank against it. When a category filter
  is active each row also shows its place WITHIN that category, from
  `Filter.standings/2`'s `places` map - see that function's own moduledoc for
  exactly how that number is derived.

  ## Why this is a server-side filter, unlike the site's other search boxes

  `index.html.heex`'s tournament search and (before this change) this very
  table's club/federation/category dropdowns filter client-side, and their
  own comments explain why: it keeps `OpenResultsWeb.Plugs.Revalidate`'s
  page cache trivially valid, because every reader of one URL always got
  byte-identical HTML.

  The filter bar breaks that assumption on purpose - a `?category=U1800`
  request must render fewer rows, in real HTML, so the page works with no
  JavaScript at all and a filtered link is what a reader can actually send
  someone. `Revalidate.call/2` is where the trade is made: a request
  carrying any filter/sort key bypasses the page cache entirely rather than
  polluting it with a key space bounded only by how creative a query string
  can get - see that module's own moduledoc for the decision in full.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :filters, OpenResultsWeb.FilterParams, required: true

  def standings_table(assigns) do
    payload = assigns.payload
    show = display_rules(payload)
    filtered = Filter.standings(payload, assigns.filters)
    players = Tournament.players_by_no(payload)
    all_rows = Tournament.standings_rows(payload)
    # Only when the tournament actually groups its players. A column of
    # dashes on every ordinary open is noise.
    categories? = Enum.any?(all_rows, & &1["category"])
    working_published? = Tournament.show?(payload, "tiebreak_working")
    # Each row's working is a small table per tie-break with every opponent
    # named in it - on a thousand-player open, over two hundred thousand
    # elements and eleven megabytes of HTML for one standings page, which a
    # phone on the hall's wifi parses again on every result. Inline only
    # while the table is short enough to carry it: a search for one name,
    # a category, or an ordinary club tournament. The player's own page
    # always has the full working.
    explain_inline? = length(filtered.rows) <= @inline_working_rows

    assigns =
      assigns
      |> assign(:rows, filtered.rows)
      |> assign(:places, filtered.places)
      |> assign(:empty?, all_rows != [] and filtered.rows == [])
      |> assign(:tiebreaks, Tournament.tiebreaks(payload))
      |> assign(:players, players)
      # Keizer standings carry value, Keizer points and score where a swiss
      # carries points and tiebreaks. Keyed off `system`, as the contract says.
      |> assign(:keizer?, Tournament.keizer?(payload))
      |> assign(:manual_order?, Tournament.manual_order?(payload))
      |> assign(:withheld?, Tournament.tiebreaks_withheld?(payload))
      |> assign(:manual_stale?, Tournament.manual_warning?(payload, :stale))
      |> assign(:manual_incomplete?, Tournament.manual_warning?(payload, :incomplete))
      |> assign(:show, show)
      |> assign(:categories?, categories?)
      # The attendance column, only when the arbiter published it: an
      # additive field on the rows (see docs/snapshot-schema.md). Asked of
      # the rows rather than of a display tick, because a tournament that
      # does not send it has no tick either.
      |> assign(:rounds_played?, Enum.any?(all_rows, &Map.has_key?(&1, "rounds_played")))
      # The performance column, likewise: only when a row carries it, which
      # OpenPairings does only for an arbiter who ticked "Performance".
      |> assign(:performance?, Enum.any?(all_rows, &Map.has_key?(&1, "performance")))
      # A finer tick than `tiebreaks` itself: an arbiter can publish the
      # columns while keeping the per-round arithmetic behind them closed.
      # Absent means shown, like every other key `Tournament.show?/2` reads.
      |> assign(:explain_tiebreaks?, explain_inline? and working_published?)
      # The arbiter published the working, but this many rows cannot carry
      # it - said once under the table, where the player pages are offered
      # instead.
      |> assign(
        :working_elsewhere?,
        working_published? and not explain_inline? and Tournament.show?(payload, "tiebreaks")
      )
      # The filter bar's own option lists - only categories the arbiter
      # shows (`Filter.categories/1` reads the same gate `Tournament.show?/2`
      # does through `tournament.categories` itself being absent when
      # hidden), and only clubs/federations behind their own display ticks,
      # exactly as the site's other dropdowns already work.
      |> assign(:bar_categories, Filter.categories(payload))
      |> assign(:bar_clubs, (show.club && Filter.player_values(payload, "club")) || [])
      |> assign(
        :bar_federations,
        (show.federation && Filter.player_values(payload, "federation")) || []
      )
      |> assign(:total_players, length(all_rows))

    # What the phone's line under each name carries: exactly the columns
    # it hides (see `.row-meta` in app.css), each only where the column
    # itself is drawn.
    assigns =
      assign(assigns, :meta_columns, %{
        rating: show.rating,
        sex: show.sex,
        category: categories? and show.category,
        rounds_played: assigns.rounds_played?,
        performance: assigns.performance? and not assigns.keizer?
      })

    ~H"""
    <p :if={@manual_order?} class="footnote manual-order">
      {gettext(
        "The order below was set by the arbiter, not computed from the tiebreaks. The points and tiebreak columns are unchanged; the rank column is their decision."
      )}
      <span :if={@manual_incomplete?}>
        {gettext("A player was added after that order was set and has not been placed in it yet.")}
      </span>

      <%!-- The one that matters. "The arbiter chose this order" and "the
            arbiter chose this order and it is now out of date" are different
            statements, and only the first was travelling. --%>
      <strong :if={@manual_stale?}>
        {gettext(
          "A result has changed since the order was last set, so it may no longer match the real standings."
        )}
      </strong>
    </p>

    <%!-- Said where the ordering is, not on a player's card, because the
          question it answers is about the table: why is that person above
          me when every number I can see is the same? --%>
    <p :if={@withheld? and @rows != []} class="footnote">
      {gettext(
        "The order also uses tie-breaks this tournament does not publish, so two players can appear one above the other with every column here identical."
      )}
    </p>

    <p :if={@rows == [] and not @empty?} class="empty">
      {gettext("No standings have been published for this tournament yet.")}
    </p>

    <p :if={@rows != [] and @working_elsewhere?} id="working-elsewhere" class="footnote">
      {gettext(
        "How each tie-break was reached is on the player's own page - open a name. Search for a player, or filter, to see it in this table."
      )}
    </p>
    <.follow_pin :if={@rows != []} slug={@slug} on={@show.player_cards} />
    <FilterBar.filter_bar
      :if={@rows != [] or @empty?}
      action={~p"/t/#{@slug}"}
      filters={@filters}
      categories={@bar_categories}
      federations={@bar_federations}
      clubs={@bar_clubs}
      empty?={@empty?}
      total={@total_players}
      shown={length(@rows)}
      unit={:players}
      rounds_played?={@rounds_played?}
    />
    <div :if={@rows != []} class="scroller">
      <table class="standings">
        <caption class="visually-hidden">{standings_caption(@payload)}</caption>

        <thead>
          <tr>
            <th class="num" scope="col" aria-sort={aria_sort(@filters, "rank")}>
              <.sort_link slug={@slug} filters={@filters} key="rank">{gettext("#")}</.sort_link>
            </th>

            <th scope="col" aria-sort={aria_sort(@filters, "name")}>
              <.sort_link slug={@slug} filters={@filters} key="name">{gettext("Player")}</.sort_link>
            </th>

            <th
              :if={@show.rating}
              class="num col-rating"
              scope="col"
              aria-sort={aria_sort(@filters, "rating")}
            >
              <.sort_link slug={@slug} filters={@filters} key="rating">{gettext("Rating")}</.sort_link>
            </th>

            <th :if={@show.sex} class="col-sex" scope="col">{gettext("Sex")}</th>

            <th :if={@categories? and @show.category} class="col-cat" scope="col">
              {gettext("Cat")}
            </th>

            <th
              :if={@rounds_played?}
              class="num col-rds"
              scope="col"
              title={gettext("Rounds this player was there for")}
              aria-sort={aria_sort(@filters, "rounds_played")}
            >
              <.sort_link slug={@slug} filters={@filters} key="rounds_played">
                {gettext("Rds")}
              </.sort_link>
            </th>

            <th
              :if={@performance? and not @keizer?}
              class="num col-perf"
              scope="col"
              title={gettext("Performance")}
            >
              {gettext("Perf.")}
            </th>

            <%= if @keizer? do %>
              <th class="num" scope="col">{gettext("Value")}</th>

              <th class="num" scope="col">{gettext("Keizer points")}</th>

              <th class="num" scope="col">{gettext("Score")}</th>
            <% else %>
              <th class="num" scope="col">{gettext("Points")}</th>

              <%!-- The placings are unaffected by hiding these. The arbiter
                    is hiding the arithmetic, not the result - the order is
                    still exactly the one they computed. --%>
              <th :for={tiebreak <- @tiebreaks} :if={@show.tiebreaks} class="num" scope="col">
                <.tiebreak_heading tiebreak={tiebreak} />
              </th>
            <% end %>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows} class={Tournament.uncounted?(row) && "uncounted"}>
            <td class="num rank">
              {if(Tournament.uncounted?(row), do: "–", else: row["rank"])}
              <%!-- The place within the active category filter, e.g. "1 in
                    U1800" beside the overall rank - see
                    `Filter.standings/2`'s `places`, keyed by pairing number
                    and computed from the category alone, independent of the
                    club/federation/name filters that might also be active. --%>
              <span :if={Map.get(@places, row["player"])} class="quiet category-place">
                {gettext("%{place} in %{category}",
                  place: Map.get(@places, row["player"]),
                  category: @filters.category
                )}
              </span>
            </td>

            <%!-- The row's header: a screen reader moving along a row, or
                  down the Points column, hears whose number it is. --%>
            <th scope="row" class="row-head">
              <.player_link
                slug={@slug}
                no={row["player"]}
                player={@players[row["player"]]}
                show={@show}
                q={@filters.q}
                cards?={@show.player_cards}
                detail
              />
              <span :if={Tournament.uncounted?(row)} class="uncounted-note">
                {gettext("results not counted (withdrawn)")}
              </span>

              <%!-- The columns a phone drops, said under the name instead -
                    see `.row-meta` in app.css. One span of plain text per
                    row, because a thousand-player open pays for every
                    element twice: once to download, once per refresh. --%>
              <.row_meta text={standings_meta(row, @players[row["player"]], @meta_columns)} />
            </th>

            <td :if={@show.rating} class="num col-rating">{rating(@players, row["player"])}</td>

            <td :if={@show.sex} class="col-sex">{dash(@players[row["player"]]["sex"])}</td>

            <td :if={@categories? and @show.category} class="col-cat">{dash(row["category"])}</td>

            <td :if={@rounds_played?} class="num col-rds">{dash(row["rounds_played"])}</td>

            <td :if={@performance? and not @keizer?} class="num col-perf">
              {dash(row["performance"])}
            </td>

            <%= if @keizer? do %>
              <td class="num">{number(row["value"])}</td>

              <td class="num strong">{number(row["points"])}</td>

              <td class="num">{number(row["score"])}</td>
            <% else %>
              <td class="num strong">{number(row["points"])}</td>
              <% working = Tournament.working_for_row(row) %>
              <td
                :for={{tiebreak, at} <- Enum.with_index(@tiebreaks)}
                :if={@show.tiebreaks}
                class="num tb-cell"
              >
                <.tiebreak_cell
                  slug={@slug}
                  players={@players}
                  show={@show}
                  code={tiebreak["code"]}
                  label={Tournament.tiebreak_label(tiebreak)}
                  who={get_in(@players, [row["player"], "name"])}
                  key={"#{row["player"]}-#{at}"}
                  value={Tournament.tiebreak_value(row, at)}
                  working={working}
                  explain?={@explain_tiebreaks?}
                />
              </td>
            <% end %>
          </tr>
        </tbody>
      </table>
    </div>
    <.uncounted_footnote :if={Enum.any?(@rows, &Tournament.uncounted?/1)} />
    <%!-- Keizer's ladder is not a FIDE tiebreak table and reads like a broken
          one if nobody says so: the points move for reasons that are not in
          the results column. Kept out of `standings.html.heex` and put here
          instead so it is part of the same conditional as the table it
          explains, filter and all. --%>
    <p :if={@rows != [] and @keizer?} class="footnote">
      {gettext(
        "These are Keizer points, not FIDE tiebreaks - the whole ladder is recalculated from results, byes and absences every time."
      )}
    </p>
    """
  end

  @doc """
  The followed player's row, pinned above the table - empty in the HTML and
  filled by the root layout's follow script from the visitor's own choice
  (`localStorage`, per tournament, set on a player's page by
  `follow_button/1`). The server sends every visitor the same bytes, so the
  page cache keyed by snapshot stays right; with no script, or nobody
  followed, it stays `hidden` and costs nothing but these few elements.
  """
  attr :slug, :string, required: true
  attr :on, :boolean, default: true, doc: "false where names are not links, so nothing can match"

  def follow_pin(assigns) do
    ~H"""
    <div :if={@on} id="follow-pin" class="follow-pin" data-follow-pin={@slug} hidden>
      <div class="follow-pin-head">
        <span class="follow-pin-label">{gettext("Following")}</span>
        <button type="button" id="follow-stop" class="follow-stop" data-follow-stop>
          {gettext("Stop following")}
        </button>
      </div>

      <div class="scroller follow-pin-rows" data-follow-rows></div>
    </div>
    """
  end

  @doc """
  The switch on a player's page that makes them the one this device follows
  - see `follow_pin/1`. Hidden until the script shows it, because a button
  that does nothing without JavaScript is worse than no button.
  """
  attr :slug, :string, required: true
  attr :no, :integer, required: true

  def follow_button(assigns) do
    ~H"""
    <div class="follow-control">
      <%!-- The explanation is the button's own title now: a paragraph under it
            would put the compact control back to being a block. The script
            still reveals a `.follow-hint` if a page carries one. --%>
      <button
        type="button"
        id="follow-player"
        class="follow-button"
        title={
          gettext(
            "Their row stays at the top of the standings, and their board at the top of each round - on this device only."
          )
        }
        data-follow-slug={@slug}
        data-follow-no={@no}
        data-label-follow={gettext("Follow this player")}
        data-label-following={gettext("Stop following")}
        hidden
      >
        {gettext("Follow this player")}
      </button>
    </div>
    """
  end

  @doc """
  The quiet line under a name that carries, on a phone, the columns the
  phone hides. Renders nothing when there is nothing to say.
  """
  attr :text, :string, default: nil

  def row_meta(assigns) do
    ~H"""
    <span :if={@text} class="row-meta">{@text}</span>
    """
  end

  @doc """
  The text of `row_meta/1` for one standings row: rating, sex, category,
  rounds present and performance, each only where its column is drawn and
  the row has a value. `nil` when none of them do.
  """
  def standings_meta(row, player, columns) do
    player = player || %{}

    [
      columns.rating && present(player["rating"]),
      columns.sex && present(player["sex"]),
      columns.category && present(row["category"]),
      columns.rounds_played && labelled(gettext("Rds"), row["rounds_played"]),
      columns.performance && labelled(gettext("Perf."), row["performance"])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp present(nil), do: nil
  defp present(value), do: to_string(value)

  defp labelled(_label, nil), do: nil
  defp labelled(label, value) when is_number(value), do: "#{label} #{number(value)}"
  defp labelled(label, value), do: "#{label} #{value}"

  @doc """
  The sentence under any table that lists a player whose results are not
  counted: FIDE C.05 6.6, a round-robin player who left with fewer than
  half the games played. Said once per table - the mark on the row says
  which player, this says what it means for everybody else's points.
  """
  def uncounted_footnote(assigns) do
    ~H"""
    <p class="footnote uncounted-footnote">
      {gettext(
        "Results not counted (withdrawn): this player left the tournament with fewer than half of the games played. Under the round-robin rules (FIDE C.05 6.6) those games stay in the table but count for nobody - not for this player's place, and not in the other players' points."
      )}
    </p>
    """
  end

  @doc """
  The team standings table for a team event: rank, team, match points, game
  points and the configured team tie-breaks with the same expandable
  "working" a player's tie-break cell offers - see `Tournament.team_working/2`.
  Each team name links to its own page (`team.html.heex`).
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def team_standings_table(assigns) do
    payload = assigns.payload

    assigns =
      assigns
      |> assign(:rows, Tournament.team_standings_rows(payload))
      |> assign(:tiebreaks, Tournament.team_tiebreaks(payload))
      |> assign(:pending?, Tournament.team_standings_pending?(payload))
      |> assign(:teams, Tournament.teams_by_no(payload))

    ~H"""
    <p :if={@pending?} class="empty">
      {gettext("No team standings have been published for this tournament yet.")}
    </p>

    <div :if={not @pending?} class="scroller">
      <table class="standings">
        <caption class="visually-hidden">
          {gettext("Team standings after round %{round} of %{tournament}.",
            round: Tournament.team_after_round(@payload),
            tournament: Tournament.name(@payload)
          )}
        </caption>

        <thead>
          <tr>
            <th class="num" scope="col">{gettext("#")}</th>

            <th scope="col">{gettext("Team")}</th>

            <th class="num" scope="col">{gettext("MP")}</th>

            <th class="num" scope="col">{gettext("GP")}</th>

            <th :for={tiebreak <- @tiebreaks} class="num" scope="col">
              <.tiebreak_heading tiebreak={tiebreak} />
            </th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows}>
            <td class="num rank">{row["rank"]}</td>

            <th scope="row" class="row-head">
              <a href={~p"/t/#{@slug}/team/#{row["team"]}"}>
                {Tournament.team_label(@teams[row["team"]])}
              </a>
            </th>

            <td class="num strong">{number(row["mp"])}</td>

            <td class="num">{number(row["gp"])}</td>
            <% working = Tournament.working_for_row(row) %>
            <td :for={{tiebreak, at} <- Enum.with_index(@tiebreaks)} class="num tb-cell">
              <.team_tiebreak_cell
                slug={@slug}
                teams={@teams}
                code={tiebreak["code"]}
                key={"#{row["team"]}-#{at}"}
                value={Tournament.tiebreak_value(row, at)}
                working={working}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # A tie-break's column heading. The full name on a screen with room for it,
  # the regulations' abbreviation on a phone - "Buchholz Cut-1" spelled out
  # made one column wider than the name beside it. The abbreviation carries
  # the full name as its title. No "?" here: a table full of question marks
  # reads like an exam. The explanations live on the player page, where
  # someone who opened a row is actually asking.
  attr :tiebreak, :map, required: true

  defp tiebreak_heading(assigns) do
    assigns =
      assign(assigns,
        label: Tournament.tiebreak_label(assigns.tiebreak),
        short: Tournament.tiebreak_short(assigns.tiebreak)
      )

    # The text stays the name, so a screen reader and a copy-paste get the
    # name; a phone's stylesheet swaps what is drawn for `data-short`.
    ~H"""
    <span class="tb-head" title={@label} data-short={@short != @label && @short}>{@label}</span>
    """
  end

  attr :slug, :string, required: true
  attr :teams, :map, required: true
  attr :code, :string, required: true
  attr :key, :string, required: true
  attr :value, :any, required: true
  attr :working, :map, required: true

  def team_tiebreak_cell(assigns) do
    open? = not is_nil(assigns.value) and Map.has_key?(assigns.working, assigns.code)

    assigns =
      assigns
      |> assign(:open?, open?)
      |> assign(:parts, if(open?, do: assigns.working[assigns.code]["parts"], else: []))

    ~H"""
    <details :if={@open?} class="tb-detail" data-detail={@key}>
      <summary>
        {number(@value)} <span class="visually-hidden">{gettext("show how this was reached")}</span>
      </summary>

      <div class="scroller">
        <table class="working-table tb-working">
          <caption class="visually-hidden">{gettext("How this tie-break was reached")}</caption>

          <thead class="tb-working-head">
            <tr>
              <th scope="col"><span class="visually-hidden">{gettext("Rd")}</span></th>

              <th scope="col"><span class="visually-hidden">{gettext("From")}</span></th>

              <th scope="col"><span class="visually-hidden">{gettext("Value")}</span></th>
            </tr>
          </thead>

          <tbody>
            <tr :for={part <- @parts}>
              <th scope="row" class="num row-head">{part["round"]}</th>

              <td>
                <%= if part["opponent"] && Map.has_key?(@teams, part["opponent"]) do %>
                  <a href={~p"/t/#{@slug}/team/#{part["opponent"]}"}>
                    {Tournament.team_label(@teams[part["opponent"]])}
                  </a>
                <% else %>
                  <span class="quiet">{gettext("unplayed round")}</span>
                <% end %>
              </td>

              <td class="num">{number(part["value"])}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    <span :if={not @open?}>{number(@value)}</span>
    """
  end

  @doc """
  The team-vs-team cross-table for a team round robin: a row and a column
  per team, and in each cell the match's game points, from the row team's
  own side. See `Tournament.team_crosstable/1`.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def team_crosstable_table(assigns) do
    rows = Tournament.team_crosstable(assigns.payload)
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <h3>{gettext("Team cross-table")}</h3>

    <div :if={@rows != []} class="scroller">
      <table class="crosstable">
        <caption class="visually-hidden">{gettext("Team cross-table")}</caption>

        <thead>
          <tr>
            <th scope="col">{gettext("Team")}</th>

            <th :for={opp <- @rows} class="num" scope="col">{opp.no}</th>

            <th class="num" scope="col">{gettext("MP")}</th>

            <th class="num" scope="col">{gettext("GP")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows}>
            <th scope="row" class="row-head">
              <a href={~p"/t/#{@slug}/team/#{row.no}"}>{Tournament.team_label(row.team)}</a>
            </th>

            <td :for={opp <- @rows} class="num">
              <%= if opp.no == row.no do %>
                <span class="quiet">-</span>
              <% else %>
                <%= for %{match: m} <- Map.get(row.cells, opp.no, []) do %>
                  <% {gp, _mp} = Tournament.match_points_for(m, row.no) %> <% pending =
                    Tournament.match_postponed_boards(m) %> <span :if={gp}>{number(gp)}</span>
                  <span :if={is_nil(gp)} class="quiet">{gettext("?")}</span>
                  <%!-- The match's score is provisional while any of its
                        boards is a postponed game still to be played - see
                        `match_score/1`'s own moduledoc, which says the same
                        thing beside a round's own pairing list. That line
                        stays page-level there; here, where a whole team's
                        row of results has to fit one screen, the mark sits
                        in the one cell it is actually about. --%>
                  <abbr
                    :if={pending > 0}
                    class="xt-postponed"
                    title={ngettext("1 board pending", "%{count} boards pending", pending)}
                  ><.said_as words={ngettext("1 board pending", "%{count} boards pending", pending)}>
                    ⏳
                  </.said_as></abbr>
                <% end %>
              <% end %>
            </td>

            <td class="num strong">{number(row.mp)}</td>

            <td class="num">{number(row.gp)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  The team cross-table by round, for a team Swiss: a row per team, a column
  per round, and in each cell the opponent's number, the team's colour on
  board 1, the match's game score from this team's side and, underneath, the
  match points and game points so far. See `Tournament.team_round_crosstable/1`.

  Only the rounds the standings reach and whose results are public are here
  (`Tournament.crosstable_rounds/1`), exactly as in the player cross-table.
  The final MP and GP are the standings' own.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def team_round_crosstable_table(assigns) do
    table = Tournament.team_round_crosstable(assigns.payload)
    teams = Tournament.teams_by_no(assigns.payload)

    assigns =
      assigns
      |> assign(:rounds, table.rounds)
      |> assign(:rows, table.rows)
      |> assign(:teams, teams)
      |> assign(:placed?, Enum.any?(table.rows, & &1.rank))

    ~H"""
    <p :if={@rounds == [] or @rows == []} class="empty">
      {gettext("Team results appear here once the standings after round 1 are published.")}
    </p>

    <div :if={@rounds != [] and @rows != []} class="scroller xt-scroller">
      <table class="crosstable team-crosstable" id="team-crosstable">
        <caption class="visually-hidden">{gettext("Team cross-table")}</caption>

        <thead>
          <tr>
            <th class="num xt-no" scope="col" title={gettext("Team number")}>{gettext("No")}</th>

            <th class="xt-name" scope="col">{gettext("Team")}</th>

            <th :for={n <- @rounds} class="xt-round" scope="col">
              <a
                href={~p"/t/#{@slug}/round/#{n}"}
                title={Tournament.round_heading(@payload, n)}
                aria-label={round_link_label(@payload, n)}
              >
                {Tournament.round_label(@payload, n)}
              </a>
            </th>

            <th :if={@placed?} class="num" scope="col">{gettext("MP")}</th>

            <th :if={@placed?} class="num" scope="col">{gettext("GP")}</th>

            <th :if={@placed?} class="num" scope="col">{gettext("Rank")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows}>
            <td class="num xt-no">{row.no}</td>

            <th scope="row" class="xt-name row-head">
              <a href={~p"/t/#{@slug}/team/#{row.no}"}>{Tournament.team_label(row.team)}</a>
            </th>
            <.team_round_cell :for={cell <- row.cells} cell={cell} slug={@slug} teams={@teams} />
            <td :if={@placed?} class="num strong">{number(row.mp)}</td>

            <td :if={@placed?} class="num">{number(row.gp)}</td>

            <td :if={@placed?} class="num rank">{row.rank}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <p :if={@rounds != [] and @rows != []} class="footnote">
      {gettext(
        "Each cell is one round: the opponent's team number, the colour this team had on board 1 - w for White, b for Black - and the game score from this team's side."
      )} {gettext(
        "Under the score, the match points and game points this team has after that round. A team that is not listed in a round has an empty cell; the bye is scored as a drawn match."
      )}
    </p>
    """
  end

  attr :cell, :any, required: true
  attr :slug, :string, required: true
  attr :teams, :map, required: true

  defp team_round_cell(%{cell: nil} = assigns) do
    ~H"""
    <td class="xt-cell xt-empty">
      <span class="visually-hidden">{gettext("not scheduled in this round")}</span>
    </td>
    """
  end

  defp team_round_cell(assigns) do
    assigns =
      assigns
      |> assign(:opponent, Map.get(assigns.teams, assigns.cell.opponent))
      |> assign(:pending, Tournament.match_postponed_boards(assigns.cell.match))

    ~H"""
    <td class="xt-cell">
      <span class="xt-game">
        <%= if @cell.bye? do %>
          <span class="xt-opp">{gettext("bye")}</span>
        <% else %>
          <a
            :if={@opponent}
            href={~p"/t/#{@slug}/team/#{@cell.opponent}"}
            class="xt-opp"
            title={Tournament.team_label(@opponent)}
            aria-label={"#{@cell.opponent} #{Tournament.team_label(@opponent)}"}
          >{@cell.opponent}</a> <span :if={is_nil(@opponent)} class="xt-opp">?</span>
          <abbr
            :if={@cell.colour}
            class={["xt-colour", colour_class(@cell.colour)]}
            title={colour_word(@cell.colour)}
          >{colour_mark(@cell.colour)}</abbr>
        <% end %>

        <span :if={is_number(@cell.gp)} class="xt-score">
          {number(@cell.gp)}<span :if={is_number(@cell.opp_gp)}>-{number(@cell.opp_gp)}</span>
        </span>

        <span :if={not is_number(@cell.gp)} class="unreported">
          <.said_as words={gettext("not yet reported")}>-</.said_as>
        </span>

        <abbr
          :if={@pending > 0}
          class="xt-postponed"
          title={ngettext("1 board pending", "%{count} boards pending", @pending)}
        ><.said_as words={ngettext("1 board pending", "%{count} boards pending", @pending)}>
          ⏳
        </.said_as></abbr>
      </span>

      <span :if={is_number(@cell.total_mp) and is_number(@cell.total_gp)} class="xt-note xt-running">
        <.said_as words={
          gettext("%{mp} match points, %{gp} game points so far",
            mp: number(@cell.total_mp),
            gp: number(@cell.total_gp)
          )
        }>
          {number(@cell.total_mp)} · {number(@cell.total_gp)}
        </.said_as>
      </span>
    </td>
    """
  end

  @doc """
  The team list: a row per team with its place, match and game points, its
  captain when the arbiter named one, and its roster in board order. See
  `Tournament.team_list/1`.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def team_list_table(assigns) do
    rows = Tournament.team_list(assigns.payload)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:placed?, Enum.any?(rows, & &1.rank))
      |> assign(:captains?, Enum.any?(rows, &Map.get(&1.team, "captain")))
      |> assign(:ratings?, Enum.any?(rows, & &1.rating))
      |> assign(:show, display_rules(assigns.payload))

    ~H"""
    <p :if={@rows == []} class="empty">{gettext("No teams have been published yet.")}</p>

    <div :if={@rows != []} class="scroller">
      <table class="standings team-list" id="team-list">
        <caption class="visually-hidden">
          {gettext("Teams of %{tournament}", tournament: Tournament.name(@payload))}
        </caption>

        <thead>
          <tr>
            <th :if={@placed?} class="num" scope="col">{gettext("#")}</th>

            <th scope="col">{gettext("Team")}</th>

            <th :if={@placed?} class="num" scope="col">{gettext("MP")}</th>

            <th :if={@placed?} class="num" scope="col">{gettext("GP")}</th>

            <th :if={@ratings?} class="num" scope="col">{gettext("Rating")}</th>

            <th :if={@captains?} scope="col">{gettext("Captain")}</th>

            <th scope="col">{gettext("Players")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows} id={"team-#{row.no}"}>
            <td :if={@placed?} class="num rank">{row.rank}</td>

            <th scope="row" class="row-head">
              <a href={~p"/t/#{@slug}/team/#{row.no}"}>{Tournament.team_label(row.team)}</a>
            </th>

            <td :if={@placed?} class="num strong">{number(row.mp)}</td>

            <td :if={@placed?} class="num">{number(row.gp)}</td>

            <td :if={@ratings?} class="num">
              <span :if={is_nil(row.rating)} class="quiet">-</span> {row.rating}
            </td>

            <td :if={@captains?}>{row.team["captain"]}</td>

            <td>
              <span :if={row.roster == []} class="quiet">-</span>
              <%= for {player, at} <- Enum.with_index(row.roster) do %>
                <span :if={at > 0}>, </span>
                <.player_link
                  slug={@slug}
                  no={player["no"]}
                  player={player}
                  show={@show}
                  cards?={@show.player_cards}
                  detail
                />
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  The teams by board: a row per team, a column per board, and in each cell the
  team's player on that board with the points and games they have. See
  `Tournament.team_board_grid/1`.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def team_board_grid_table(assigns) do
    grid = Tournament.team_board_grid(assigns.payload)

    assigns =
      assigns
      |> assign(:boards, grid.boards)
      |> assign(:rows, grid.rows)
      |> assign(:show, display_rules(assigns.payload))

    ~H"""
    <p :if={@boards == []} class="empty">
      {gettext("The board statistics appear here once the standings after round 1 are published.")}
    </p>

    <div :if={@boards != []} class="scroller">
      <table class="standings team-boards" id="team-boards">
        <caption class="visually-hidden">{gettext("Teams by board")}</caption>

        <thead>
          <tr>
            <th scope="col">{gettext("Team")}</th>

            <th :for={board <- @boards} scope="col">
              {gettext("Board %{board}", board: board)}
            </th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows}>
            <th scope="row" class="row-head">
              <a href={~p"/t/#{@slug}/team/#{row.no}"}>{Tournament.team_label(row.team)}</a>
            </th>

            <td :for={board <- @boards}>
              <% entries = Map.get(row.cells, board, []) %>
              <span :if={entries == []} class="quiet">
                <.said_as words={gettext("nobody")}>-</.said_as>
              </span>

              <div :for={entry <- entries} class="team-board-entry">
                <.player_link
                  slug={@slug}
                  no={entry.player["no"]}
                  player={entry.player}
                  show={@show}
                  cards?={@show.player_cards}
                  detail
                />
                <span class="quiet">
                  {number(entry.row["points"])}/{entry.row["games"]}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <p :if={@boards != []} class="footnote">
      {gettext(
        "Each player stands on the board they played most often. Beside the name: points scored out of games played."
      )}
    </p>
    """
  end

  @doc """
  A team's score in a match from the team's own side - its game points
  first - with the postponed-board note and the forfeit decision `match_score/1`
  carries. `match` is read through `visible_match/2`, so nothing shows while
  the round's results are withheld.
  """
  attr :match, :map, required: true
  attr :team_no, :integer, required: true
  attr :results, :boolean, default: true

  def own_match_score(assigns) do
    match = visible_match(assigns.match, assigns.results)

    assigns = assign(assigns, :match, orient_match(match, assigns.team_no))

    ~H"""
    <.match_score match={@match} />
    """
  end

  # `match` with team `no` on the "a" side - the numbers swapped when it was
  # "b" - so a team's own page reads its score first.
  defp orient_match(match, no) do
    if Tournament.match_side(match, no) == :b do
      match
      |> swap_sides("game_points")
      |> swap_sides("match_points")
    else
      match
    end
  end

  defp swap_sides(match, key) do
    case Map.get(match, key) do
      %{"a" => a, "b" => b} = points -> Map.put(match, key, %{points | "a" => b, "b" => a})
      _withheld -> match
    end
  end

  @doc """
  The starting rank: every player, in pairing-number order.

  What the standings page renders in place of the standings table while
  `Tournament.starting_rank?/1` holds - see `standings.html.heex`.

  There is nothing to sort or filter here the way `standings_table/1` offers:
  a field that has not played a round has no points, no rank and no
  tiebreaks to sort by, only the number the arbiter assigned it going in.

  Every column honours the arbiter's own display rules, exactly as the
  standings table and a player's own card do: `rating`, `federation` and
  `club` each hide on their own tick, and the name links to the player's
  card only when `player_cards` is on - the same three ticks
  `Tournament.show?/2` already governs everywhere else.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def starting_rank_table(assigns) do
    payload = assigns.payload
    show = display_rules(payload)
    rows = Tournament.starting_rank(payload)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:show, show)
      # Same rule as the standings: a column only when the field is actually
      # split into categories. This list forgot categories existed, so the
      # arbiter's tick sat there doing nothing until round 1 was paired.
      |> assign(
        :categories?,
        show.category and Enum.any?(rows, &(&1["category"] not in [nil, ""]))
      )

    ~H"""
    <p :if={@rows == []} class="empty">
      {gettext("No players have been published for this tournament yet.")}
    </p>

    <div :if={@rows != []} class="scroller">
      <table class="starting-rank">
        <caption class="visually-hidden">
          {gettext("Standings of %{tournament}, before round 1.",
            tournament: Tournament.name(@payload)
          )}
        </caption>

        <thead>
          <tr>
            <th class="num" scope="col" title={gettext("Starting number")}>{gettext("No")}</th>

            <th scope="col">{gettext("Player")}</th>

            <th :if={@show.rating} class="num" scope="col">{gettext("Rating")}</th>

            <th :if={@show.federation} scope="col">{gettext("Federation")}</th>

            <th :if={@show.club} class="col-club" scope="col">{gettext("Club")}</th>

            <th :if={@show.sex} scope="col">{gettext("Sex")}</th>

            <th :if={@categories?} scope="col">{gettext("Category")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={player <- @rows}>
            <td class="num">{player["no"]}</td>

            <th scope="row" class="row-head">
              <.player_link
                slug={@slug}
                no={player["no"]}
                player={player}
                show={@show}
                cards?={@show.player_cards}
                flag={false}
                detail
              />
            </th>

            <td :if={@show.rating} class="num">{dash(player["rating"])}</td>

            <td :if={@show.federation}>
              <Flags.fed code={player["federation"]} on={@show.flags} />
            </td>

            <td :if={@show.club} class="col-club">{dash(player["club"])}</td>

            <td :if={@show.sex}>{dash(player["sex"])}</td>

            <td :if={@categories?} class="col-cat">{dash(player["category"])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  One tiebreak value on the standings table, openable to the same per-round
  working the player page already shows in full - see `working_tables/1`.

  A plain number unless there is something to open: the tournament has to
  publish this tiebreak's working at all (`working` is keyed by code, empty
  for a tiebreak whose arithmetic is not a per-round sum - Direct Encounter,
  chiefly - or for a tournament that has not published any working), and
  `display.tiebreak_working` has to allow it. That is a finer tick than
  `display.tiebreaks` itself: an arbiter can publish the tiebreak COLUMNS
  while keeping the per-round arithmetic behind them closed, the same
  distinction the schema already draws between a value and its working.

  `<details>`/`<summary>` rather than a hover card or a script-built popover:
  it opens and closes by tap and by keyboard with nothing written here to
  make that true, and it degrades to exactly the plain number underneath it
  the moment either the working is absent or the tick is off - never a
  disclosure triangle with nothing behind it.
  """
  attr :slug, :string, required: true
  attr :players, :map, required: true
  attr :show, :map, default: %{}
  attr :code, :string, required: true
  attr :value, :any, required: true

  attr :label, :string,
    default: nil,
    doc: "the tiebreak's own label, which names the small table inside"

  attr :who, :string,
    default: nil,
    doc: "the player the row is, named in the sheet a phone opens this as"

  attr :key, :string,
    default: nil,
    doc: """
    unique on the page - the player and the column - so the refresher can
    reopen this `<details>` in the fresh HTML if the reader had it open
    """

  attr :working, :map,
    required: true,
    doc: "this ROW's working, from `Tournament.working_for_row/1` - not re-fetched per cell"

  attr :explain?, :boolean, required: true, doc: "`display.tiebreak_working`, resolved once"

  def tiebreak_cell(assigns) do
    # `not is_nil(@value)` matters for the row short of a value - see
    # `Tournament.tiebreak_value/2` - where the working may still carry an
    # entry for a column this particular row sent nothing for. Opening a
    # blank cell to "explain" a number that is not there would be
    # explaining nothing.
    open? =
      assigns.explain? and not is_nil(assigns.value) and
        Map.has_key?(assigns.working, assigns.code)

    assigns =
      assigns
      |> assign(:open?, open?)
      |> assign(:parts, if(open?, do: assigns.working[assigns.code]["parts"], else: []))

    ~H"""
    <details :if={@open?} class="tb-detail" data-detail={@key}>
      <summary>
        {number(@value)} <span class="visually-hidden">{gettext("show how this was reached")}</span>
      </summary>

      <div class="scroller">
        <%!-- On a phone this opens as a sheet over the bottom of the screen,
              not inside the cell (which made the row a quarter of a screen
              tall and pushed every other tie-break out of sight), and the
              sheet needs to say whose number it explains. The table's own
              caption already says it to a screen reader. --%>
        <div class="tb-sheet-head">
          <span aria-hidden="true">
            <strong>{@label}</strong> <span :if={@who} class="quiet">· {@who}</span>
          </span>

          <button type="button" class="tb-sheet-close" data-close-detail>
            {gettext("Close")}
          </button>
        </div>

        <%!-- The column headings are there for a screen reader and hidden
              from the eye, which already has the full table's headings on the
              player's page and needs none inside a cell this small. --%>
        <table class="working-table tb-working">
          <caption :if={@label} class="visually-hidden">{@label}</caption>

          <thead class="tb-working-head">
            <tr>
              <th scope="col"><span class="visually-hidden">{gettext("Rd")}</span></th>

              <th scope="col"><span class="visually-hidden">{gettext("From")}</span></th>

              <th scope="col"><span class="visually-hidden">{gettext("Value")}</span></th>
            </tr>
          </thead>

          <tbody>
            <tr :for={part <- @parts} class={not Tournament.part_counted?(part) && "withheld"}>
              <th scope="row" class="num row-head">{part["round"]}</th>

              <td>
                <.part_source
                  part={part}
                  slug={@slug}
                  player={@players[part["opponent"]]}
                  show={@show}
                />
              </td>

              <td class="num">{number(part["value"])}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    <span :if={not @open?}>{number(@value)}</span>
    """
  end

  # `nil` and `false` are the two values a HEEx attribute omits outright; an
  # empty string is not, so it would print `data-city=""` on the front
  # page's search box - matchable against nothing, and indistinguishable in
  # the DOM from a real empty value nobody would ever type, but worth
  # closing rather than relying on that. Numbers pass through as strings for
  # the same `data-*` attributes; nothing on `index.html.heex` is numeric
  # today, but a caller should not have to know that to reuse this.
  defp data_value(value) when is_number(value), do: to_string(value)
  defp data_value(value) when is_binary(value) and value != "", do: value
  defp data_value(_absent_or_blank), do: nil

  @doc """
  The cross-table: a row per player, a column per published round.

  What every other results site has and this one did not. It answers the
  question the standings and the round pages between them make a reader
  assemble by hand - who did this player actually play, and what happened -
  and it is the first thing an arbiter looks for.

  ## The columns

  Only PUBLISHED rounds, so an arbiter who has posted 1, 2, 3 and 5 gets four
  columns and no gap where 4 would be. That is the opposite of the round
  strip in the masthead, which shows the gap on purpose: a strip is a list of
  what exists, and this is a table of results, where an empty column would
  read as a round nobody turned up to.

  And only rounds the published standings already cover -
  `Tournament.within_standings?/2` again narrows "published" the same way it
  does for `Tournament.crosstable/1` itself, so a round already live but not
  yet folded into the standings beside this grid gets no column here either,
  even though its own page already shows it.

  Each heading links to that round's own page, which is where the boards,
  the ratings and the scores going in are.

  ## The two columns that stay put

  The pairing number and the name are pinned to the left edge while the
  rounds scroll under them. A 450-player, eleven-round grid is wider than
  any screen, and a reader who has scrolled to round 9 without them is
  looking at a wall of numbers belonging to nobody. Everything else about
  the width is `.scroller`'s job - the table scrolls inside its own box and
  the page body never moves sideways.

  ## What a cell is not

  Not the board's result token. `1-0` is a win for one seat and a loss for
  the other, so each cell carries the score of the player whose ROW it is -
  see `OpenResultsWeb.Tournament.crosstable/1`, where the split happens.

  ## The filter bar filters ROWS only

  `filters` (see `OpenResultsWeb.Tournament.Filter.crosstable_rows/3`)
  narrows which players get a row here - never the columns, and never the
  opponent numbers inside a cell: an opponent is named by their overall
  pairing number whether or not that opponent's own row is currently
  shown, exactly as it was before this feature existed. There is no sort
  control on this page - see `crosstable_rows/3`'s own moduledoc for why
  re-ordering these rows at all would fight the reason they are in
  starting-number order in the first place.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :filters, OpenResultsWeb.FilterParams, required: true

  def crosstable_table(assigns) do
    payload = assigns.payload
    all_rows = Tournament.crosstable(payload)
    rows = Filter.crosstable_rows(payload, assigns.filters, all_rows)
    # Published AND no later than the standings beside this page - see
    # `Tournament.within_standings?/2`. `Tournament.crosstable/1` applies the
    # same filter to the same list to build each row's `cells`, so the
    # columns here and the cells there can never disagree about which rounds
    # exist.
    rounds = Tournament.crosstable_rounds(payload)

    show = display_rules(payload)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:empty?, all_rows != [] and rows == [] and rounds != [])
      |> assign(:rounds, rounds)
      |> assign(:show, show)
      |> assign(:bar_categories, Filter.categories(payload))
      |> assign(:bar_clubs, (show.club && Filter.player_values(payload, "club")) || [])
      |> assign(
        :bar_federations,
        (show.federation && Filter.player_values(payload, "federation")) || []
      )
      # A Keizer ladder's "points" are the ladder's own currency and not the
      # sum of the row they would sit beside: player 1 of the fixture has two
      # wins and 17 points. The game score is the number that belongs at the
      # end of a row of results, and Keizer standings carry it separately.
      |> assign(:keizer?, Tournament.keizer?(payload))
      # Only when the arbiter has actually published placings. Two columns of
      # blanks on a tournament that has not ranked anybody yet is noise, and
      # this page is deliberately readable without a standings block at all.
      |> assign(:placings?, Enum.any?(all_rows, &(&1.rank || &1.points || &1.score)))
      # Which empty message applies. Before the first standings are
      # published there is nothing this page may show at all - not "no
      # rounds", which is a different and rarer claim about a tournament
      # that has genuinely posted nothing.
      |> assign(:awaiting_standings?, is_nil(Tournament.after_round(payload)))
      |> assign(:total_players, length(all_rows))

    ~H"""
    <p :if={@rounds == [] or (@rows == [] and not @empty?)} class="empty">
      {if @awaiting_standings?,
        do: gettext("Results appear here once the standings after round 1 are published."),
        else: gettext("No rounds have been published for this tournament yet.")}
    </p>

    <FilterBar.filter_bar
      :if={@rounds != [] and (@rows != [] or @empty?)}
      action={~p"/t/#{@slug}/crosstable"}
      filters={@filters}
      categories={@bar_categories}
      federations={@bar_federations}
      clubs={@bar_clubs}
      sort?={false}
      empty?={@empty?}
      total={@total_players}
      shown={length(@rows)}
      unit={:players}
    />
    <div :if={@rows != [] and @rounds != []} class="scroller xt-scroller">
      <table class="crosstable" data-follow-table={@slug}>
        <caption class="visually-hidden">{gettext("Cross-table")}</caption>

        <thead>
          <tr>
            <th class="num xt-no" scope="col" title={gettext("Starting number")}>{gettext("No")}</th>

            <th class="xt-name" scope="col">{gettext("Player")}</th>

            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>

            <%!-- Named in full: a link called "3" says nothing out of context,
                  and a list of a page's links is exactly out of context. The
                  visible number is still the start of the name, so speech input
                  saying "3" finds it. --%>
            <th :for={n <- @rounds} class="xt-round" scope="col">
              <a
                href={~p"/t/#{@slug}/round/#{n}"}
                title={Tournament.round_heading(@payload, n)}
                aria-label={round_link_label(@payload, n)}
              >
                {Tournament.round_label(@payload, n)}
              </a>
            </th>

            <th :if={@show.standings and @placings?} class="num" scope="col">
              {if(@keizer?, do: gettext("Score"), else: gettext("Points"))}
            </th>

            <th :if={@show.standings and @placings?} class="num" scope="col">{gettext("Rank")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @rows} class={row.uncounted? && "uncounted"}>
            <td class="num xt-no">{row.no}</td>

            <th scope="row" class="xt-name row-head">
              <.player_link
                slug={@slug}
                no={row.no}
                player={row.player}
                show={@show}
                q={@filters.q}
                cards?={@show.player_cards}
                detail
              />
              <span :if={row.uncounted? and @show.standings} class="uncounted-note">
                {gettext("results not counted (withdrawn)")}
              </span>
            </th>

            <td :if={@show.rating} class="num">{dash(row.player["rating"])}</td>
            <.crosstable_cell :for={cell <- row.cells} cell={cell} slug={@slug} show={@show} />
            <td :if={@show.standings and @placings?} class="num strong">
              {number(if(@keizer?, do: row.score, else: row.points))}
            </td>

            <td :if={@show.standings and @placings?} class="num rank">
              {if(row.uncounted?, do: "–", else: row.rank)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <.uncounted_footnote :if={@show.standings and Enum.any?(@rows, & &1.uncounted?)} />
    <%!-- The key. A cross-table is notation before it is a table, and a
          reader who has not seen one before is owed the sentence that turns
          `6w1` into words - in their own language, which is why the two
          letters are spelled out here rather than only sitting in a tooltip
          nobody on a phone can open. --%>
    <p :if={@rows != [] and @rounds != []} class="footnote">
      {gettext(
        "Each cell is one round: the opponent's pairing number, the colour this player had - w for White, b for Black - and the score from this player's own side."
      )} {gettext(
        "A bye or a forfeit is named under the score, because neither is an ordinary result. An empty cell is a round this player is not listed in."
      )} {gettext("An hourglass (⏳) marks a postponed game still to be played, in place of a score.")}
    </p>
    """
  end

  # A round heading's accessible name. It has to CONTAIN the visible label
  # (WCAG 2.5.3), which "Round 3" does for "3" and "Match 2, game 1" does not
  # for "M2-1" - so the label leads whenever the heading does not already
  # carry it.
  defp round_link_label(payload, n) do
    label = Tournament.round_label(payload, n)
    heading = Tournament.round_heading(payload, n)

    if String.contains?(heading, label), do: heading, else: "#{label}, #{heading}"
  end

  # One player's round: who they played, which colour they had and what they
  # scored - or the bye, or the token this server could not read, or nothing.
  attr :cell, :map, required: true
  attr :slug, :string, required: true
  attr :show, :map, default: %{}

  def crosstable_cell(assigns) do
    {token, note} = Tournament.result_parts(assigns.cell.result)

    assigns =
      assigns
      # `token` is only ever rendered for a result this server cannot read -
      # see the score below. A known one is shown as the row player's own
      # points instead, because the token belongs to the board and the cell
      # belongs to one seat of it.
      |> assign(:token, token)
      |> assign(:note, note_label(note))
      |> assign(:cards?, shown?(assigns.show, :player_cards))
      |> assign(
        :postponed_title,
        if(Map.get(assigns.cell, :pending),
          do: pending_words(),
          else: postponed_title(assigns.cell.postponed_date, shown?(assigns.show, :dates))
        )
      )

    ~H"""
    <td
      class={["xt-cell", @cell.kind == :none && "xt-empty"]}
      title={@cell.kind == :none && gettext("no game published for this round")}
    >
      <%= case @cell.kind do %>
        <% :game -> %>
          <span class="xt-game">
            <a
              :if={@cards? && @cell.opponent_no}
              href={~p"/t/#{@slug}/player/#{@cell.opponent_no}"}
              class="player xt-opp"
              data-player={@cell.opponent_no}
            >{@cell.opponent_no}</a>
            <span :if={not @cards? and @cell.opponent_no} class="xt-opp">{@cell.opponent_no}</span>
            <abbr
              :if={@cell.colour}
              class={["xt-colour", colour_class(@cell.colour)]}
              title={colour_word(@cell.colour)}
            >{colour_mark(@cell.colour)}</abbr>
            <span :if={not is_nil(@cell.points)} class="xt-score">{number(@cell.points)}</span>
            <%!-- A token from a newer client, shown as it arrived. Neither
                  seat gets a score from it: guessing which half of
                  `1-0ADJ` belongs to whom would be inventing a result, and
                  printing the whole token in both rows would tell the loser
                  they won. --%>
            <span
              :if={not @cell.postponed and is_nil(@cell.points) and @token}
              class="xt-score xt-token"
            >{@token}</span>
            <%!-- A postponed game still to be played: the same fact a
                  round's own page and a player's card already say in words,
                  here as the compact mark this grid's cells are written in -
                  the hourglass reads the same in every language, unlike a
                  letter drawn from the translated word. The full sentence,
                  with the agreed date when the arbiter's "dates" tick allows
                  it, is on the mark for a mouse and said in words for a
                  screen reader - never only in the title, which a touch
                  screen cannot open. --%>
            <abbr
              :if={is_nil(@cell.points) and @cell.postponed}
              class="xt-postponed"
              title={@postponed_title}
            ><.said_as words={@postponed_title}>⏳</.said_as></abbr>
            <span
              :if={is_nil(@cell.points) and is_nil(@token) and not @cell.postponed}
              class="unreported"
              title={gettext("not yet reported")}
            ><.said_as words={gettext("not yet reported")}>-</.said_as></span>
          </span>

          <%!-- Forfeit and unrated, said in words under the score. A forfeit
                is worth its point and is still not a game that was played,
                and this is the one place on the site where the difference has
                to survive being one character wide. --%>
          <span :if={@note} class="xt-note">{@note}</span>
        <% :bye -> %>
          <span class="xt-game">
            <span class="xt-score">{number(@cell.points)}</span>
          </span>

          <%!-- The arbiter's own word for it, and their own value beside it.
                A bare `1` in this column would be indistinguishable from a
                win. The vacated seat's result token is deliberately not
                repeated here - "seat vacated" already says the game was not
                played, which is the only thing the token was carrying. --%>
          <span class="xt-note">{bye_kind(@cell.bye)}</span>
        <% _nothing -> %>
          <%!-- A published round this player is not listed in: unpaired, or a
                board the arbiter hid. The payload cannot tell the two apart -
                a hidden board is absent rather than flagged - so the cell
                says nothing rather than choosing. Empty and not a zero: a
                zero is a game somebody lost. Empty to the eye, that is: a
                screen reader would otherwise say "blank" and a touch screen
                cannot show the title. --%>
          <span class="visually-hidden">{gettext("no game published for this round")}</span>
      <% end %>
    </td>
    """
  end

  # The colour mark, and the word behind it.
  #
  # `w` and `b` are NOT translated, which is a decision rather than an
  # oversight. They are the notation a TRF file, a printed pairing sheet and
  # every other results site already use, so an arbiter checking this page
  # against their own file reads the same two letters in every language.
  # Translating them would also collide across languages rather than merely
  # differ: French `b` is blancs and English `b` is black, so the same letter
  # would mean opposite things on two versions of one page.
  #
  # The word itself is on the mark as an `<abbr title>`, and the footnote
  # under the table spells both letters out in the reader's own language -
  # because a tooltip is not available to somebody reading this on a phone.
  defp colour_mark(:white), do: "w"
  defp colour_mark(:black), do: "b"

  defp colour_word(:white), do: gettext("White")
  defp colour_word(:black), do: gettext("Black")

  defp colour_class(:white), do: "xt-white"
  defp colour_class(:black), do: "xt-black"

  @doc """
  One round's boards.

  Only the boards that were published are here, because a board the arbiter
  hid was withheld when the document was built. There is no filtering to
  forget and nothing on the server to leak.

  ## The filter bar

  A board STAYS in the table when either seat's player matches the active
  filters - `Filter.round_boards/3` decides that per board and says which
  seat(s) matched - because hiding half a board while leaving the other
  seat's opponent unexplained would be worse than showing the whole board
  with the match picked out. A non-matching seat renders exactly as
  before; a matching one gets `.pairing-match` (a visible mark, not colour
  alone) and `aria-current="true"`, so a screen reader hears which seat -
  or both - answered the search. There is no sort control here: see
  `Filter.round_boards/3`'s own moduledoc.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true
  attr :filters, OpenResultsWeb.FilterParams, required: true

  def pairings_table(assigns) do
    show = display_rules(assigns.payload)
    all_boards = Tournament.boards(assigns.round)
    tagged = Filter.round_boards(assigns.payload, assigns.filters, all_boards)
    shown = Enum.filter(tagged, fn {_board, tag} -> tag.shown? end)

    assigns =
      assigns
      |> assign(:tagged, shown)
      |> assign(:total_boards, length(all_boards))
      |> assign(:empty?, all_boards != [] and shown == [])
      |> assign(:show, show)
      |> assign(:results?, Tournament.results_public?(assigns.round))
      |> assign(:bar_categories, Filter.categories(assigns.payload))
      |> assign(:bar_clubs, (show.club && Filter.player_values(assigns.payload, "club")) || [])
      |> assign(
        :bar_federations,
        (show.federation && Filter.player_values(assigns.payload, "federation")) || []
      )
      |> assign(:bar_teams, Filter.team_options(assigns.payload))
      # The points each player carried INTO this round, which is what a
      # pairing list means by score and what explains why these two are on
      # this board. Their points after it are on the standings.
      |> assign(:scores, Tournament.scores_before(assigns.payload, assigns.round["number"]))
      |> assign(:gaps, Tournament.score_gaps(assigns.payload, assigns.round["number"]))
      |> assign(:teams, Tournament.teams_by_no(assigns.payload))
      |> assign(:groups, board_groups(assigns.round, shown))
      # Bd, rating, points going in, then the seats: the columns a match's
      # header line has to span.
      |> assign(
        :span,
        4 + if(show.rating, do: 2, else: 0) + if(show.pairing_scores, do: 2, else: 0)
      )

    ~H"""
    <p :if={@empty? or @tagged == []} class="empty">
      {if @empty?,
        do: gettext("No players match these filters."),
        else: gettext("No boards were published for this round.")}
      <a :if={@empty?} href={~p"/t/#{@slug}/round/#{@round["number"]}"}>{gettext("Clear filters")}</a>
    </p>
    <.follow_pin :if={@tagged != []} slug={@slug} on={@show.player_cards} />
    <FilterBar.filter_bar
      :if={@tagged != [] or @empty?}
      action={~p"/t/#{@slug}/round/#{@round["number"]}"}
      filters={@filters}
      categories={@bar_categories}
      federations={@bar_federations}
      clubs={@bar_clubs}
      teams={@bar_teams}
      sort?={false}
      total={@total_boards}
      shown={length(@tagged)}
      unit={:boards}
    />
    <div :if={@tagged != []} class="scroller">
      <table id="pairings" class="pairings">
        <caption class="visually-hidden">
          {Tournament.round_heading(@payload, @round["number"])}
        </caption>

        <thead>
          <tr>
            <th class="num col-bd" scope="col">{gettext("Bd")}</th>

            <th :if={@show.rating} class="num col-rating" scope="col">{gettext("Elo")}</th>

            <th
              :if={@show.pairing_scores}
              class="num col-pts"
              scope="col"
              title={gettext("Points going into this round")}
            >
              {gettext("Pts")}
            </th>

            <th scope="col">{gettext("White")}</th>

            <th class="num col-result" scope="col">{gettext("Result")}</th>

            <th scope="col">{gettext("Black")}</th>

            <th
              :if={@show.pairing_scores}
              class="num col-pts"
              scope="col"
              title={gettext("Points going into this round")}
            >
              {gettext("Pts")}
            </th>

            <th :if={@show.rating} class="num col-rating" scope="col">{gettext("Elo")}</th>
          </tr>
        </thead>

        <%!-- One `tbody` per match in a team round, with the match's header
              line as its first row; an individual round is a single `tbody`
              and no header. Boards keep the order the arbiter set. --%>
        <tbody :for={group <- @groups}>
          <tr :if={group.match} class="match-head">
            <th colspan={@span} scope="rowgroup" id={group.anchor}>
              <% match = visible_match(group.match, @results?) %>
              <span class="match-head-no">{gettext("Match %{number}", number: group.match["number"])}</span>
              <.team_link slug={@slug} teams={@teams} no={group.match["team_a"]} />
              <span class="match-head-score">
                <.match_score match={match} />
              </span>
              <.team_link slug={@slug} teams={@teams} no={group.match["team_b"]} />
              <.forfeit_decision match={match} teams={@teams} />
            </th>
          </tr>

          <%!-- The anchor `/t/:slug/player/:no/board` lands on - see
                `TournamentController.board/2`. --%>
          <tr
            :for={{board, tag, k} <- group.rows}
            id={is_integer(board["board"]) && "board-#{board["board"]}"}
          >
            <th scope="row" class="num row-head col-bd">{k || Tournament.board_label(board)}</th>

            <td :if={@show.rating} class="num col-rating">{rating(@players, board["white"])}</td>

            <td :if={@show.pairing_scores} class="num col-pts">
              <.score points={@scores[board["white"]]} reason={@gaps[board["white"]]} />
            </td>

            <td class={seat_class(:white, tag.white?)} aria-current={tag.white? && "true"}>
              <.player_link
                slug={@slug}
                no={board["white"]}
                player={@players[board["white"]]}
                show={@show}
                q={@filters.q}
                cards?={@show.player_cards}
                detail
              />
              <span :if={tag.white?} class="visually-hidden">{gettext("matches your filter")}</span>
            </td>

            <td class="num col-result">
              <.result
                token={@results? && board["result"]}
                postponed={Tournament.postponed?(board)}
                pending={Tournament.pending?(board)}
                postponed_date={postponed_date(@show, board)}
              />
            </td>

            <td class={seat_class(:black, tag.black?)} aria-current={tag.black? && "true"}>
              <.player_link
                slug={@slug}
                no={board["black"]}
                player={@players[board["black"]]}
                show={@show}
                q={@filters.q}
                cards?={@show.player_cards}
                detail
              />
              <span :if={tag.black?} class="visually-hidden">{gettext("matches your filter")}</span>
            </td>

            <td :if={@show.pairing_scores} class="num col-pts">
              <.score points={@scores[board["black"]]} reason={@gaps[board["black"]]} />
            </td>

            <td :if={@show.rating} class="num col-rating">{rating(@players, board["black"])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # A player's rating, or the dash - one short call, because the pairing
  # list prints two of these on each of five hundred boards.
  defp rating(players, no), do: dash(players[no]["rating"])

  # A seat cell's classes: `seat` and its colour for the phone layout (which
  # stacks White over Black - see `.pairings` in app.css), the match mark
  # when the filter bar picked this seat out.
  defp seat_class(colour, true), do: ["seat", "seat-#{colour}", "pairing-match"]
  defp seat_class(colour, _matched), do: ["seat", "seat-#{colour}"]

  # A team round's boards grouped under their matches, in the order the
  # boards are listed: `%{match:, anchor:, rows: [{board, tag, k}]}`, where
  # `k` is the board's place inside its match. A new group starts whenever
  # the match changes, so a board listed out of place (a fixed table, a
  # vacated seat) is not folded into the wrong match; only the first group of
  # a match carries its anchor, `match-N`, which the matches table links to.
  # An individual round is one group with no match and no `k`.
  defp board_groups(round, tagged) do
    in_match = Tournament.board_matches(round)

    {groups, _seen} =
      Enum.reduce(tagged, {[], MapSet.new()}, fn {board, tag}, {groups, seen} ->
        case Map.get(in_match, board["board"]) do
          nil ->
            {add_to_group(groups, nil, nil, {board, tag, nil}), seen}

          %{match: match, k: k} ->
            number = match["number"]
            anchor = if MapSet.member?(seen, number), do: nil, else: "match-#{number}"
            {add_to_group(groups, match, anchor, {board, tag, k}), MapSet.put(seen, number)}
        end
      end)

    groups |> Enum.reverse() |> Enum.map(&%{&1 | rows: Enum.reverse(&1.rows)})
  end

  defp add_to_group([%{match: current} = group | rest], match, _anchor, row)
       when current == match,
       do: [%{group | rows: [row | group.rows]} | rest]

  defp add_to_group(groups, match, anchor, row),
    do: [%{match: match, anchor: anchor, rows: [row]} | groups]

  # A match as the page may show it: while the round's results are withheld,
  # `match_score/1` and `forfeit_decision/1` must never see the real numbers.
  defp visible_match(match, true = _results?), do: match

  defp visible_match(match, _withheld),
    do: Map.drop(match, ~w(game_points match_points forfeit_decision))

  @doc """
  One round's matches, "Team A 2½ - 1½ Team B", one line each, the match
  number linking to that match's boards in the pairing list below
  (`pairings_table/1` groups a team round's boards under their matches - the
  boards are listed once, there). Renders nothing when the round has no
  `matches` (an individual tournament - see `Tournament.matches/1`).

  Withheld exactly like `pairings_table/1`'s own boards: the two teams
  always show, and the score is blank while the round's results are not
  public (`Tournament.results_public?/1`) or the match itself is not yet
  decided.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def matches_table(assigns) do
    payload = assigns.payload
    matches = Tournament.matches(assigns.round)
    teams = Tournament.teams_by_no(payload)
    results? = Tournament.results_public?(assigns.round)

    assigns =
      assigns
      |> assign(:matches, matches)
      |> assign(:teams, teams)
      |> assign(:results?, results?)
      |> assign(:show, display_rules(payload))

    ~H"""
    <div :if={@matches != []} class="scroller">
      <table class="matches">
        <caption class="visually-hidden">
          {gettext("Matches, %{round}", round: Tournament.round_heading(@payload, @round["number"]))}
        </caption>

        <thead>
          <tr>
            <th scope="col">{gettext("Match")}</th>

            <th scope="col">{gettext("Team A")}</th>

            <th class="num" scope="col">{gettext("Score")}</th>

            <th scope="col">{gettext("Team B")}</th>
          </tr>
        </thead>

        <tbody>
          <%= for match <- @matches do %>
            <%!-- Redacted rather than gated: while a round's results are
                  withheld, `match_score/1` and `forfeit_decision/1` must
                  never see the real numbers, because the column that used to
                  hide is now always on the page. --%> <% visible_match =
              visible_match(match, @results?) %>
            <tr>
              <th scope="row" class="num row-head">
                <a :if={not match["bye"]} href={"#match-#{match["number"]}"}>{match["number"]}</a>
                <span :if={match["bye"]}>{match["number"]}</span>
              </th>

              <%= if match["bye"] do %>
                <td colspan="3">
                  <.team_link slug={@slug} teams={@teams} no={match["team_a"]} /> {gettext(
                    "has the bye"
                  )}
                  <%!-- A team Swiss's bye is scored as a drawn match (C.04.6 1.4);
                        a round robin's carries no match points at all. --%>
                  <span
                    :if={
                      @results? and is_map(match["match_points"]) and
                        is_number(match["match_points"]["a"])
                    }
                    class="quiet"
                  >
                    ({gettext("scored as a drawn match")})
                  </span>
                </td>
              <% else %>
                <td class={match_white?(match, :a) && "pairing-match"}>
                  <.team_link slug={@slug} teams={@teams} no={match["team_a"]} />
                </td>

                <td class="num">
                  <.match_score match={visible_match} />
                  <.forfeit_decision match={visible_match} teams={@teams} />
                </td>

                <td class={match_white?(match, :b) && "pairing-match"}>
                  <.team_link slug={@slug} teams={@teams} no={match["team_b"]} />
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp match_white?(match, :a), do: match["board1_white_team"] == match["team_a"]
  defp match_white?(match, :b), do: match["board1_white_team"] == match["team_b"]

  @doc """
  A match's game points, and its match points when there are any.

  While any of the match's boards is a postponed game still to be played
  (`matches[].postponed_boards`), both numbers are OpenPairings' provisional
  ones - each postponed board counted as a draw - and the score says how many
  boards are still pending rather than reading as final. Nothing is
  recomputed: the numbers shown are the ones that arrived.
  """
  attr :match, :map, required: true

  def match_score(assigns) do
    assigns = assign(assigns, :pending, Tournament.match_postponed_boards(assigns.match))

    ~H"""
    <%= case {@match["game_points"], @match["match_points"]} do %>
      <% {nil, _} -> %>
        <span class="quiet">{gettext("not yet published")}</span>
      <% {%{"a" => a, "b" => b}, mp} -> %>
        {number(a)} - {number(b)}<span :if={@pending > 0} class="match-pending">, {ngettext(
          "1 board pending",
          "%{count} boards pending",
          @pending
        )}</span>
        <span :if={mp} class="quiet">
          ({number(mp["a"])}-{number(mp["b"])} {gettext("MP")})
        </span>
      <% _other -> %>
        <span class="quiet">-</span>
    <% end %>
    """
  end

  @doc """
  "Awarded to Team A by the arbiter", for a match the arbiter forfeited by
  decision (`Tournament.forfeit_decision_to/1`), and "Neither team turned
  up" for a double forfeit (`Tournament.double_forfeit?/1`). Nothing for any
  other match.

  Shown only beside match points that are shown: OpenPairings sends the
  decision exactly when it sends the match points, and a page that met one
  without the other would be reading a payload that broke that promise, so
  it says nothing rather than half a result. The match's boards stay listed
  as they are - a decision taken after games were played leaves those games
  on the page.
  """
  attr :match, :map, required: true
  attr :teams, :map, required: true

  def forfeit_decision(assigns) do
    to = Tournament.forfeit_decision_to(assigns.match)
    shown? = to != nil and is_map(assigns.match["match_points"])

    assigns =
      assigns
      |> assign(:shown?, shown?)
      |> assign(:team, to && Map.get(assigns.teams, to))

    assigns =
      assign(
        assigns,
        :double?,
        Tournament.double_forfeit?(assigns.match) and is_map(assigns.match["match_points"])
      )

    ~H"""
    <span :if={@shown?} class="match-forfeit">
      {gettext("Awarded to %{team} by the arbiter",
        team: if(@team, do: Tournament.team_label(@team), else: gettext("?"))
      )}
    </span>

    <span :if={@double?} class="match-forfeit">
      {gettext("Neither team turned up: both lost by forfeit")}
    </span>
    """
  end

  attr :slug, :string, required: true
  attr :teams, :map, required: true
  attr :no, :any, required: true

  def team_link(assigns) do
    ~H"""
    <%= if @no && Map.has_key?(@teams, @no) do %>
      <a href={~p"/t/#{@slug}/team/#{@no}"}>{Tournament.team_label(@teams[@no])}</a>
    <% else %>
      <span class="quiet">{gettext("?")}</span>
    <% end %>
    """
  end

  @doc """
  The "Live" label for a round whose results are public and still coming
  in, with how many are in. Counting, never calculating: boards with a
  result against boards in the round. Renders nothing for a round that is
  not live - finished, or withheld.
  """
  attr :round, :map, required: true

  def live_marker(assigns) do
    {reported, total} = Tournament.results_progress(assigns.round)
    assigns = assign(assigns, reported: reported, total: total)

    ~H"""
    <span :if={Tournament.live_round?(@round)} class="live-marker">
      <span class="live-badge">{gettext("Live")}</span>
      <span class="quiet">
        {gettext("%{reported} of %{total} results", reported: @reported, total: @total)}
      </span>
    </span>
    """
  end

  @doc """
  The round's "Proof" pill: a disclosure, no script, that says which program
  paired the round and offers the engine's pairing proof as a file, with
  its digest and how to check it. Renders nothing for a round whose
  snapshot announces no proof - an older round, a round paired by hand, a
  field too large to prove - so a page without proofs looks exactly as it
  always did.
  """
  attr :round, :map, required: true
  attr :slug, :string, required: true

  def round_proof(assigns) do
    proof = Tournament.round_proof(assigns.round)

    assigns =
      assign(assigns,
        proof: proof,
        engine: Tournament.round_engine(assigns.round),
        bytes: proof && proof["bytes"]
      )

    ~H"""
    <details :if={@proof} class="round-proof" id={"round-proof-#{@round["number"]}"}>
      <summary class="round-proof-trigger">
        <.icon name="hero-check-badge-mini" class="round-proof-icon" />
        {gettext("Proof")}
      </summary>
      <div class="round-proof-panel">
        <p :if={@engine} class="round-proof-engine">
          {gettext("Paired by %{engine}", engine: engine_label(@engine))}
        </p>
        <p class="quiet">
          {gettext(
            "The engine's own proof that every matching it used for this round was optimal, checkable with a verifier that shares none of its code."
          )}
        </p>
        <a
          class="round-proof-download"
          id={"round-proof-download-#{@round["number"]}"}
          href={~p"/t/#{@slug}/round/#{@round["number"]}/proof"}
          download
        >
          <.icon name="hero-arrow-down-tray-mini" class="round-proof-icon" />
          {gettext("Download proof")}
          <span :if={is_integer(@bytes)} class="quiet">({kilobytes(@bytes)})</span>
        </a>
        <p class="round-proof-digest quiet">
          SHA-256 <code>{@proof["sha256"]}</code>
        </p>
      </div>
    </details>
    """
  end

  defp engine_label({name, nil}), do: engine_name(name)
  defp engine_label({name, version}), do: "#{engine_name(name)} #{version}"

  defp engine_name("ainalrami"), do: "Ainalrami"
  defp engine_name(name), do: name

  defp kilobytes(bytes) when bytes < 1_000_000, do: "#{max(1, div(bytes + 999, 1000))} kB"

  defp kilobytes(bytes),
    do: "#{:erlang.float_to_binary(bytes / 1_000_000, decimals: 1)} MB"

  @doc """
  One line per round whose results the arbiter has not published, said once
  on the page rather than repeated in every row of the result column - which
  stays on the page regardless, its cells all reading as unreported (see
  `pairings_table/1`).
  """
  attr :rounds, :list, required: true, doc: "round numbers"
  attr :payload, :map, required: true

  def withheld_results_note(assigns) do
    ~H"""
    <p :for={n <- @rounds} class="footnote results-withheld">
      {gettext("Results for round %{round} are not published yet.",
        round: Tournament.round_label(@payload, n)
      )}
    </p>
    """
  end

  @doc """
  One line saying the standings are provisional, when a postponed game in the
  rounds they cover is still to be played - `standings.provisional` and
  `standings.postponed_games`. The table counts each such game as the
  snapshot's `postponed_as` says (`Tournament.postponed_valuation/1`) - a draw
  unless the rules say otherwise - until it is played, so it is right for now
  and will move; the line says both. A snapshot that does not say how they are
  valued gets the draw wording it always had. Nothing when the standings are
  final.
  """
  attr :payload, :map, required: true

  def provisional_standings_note(assigns) do
    {provisional?, count} = Tournament.standings_provisional(assigns.payload)

    assigns =
      assign(assigns,
        provisional?: provisional?,
        count: count,
        unreported?: Tournament.standings_unreported?(assigns.payload),
        valuation: valuation_phrase(Tournament.postponed_valuation(assigns.payload))
      )

    ~H"""
    <p :if={@provisional?} id="standings-provisional" class="footnote standings-provisional">
      <%= cond do %>
        <%!-- Some of the games are pending boards (`boards[].pending`):
              not postponed by anybody, just without a result in a round
              the tournament has moved past - so they are not called
              postponed. `standings_unreported?/1` is only ever true with a
              count. --%>
        <% @unreported? and is_nil(@valuation) -> %>
          {ngettext(
            "Provisional: 1 game has no result yet and counts as a draw until it has.",
            "Provisional: %{count} games have no result yet and count as draws until they have.",
            @count
          )}
        <% @unreported? -> %>
          {ngettext(
            "Provisional: 1 game has no result yet and counts %{valuation} until it has.",
            "Provisional: %{count} games have no result yet and count %{valuation} until they have.",
            @count,
            valuation: @valuation
          )}
        <% is_nil(@valuation) and @count -> %>
          {ngettext(
            "Provisional: 1 postponed game is still to be played and counts as a draw until it is.",
            "Provisional: %{count} postponed games are still to be played and count as draws until they are.",
            @count
          )}
        <% is_nil(@valuation) -> %>
          {gettext(
            "Provisional: postponed games are still to be played and count as draws until they are."
          )}
        <% @count -> %>
          {ngettext(
            "Provisional: 1 postponed game is still to be played and counts %{valuation} until it is.",
            "Provisional: %{count} postponed games are still to be played and count %{valuation} until they are.",
            @count,
            valuation: @valuation
          )}
        <% true -> %>
          {gettext(
            "Provisional: postponed games are still to be played and count %{valuation} until they are.",
            valuation: @valuation
          )}
      <% end %>
    </p>
    """
  end

  # How the standings count the postponed games, as a phrase that follows
  # "counts"/"count"; `nil` for the draw wording (and for a snapshot that does
  # not say).
  defp valuation_phrase(:draw), do: nil
  defp valuation_phrase(:unknown), do: nil
  defp valuation_phrase({:uniform, ["draw", "draw"]}), do: nil
  defp valuation_phrase({:uniform, ["loss", "loss"]}), do: gettext("as a loss for both players")
  defp valuation_phrase({:uniform, ["win", "win"]}), do: gettext("as a win for both players")

  defp valuation_phrase({:uniform, ["loss", "win"]}),
    do: gettext("as a win for one player and a loss for the other")

  defp valuation_phrase({:uniform, ["draw", "win"]}),
    do: gettext("as a win for one player and a draw for the other")

  defp valuation_phrase({:uniform, ["draw", "loss"]}),
    do: gettext("as a draw for one player and a loss for the other")

  defp valuation_phrase(:mixed), do: gettext("as they were valued when postponed")

  @doc """
  A running score, or a marker where it cannot be known.

  A blank would read as zero. `Tournament.scores_before/2` returns `nil` the
  moment an earlier round is unpublished, withheld or unfinished, and saying
  so is the point - a total that stepped over a gap would be a number the
  arbiter never agreed to.
  """
  attr :points, :any, default: nil
  # Why `points` is unknown, when the caller knows: `:postponed` for a game
  # still to be played that the snapshot cannot price, anything else for the
  # general "an earlier round is not public".
  attr :reason, :atom, default: nil

  def score(assigns) do
    assigns =
      assign(
        assigns,
        :words,
        if(assigns.reason == :postponed,
          do: gettext("a postponed game has not been played yet"),
          else: gettext("an earlier round is not public")
        )
      )

    ~H"""
    <span :if={is_nil(@points)} class="unreported" title={@words}>
      <.said_as words={@words}>-</.said_as>
    </span>
    <span :if={not is_nil(@points)}>{number(@points)}</span>
    """
  end

  @doc """
  A mark that means something only to the eye - a hyphen for "no result",
  "not public" - with the words behind it said to a screen reader instead.

  The words used to live only in a `title`, which a screen reader does not
  read on a plain span and a phone cannot show at all, so the hyphen was
  read out as "dash", or skipped, and the reason was lost. The `title` stays
  where it was, for a mouse.
  """
  attr :words, :string, required: true
  slot :inner_block, required: true

  def said_as(assigns) do
    ~H"""
    <span aria-hidden="true">{render_slot(@inner_block)}</span>
    <span class="visually-hidden">{@words}</span>
    """
  end

  @doc """
  A round's byes.

  The kind and the value both come from the payload. The value is
  configurable, so a half-point bye worth something other than a half point is
  the arbiter's decision to state and not this app's to assume.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def byes_table(assigns) do
    assigns =
      assigns
      |> assign(:byes, Tournament.byes(assigns.round))
      |> assign(:show, display_rules(assigns.payload))

    ~H"""
    <div :if={@byes != []} class="scroller">
      <table class="byes">
        <caption class="visually-hidden">{gettext("Byes")}</caption>

        <thead>
          <tr>
            <th scope="col">{gettext("Player")}</th>

            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>

            <th scope="col">{gettext("Bye")}</th>

            <th class="num" scope="col">{gettext("Points")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={bye <- @byes}>
            <%!-- `detail` and an Elo column, matching the boards table above.
                  Without them a player sitting out lost their title and rating
                  from a page that shows both for everybody who is playing. --%>
            <th scope="row" class="row-head">
              <.player_link
                slug={@slug}
                no={bye["player"]}
                player={@players[bye["player"]]}
                show={@show}
                cards?={@show.player_cards}
                detail
              />
            </th>

            <td :if={@show.rating} class="num">{dash(@players[bye["player"]]["rating"])}</td>

            <%!-- The result only exists on a vacated seat, where the points
                  alone would not explain themselves: "0" against a name reads
                  as a zero-point bye until it says the game was forfeited. --%>
            <td>
              {bye_kind(bye["kind"])}
              <span :if={bye["result"]} class="quiet">(<.result token={bye["result"]} />)</span>
            </td>

            <td class="num">{number(bye["points"])}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  A round's boards, projected: readable from across a room, and left to the
  script below to page through when they do not all fit on the screen in
  front of them.

  Reached via `?display=1` on the round's own URL, so this is the same
  document as `pairings_table/1` above and not a separate page - see
  `TournamentController.round/2`. Two differences from the ordinary table:
  every name is plain text rather than a link, because a tap here pauses the
  cycle rather than following it somewhere; and there is no rating or score
  column, because a hall screen must never need to scroll sideways to find a
  board, and neither serves what a projector is actually for - finding your
  name and seeing who you are playing.

  Byes are listed underneath, statically - useful to a player checking
  whether they are even on a board, and deliberately NOT part of the cycle,
  same as standings: nobody watches a hall screen for their own bye.

  The pagination itself is client-side JavaScript, and has to be: this is a
  plain controller with no socket, and a hall screen must keep cycling
  through a venue's wifi wobbling, not stop the moment it does.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :round, :map, required: true
  attr :players, :map, required: true

  def projector_round(assigns) do
    assigns =
      assigns
      |> assign(:boards, Tournament.boards(assigns.round))
      |> assign(:show, display_rules(assigns.payload))
      |> assign(:results?, Tournament.results_public?(assigns.round))

    ~H"""
    <section
      class="projector"
      data-projector
      aria-label={gettext("Round pairings, projector view")}
    >
      <.finished_marker payload={@payload} />
      <header class="projector-head">
        <h1>{Tournament.name(@payload)}</h1>

        <%!-- Gated for the same reason as the ordinary round heading: a hall
              screen is the most public surface this app has, and the date it
              shows is the round's, which the "dates" tick covers. --%>
        <p class="projector-round">
          {Tournament.round_heading(@payload, @round["number"])}
          <span :if={@show.dates && @round["date"]}>{date(@round["date"])}</span>
        </p>
      </header>

      <p :if={@boards == []} class="empty">{gettext("No boards were published for this round.")}</p>

      <.withheld_results_note
        rounds={if @results?, do: [], else: [@round["number"]]}
        payload={@payload}
      />
      <div :if={@boards != []} class="projector-table-wrap" id="projector-boards">
        <table class="pairings projector-pairings">
          <caption class="visually-hidden">
            {Tournament.round_heading(@payload, @round["number"])}
          </caption>

          <thead>
            <tr>
              <th class="num" scope="col">{gettext("Bd")}</th>

              <th scope="col">{gettext("White")}</th>

              <th class="num" scope="col">{gettext("Result")}</th>

              <th scope="col">{gettext("Black")}</th>
            </tr>
          </thead>

          <tbody>
            <tr :for={board <- @boards}>
              <th scope="row" class="num row-head">{Tournament.board_label(board)}</th>

              <td>
                <.player_link
                  slug={@slug}
                  no={board["white"]}
                  player={@players[board["white"]]}
                  show={@show}
                  cards?={false}
                  detail
                />
              </td>

              <td class="num">
                <.result
                  token={@results? && board["result"]}
                  postponed={Tournament.postponed?(board)}
                  pending={Tournament.pending?(board)}
                  postponed_date={postponed_date(@show, board)}
                />
              </td>

              <td>
                <.player_link
                  slug={@slug}
                  no={board["black"]}
                  player={@players[board["black"]]}
                  show={@show}
                  cards?={false}
                  detail
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Hidden until the script decides otherwise. A counter reading "1 of
            1" only tells a viewer that nobody checked, so this stays out of
            the accessibility tree entirely whenever every board already fits. --%>
      <%!-- The counter's wording is an attribute rather than text because the
            script rewrites it on every turn of the cycle, and a string built
            in JavaScript is a string outside the catalogue. --%>
      <div
        :if={@boards != []}
        class="projector-foot"
        id="projector-foot"
        data-page-label={gettext("Page %{page} of %{count}", page: "{page}", count: "{count}")}
        hidden
      >
        <span class="projector-page" id="projector-page"></span>
        <span class="projector-paused" id="projector-paused" hidden>
          {gettext("Paused - tap or press space to resume")}
        </span>

        <%!-- Not decoration: someone looking for board 47 needs to know their
              page is coming and roughly when, or a rotating screen is worse
              than a still one. --%>
        <span class="projector-bar" id="projector-bar" aria-hidden="true">
          <span class="projector-bar-fill" id="projector-bar-fill"></span>
        </span>
      </div>

      <section
        :if={Tournament.show?(@payload, "byes") and Tournament.byes(@round) != []}
        class="projector-byes"
      >
        <h2>{gettext("Byes")}</h2>
        <.byes_table slug={@slug} round={@round} players={@players} payload={@payload} />
      </section>
    </section>

    {OpenResultsWeb.InlineScripts.tag("projector")}
    """
  end

  @doc """
  One player's game in each round the published standings cover.

  Every round IN THAT RANGE gets a row, including the ones the arbiter has
  not published, so the gaps are visible instead of being closed up. A round
  beyond the range - already live, with a real board and a real result -
  gets no row at all: `@card` never carries one, because `Tournament.card/2`
  stops at the same boundary `Tournament.within_standings?/2` sets for the
  cross-table. The caller shows this table only when `@card` is non-empty -
  see `player.html.heex`.
  """
  attr :slug, :string, required: true
  attr :card, :list, required: true
  attr :payload, :map, required: true

  def card_table(assigns) do
    show = display_rules(assigns.payload)

    assigns =
      assigns
      |> assign(:show, show)
      # Each opponent's own total, so a reader can see the strength of the
      # field somebody actually played - the same column the arbiter's own
      # Players Card carries, and the reason a 4/5 against the top boards
      # reads differently from 4/5 against the bottom.
      |> assign(:totals, Tournament.standings_points(assigns.payload))
      # `:game` rows span the same columns as the placeholders below them, so
      # the two have to agree. Counted rather than written out, because they
      # move with the arbiter's ticks.
      |> assign(
        :game_span,
        3 + count_if([show.federation, show.title, show.rating, show.standings])
      )

    ~H"""
    <div class="scroller">
      <table class="card">
        <caption class="visually-hidden">{gettext("Round by round")}</caption>

        <thead>
          <tr>
            <th class="num" scope="col">{gettext("Rd")}</th>

            <th class="col-colour" scope="col">{gettext("Colour")}</th>

            <th class="num col-no" scope="col" title={gettext("Opponent's pairing number")}>
              {gettext("No")}
            </th>

            <th :if={@show.federation} class="col-fed" scope="col">{gettext("Nat")}</th>

            <th :if={@show.title} class="col-title" scope="col">{gettext("Tit")}</th>

            <th class="col-opponent" scope="col">{gettext("Opponent")}</th>

            <th :if={@show.rating} class="num" scope="col">{gettext("Elo")}</th>

            <%!-- Gated on the STANDINGS tick, which the rest of this table is
                  not. The tick's own hint says why: "some arbiters withhold
                  standings until the last round is in". These are each
                  opponent's running total, read out of `standings.rows` - so
                  a reader who walks the cards reconstructs exactly the league
                  table the arbiter is withholding, one player at a time.
                  The cross-table hides its rank and points columns on the
                  same tick, and the two have to agree. --%>
            <th
              :if={@show.standings}
              class="num col-opp-pts"
              scope="col"
              title={gettext("Opponent's total")}
            >
              {gettext("Pts")}
            </th>

            <th class="num" scope="col">{gettext("Result")}</th>

            <th class="num" scope="col">{gettext("Score")}</th>
          </tr>
        </thead>

        <tbody>
          <tr :for={entry <- @card} class={entry.kind == :unpublished && "withheld"}>
            <th scope="row" class="num row-head">{entry.round}</th>

            <%= case entry.kind do %>
              <% :game -> %>
                <%!-- The word for a reader, the square for a phone, which has
                      room for the square only - see `.colour-mark`. --%>
                <td class="col-colour">
                  <span class={["colour-mark", "colour-#{entry.colour}"]} aria-hidden="true"></span>
                  <span class="colour-word">
                    {if(entry.colour == :white, do: gettext("White"), else: gettext("Black"))}
                  </span>
                </td>

                <td class="num col-no">{entry.opponent_no}</td>

                <td :if={@show.federation} class="col-fed">
                  <Flags.fed code={entry.opponent && entry.opponent["federation"]} on={@show.flags} />
                </td>

                <td :if={@show.title} class="col-title">
                  {dash(entry.opponent && entry.opponent["title"])}
                </td>

                <td class="col-opponent">
                  <.player_link
                    slug={@slug}
                    no={entry.opponent_no}
                    player={entry.opponent}
                    show={@show}
                    cards?={@show.player_cards}
                    flag={false}
                  />
                </td>

                <td :if={@show.rating} class="num">
                  {dash(entry.opponent && entry.opponent["rating"])}
                </td>

                <td :if={@show.standings} class="num col-opp-pts">
                  <.score points={@totals[entry.opponent_no]} />
                </td>

                <td class="num">
                  <.result
                    token={entry.result}
                    postponed={entry.postponed}
                    pending={entry.pending}
                    postponed_date={if(@show.dates, do: entry.postponed_date)}
                  />
                </td>
              <% :bye -> %>
                <%!-- The bye's label sits where the opponent's NAME sits, under
                      "Opponent", with the cells before it left blank - the way
                      the arbiter's own player card reads it. It used to span
                      from "No" onwards, so the text started two or three
                      columns to the left of every name above and below it and
                      read as if it had landed in the wrong column. --%>
                <td class="col-colour"></td>

                <td class="col-no"></td>

                <td :if={@show.federation} class="col-fed"></td>

                <td :if={@show.title} class="col-title"></td>

                <td
                  colspan={1 + count_if([@show.rating, @show.standings])}
                  class="quiet"
                >
                  {bye_kind(entry.bye)}
                </td>

                <td class="num">{number(entry.points)}</td>
              <% :unpublished -> %>
                <td colspan={@game_span + 2} class="quiet">{gettext("not published")}</td>
              <% _no_game -> %>
                <td colspan={@game_span + 2} class="quiet">
                  {gettext("no game published for this round")}
                </td>
            <% end %>

            <td class="num strong">
              {number(entry.score)}
              <span :if={entry.uncounted?} class="uncounted-note">{gettext("not counted")}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <p :if={Enum.any?(@card, & &1.uncounted?)} class="footnote uncounted-footnote">
      {gettext(
        "Not counted: the opponent left the tournament with fewer than half of the games played, so under the round-robin rules (FIDE C.05 6.6) the game stays on record and adds nothing to the score."
      )}
    </p>
    """
  end

  defp count_if(flags), do: Enum.count(flags, & &1)

  # A blank table cell reads as "nobody has typed this in"; a dash reads as
  # "there is none". They are different claims, and for a rating the second is
  # the true one - an unrated player is not a player whose rating is pending.
  defp dash(nil), do: "-"
  defp dash(""), do: "-"
  defp dash(value), do: value

  # The arbiter's display rules as a plain map with atom keys, resolved once
  # per table. Every key defaults to shown - see `Tournament.show?/2` for why
  # that direction is the safe one.
  defp display_rules(payload) do
    Map.new(
      ~w(standings crosstable pairings player_cards byes rating title federation club category
         city dates arbiter deputy time_control fide_badge tiebreaks pairing_scores),
      &{String.to_atom(&1), Tournament.show?(payload, &1)}
    )
    # Not a `show?/2` key: absent means off - see `Tournament.flags?/1`.
    |> Map.put(:flags, Tournament.flags?(payload))
    # Nor this one: absent means no column. See `Tournament.sex?/1`.
    |> Map.put(:sex, Tournament.sex?(payload))
  end

  @doc """
  A player, linked to their card.

  Falls back to the bare pairing number when the payload references a player
  it does not list. That should not happen, but a page that renders a
  tournament minus one board beats a page that renders nothing.
  """
  attr :slug, :string, required: true
  attr :no, :any, required: true
  attr :player, :map, default: nil

  attr :detail, :boolean,
    default: false,
    doc: """
    Show the title alongside the name. Not the rating: every table that wants
    one has a column for it, and rendering it here as well printed it twice
    on the standings - which it did before the pairings gained a column, and
    which adding one to the pairings would have repeated.
    """

  attr :show, :map,
    default: %{},
    doc: "the arbiter's display rules; missing keys mean shown, as everywhere else"

  attr :cards?, :boolean, default: true, doc: "false renders the name without a link"

  attr :flag, :boolean,
    default: true,
    doc: """
    The federation's flag before the name, when the arbiter asked for flags
    (`@show.flags` - absent means off, unlike every other key in `show`).
    Pass false in a row that already prints the federation code with its own
    flag: one flag per player per row is plenty.
    """

  attr :q, :string,
    default: nil,
    doc: """
    The active search term, if any - when it is a substring of the name
    shown here, the matching part is wrapped in `<mark>` (escaped through
    `highlighted_name/2`, never raw player data). `nil` on every page that
    has no search box at all, and on every render of a name this is not the
    filter bar's own search for (a bare pairing-number fallback name is
    never highlighted, since it does not come from the player).
    """

  def player_link(assigns) do
    ~H"""
    <a
      :if={@no && @cards?}
      href={~p"/t/#{@slug}/player/#{@no}"}
      class="player"
      data-player={@no}
    >
      <Flags.name_flag :if={@flag} code={@player && @player["federation"]} on={flags?(@show)} />
      <span :if={@detail && shown?(@show, :title) && @player && @player["title"]} class="title">
        {@player["title"]}
      </span>

      <span class="name">
        {display_name(@player, @no, @q)}
      </span>
    </a>

    <span :if={@no && not @cards?} class="player">
      <Flags.name_flag :if={@flag} code={@player && @player["federation"]} on={flags?(@show)} />
      <span :if={@detail && shown?(@show, :title) && @player && @player["title"]} class="title">
        {@player["title"]}
      </span>

      <span class="name">
        {display_name(@player, @no, @q)}
      </span>
    </span>
    <span :if={is_nil(@no)} class="player">-</span>
    """
  end

  # `@player["name"]` highlighted against the active search term, or the
  # "Player %{number}" fallback when there is no player - never highlighted,
  # since a bare pairing number is not something the search box matched.
  defp display_name(%{"name" => name}, _no, q) when is_binary(name),
    do: highlighted_name(name, q)

  defp display_name(_player, no, _q), do: gettext("Player %{number}", number: no)

  defp highlighted_name(name, q) when is_binary(q) and q != "" do
    case find_match(name, q) do
      {pre, match, post} ->
        raw(escaped(pre) <> "<mark>" <> escaped(match) <> "</mark>" <> escaped(post))

      nil ->
        name
    end
  end

  defp highlighted_name(name, _q), do: name

  # Byte-offset matching on the downcased name, sliced out of the ORIGINAL
  # (correctly-cased) name at the same byte offsets - safe as long as
  # downcasing does not change the string's byte length, which holds for
  # every script this site's fixtures and real tournaments actually use. A
  # case where it does not (a rare expanding downcase, e.g. "İ") simply
  # finds no match and falls back to the plain name - never a crash, never
  # a mis-sliced tag.
  defp find_match(name, q) do
    down = String.downcase(name)
    query = String.downcase(q)

    if byte_size(down) == byte_size(name) do
      case :binary.match(down, query) do
        {start, len} ->
          {binary_part(name, 0, start), binary_part(name, start, len),
           binary_part(name, start + len, byte_size(name) - start - len)}

        :nomatch ->
          nil
      end
    end
  rescue
    _ -> nil
  end

  @doc """
  Why this player is where they are: their placing, their score, and what
  each tiebreak was made of.

  This is the block the overlay card shows. It is deliberately the SUMMARY
  and not the whole page - before the working existed, right-clicking a name
  fetched the player page and put its one section in a dialog, so the two
  gestures produced identical content and the overlay's only value was not
  losing your place in the standings. Left-click now leads somewhere with
  more in it: the round-by-round table, the chart, and every contribution
  named.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :no, :integer, required: true

  def placing(assigns) do
    payload = assigns.payload
    row = Tournament.standings_row(payload, assigns.no)

    assigns =
      assigns
      |> assign(:row, row)
      |> assign(:working, Tournament.working(payload, assigns.no))
      |> assign(:codes, Tournament.working_codes(payload, assigns.no))
      |> assign(:labels, tiebreak_labels(payload))
      |> assign(:show, display_rules(payload))

    ~H"""
    <p :if={@row && not Tournament.uncounted?(@row)} class="placing">
      <span class="placing-rank">{@row["rank"]}</span>
      <span class="placing-of">
        {gettext("of %{total}, on %{points}",
          total: Tournament.ranked_total(@payload),
          points: number(@row["points"])
        )}
      </span>
    </p>
    <%!-- No place to print: C.05 6.6 keeps the games and drops the row
          from the ranking. --%>
    <p :if={Tournament.uncounted?(@row)} class="placing placing-uncounted">
      <span class="placing-of">{gettext("results not counted (withdrawn)")}</span>
    </p>
    <.uncounted_footnote :if={Tournament.uncounted?(@row)} />
    <table :if={@codes != [] and @show.tiebreaks} class="tiebreak-summary">
      <caption class="visually-hidden">{gettext("Tie-breaks")}</caption>

      <tbody>
        <tr :for={code <- @codes}>
          <th scope="row">
            {@labels[code]} <TiebreakHelp.help code={code} name={@labels[code]} />
          </th>

          <td class="num strong">{number(@working[code]["total"])}</td>

          <td class="quiet">{composition(@working[code]["parts"])}</td>
        </tr>
      </tbody>
    </table>

    <p :if={@codes == [] and @show.tiebreaks} class="footnote">
      {gettext("This tournament publishes no breakdown of its tie-breaks.")}
    </p>

    <%!-- The placing above is a claim, so the same caveat belongs here: what
          is listed may not be everything that put them there. --%>
    <p :if={Tournament.tiebreaks_withheld?(@payload)} class="footnote">
      {gettext("The order also uses tie-breaks this tournament does not publish.")}
    </p>
    """
  end

  # One line saying what a tiebreak is made of, without repeating the table
  # underneath it on the full page. Says only what is true of THIS list: a
  # tiebreak with nothing discarded says nothing about discarding.
  defp composition(parts) do
    counted = Enum.count(parts, &Tournament.part_counted?/1)
    cut = Enum.count(parts, &(Tournament.part_kind(&1) == "cut"))
    excluded = Enum.count(parts, &(Tournament.part_kind(&1) == "excluded"))
    virtual = Enum.count(parts, &(Tournament.part_kind(&1) == "virtual"))

    [
      ngettext("from %{count} round", "from %{count} rounds", counted),
      virtual > 0 && ngettext("%{count} unplayed", "%{count} unplayed", virtual),
      cut > 0 && ngettext("%{count} discarded", "%{count} discarded", cut),
      excluded > 0 && ngettext("%{count} not counted", "%{count} not counted", excluded)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  @doc """
  Every tiebreak's working in full: one row per round, with the opponent it
  came from and what it was worth.

  The values are the arbiter's own, sent with the document. Nothing on this
  page adds them up to check, and nothing recomputes them - see
  `OpenResultsWeb.Tournament.working/2` for why that would be worse than
  useless here.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true
  attr :no, :integer, required: true

  def working_tables(assigns) do
    payload = assigns.payload

    assigns =
      assigns
      |> assign(:working, Tournament.working(payload, assigns.no))
      |> assign(:codes, Tournament.working_codes(payload, assigns.no))
      |> assign(:labels, tiebreak_labels(payload))
      |> assign(:players, Tournament.players_by_no(payload))
      |> assign(:show, display_rules(payload))

    ~H"""
    <section :if={@codes != [] and @show.tiebreaks} class="working">
      <h3>{gettext("Where the tie-breaks come from")}</h3>

      <div :for={code <- @codes} class="working-block">
        <h4>
          {@labels[code]} <TiebreakHelp.help code={code} name={@labels[code]} />
          <span class="num strong">{number(@working[code]["total"])}</span>
        </h4>

        <div class="scroller">
          <table class="working-table">
            <caption class="visually-hidden">{@labels[code]}</caption>

            <thead>
              <tr>
                <th class="num" scope="col">{gettext("Rd")}</th>

                <th scope="col">{gettext("From")}</th>

                <th class="num" scope="col">{gettext("Value")}</th>
              </tr>
            </thead>

            <tbody>
              <tr
                :for={part <- @working[code]["parts"]}
                class={not Tournament.part_counted?(part) && "withheld"}
              >
                <th scope="row" class="num row-head">{part["round"]}</th>

                <td>
                  <.part_source
                    part={part}
                    slug={@slug}
                    player={@players[part["opponent"]]}
                    show={@show}
                  />
                </td>

                <td class="num">{number(part["value"])}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <p class="footnote">
        {gettext(
          "These are the arbiter's numbers, published with the results - this page does not calculate them. An unplayed round contributes a notional opponent under FIDE Article 16 rather than a real one, which is why some rows name nobody."
        )}
      </p>
    </section>
    """
  end

  # What a contribution came from: an opponent, a rule, or nobody.
  attr :part, :map, required: true
  attr :slug, :string, required: true
  attr :player, :map, default: nil
  attr :show, :map, default: %{}

  def part_source(assigns) do
    ~H"""
    <.player_link
      :if={@part["opponent"]}
      slug={@slug}
      no={@part["opponent"]}
      player={@player}
      show={@show}
      cards?={Map.get(@show, :player_cards, true)}
      flag={false}
    />
    <span :if={is_nil(@part["opponent"])} class="quiet">
      {source_label(@part)}
    </span>
    <span :if={Tournament.part_kind(@part) == "cut"} class="tag">{gettext("discarded")}</span>
    <span :if={Tournament.part_kind(@part) == "excluded" and @part["opponent"]} class="tag">
      {gettext("not counted")}
    </span>
    """
  end

  # A part with no opponent to name is an unplayed round - Article 16's
  # notional opponent - and stays one after a cut modifier discards it. `kind`
  # holds one value, so marking it `"cut"` overwrites `"virtual"`; the absent
  # opponent is what survives, and it is enough. The "discarded" tag beside
  # this says the rest.
  defp source_label(part) do
    case Tournament.part_kind(part) do
      "excluded" -> gettext("not counted")
      _virtual_or_cut -> gettext("unplayed round")
    end
  end

  @doc """
  One picture of a player's tournament: what each round contributed to a
  tie-break, and how their own score climbed.

  Both series are in POINTS, which is the only reason they can share an axis.
  A dual-scale chart that put a running total and a per-round contribution on
  different axes would let the two cross wherever the scaling happened to put
  them, and the crossing would mean nothing.

  The bars are the tie-break's own published contributions - the strength of
  the field this player actually faced, which is what a Buchholz IS. A bar
  the arbiter's rules did not count (discarded by a cut, or below Koya's
  threshold) is drawn in the withheld colour rather than left out, because
  "that round did not help you" is the interesting part.

  Inline SVG, no library: this site ships one stylesheet and one script, and
  a chart is not a reason to change that.
  """
  # A line through two points is not a trend, and one bar pair beside it
  # reads as a broken chart. The round-by-round card below says the same thing.
  @chart_min_points 3

  attr :payload, :map, required: true
  attr :card, :list, required: true
  attr :no, :integer, required: true

  def score_chart(assigns) do
    payload = assigns.payload
    code = assigns.payload |> Tournament.working_codes(assigns.no) |> List.first()
    working = Tournament.working(payload, assigns.no)

    bars =
      case code do
        nil -> %{}
        code -> Map.new(working[code]["parts"], &{Map.get(&1, "round"), &1})
      end

    points =
      for entry <- assigns.card,
          is_number(entry.score),
          do: {entry.round, entry.score}

    max =
      [
        Enum.map(points, &elem(&1, 1)),
        bars |> Map.values() |> Enum.map(&Map.get(&1, "value", 0)) |> Enum.filter(&is_number/1)
      ]
      |> List.flatten()
      |> Enum.max(fn -> 0 end)

    assigns =
      assigns
      |> assign(:code, code)
      |> assign(:label, code && tiebreak_labels(payload)[code])
      |> assign(:bars, bars)
      |> assign(:points, points)
      |> assign(:rounds, Enum.map(assigns.card, & &1.round))
      |> assign(:max, max)
      |> assign(:min_points, @chart_min_points)

    ~H"""
    <figure :if={length(@points) >= @min_points and @max > 0} class="chart">
      <svg
        viewBox={"0 0 #{chart_width(@rounds)} 190"}
        width={chart_width(@rounds)}
        height="190"
        class="chart-svg"
        role="img"
      >
        <title>
          {chart_title(@label)}
        </title>

        <%!-- Gridlines at whole points, labelled. Two decimals would be
              noise on an axis whose whole job is "roughly how big". --%>
        <g class="chart-grid">
          <g :for={value <- gridlines(@max)}>
            <line
              x1="30"
              x2={chart_right(@rounds)}
              y1={y(value, @max)}
              y2={y(value, @max)}
            />
            <text x="24" y={y(value, @max) + 4} text-anchor="end">{trunc(value)}</text>
          </g>
        </g>

        <g :for={{round, index} <- Enum.with_index(@rounds)}>
          <% part = @bars[round] %>
          <rect
            :if={part && is_number(part["value"]) && part["value"] > 0}
            x={bar_x(index, @rounds) - bar_width(@rounds) / 2}
            y={y(part["value"], @max)}
            width={bar_width(@rounds)}
            height={164 - y(part["value"], @max)}
            class={
              if(Tournament.part_counted?(part), do: "chart-bar", else: "chart-bar chart-bar-out")
            }
          />
          <text x={bar_x(index, @rounds)} y="182" text-anchor="middle" class="chart-round">
            {round}
          </text>
        </g>

        <%!-- The score line stops where the running total does: at the first
              round whose contribution is not public. A line drawn across that
              gap would be a number the arbiter never published. --%>
        <polyline
          :if={length(@points) > 1}
          class="chart-line"
          points={line_points(@points, @rounds, @max)}
        />
        <circle
          :for={{round, score} <- @points}
          cx={bar_x(Enum.find_index(@rounds, &(&1 == round)), @rounds)}
          cy={y(score, @max)}
          r="3"
          class="chart-dot"
        />
      </svg>

      <figcaption>
        <span class="chart-key chart-key-line"></span> {gettext("running score")}
        <span :if={@label}>
          <span class="chart-key chart-key-bar"></span> {gettext(
            "what each round gave to %{tiebreak}",
            tiebreak: @label
          )}
        </span>
      </figcaption>
    </figure>
    """
  end

  defp chart_title(nil), do: gettext("The player's running score by round.")

  defp chart_title(label) do
    gettext(
      "The player's running score by round, and each round's contribution to %{tiebreak}.",
      tiebreak: label
    )
  end

  # The chart is 190 high and at most 640 wide, with each round given at most
  # 80 units. A short event gets a narrower chart instead of two bars stretched
  # across the full width. The SVG's `width` attribute is its natural size, and
  # the stylesheet only lets it shrink, never grow. The first version sized the
  # box by round count AND scaled it to `width: 100%`, so a five-round event
  # grew taller than the screen; capping at the natural size is what prevents
  # that now.
  @chart_left 34
  @chart_max_width 640
  @chart_slot_max 80

  defp chart_width(rounds),
    do: min(@chart_max_width, @chart_left + @chart_slot_max * max(length(rounds), 1) + 10)

  defp chart_right(rounds), do: chart_width(rounds) - 10

  defp chart_slot(rounds), do: (chart_right(rounds) - @chart_left) / max(length(rounds), 1)
  defp bar_x(index, rounds), do: @chart_left + chart_slot(rounds) * (index + 0.5)
  defp bar_width(rounds), do: min(28.0, chart_slot(rounds) * 0.55)

  # 26px of bottom gutter for the round numbers, 12px of headroom on top.
  defp y(_value, max) when max <= 0, do: 164
  defp y(value, max), do: 164 - value / max * 138

  defp gridlines(max) do
    step = if max > 8, do: 2, else: 1
    Stream.iterate(0, &(&1 + step)) |> Enum.take_while(&(&1 <= max)) |> Enum.map(&(&1 / 1))
  end

  defp line_points(points, rounds, max) do
    Enum.map_join(points, " ", fn {round, score} ->
      "#{bar_x(Enum.find_index(rounds, &(&1 == round)), rounds)},#{y(score, max)}"
    end)
  end

  defp tiebreak_labels(payload) do
    payload
    |> Tournament.tiebreaks()
    |> Map.new(fn tb -> {Map.get(tb, "code"), Tournament.tiebreak_label(tb)} end)
  end

  # Missing means shown, matching `Tournament.show?/2`. Callers build this map
  # once per table rather than asking the payload per cell.
  defp shown?(show, key), do: Map.get(show, key, true)

  # The one key of `show` where a missing entry means OFF: a caller that
  # never mentioned flags has not asked for any. `display_rules/1` puts the
  # effective value there (flags asked for AND federations shown).
  defp flags?(show), do: Map.get(show, :flags, false) == true

  @doc """
  A result token, with its forfeit or unrated marker spelled out.

  A game with no result yet is a hyphen rather than a blank, because a blank
  cell in a pairing list reads as a board nobody has typed in, which is a
  different thing from a game still in progress.

  A postponed game - one the arbiter paired and the players will play later,
  `boards[].postponed` - says so in words instead, with the date the players
  agreed when there is one. The caller passes the date only where the
  arbiter's "dates" tick allows it (see `postponed_date/2`), because it is the
  same kind of fact as a round's date, which that tick already hides. Once
  the game is played the next snapshot carries its result and no flag, and
  the token simply takes the label's place.
  """
  attr :token, :any, required: true
  attr :postponed, :boolean, default: false, doc: "`Tournament.postponed?/1` for the board"
  attr :postponed_date, :string, default: nil, doc: "the agreed date, already gated"

  attr :pending, :boolean,
    default: false,
    doc: "`Tournament.pending?/1` for the board: counted, not postponed, no result yet"

  def result(assigns) do
    {base, note} = Tournament.result_parts(assigns.token)

    assigns =
      assigns
      |> assign(:base, base)
      |> assign(:note, note_label(note))
      |> assign(:pending, is_nil(base) and assigns.pending)
      |> assign(:postponed, is_nil(base) and assigns.postponed and not assigns.pending)

    ~H"""
    <span class="result">
      <span :if={@base} class="token">{@base}</span>
      <span :if={@postponed} class="postponed">
        {if @postponed_date,
          do: gettext("Postponed, to be played %{date}", date: date(@postponed_date)),
          else: gettext("Postponed")}
      </span>

      <%!-- A pending board (`boards[].pending`): the standings count it,
            nobody postponed it, and it may have been played and not typed
            in yet - so it says exactly that much. --%>
      <span :if={@pending} class="postponed pending" title={pending_words()}>
        {pending_words()}
      </span>

      <span
        :if={is_nil(@base) and not @postponed and not @pending}
        class="unreported"
        title={gettext("not yet reported")}
      >
        <.said_as words={gettext("not yet reported")}>-</.said_as>
      </span>
      <span :if={@note} class="note">{@note}</span>
    </span>
    """
  end

  # The agreed date of a postponed board, or `nil` where the arbiter's "dates"
  # tick is off: when a game is played is the same kind of fact as the round
  # date that tick already hides, and a hidden date must not come back one
  # board at a time.
  defp postponed_date(show, board), do: if(show.dates, do: Tournament.postponed_date(board))

  # The same sentence `result/1` prints in full, for a marker that only has
  # room for the mark itself - reused rather than reworded, so a cross-table
  # cell and a round's own page never say this two different ways. The date
  # is gated on the arbiter's "dates" tick here too, exactly as `postponed_date/2`
  # gates it for that page.
  # What a pending board says, on a round's page and on its cross-table mark.
  defp pending_words, do: gettext("Result not yet in")

  defp postponed_title(iso_date, dates_shown?) do
    if iso_date && dates_shown? do
      gettext("Postponed, to be played %{date}", date: date(iso_date))
    else
      gettext("Postponed")
    end
  end

  # `Tournament.result_parts/1` names the marker; the wording is this
  # module's, the same division of labour the moduledoc sets out. A marker
  # from a newer client passes through as it arrived rather than vanishing.
  defp note_label("forfeit"), do: gettext("forfeit")
  defp note_label("unrated"), do: gettext("unrated")
  defp note_label(other), do: other

  @doc """
  A number as a scoreboard prints it: `2.5`, `17`, `22.25` - `2,5`, `17`,
  `22,25` in `nl` and `fr`, per `OpenResultsWeb.Format.number/1`.

  Trailing `.0` goes, because JSON has one number type and an arbiter writing
  17 Keizer points did not mean 17.0. Anything that is not a number comes back
  as `nil` and leaves the cell empty - a tiebreak value of the wrong shape is
  worth one blank cell, not a crashed page.

  This is the one function behind every score, tiebreak value and Keizer
  value on the site, so the locale swap lives here rather than at each of
  its call sites - see the 2026-09-12 translations audit, finding 2.
  """
  def number(value) when is_integer(value), do: Integer.to_string(value)

  def number(value) when is_float(value) do
    if trunc(value) == value do
      Integer.to_string(trunc(value))
    else
      value |> Float.to_string() |> Format.number()
    end
  end

  def number(value) when is_binary(value), do: Format.number(value)
  def number(_not_a_number), do: nil

  @doc """
  A bye's kind, as an arbiter would say it out loud.

  Unrecognised kinds pass through: the contract lists five, and a sixth from a
  newer client is still something to show.
  """
  def bye_kind("pairing-allocated"), do: gettext("pairing-allocated bye")
  def bye_kind("half-point"), do: gettext("half-point bye")
  def bye_kind("zero-point"), do: gettext("zero-point bye")
  def bye_kind("full-point"), do: gettext("full-point bye")
  def bye_kind("absent"), do: gettext("absent")

  # Not a bye at all, which is exactly why it has its own word. The arbiter
  # emptied one seat of a board and recorded a result against it anyway - a
  # forfeit, usually. Every one of these used to arrive labelled
  # "pairing-allocated" and carrying the tournament's bye value, so a player
  # who forfeited appeared here with a full point for the round and a running
  # total that disagreed with the standings on the next page. The arbiter's
  # app now sends what happened; this is where it gets a name.
  def bye_kind("vacated-seat"), do: gettext("seat vacated")

  # A round played before a late entrant joined: worth nothing, and named so
  # that the zero beside it reads as "was not here yet" and not as a loss.
  def bye_kind("not-joined"), do: gettext("not yet joined")

  # No board and no bye: withdrawn, or taken off a board by hand. Worth
  # nothing, and said out loud so the zero is not mistaken for a lost game.
  def bye_kind("not-paired"), do: gettext("not paired")

  def bye_kind(kind) when is_binary(kind), do: kind
  def bye_kind(_absent), do: gettext("bye")

  @doc """
  The other editions of this tournament's series - the same event in other
  years - as `OpenResults.ResultsIndex.editions/1` found them: same series,
  same publisher, visible here. Nothing at all when there are none.
  """
  attr :editions, :list, default: []

  def other_editions(assigns) do
    ~H"""
    <section :if={@editions != []} id="other-editions" class="other-editions">
      <h2>{gettext("Other editions")}</h2>
      <ul class="tournaments" id="other-editions-list">
        <li :for={entry <- @editions} id={"edition-" <> entry.slug} class="hub-entry">
          <a href={~p"/t/#{entry.slug}"}>{entry.name}</a>
          <OpenResultsWeb.HubHTML.unapproved :if={entry.status == "pending"} />
          <span class="details">
            <span :if={entry.city}>{entry.city}</span>
            <span :if={OpenResultsWeb.HubHTML.dates(entry)}>
              {OpenResultsWeb.HubHTML.dates(entry)}
            </span>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  Links to the CSV exports (`OpenResultsWeb.ExportController`), each only
  where its page is published - the same switches the controller enforces.
  """
  attr :payload, :map, required: true
  attr :slug, :string, required: true

  def export_links(assigns) do
    payload = assigns.payload

    links =
      Enum.filter(
        [
          {Tournament.show?(payload, "standings"), "standings", gettext("Standings")},
          {Tournament.crosstable?(payload), "crosstable", gettext("Cross-table")},
          {Tournament.show?(payload, "pairings"), "pairings", gettext("Pairings")},
          {Tournament.show?(payload, "standings"), "players", gettext("Player list")}
        ],
        &elem(&1, 0)
      )

    assigns = assign(assigns, :links, links)

    ~H"""
    <p :if={@links != []} class="footnote export-links" id="export-links">
      <span>{gettext("Download as CSV:")}</span>
      <a
        :for={{_shown, kind, label} <- @links}
        id={"export-" <> kind}
        href={"/t/#{@slug}/#{kind}.csv"}
        download
      >
        {label}
      </a>
    </p>
    """
  end
end
