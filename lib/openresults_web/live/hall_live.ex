defmodule OpenResultsWeb.HallLive do
  @moduledoc """
  The hall display: one tournament, full screen, for a television or a
  projector in the playing hall. `GET /t/:slug/hall`.

  It cycles through the current round's pairings, an alphabetical "find your
  name" list, the results as they come in, the top of the standings and the
  arbiter's announcement - see `OpenResultsWeb.Hall` for what is on each page
  and when the cycle holds on the pairings instead.

  ## Why this page, alone on this site, keeps a connection open

  Every other public page is a static document that polls, and the reasons
  for that (hundreds of phones, a hall's wifi, a page that must read the
  moment it lands) are sound for them. A hall display is the other case: one
  screen per room, on for hours, that should show a result within a second
  of the arbiter publishing it and must keep its place in a cycle while it
  does. So it is a LiveView subscribed to `OpenResults.TournamentEvents`, and
  a publish pushes a re-read rather than waiting for a poll.

  It carries no session and sets no cookie: the socket is declared without
  one (see `OpenResultsWeb.Endpoint`), the locale travels in the signed page
  session, and there is nothing a forged connection could act on.

  ## Reading the tournament

  Always through `OpenResults.Tournaments.public_latest/1`, like every public
  page, so a hidden tournament is gone from the screen on the next message.
  The static render answers the same 404 as the standings page before any of
  this runs - see `OpenResultsWeb.Plugs.HallGate`. Not through the rendered
  page cache (`OpenResultsWeb.Plugs.Revalidate`): the route is outside that
  scope, and the socket re-reads the snapshot itself, so nothing here can be
  served stale.

  Besides the push, every turn of the cycle compares the snapshot id against
  `OpenResults.Snapshots.latest_id/1` - an ETS lookup - so a message lost to
  a reconnect costs one page turn, not the rest of the round.

  ## The cycle

  Kept by the server: a timer per page, a sequence number that makes a stale
  timer harmless, and a pause. A tap or the space bar pauses on the page
  showing; the arrow keys step. The progress bar is a CSS animation restarted
  by giving it a new id each page, so there is no script driving it. The
  clock is the one script (`.HallClock`), because the hall's time is the
  television's, not the server's.
  """

  use OpenResultsWeb, :live_view

  import OpenResultsWeb.LiveBoardsComponents, only: [tile: 1]

  alias OpenResults.LiveBoards
  alias OpenResults.Snapshots
  alias OpenResults.TournamentEvents
  alias OpenResults.Tournaments
  alias OpenResultsWeb.Hall
  alias OpenResultsWeb.LiveBoardsData
  alias OpenResultsWeb.TournamentHTML

  @doc """
  The page session: the locale `OpenResultsWeb.Plugs.Locale` chose for this
  request. Signed into the page by LiveView, never a cookie.
  """
  def session(conn) do
    %{"locale" => conn.assigns[:locale] || OpenResultsWeb.Locale.default()}
  end

  @impl true
  def mount(%{"slug" => slug} = params, session, socket) do
    locale = Map.get(session, "locale") || OpenResultsWeb.Locale.default()
    Gettext.put_locale(OpenResultsWeb.Gettext, locale)

    if connected?(socket) do
      TournamentEvents.subscribe(slug)
      LiveBoards.subscribe(slug)
    end

    projector? = socket.assigns[:live_action] == :projector
    choice = theme_choice(params["theme"])

    socket =
      socket
      |> assign(
        slug: slug,
        locale: locale,
        # No picker on a hall screen: `?pieces=chessnut` in its URL, or what
        # that browser remembered.
        pieces: OpenResultsWeb.Pieces.choose(params, get_connect_params(socket)),
        projector?: projector?,
        theme_choice: choice || "black",
        theme_from_url?: choice != nil,
        theme: theme(choice),
        # The projector view is the pairings and nothing else, whatever
        # `?views=` says; the hall display narrows by it.
        only: if(projector?, do: [:pairings], else: Hall.parse_views(params["views"])),
        snapshot_id: nil,
        payload: nil,
        available?: false,
        data: nil,
        settings: nil,
        arrivals: %{},
        slides: [],
        index: 0,
        paused?: false,
        cycle: 0,
        timer_cycle: nil,
        page_title: screen_title(projector?)
      )
      |> init_streams()
      |> load(true)
      |> schedule()

    {:ok, socket, layout: false}
  end

  defp screen_title(true), do: gettext("Projector view")
  defp screen_title(false), do: gettext("Hall display")

  # A theme picked for the room by whoever sets up the screen, in the URL
  # (`?theme=black|white|ultra`; `light` is the older spelling of white), or
  # on the screen itself - the hook then remembers it in that browser, and the
  # URL still wins over what it remembered. Black unless asked: a bright white
  # slab at the front of a playing hall is the thing everyone looks at
  # instead of their board.
  defp theme_choice(value) when value in ["black", "white", "ultra"], do: value
  defp theme_choice("light"), do: "white"
  defp theme_choice(_absent_or_junk), do: nil

  defp theme("white"), do: "contrast"
  defp theme("ultra"), do: "ultra"
  defp theme(_black_or_absent), do: "night"

  defp init_streams(socket) do
    socket
    |> stream_configure(:rows, dom_id: & &1.id)
    |> stream(:rows, [])
    |> assign(:row_count, 0)
  end

  @impl true
  def handle_info({:tournament_changed, slug}, %{assigns: %{slug: slug}} = socket) do
    {:noreply, socket |> load(false) |> ensure_timer()}
  end

  def handle_info({:advance, cycle}, %{assigns: %{cycle: cycle, paused?: false}} = socket) do
    socket = if stale?(socket), do: load(socket, false), else: socket
    # Rows are sent once, by `step/2`: a stream reset twice in one handler
    # would carry the first page's rows into the second page's markup.
    {:noreply, socket |> refresh_live(false) |> step(1) |> clear_if_empty() |> schedule()}
  end

  # A game on a board changed. The delay is applied by reading, not by
  # sending late - see `OpenResults.LiveBoards` - so with one set the read
  # that shows the change is simply scheduled for when it becomes visible.
  def handle_info({:live_board, slug, _round, _board}, %{assigns: %{slug: slug}} = socket) do
    delay_ms = :timer.minutes(LiveBoards.delay_minutes(slug))

    if delay_ms == 0 do
      {:noreply, socket |> refresh_live() |> ensure_timer()}
    else
      Process.send_after(self(), :live_refresh, delay_ms + 50)
      {:noreply, socket}
    end
  end

  def handle_info(:live_refresh, socket),
    do: {:noreply, socket |> refresh_live() |> ensure_timer()}

  def handle_info({:live_delay, _slug}, socket),
    do: {:noreply, socket |> refresh_live() |> ensure_timer()}

  # A timer from before a pause, a step or a new round: its page is gone.
  def handle_info({:advance, _old_cycle}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_pause", _params, socket), do: {:noreply, toggle_pause(socket)}

  def handle_event("key", %{"key" => key}, socket) when key in [" ", "Spacebar"],
    do: {:noreply, toggle_pause(socket)}

  def handle_event("key", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, socket |> step(1) |> schedule()}

  def handle_event("key", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, socket |> step(-1) |> schedule()}

  def handle_event("key", _params, socket), do: {:noreply, socket}

  defp toggle_pause(%{assigns: %{paused?: true}} = socket),
    do: socket |> assign(paused?: false) |> schedule()

  # A pause holds the page it is on rather than jumping back to the start, so
  # a player mid-read is not chased off their own board - the projector
  # view's rule. It also holds through a publish (see `ensure_timer/1`).
  defp toggle_pause(socket), do: socket |> assign(paused?: true) |> bump()

  ## ---------- data ----------

  defp stale?(socket) do
    Snapshots.latest_id(socket.assigns.slug) != socket.assigns.snapshot_id
  end

  # Re-reads the tournament and rebuilds the cycle, keeping the page on the
  # screen where it still exists - a result arriving must not throw somebody
  # reading page 3 of the names back to page 1.
  defp load(socket, initial?) do
    case Tournaments.public_latest(socket.assigns.slug) do
      nil ->
        socket
        |> assign(available?: false, snapshot_id: nil, data: nil, slides: [], index: 0)
        |> put_rows()

      %{id: id} when id == socket.assigns.snapshot_id and not initial? ->
        socket

      snapshot ->
        apply_snapshot(socket, snapshot, initial?)
    end
  end

  defp apply_snapshot(socket, snapshot, initial?) do
    settings = snapshot.payload |> Hall.settings(socket.assigns.only) |> screen_settings(socket)

    data =
      snapshot.payload |> Hall.build(settings) |> put_live(snapshot.payload, socket.assigns.slug)

    now = now()
    slides = Hall.slides(data, settings)

    previous = socket.assigns.data
    old_round = previous && previous.round && previous.round.number
    new_round = data.round && data.round.number
    new_round? = not initial? and new_round != nil and new_round != old_round

    index =
      if new_round? and Hall.hold?(data, settings),
        do: 0,
        else: keep_place(socket.assigns.slides, socket.assigns.index, slides)

    socket
    |> assign(
      available?: true,
      snapshot_id: snapshot.id,
      payload: snapshot.payload,
      settings: settings,
      data: data,
      arrivals: Hall.arrivals(socket.assigns.arrivals, data, now, initial?),
      slides: slides,
      index: index,
      page_title: "#{data.name} - #{screen_title(socket.assigns.projector?)}"
    )
    |> then(fn socket -> if new_round?, do: bump(socket), else: socket end)
    |> put_rows()
  end

  # The projector view shows the pairings whether or not the arbiter put them
  # in the hall display's cycle: it is a screen of its own, and what it may
  # show is decided by the display rules `Hall.build/2` already applies.
  # The games being played on this round's boards, as tiles.
  defp put_live(%{round: nil} = data, _payload, _slug), do: Map.put(data, :live, [])

  defp put_live(data, payload, slug) do
    tiles =
      payload
      |> LiveBoardsData.tiles(slug, data.round.number, plies: false)
      |> Enum.filter(&(LiveBoardsData.live?(&1) and &1.view.ply > 0))

    Map.put(data, :live, tiles)
  end

  # Re-reads the live games and rebuilds the cycle around them. Sends rows
  # again only when the picture on screen can have changed: a live page
  # always (a clock may have moved), another page only if the set of games or
  # a board's position did.
  defp refresh_live(socket, rows? \\ true)

  defp refresh_live(%{assigns: %{data: nil}} = socket, _rows?), do: socket

  defp refresh_live(socket, rows?) do
    %{data: old, payload: payload, slug: slug, settings: settings} = socket.assigns
    data = put_live(old, payload, slug)
    slides = Hall.slides(data, settings)
    live_page? = match?({:live, _page}, current_slide(socket.assigns))

    if not live_page? and
         Enum.map(data.live, &{&1.id, &1.signature}) ==
           Enum.map(old.live, &{&1.id, &1.signature}) do
      assign(socket, data: data)
    else
      socket
      |> assign(
        data: data,
        slides: slides,
        index: keep_place(socket.assigns.slides, socket.assigns.index, slides)
      )
      |> then(fn socket -> if rows?, do: put_rows(socket), else: socket end)
    end
  end

  # `step/2` leaves a cycle with no slides alone; its rows still have to go.
  defp clear_if_empty(%{assigns: %{slides: []}} = socket), do: put_rows(socket)
  defp clear_if_empty(socket), do: socket

  defp screen_settings(settings, %{assigns: %{projector?: true}}),
    do: %{settings | views: [:pairings]}

  defp screen_settings(settings, _socket), do: settings

  # The same page if it still exists, else the first page of the same view,
  # else the slide that now sits where the old one was.
  defp keep_place([], _index, _slides), do: 0
  defp keep_place(_old, _index, []), do: 0

  defp keep_place(old, index, slides) do
    {view, _page} = current = Enum.at(old, index) || hd(old)

    Enum.find_index(slides, &(&1 == current)) ||
      Enum.find_index(slides, &(elem(&1, 0) == view)) ||
      min(index, length(slides) - 1)
  end

  ## ---------- the cycle ----------

  defp step(%{assigns: %{slides: []}} = socket, _by), do: socket

  defp step(socket, by) do
    count = length(socket.assigns.slides)

    socket
    |> assign(index: Integer.mod(socket.assigns.index + by, count))
    |> put_rows()
  end

  # Every page turn gets a new cycle number: the timer for the page before
  # it is ignored when it fires, and the progress bar, keyed on it, restarts.
  defp bump(socket), do: assign(socket, cycle: socket.assigns.cycle + 1)

  defp schedule(socket) do
    socket = bump(socket)
    cycle = socket.assigns.cycle

    if connected?(socket) and not socket.assigns.paused? and length(socket.assigns.slides) > 1 do
      Process.send_after(self(), {:advance, cycle}, seconds(socket) * 1000)
      assign(socket, timer_cycle: cycle)
    else
      assign(socket, timer_cycle: nil)
    end
  end

  # After a publish: a timer is left alone when one is running for the page
  # in view, so that page keeps its full time; one is started when there is
  # none - the round has just changed, or one page became several.
  # Paused stays paused through a publish: a timer started here would move
  # the screen on under somebody reading their board.
  defp ensure_timer(%{assigns: %{paused?: true}} = socket), do: socket
  defp ensure_timer(%{assigns: %{timer_cycle: cycle, cycle: cycle}} = socket), do: socket
  defp ensure_timer(socket), do: schedule(socket)

  defp seconds(%{assigns: %{settings: %{page_seconds: seconds}}}), do: seconds
  defp seconds(_no_settings), do: 15

  defp now, do: System.monotonic_time(:millisecond)

  defp current_slide(%{slides: slides, index: index}), do: Enum.at(slides, index)

  defp put_rows(socket) do
    rows =
      case current_slide(socket.assigns) do
        nil -> []
        slide -> Hall.rows(socket.assigns.data, slide, socket.assigns.arrivals, now())
      end

    socket
    |> assign(:row_count, length(rows))
    |> stream(:rows, rows, reset: true)
  end

  ## ---------- rendering ----------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:slide, current_slide(assigns))
      |> assign(:total, length(assigns.slides))

    ~H"""
    <div
      id="hall"
      class={["hall", @paused? && "is-paused", @projector? && "is-projector"]}
      data-screen={if(@projector?, do: "projector", else: "hall")}
      data-view={@slide && elem(@slide, 0)}
      data-page={@slide && elem(@slide, 1)}
      data-cycle={@cycle}
      data-seconds={@settings && @settings.page_seconds}
      phx-click="toggle_pause"
      phx-window-keydown="key"
    >
      <a class="skip-link" href="#hall-stage">
        {gettext("Skip to content")}
      </a>
      <.screen_tools theme_choice={@theme_choice} theme_from_url?={@theme_from_url?} />
      <header class="hall-head">
        <div class="hall-title">
          <h1 id="hall-name">{(@data && @data.name) || screen_title(@projector?)}</h1>

          <p :if={@data && @data.round} id="hall-round" class="hall-round">
            <span>{@data.round.heading}</span>
            <span :if={@data.round.date} class="hall-quiet">
              {TournamentHTML.date(@data.round.date)}
            </span>

            <span :if={@data.round.final?} id="hall-final" class="hall-final">
              {gettext("Final round")}
            </span>
          </p>
        </div>
        <.clock />
      </header>

      <main id="hall-stage" class="hall-stage" tabindex="-1" aria-live="polite">
        <%= cond do %>
          <% not @available? -> %>
            <p id="hall-unavailable" class="hall-empty">
              {gettext("Nothing is published for this tournament at the moment.")}
            </p>
          <% is_nil(@slide) -> %>
            <p id="hall-idle" class="hall-empty">
              {gettext("Nothing to show yet - this screen fills in as the arbiter publishes.")}
            </p>
          <% true -> %>
            <.slide
              slide={@slide}
              data={@data}
              streams={@streams}
              standings_top={@settings.standings_top}
              slug={@slug}
              pieces={@pieces}
              row_count={@row_count}
            />
        <% end %>
      </main>

      <footer id="hall-foot" class="hall-foot">
        <span :if={@slide} id="hall-view-name" class="hall-view-name">{view_name(@slide)}</span>
        <span :if={@slide && page_total(@slides, @slide) > 1} id="hall-page" class="hall-page">
          {gettext("Page %{page} of %{count}",
            page: elem(@slide, 1) + 1,
            count: page_total(@slides, @slide)
          )}
        </span>

        <span :if={@paused?} id="hall-paused" class="hall-paused">
          {gettext("Paused - tap or press space to resume")}
        </span>

        <span
          :if={@total > 1 and not @paused?}
          class="hall-bar"
          aria-hidden="true"
        >
          <span
            id={"hall-bar-#{@cycle}"}
            class="hall-bar-fill"
            style={"animation-duration: #{@settings.page_seconds}s"}
          ></span>
        </span>

        <span
          id="hall-offline"
          class="hall-offline"
          hidden
          phx-disconnected={JS.show()}
          phx-connected={JS.hide()}
        >
          {gettext("Reconnecting…")}
        </span>
      </footer>
    </div>
    """
  end

  # How many pages the view on screen has, for "Page 2 of 5".
  defp page_total(slides, {view, _page}), do: Enum.count(slides, &(elem(&1, 0) == view))

  defp view_name({:pairings, _page}), do: gettext("Pairings")
  defp view_name({:names, _page}), do: gettext("Find your board")
  defp view_name({:results, _page}), do: gettext("Results")
  defp view_name({:standings, _page}), do: gettext("Standings")
  defp view_name({:live, _page}), do: gettext("Live boards")
  defp view_name({:announcement, _page}), do: gettext("Announcement")

  # How much larger than the hall's base size a board row may be drawn. A
  # full page (`Hall.boards_per_page/0`) gets 1.25, which is what fits; a short
  # one - six boards in a club rapid - grows into the empty screen it would
  # otherwise leave, up to 1.6 so names never outshout the tournament's title.
  # The 70 is the stage's height in hall units, the 2.2 a row's padding and the
  # 3.84 one em of row height, all from app.css's `.hall-table`.
  defp fit_style(rows) when rows > 0 do
    fit = ((70 / rows - 2.2) / 3.84) |> max(1.25) |> min(1.6) |> Float.round(3)
    "--fit: #{fit}"
  end

  defp fit_style(_none), do: nil

  attr :slide, :any, required: true
  attr :data, :map, required: true
  attr :streams, :any, required: true
  attr :standings_top, :integer, required: true
  attr :slug, :string, default: nil
  attr :pieces, :string, default: "cburnett"
  attr :row_count, :integer, default: 0

  defp slide(%{slide: {:pairings, _}} = assigns) do
    assigns = assign(assigns, :matches?, Hall.matches?(assigns.data))

    ~H"""
    <section id="hall-pairings" class="hall-view">
      <p :if={not @data.results? and @data.round} class="hall-note">
        {gettext("Results for round %{round} are not published yet.",
          round: @data.round.label
        )}
      </p>

      <table :if={not @matches?} class="hall-table hall-boards">
        <caption class="visually-hidden">{@data.round.heading}</caption>

        <thead>
          <tr>
            <th class="num" scope="col">{gettext("Bd")}</th>

            <th scope="col">{gettext("White")}</th>

            <th class="num" scope="col">{gettext("Result")}</th>

            <th scope="col">{gettext("Black")}</th>
          </tr>
        </thead>

        <tbody id="hall-rows" phx-update="stream" style={fit_style(@row_count)}>
          <tr :for={{id, board} <- @streams.rows} id={id}>
            <th scope="row" class="num hall-board">{board.label}</th>

            <td><.person person={board.white} /></td>

            <td class="num hall-result">
              <.board_result board={board} />
            </td>

            <td><.person person={board.black} /></td>
          </tr>
        </tbody>
      </table>

      <table :if={@matches?} class="hall-table hall-matches">
        <caption class="visually-hidden">{@data.round.heading}</caption>

        <thead>
          <tr>
            <th class="num" scope="col">{gettext("Match")}</th>

            <th scope="col">{gettext("Team")}</th>

            <th class="num" scope="col">{gettext("Score")}</th>

            <th scope="col">{gettext("Team")}</th>
          </tr>
        </thead>

        <tbody id="hall-rows" phx-update="stream" style={fit_style(@row_count)}>
          <tr :for={{id, match} <- @streams.rows} id={id}>
            <th scope="row" class="num hall-board">{match.number}</th>

            <td>
              {match.team_a}
              <span :if={match.colour_a} class={["hall-colour", "hall-colour-#{match.colour_a}"]}>
                {colour(match.colour_a)}
              </span>
            </td>

            <td class="num hall-result">
              <%= cond do %>
                <% match.bye? -> %>
                  {gettext("bye")}
                <% is_number(match.score_a) and is_number(match.score_b) -> %>
                  {TournamentHTML.number(match.score_a)} - {TournamentHTML.number(match.score_b)}
                <% true -> %>
                  <span class="hall-quiet">-</span>
              <% end %>
            </td>

            <td>
              {match.team_b}
              <span :if={match.colour_b} class={["hall-colour", "hall-colour-#{match.colour_b}"]}>
                {colour(match.colour_b)}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp slide(%{slide: {:names, page}} = assigns) do
    assigns = assign(assigns, :range, Hall.name_range(Hall.rows(assigns.data, {:names, page})))

    ~H"""
    <section id="hall-names" class="hall-view">
      <p :if={@range} class="hall-range">
        {gettext("Names %{from} to %{to}", from: elem(@range, 0), to: elem(@range, 1))}
      </p>

      <ol id="hall-rows" class="hall-names" phx-update="stream">
        <li :for={{id, entry} <- @streams.rows} id={id} class="hall-name">
          <span class="hall-name-who"><.person person={entry} /></span>
          <span :if={entry.board} class="hall-name-seat">
            <span :if={is_nil(entry.match)} class="hall-name-board">
              {gettext("Bd %{board}", board: entry.board)}
            </span>

            <span :if={entry.match} class="hall-name-board">
              {gettext("Match %{match}, Bd %{board}", match: entry.match, board: entry.k)}
            </span>

            <span class={["hall-colour", "hall-colour-#{entry.colour}"]}>
              {colour(entry.colour)}
            </span>
          </span>

          <span :if={is_nil(entry.board)} class="hall-name-seat hall-quiet">
            {TournamentHTML.bye_kind(entry.bye)}
          </span>
        </li>
      </ol>
    </section>
    """
  end

  defp slide(%{slide: {:results, _}} = assigns) do
    {reported, total} = assigns.data.progress
    assigns = assign(assigns, reported: reported, total: total)

    ~H"""
    <section id="hall-results" class="hall-view">
      <p class="hall-progress">
        <span id="hall-progress-count" class="hall-progress-count">
          {gettext("%{reported} of %{total} results", reported: @reported, total: @total)}
        </span>

        <span class="hall-progress-bar" aria-hidden="true">
          <span
            class="hall-progress-fill"
            style={"transform: scaleX(#{if @total > 0, do: Float.round(@reported / @total, 3), else: 0})"}
          ></span>
        </span>
      </p>

      <table class="hall-table hall-boards">
        <caption class="visually-hidden">{gettext("Results")}</caption>

        <thead>
          <tr>
            <th class="num" scope="col">
              {if Hall.matches?(@data), do: gettext("Match/Bd"), else: gettext("Bd")}
            </th>

            <th scope="col">{gettext("White")}</th>

            <th class="num" scope="col">{gettext("Result")}</th>

            <th scope="col">{gettext("Black")}</th>
          </tr>
        </thead>

        <tbody id="hall-rows" phx-update="stream" style={fit_style(@row_count)}>
          <tr :for={{id, board} <- @streams.rows} id={id} class={[board.fresh? && "is-fresh"]}>
            <th scope="row" class="num hall-board">{board.label}</th>

            <td><.person person={board.white} /></td>

            <td class="num hall-result">
              <.board_result board={board} />
            </td>

            <td><.person person={board.black} /></td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp slide(%{slide: {:standings, _}} = assigns) do
    ~H"""
    <section id="hall-standings" class="hall-view">
      <p class="hall-range">
        <span :if={@data.standings.after_round}>
          {gettext("after round %{number}", number: @data.standings.after_round)}
        </span>

        <span :if={@data.standings.provisional?} class="hall-quiet">
          {gettext("provisional")}
        </span>
      </p>

      <table class="hall-table hall-standings">
        <caption class="visually-hidden">{gettext("Standings")}</caption>

        <thead>
          <tr>
            <th class="num" scope="col">{gettext("#")}</th>

            <th scope="col">
              {if @data.standings.kind == :teams, do: gettext("Team"), else: gettext("Name")}
            </th>

            <%= case @data.standings.kind do %>
              <% :teams -> %>
                <th class="num" scope="col">{gettext("MP")}</th>

                <th class="num" scope="col">{gettext("GP")}</th>
              <% :keizer -> %>
                <th class="num" scope="col">{gettext("Keizer points")}</th>
              <% :points -> %>
                <th class="num" scope="col">{gettext("Pts")}</th>
            <% end %>
          </tr>
        </thead>

        <tbody id="hall-rows" phx-update="stream">
          <tr :for={{id, row} <- @streams.rows} id={id}>
            <th scope="row" class="num hall-board">{row.rank}</th>

            <%= if @data.standings.kind == :teams do %>
              <td>{row.team}</td>

              <td class="num hall-points">{TournamentHTML.number(row.mp)}</td>

              <td class="num">{TournamentHTML.number(row.gp)}</td>
            <% else %>
              <td><.person person={row.person} /></td>

              <td class="num hall-points">{TournamentHTML.number(row.points)}</td>
            <% end %>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp slide(%{slide: {:live, _}} = assigns) do
    ~H"""
    <section id="hall-live" class="hall-view hall-live">
      <div id="hall-rows" class="hall-live-grid" phx-update="stream">
        <.tile
          :for={{_id, tile} <- @streams.rows}
          tile={tile}
          slug={@slug}
          link?={false}
          pieces={@pieces}
          class="lb-tile-hall"
        />
      </div>
    </section>
    """
  end

  defp slide(%{slide: {:announcement, _}} = assigns) do
    ~H"""
    <section id="hall-announcement" class="hall-view hall-announcement">
      <p id="hall-announcement-text">{@data.announcement}</p>
    </section>
    """
  end

  attr :person, :map, default: nil

  defp person(assigns) do
    ~H"""
    <span :if={@person} class="hall-person">
      <span :if={@person.title} class="hall-person-title">{@person.title}</span>
      <span class="hall-person-name">{@person.name}</span>
      <span :if={@person.federation} class="hall-person-meta">
        <Flags.flag :if={@person[:flag]} src={@person.flag} />{@person.federation}
      </span>
      <span :if={@person.rating} class="hall-person-meta">{@person.rating}</span>
    </span>
    <span :if={is_nil(@person)} class="hall-quiet">-</span>
    """
  end

  attr :board, :map, required: true

  defp board_result(assigns) do
    ~H"""
    <%= cond do %>
      <% @board.result -> %>
        <TournamentHTML.result token={@board.result} />
      <% @board.postponed? -> %>
        <TournamentHTML.result
          token={nil}
          postponed={true}
          postponed_date={@board.postponed_date}
        />
      <% true -> %>
        <span class="hall-quiet">-</span>
    <% end %>
    """
  end

  defp colour(:white), do: gettext("White")
  defp colour(:black), do: gettext("Black")
  defp colour(_none), do: nil

  attr :theme_choice, :string, required: true
  attr :theme_from_url?, :boolean, required: true

  # The controls a person at the screen reaches for: full screen, and the
  # colours. Fixed in the bottom-right corner (clear of the clock), faded out after a few seconds without
  # movement so they are never on the picture for the room, and back on any
  # mouse move, tap or key. Server-rendered once and then the hook's: the
  # label and pressed states change in the browser only, hence `ignore`.
  defp screen_tools(assigns) do
    ~H"""
    <div
      id="screen-tools"
      class="screen-tools"
      phx-hook=".ScreenTools"
      phx-update="ignore"
      data-initial-choice={@theme_choice}
      data-theme-from-url={to_string(@theme_from_url?)}
      data-theme-store="openresults.screen.theme"
    >
      <div id="screen-themes" class="screen-themes" role="group" aria-label={gettext("Colours")}>
        <button
          :for={{choice, label} <- theme_options()}
          type="button"
          id={"theme-#{choice}"}
          class="screen-btn"
          data-choice={choice}
          aria-pressed={to_string(choice == @theme_choice)}
        >
          {label}
        </button>
      </div>

      <button
        type="button"
        id="fullscreen-toggle"
        class="screen-btn"
        data-state="off"
        data-label-enter={gettext("Full screen")}
        data-label-exit={gettext("Exit full screen")}
        title={gettext("Full screen (F)")}
        hidden
      >
        <svg class="screen-icon screen-icon-enter" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"
            fill="none"
            stroke="currentColor"
            stroke-width="2.4"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>

        <svg class="screen-icon screen-icon-exit" viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5"
            fill="none"
            stroke="currentColor"
            stroke-width="2.4"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
        <span class="screen-btn-label">{gettext("Full screen")}</span>
      </button>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScreenTools">
      export default {
        mounted() {
          this.root = document.documentElement
          this.fsButton = this.el.querySelector("#fullscreen-toggle")
          this.names = {black: "night", white: "contrast", ultra: "ultra"}
          this.store = this.el.dataset.themeStore

          // The URL wins; then what this browser remembered; then the server's.
          let choice = this.el.dataset.initialChoice
          if (this.el.dataset.themeFromUrl !== "true") {
            const kept = this.read()
            if (kept && this.names[kept]) choice = kept
          }
          this.apply(choice, false)

          this.onClick = (e) => {
            // A tap on a control must not also pause the cycle underneath.
            e.stopPropagation()
            // `button[data-choice]`, not any `[data-choice]`: the root element
            // used to carry the server's choice under that very name, so
            // `closest` found it from the full-screen button too, treated the
            // click as a colour pick and returned before reaching the
            // full-screen branch - which is why that button did nothing.
            const theme = e.target.closest("button[data-choice]")
            if (theme) { this.apply(theme.dataset.choice, true); return }
            if (e.target.closest("#fullscreen-toggle")) this.toggleFullscreen()
          }
          this.el.addEventListener("click", this.onClick)

          this.onKey = (e) => {
            if (e.ctrlKey || e.metaKey || e.altKey) return
            if ((e.key === "f" || e.key === "F") && !e.target.closest("input, textarea, select")) {
              this.toggleFullscreen()
            }
          }
          window.addEventListener("keydown", this.onKey)

          this.onWake = () => this.wake()
          for (const type of ["mousemove", "pointerdown", "touchstart", "keydown"]) {
            window.addEventListener(type, this.onWake, {passive: true})
          }
          this.wake()

          this.onFsChange = () => this.syncFullscreen()
          document.addEventListener("fullscreenchange", this.onFsChange)
          document.addEventListener("webkitfullscreenchange", this.onFsChange)
          if (document.fullscreenEnabled || document.webkitFullscreenEnabled) {
            this.fsButton.hidden = false
          }
          this.syncFullscreen()
        },
        destroyed() {
          clearTimeout(this.idle)
          window.removeEventListener("keydown", this.onKey)
          for (const type of ["mousemove", "pointerdown", "touchstart", "keydown"]) {
            window.removeEventListener(type, this.onWake)
          }
          document.removeEventListener("fullscreenchange", this.onFsChange)
          document.removeEventListener("webkitfullscreenchange", this.onFsChange)
        },
        read() {
          try { return window.localStorage.getItem(this.store) } catch (_e) { return null }
        },
        write(choice) {
          try { window.localStorage.setItem(this.store, choice) } catch (_e) { /* private window */ }
        },
        apply(choice, remember) {
          this.root.setAttribute("data-theme", this.names[choice])
          for (const button of this.el.querySelectorAll("button[data-choice]")) {
            button.setAttribute("aria-pressed", String(button.dataset.choice === choice))
          }
          if (remember) this.write(choice)
        },
        wake() {
          this.el.classList.remove("is-idle")
          clearTimeout(this.idle)
          this.idle = setTimeout(() => {
            // Never hide a control somebody is steering by keyboard.
            if (this.el.contains(document.activeElement)) { this.wake(); return }
            this.el.classList.add("is-idle")
          }, 4000)
        },
        fullscreenElement() {
          return document.fullscreenElement || document.webkitFullscreenElement
        },
        toggleFullscreen() {
          if (this.fsButton.hidden) return
          let result
          if (this.fullscreenElement()) {
            const exit = document.exitFullscreen || document.webkitExitFullscreen
            result = exit && exit.call(document)
          } else {
            const el = document.documentElement
            const enter = el.requestFullscreen || el.webkitRequestFullscreen
            result = enter && enter.call(el, {navigationUI: "hide"})
          }
          if (result && result.catch) result.catch(() => {})
        },
        syncFullscreen() {
          const on = !!this.fullscreenElement()
          const button = this.fsButton
          button.dataset.state = on ? "on" : "off"
          button.setAttribute("aria-pressed", String(on))
          button.querySelector(".screen-btn-label").textContent =
            on ? button.dataset.labelExit : button.dataset.labelEnter
        }
      }
    </script>
    """
  end

  defp theme_options do
    [
      {"black", gettext("Black")},
      {"white", gettext("White")},
      {"ultra", gettext("Ultra contrast")}
    ]
  end

  # The time on the television, not the server's: a hall in Brussels
  # watching a server in Frankfurt would otherwise be an hour out every
  # winter. Rendered by the hook from the browser's own clock and locale.
  defp clock(assigns) do
    ~H"""
    <p
      id="hall-clock"
      class="hall-clock"
      data-format="HH:MM:SS"
      phx-hook=".HallClock"
      phx-update="ignore"
    >
    </p>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".HallClock">
      export default {
        mounted() {
          this.tick()
          this.timer = setInterval(() => this.tick(), 1000)
        },
        destroyed() {
          clearInterval(this.timer)
        },
        tick() {
          const lang = document.documentElement.lang || undefined
          this.el.textContent = new Date().toLocaleTimeString(lang, {
            hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23"
          })
        }
      }
    </script>
    """
  end
end
