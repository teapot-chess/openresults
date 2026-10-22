defmodule OpenResultsWeb.ProjectorLive do
  @moduledoc """
  The chosen games of a round on one screen, each as large as the window
  allows - for the projector at the front of a hall, or a screen in the
  analysis room. `GET /t/:slug/live/:round/projector`.

  Everything is in the address, so the hall PC bookmarks it once:

    * `boards=1,3,5` - the boards to show. Absent, empty or naming no board
      of the round: all of them.
    * `auto=1` (the default) or `auto=0` - whether a finished game leaves
      the screen by itself (below).
    * `pieces=chessnut` - the piece set (`OpenResultsWeb.Pieces`).
    * `theme=night` - one of the site's themes, for this screen only;
      without it the page follows the site's own theme choice.

  The dialog that writes the address is `OpenResultsWeb.ProjectorPicker`, on
  the broadcast and the All boards pages. The older `/t/:slug/projector` is a
  different screen - the pairings list for the hall - and stays as it was.

  ## What a tile carries

  No moves, no history, nothing to click. Black's bar, the position with the
  last move marked, White's bar. A bar is the name, title, Elo, the points
  the player brought INTO this round (the round page's number, with its `-`
  where it cannot be known - `Tournament.scores_before/2`), and the clock,
  highlighted while it runs.

  ## The automatic mode

  A board published as not played (a forfeit) is never shown: there is
  nothing to watch. A game that is already over when the page opens is not
  shown either. A game that ends while the screen is up keeps its tile,
  with the result written large across it, for `hold_ms/0` (half a minute),
  then the tile goes and the rest grow into the room. When the last chosen
  game has gone, the screen says so and lists the results.

  Without it, a finished game stays where it is, result and final position.

  ## Size

  The server only guesses the grid (a 16:9 window); the page's hook
  (`.ProjectorFit`) measures the window and picks the number of columns that
  gives the largest board, on every resize, on entering or leaving full
  screen, and whenever a tile comes or goes. Inside its cell a tile is a
  square board plus two bars whose height and type are fractions of the
  board: the cell is a size container, and nothing knows a screen size.

  ## Updates

  As `OpenResultsWeb.BoardsLive`: a changed board re-reads that board alone,
  the broadcast delay is applied by reading the game as it stood `delay`
  ago, a tick every #{15} seconds catches anything a lost message missed,
  and a publish re-reads names, pairings and points.
  """

  use OpenResultsWeb, :live_view

  import OpenResultsWeb.LiveBoardsComponents

  alias OpenResults.LiveBoards
  alias OpenResults.TournamentEvents
  alias OpenResults.Tournaments
  alias OpenResultsWeb.LiveBoardsData
  alias OpenResultsWeb.Tournament
  alias OpenResultsWeb.TournamentHTML

  @tick :timer.seconds(15)

  # The site's themes a bookmark may name; anything else is ignored and the
  # site's own choice stands.
  @themes ~w(paper night board slate contrast ultra)

  # A tile's height over its width - see `.proj-tile` in app.css, whose
  # `--proj-cap`, `--proj-bar` and `--proj-gap` give the same number. Used
  # for the server's first guess at the grid only; the hook reads the
  # stylesheet.
  @tile_ratio 1 + 0.06 + 2 * 0.12 + 3 * 0.015

  @doc """
  How long a finished game stays on the screen before its tile goes, in ms.
  `config :openresults, :projector_hold_ms` - the tests shorten it.
  """
  def hold_ms, do: Application.get_env(:openresults, :projector_hold_ms, :timer.seconds(30))

  @impl true
  def mount(%{"slug" => slug} = params, session, socket) do
    locale = Map.get(session, "locale") || OpenResultsWeb.Locale.default()
    Gettext.put_locale(OpenResultsWeb.Gettext, locale)

    if connected?(socket) do
      TournamentEvents.subscribe(slug)
      LiveBoards.subscribe(slug)
      Process.send_after(self(), :tick, @tick)
    end

    socket =
      socket
      |> assign(
        slug: slug,
        locale: locale,
        pieces: OpenResultsWeb.Pieces.choose(params, get_connect_params(socket)),
        theme: if(params["theme"] in @themes, do: params["theme"]),
        round_param: params["round"],
        wanted: parse_boards(params["boards"]),
        auto: parse_auto(params["auto"]),
        payload: nil,
        snapshot_id: nil,
        title: slug,
        round: nil,
        round_heading: nil,
        delay: 0,
        unknown_round?: false,
        all?: true,
        selected: MapSet.new(),
        sigs: %{},
        visible: MapSet.new(),
        holding: MapSet.new(),
        gone: MapSet.new(),
        finals: %{},
        scores: %{},
        gaps: %{},
        points?: false,
        ended: nil,
        page_title: gettext("Projector view")
      )
      |> stream_configure(:tiles, dom_id: & &1.id)
      |> stream(:tiles, [])
      |> load(true)

    {:ok, socket, layout: false}
  end

  # `1,3,5` - and, forgivingly, `1, 3 ,5` or a list. Junk is dropped.
  @doc false
  def parse_boards(value) when is_binary(value),
    do: value |> String.split(",") |> parse_boards()

  def parse_boards(values) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case Integer.parse(String.trim(to_string(value))) do
        {n, ""} when n > 0 -> [n]
        _junk -> []
      end
    end)
    |> Enum.uniq()
  end

  def parse_boards(_absent), do: []

  defp parse_auto(value) when value in ["0", "false", "off", "no"], do: false
  defp parse_auto(_one_or_absent), do: true

  # --- reading -----------------------------------------------------------------

  defp load(socket, initial?) do
    case Tournaments.public_latest(socket.assigns.slug) do
      nil ->
        socket
        |> assign(payload: nil, snapshot_id: nil, round: nil, visible: MapSet.new(), ended: nil)
        |> stream(:tiles, [], reset: true)

      snapshot ->
        payload = snapshot.payload
        slug = socket.assigns.slug
        numbers = payload |> LiveBoardsData.rounds() |> Enum.map(&Map.get(&1, "number"))
        round = pick_round(socket.assigns.round_param, numbers)
        all = if round, do: LiveBoardsData.tiles(payload, slug, round, plies: false), else: []
        {tiles, all?} = choose(all, socket.assigns.wanted)

        socket
        |> assign(
          payload: payload,
          snapshot_id: snapshot.id,
          title: Tournament.name(payload),
          round: round,
          round_heading: round && Tournament.round_heading(payload, round),
          delay: LiveBoards.delay_minutes(slug),
          unknown_round?: round == nil,
          all?: all?,
          selected: MapSet.new(tiles, & &1.board),
          sigs: Map.new(tiles, &{&1.board, &1.signature}),
          scores: if(round, do: Tournament.scores_before(payload, round), else: %{}),
          gaps: if(round, do: Tournament.score_gaps(payload, round), else: %{}),
          points?: Tournament.show?(payload, "pairing_scores"),
          page_title: gettext("Projector view") <> " - " <> Tournament.name(payload)
        )
        |> place_all(tiles, initial?)
    end
  end

  defp pick_round(param, numbers) do
    case param && Integer.parse(param) do
      {n, ""} -> if n in numbers, do: n
      _junk -> nil
    end
  end

  # The boards asked for that the round has; all of them when that is none.
  defp choose(all, []), do: {all, true}

  defp choose(all, wanted) do
    case Enum.filter(all, &(&1.board in wanted)) do
      [] -> {all, true}
      some -> {some, length(some) == length(all)}
    end
  end

  # Every chosen tile, shown or not, and the stream rebuilt in board order.
  defp place_all(socket, tiles, initial?) do
    {socket, shown} =
      Enum.reduce(tiles, {socket, []}, fn tile, {socket, shown} ->
        case decide(socket, tile, initial?) do
          {socket, :show} -> {socket, [tile | shown]}
          {socket, :hide} -> {socket, shown}
        end
      end)

    shown = Enum.reverse(shown)

    socket
    |> assign(visible: MapSet.new(shown, & &1.board))
    |> stream(:tiles, Enum.map(shown, &item(socket, &1)), reset: true)
    |> settle_end(tiles)
  end

  # One tile read again: sent, or taken off the screen.
  defp place_one(socket, tile) do
    board = tile.board

    case decide(socket, tile, false) do
      {socket, :show} ->
        socket
        |> stream_insert(:tiles, item(socket, tile))
        |> assign(visible: MapSet.put(socket.assigns.visible, board), ended: nil)

      {socket, :hide} ->
        if MapSet.member?(socket.assigns.visible, board) do
          socket
          |> stream_delete_by_dom_id(:tiles, dom_id(board))
          |> assign(visible: MapSet.delete(socket.assigns.visible, board))
          |> settle_end(nil)
        else
          socket
        end
    end
  end

  # Whether a tile is on the screen, and - in the automatic mode - the
  # moment a game that has just ended starts its countdown off it.
  defp decide(%{assigns: %{auto: false}} = socket, _tile, _initial?), do: {socket, :show}

  defp decide(socket, tile, initial?) do
    %{gone: gone, holding: holding} = socket.assigns
    board = tile.board

    cond do
      MapSet.member?(gone, board) ->
        {socket, :hide}

      unplayed?(tile) ->
        {socket |> assign(gone: MapSet.put(gone, board)) |> remember(tile), :hide}

      not over?(tile) ->
        {socket, :show}

      MapSet.member?(holding, board) ->
        {socket, :show}

      # Over before the screen was up: decided, and not news.
      initial? ->
        {socket |> assign(gone: MapSet.put(gone, board)) |> remember(tile), :hide}

      true ->
        if connected?(socket), do: Process.send_after(self(), {:drop, board}, hold_ms())
        {socket |> assign(holding: MapSet.put(holding, board)) |> remember(tile), :show}
    end
  end

  # A game as it stood when it was decided, for the end screen: a board read
  # later may already carry the next thing the relay sent for it.
  defp remember(socket, tile),
    do: assign(socket, finals: Map.put(socket.assigns.finals, tile.board, summary(tile)))

  defp over?(tile), do: status(tile) == :finished or LiveBoardsData.result(tile) != nil

  # The end screen, once the automatic mode has nothing left to show. `tiles`
  # when the caller has them, else they are read.
  defp settle_end(%{assigns: %{auto: true, round: round}} = socket, tiles)
       when is_integer(round) do
    if MapSet.size(socket.assigns.visible) == 0 and MapSet.size(socket.assigns.selected) > 0 do
      tiles = tiles || selected_tiles(socket)
      finals = socket.assigns.finals

      ended =
        Enum.map(tiles, fn tile ->
          case {summary(tile), Map.get(finals, tile.board)} do
            {%{result: nil}, %{} = final} -> final
            {now, _final} -> now
          end
        end)

      assign(socket, ended: ended)
    else
      assign(socket, ended: nil)
    end
  end

  defp settle_end(socket, _tiles), do: assign(socket, ended: nil)

  defp selected_tiles(socket) do
    %{payload: payload, slug: slug, round: round, selected: selected} = socket.assigns

    payload
    |> LiveBoardsData.tiles(slug, round, plies: false)
    |> Enum.filter(&MapSet.member?(selected, &1.board))
  end

  defp summary(tile) do
    %{
      board: tile.board,
      label: tile.label,
      white: tile.white,
      black: tile.black,
      result: LiveBoardsData.result(tile),
      tile: tile
    }
  end

  defp dom_id(board), do: "proj-#{board}"

  defp item(socket, tile) do
    %{
      id: dom_id(tile.board),
      tile: tile,
      holding?: MapSet.member?(socket.assigns.holding, tile.board),
      points:
        if socket.assigns.points? do
          %{
            white: side_points(socket.assigns, tile.white),
            black: side_points(socket.assigns, tile.black)
          }
        end
    }
  end

  defp side_points(_assigns, nil), do: nil

  defp side_points(%{scores: scores, gaps: gaps}, person),
    do: %{points: Map.get(scores, person.no), reason: Map.get(gaps, person.no)}

  # --- updates -------------------------------------------------------------------

  defp refresh_board(%{assigns: %{payload: nil}} = socket, _board), do: socket
  defp refresh_board(%{assigns: %{round: nil}} = socket, _board), do: socket

  defp refresh_board(socket, board) do
    %{payload: payload, slug: slug, round: round, selected: selected} = socket.assigns

    with true <- MapSet.member?(selected, board),
         %{} = tile <- LiveBoardsData.tile(payload, slug, round, board, plies: false) do
      socket
      |> assign(sigs: Map.put(socket.assigns.sigs, board, tile.signature))
      |> place_one(tile)
    else
      _not_ours -> socket
    end
  end

  defp refresh_all(%{assigns: %{payload: nil}} = socket), do: socket
  defp refresh_all(%{assigns: %{round: nil}} = socket), do: socket

  defp refresh_all(socket) do
    sigs = socket.assigns.sigs

    socket
    |> selected_tiles()
    |> Enum.filter(&(Map.get(sigs, &1.board) != &1.signature))
    |> Enum.reduce(socket, fn tile, socket ->
      socket
      |> assign(sigs: Map.put(socket.assigns.sigs, tile.board, tile.signature))
      |> place_one(tile)
    end)
    |> assign(delay: LiveBoards.delay_minutes(socket.assigns.slug))
  end

  @impl true
  def handle_info(
        {:live_board, slug, round, board},
        %{assigns: %{slug: slug, round: round}} = socket
      ) do
    delay_ms = :timer.minutes(LiveBoards.delay_minutes(slug))

    if delay_ms == 0 do
      {:noreply, refresh_board(socket, board)}
    else
      Process.send_after(self(), {:refresh_board, board}, delay_ms + 50)
      {:noreply, socket}
    end
  end

  def handle_info({:live_board, _slug, _other_round, _board}, socket), do: {:noreply, socket}

  def handle_info({:refresh_board, board}, socket), do: {:noreply, refresh_board(socket, board)}

  # The half minute is up: the tile goes, the others take its room.
  def handle_info({:drop, board}, socket) do
    if MapSet.member?(socket.assigns.holding, board) do
      socket =
        assign(socket,
          holding: MapSet.delete(socket.assigns.holding, board),
          gone: MapSet.put(socket.assigns.gone, board)
        )

      {:noreply,
       socket
       |> stream_delete_by_dom_id(:tiles, dom_id(board))
       |> assign(visible: MapSet.delete(socket.assigns.visible, board))
       |> settle_end(nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:live_delay, _slug}, socket), do: {:noreply, load(socket, false)}

  def handle_info({:tournament_changed, slug}, %{assigns: %{slug: slug}} = socket) do
    if Tournaments.public_latest(slug) |> then(&(&1 && &1.id)) == socket.assigns.snapshot_id,
      do: {:noreply, socket},
      else: {:noreply, load(socket, false)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, refresh_all(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # --- the grid's first guess -------------------------------------------------------

  @doc """
  `{columns, rows}` that give `n` tiles the largest board on a `width` x
  `height` stage - the hook's sum, done once here for a 16:9 window so the
  page is laid out sensibly before the hook has run.
  """
  def best_grid(n, width \\ 16, height \\ 9)
  def best_grid(n, _width, _height) when n < 1, do: {1, 1}

  def best_grid(n, width, height) do
    {cols, _size} =
      1..n
      |> Enum.map(fn cols ->
        rows = div(n + cols - 1, cols)
        {cols, min(width / cols, height / rows / @tile_ratio)}
      end)
      |> Enum.max_by(&elem(&1, 1), fn -> {1, 0} end)

    {cols, div(n + cols - 1, cols)}
  end

  # --- the page ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    {cols, rows} = best_grid(MapSet.size(assigns.visible))
    assigns = assign(assigns, cols: cols, rows: rows, count: MapSet.size(assigns.visible))

    ~H"""
    <div
      id="proj"
      class={["proj", @ended && "is-ended"]}
      phx-hook=".ProjectorFit"
      data-count={@count}
      data-theme-choice={@theme}
    >
      <a class="skip-link" href="#proj-stage">{gettext("Skip to content")}</a>
      <header class="proj-head">
        <span class="lb-live-dot" aria-hidden="true"></span>
        <h1 id="proj-title" class="proj-title">{@title}</h1>
        <span :if={@round_heading} id="proj-round" class="proj-round">{@round_heading}</span>
        <.offline_note id="proj-offline" class="proj-offline" />
        <span :if={@delay > 0} id="proj-delay" class="proj-delay">
          {ngettext(
            "shown %{count} minute behind the game",
            "shown %{count} minutes behind the game",
            @delay
          )}
        </span>
        <span class="proj-spacer"></span>
        <div id="proj-tools" class="proj-tools" phx-update="ignore">
          <button
            type="button"
            id="proj-fullscreen"
            class="proj-fs"
            title={gettext("Full screen (F)")}
            aria-label={gettext("Full screen")}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true" class="lb-icon">
              <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />
            </svg>
          </button>
        </div>
      </header>

      <main id="proj-stage" class="proj-stage" tabindex="-1">
        <p :if={is_nil(@payload)} id="proj-unavailable" class="proj-empty">
          {gettext("Nothing is published for this tournament at the moment.")}
        </p>
        <p :if={@payload && @unknown_round?} id="proj-unknown-round" class="proj-empty">
          {gettext("This round has not been published.")}
        </p>

        <section :if={@ended} id="proj-end" class="proj-end" aria-labelledby="proj-end-title">
          <h2 id="proj-end-title">{gettext("All selected games have finished")}</h2>
          <table id="proj-end-results" class="proj-end-table">
            <caption class="visually-hidden">{gettext("Results")}</caption>
            <tbody>
              <tr :for={s <- @ended} id={"proj-end-#{s.board}"}>
                <th scope="row" class="proj-end-bd">{s.label}</th>
                <td class="proj-end-white">{person_name(s.white)}</td>
                <td class="proj-end-result">
                  <.result_mark :if={s.result} result={s.result} tile={s.tile} />
                  <span :if={is_nil(s.result)}>-</span>
                </td>
                <td class="proj-end-black">{person_name(s.black)}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <div
          id="proj-grid"
          class="proj-grid"
          phx-update="stream"
          style={"--proj-cols-guess: #{@cols}; --proj-rows-guess: #{@rows}"}
        >
          <div :for={{id, item} <- @streams.tiles} id={id} class="proj-cell">
            <.proj_tile item={item} pieces={@pieces} auto={@auto} />
          </div>
        </div>
      </main>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProjectorFit">
      // The grid: for N tiles on this window, the column count that gives the
      // largest board. A tile is `ratio` times as tall as it is wide - the
      // board plus the bars, all fractions of the board in the stylesheet,
      // read from there so the two cannot disagree. The answer goes on the
      // root element as --proj-cols/--proj-rows: LiveView never patches
      // <html>, so a page update cannot wipe it.
      const MIN_BOARD = 200

      const num = (style, name) => parseFloat(style.getPropertyValue(name)) || 0

      export default {
        mounted() {
          const choice = this.el.dataset.themeChoice
          if (choice) document.documentElement.setAttribute("data-theme", choice)

          this.fit = () => {
            const stage = document.getElementById("proj-stage")
            const grid = document.getElementById("proj-grid")
            const root = document.documentElement
            const n = Number(this.el.dataset.count) || 0
            if (!stage || !grid || n < 1) return

            const css = getComputedStyle(grid)
            const ratio = 1 + num(css, "--proj-cap") + 2 * num(css, "--proj-bar") + 3 * num(css, "--proj-gap")
            const gap = parseFloat(css.columnGap) || 0
            const W = stage.clientWidth
            const H = stage.clientHeight

            let best = {cols: 1, rows: n, board: 0}
            for (let cols = 1; cols <= n; cols++) {
              const rows = Math.ceil(n / cols)
              const w = (W - (cols - 1) * gap) / cols
              const h = (H - (rows - 1) * gap) / rows
              const board = Math.min(w, h / ratio)
              if (board > best.board + 0.5) best = {cols, rows, board}
            }

            // Too many boards for a narrow window to show legibly at once (a
            // phone): as many columns as fit at a readable size, and the page
            // scrolls instead. A wide screen never scrolls - a projector has
            // nobody to scroll it.
            if (best.board < MIN_BOARD && n > 1 && W < 3 * MIN_BOARD) {
              const cols = Math.max(1, Math.floor((W + gap) / (MIN_BOARD + gap)))
              const w = (W - (cols - 1) * gap) / cols
              root.style.setProperty("--proj-cols", cols)
              root.style.setProperty("--proj-rows", Math.ceil(n / cols))
              root.style.setProperty("--proj-row-h", `${Math.floor(w * ratio)}px`)
              root.dataset.projMode = "scroll"
            } else {
              root.style.setProperty("--proj-cols", best.cols)
              root.style.setProperty("--proj-rows", best.rows)
              root.style.removeProperty("--proj-row-h")
              root.dataset.projMode = "fit"
            }
          }

          this.observer = new ResizeObserver(() => this.fit())
          this.observer.observe(document.getElementById("proj-stage"))
          window.addEventListener("resize", this.fit)
          document.addEventListener("fullscreenchange", this.fit)
          this.fit()

          // Full screen: the button (hidden by the stylesheet while full
          // screen is on, and here when the browser has none) and the `f` key.
          const button = document.getElementById("proj-fullscreen")
          const enabled = document.fullscreenEnabled || document.webkitFullscreenEnabled
          if (!enabled) button.hidden = true
          this.toggle = () => {
            if (!enabled) return
            const on = document.fullscreenElement || document.webkitFullscreenElement
            const el = document.documentElement
            const call = on
              ? (document.exitFullscreen || document.webkitExitFullscreen).call(document)
              : (el.requestFullscreen || el.webkitRequestFullscreen).call(el, {navigationUI: "hide"})
            if (call && call.catch) call.catch(() => {})
          }
          button.addEventListener("click", this.toggle)
          this.onKey = (e) => {
            if (e.altKey || e.ctrlKey || e.metaKey) return
            if (e.key !== "f" && e.key !== "F") return
            if (e.target && e.target.closest && e.target.closest("input, textarea, select")) return
            this.toggle()
          }
          window.addEventListener("keydown", this.onKey)
        },
        updated() { this.fit() },
        destroyed() {
          if (this.observer) this.observer.disconnect()
          window.removeEventListener("resize", this.fit)
          window.removeEventListener("keydown", this.onKey)
          document.removeEventListener("fullscreenchange", this.fit)
        }
      }
    </script>
    """
  end

  attr :item, :map, required: true
  attr :pieces, :string, required: true
  attr :auto, :boolean, required: true

  defp proj_tile(assigns) do
    tile = assigns.item.tile
    unplayed? = unplayed?(tile)
    view = if unplayed?, do: nil, else: tile.view
    status = status(tile)
    result = LiveBoardsData.result(tile)

    assigns =
      assign(assigns,
        tile: tile,
        board: tile.board,
        status: status,
        result: result,
        unplayed?: unplayed?,
        blank?: unplayed? or (is_nil(view) and status == :finished),
        fen: (view && view.fen) || OpenResults.Chess.start_fen(),
        last: view && view.last,
        clocks: view && view.clocks
      )

    ~H"""
    <article
      class={[
        "proj-tile",
        "lb-status-#{@status}",
        (@result || @unplayed?) && "is-over",
        @item.holding? && "is-leaving"
      ]}
      aria-label={tile_label(@tile)}
    >
      <p class="proj-cap">
        <span class="proj-bd">{gettext("Board %{board}", board: @tile.label)}</span>
        <span id={"proj-#{@board}-status"} class="proj-state">
          <span :if={@status == :live} class="lb-live-dot" aria-hidden="true"></span>
          {status_label(@status, nil)}
        </span>
      </p>
      <.side tile={@tile} colour="black" clocks={@clocks} points={@item.points} />
      <div class="proj-board">
        <.board_svg
          id={"proj-#{@board}-board"}
          fen={@fen}
          last={@last}
          label={tile_label(@tile)}
          set={@pieces}
          empty={@blank?}
        />
        <p :if={@result} id={"proj-#{@board}-result"} class="proj-result">
          <span>
            <.result_mark result={@result} tile={@tile} />
          </span>
        </p>
        <p :if={@unplayed? and is_nil(@result)} class="proj-result proj-result-note">
          <span>{unplayed_note(@tile)}</span>
        </p>
      </div>
      <.side tile={@tile} colour="white" clocks={@clocks} points={@item.points} />
    </article>
    """
  end

  attr :tile, :map, required: true
  attr :colour, :string, required: true
  attr :clocks, :any, default: nil
  attr :points, :any, default: nil

  defp side(assigns) do
    colour = assigns.colour
    key = String.to_existing_atom(colour)
    person = Map.get(assigns.tile, key)
    ms = assigns.clocks && Map.get(assigns.clocks, key)
    running = (assigns.clocks && assigns.clocks.running == colour) || false

    assigns =
      assign(assigns,
        person: person,
        ms: ms,
        running: running,
        prefix: "proj-#{assigns.tile.board}-#{colour}",
        side_points: assigns.points && Map.get(assigns.points, key)
      )

    ~H"""
    <div id={@prefix} class={["proj-bar", "proj-bar-#{@colour}", @running && "is-to-move"]}>
      <span class={["lb-dot", "lb-dot-#{@colour}"]} aria-hidden="true"></span>
      <span class="visually-hidden">
        {if @colour == "white", do: gettext("White"), else: gettext("Black")}:
      </span>
      <div class="proj-who">
        <p id={"#{@prefix}-name"} class="proj-name">
          <Flags.flag
            :if={@person && @person[:flag]}
            src={@person.flag}
            code={@person.federation}
            label
          />
          <span :if={@person && @person.title} class="lb-title">{@person.title}</span>
          <span class="lb-person">{person_name(@person)}</span>
        </p>
        <p class="proj-meta">
          <span :if={@person && @person.rating} id={"#{@prefix}-elo"} class="proj-elo">
            <span class="proj-k">Elo</span> {@person.rating}
          </span>
          <span :if={@side_points} id={"#{@prefix}-points"} class="proj-pts">
            <TournamentHTML.score points={@side_points.points} reason={@side_points.reason} />
            <span class="proj-k">{gettext("pts")}</span>
          </span>
        </p>
      </div>
      <.clock
        id={"proj-#{@tile.board}-clock-#{@colour}"}
        ms={@ms}
        running={@running}
        class="proj-clock"
      />
    </div>
    """
  end

  defp person_name(nil), do: "-"
  defp person_name(person), do: person.name
end
