defmodule OpenResultsWeb.BroadcastLive do
  @moduledoc """
  A round as a broadcast: every game of the round on the left, one game large
  in the middle, its moves on the right. `GET /t/:slug/live/:round` features
  the first game in progress; `GET /t/:slug/live/:round/:board` features that
  board, so a link to one game still is one. `GET /t/:slug/live` goes to the
  newest round. The grid of every board of a round is
  `OpenResultsWeb.BoardsLive`, one click away.

  ## What is drawn, and what is only listed

  One big board and a list. The list is a stream of small rows (names,
  result, whether it is live) and never draws a board, so a round of sixty
  games costs sixty rows of text; only the featured game reads its moves.
  Picking another game is a patch: the list stays, two of its rows are sent
  again (the old and the new featured one), and the centre is redrawn.

  ## The featured game

  While nothing is selected the page follows the game: a move that arrives is
  on the board a moment later. Selecting an earlier move stops following
  until "Follow live" is pressed, so a spectator studying move 20 is not
  dragged to move 34. There is no engine and no evaluation, and nothing here
  pretends to be one.

  Keys (outside the search box): left and right step, up and down (or Home
  and End) jump to the start and to the latest move, `f` flips the board.

  ## Updates

  As `OpenResultsWeb.BoardsLive`: a changed board re-reads that board alone
  (its row, and the featured game when it is that one), the broadcast delay
  is applied by reading the game as it stood `delay` ago, a tick every
  #{15} seconds is the net under a lost message, and a publish re-reads the
  names and pairings. Nothing here passes through the page cache. What may
  be shown is `OpenResultsWeb.LiveBoardsData`'s rule.
  """

  use OpenResultsWeb, :live_view

  import OpenResultsWeb.LiveBoardsComponents

  alias OpenResults.Chess
  alias OpenResults.LiveBoards
  alias OpenResults.TournamentEvents
  alias OpenResults.Tournaments
  alias OpenResultsWeb.Format
  alias OpenResultsWeb.LiveBoardsData
  alias OpenResultsWeb.ProjectorPicker
  alias OpenResultsWeb.Tournament
  alias Phoenix.LiveView.JS

  @tick :timer.seconds(15)

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
        payload: nil,
        snapshot_id: nil,
        title: slug,
        rounds: [],
        round_param: :unset,
        round: nil,
        round_heading: nil,
        info: nil,
        team?: false,
        delay: 0,
        sigs: %{},
        game_count: 0,
        default_board: nil,
        board: nil,
        featured: nil,
        selected: nil,
        flip: false,
        query: "",
        search_form: to_form(%{"q" => ""}, as: :search),
        tab: "moves",
        unknown_round?: false,
        page_title: gettext("Live boards")
      )
      |> stream_configure(:pairings, dom_id: & &1.id)
      |> stream(:pairings, [])
      |> ProjectorPicker.init()

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :index}} = socket) do
    socket = assign(socket, round_param: nil) |> load(nil)

    case socket.assigns.round do
      nil ->
        {:noreply, socket}

      round ->
        query =
          if params["pieces"], do: "?" <> URI.encode_query(pieces: params["pieces"]), else: ""

        {:noreply,
         push_patch(socket, to: "/t/#{socket.assigns.slug}/live/#{round}" <> query, replace: true)}
    end
  end

  def handle_params(params, _uri, socket) do
    round_param = params["round"]
    board = parse(params["board"])

    socket =
      if socket.assigns.payload == nil or socket.assigns.round_param != round_param do
        socket |> assign(round_param: round_param, selected: nil) |> load(board)
      else
        feature(socket, board)
      end

    {:noreply, socket}
  end

  defp parse(nil), do: nil

  defp parse(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _junk -> nil
    end
  end

  # --- reading -----------------------------------------------------------------

  # The round, its list and the featured game, all read again.
  defp load(socket, wanted_board) do
    case Tournaments.public_latest(socket.assigns.slug) do
      nil ->
        socket
        |> assign(
          payload: nil,
          snapshot_id: nil,
          rounds: [],
          round: nil,
          featured: nil,
          board: nil,
          sigs: %{},
          game_count: 0
        )
        |> stream(:pairings, [], reset: true)

      snapshot ->
        payload = snapshot.payload
        slug = socket.assigns.slug
        numbers = payload |> LiveBoardsData.rounds() |> Enum.map(&Map.get(&1, "number"))
        round = pick_round(socket.assigns.round_param, numbers)

        tiles =
          if round, do: LiveBoardsData.tiles(payload, slug, round, plies: false), else: []

        default = default_board(tiles)
        board = wanted_board || default

        socket
        |> assign(
          payload: payload,
          snapshot_id: snapshot.id,
          title: Tournament.name(payload),
          rounds: numbers,
          round: round,
          round_heading: round && Tournament.round_heading(payload, round),
          info: LiveBoardsData.event_info(payload, round),
          team?: Tournament.team_event?(payload),
          delay: LiveBoards.delay_minutes(slug),
          unknown_round?: socket.assigns.round_param != nil and round == nil,
          sigs: Map.new(tiles, &{&1.board, LiveBoardsData.stamp(&1)}),
          game_count: length(tiles),
          default_board: default,
          board: board
        )
        |> stream(:pairings, items(socket.assigns.query, tiles, board, payload, round),
          reset: true
        )
        |> read_featured()
    end
  end

  defp pick_round(nil, numbers), do: List.last(numbers)

  defp pick_round(param, numbers) do
    case parse(param) do
      n when is_integer(n) -> if n in numbers, do: n
      nil -> nil
    end
  end

  # The game a round opens on: the first one being played, else the first
  # one that was, else board one. Never a forfeit when anything else exists.
  defp default_board([]), do: nil

  defp default_board(tiles) do
    played = Enum.reject(tiles, &unplayed?/1)

    found =
      Enum.find(played, &(status(&1) == :live)) ||
        Enum.find(played, &(status(&1) == :finished)) ||
        List.first(played) || List.first(tiles)

    found.board
  end

  # Another board in the same round: the two rows whose highlight moves are
  # sent again, and the centre is read for the new one.
  defp feature(socket, wanted) do
    board = wanted || socket.assigns.default_board
    old = socket.assigns.board

    if board == old do
      socket
    else
      socket
      |> assign(board: board, selected: nil)
      |> read_featured()
      |> reinsert_row(old)
      |> reinsert_row(board)
    end
  end

  defp read_featured(%{assigns: %{payload: payload, round: round, board: board}} = socket)
       when not is_nil(payload) and is_integer(round) and is_integer(board) do
    tile = LiveBoardsData.tile(payload, socket.assigns.slug, round, board)

    socket
    |> assign(featured: tile, page_title: page_title(tile, socket.assigns.title))
    |> clamp()
  end

  defp read_featured(socket),
    do: assign(socket, featured: nil, page_title: page_title(nil, socket.assigns.title))

  defp page_title(nil, title), do: gettext("Live boards") <> " - " <> title

  defp page_title(tile, _title),
    do: "#{(tile.white && tile.white.name) || "-"} - #{(tile.black && tile.black.name) || "-"}"

  # A selection past the end of the game it points into stops being one.
  defp clamp(%{assigns: %{selected: nil}} = socket), do: socket

  defp clamp(%{assigns: %{featured: %{view: %{plies: plies, ply: ply}}, selected: n}} = socket) do
    if length(plies) != ply or n >= ply, do: assign(socket, selected: nil), else: socket
  end

  defp clamp(socket), do: assign(socket, selected: nil)

  # One row of the list, read again and sent - unless the search hides it,
  # because inserting a row the list does not show would add it.
  defp reinsert_row(socket, nil), do: socket

  defp reinsert_row(socket, board) do
    %{payload: payload, slug: slug, round: round} = socket.assigns

    with %{} = tile <-
           payload && round && LiveBoardsData.tile(payload, slug, round, board, plies: false),
         true <- matches?(tile, socket.assigns.query) do
      stream_insert(socket, :pairings, row(tile, socket.assigns.board))
    else
      _gone_or_hidden -> socket
    end
  end

  # A board that changed: its row when its stamp moved - the picture, or a
  # fresh clock report (`LiveBoardsData.stamp/1`) - and the featured game when
  # it is this one. A repeat sends no row.
  defp refresh_board(%{assigns: %{payload: nil}} = socket, _board), do: socket
  defp refresh_board(%{assigns: %{round: nil}} = socket, _board), do: socket

  defp refresh_board(socket, board) do
    %{payload: payload, slug: slug, round: round, sigs: sigs} = socket.assigns

    socket =
      case LiveBoardsData.tile(payload, slug, round, board, plies: false) do
        nil ->
          socket

        tile ->
          stamp = LiveBoardsData.stamp(tile)

          if Map.get(sigs, board) != stamp and matches?(tile, socket.assigns.query) do
            socket
            |> stream_insert(:pairings, row(tile, socket.assigns.board))
            |> assign(sigs: Map.put(sigs, board, stamp))
          else
            assign(socket, sigs: Map.put(sigs, board, stamp))
          end
      end

    if board == socket.assigns.board, do: read_featured(socket), else: socket
  end

  defp refresh_all(%{assigns: %{payload: nil}} = socket), do: socket
  defp refresh_all(%{assigns: %{round: nil}} = socket), do: socket

  defp refresh_all(socket) do
    %{payload: payload, slug: slug, round: round, sigs: sigs, query: query} = socket.assigns
    tiles = LiveBoardsData.tiles(payload, slug, round, plies: false)

    tiles
    |> Enum.filter(&(Map.get(sigs, &1.board) != LiveBoardsData.stamp(&1) and matches?(&1, query)))
    |> Enum.reduce(socket, &stream_insert(&2, :pairings, row(&1, socket.assigns.board)))
    |> assign(
      sigs: Map.new(tiles, &{&1.board, LiveBoardsData.stamp(&1)}),
      delay: LiveBoards.delay_minutes(slug)
    )
    |> read_featured()
  end

  # --- the list ------------------------------------------------------------------

  # The rows of the list, in board order; a team round's boards under a
  # heading for their match.
  defp items(query, tiles, featured, payload, round) do
    results? = Tournament.results_public?(Tournament.round(payload, round))

    tiles
    |> Enum.filter(&matches?(&1, query))
    |> Enum.flat_map_reduce(nil, fn tile, current ->
      case tile.match do
        %{} = match when match != current ->
          {[LiveBoardsData.match_header(payload, round, match, results?), row(tile, featured)],
           match}

        _same_or_none ->
          {[row(tile, featured)], current}
      end
    end)
    |> elem(0)
  end

  defp row(tile, featured) do
    tile
    |> Map.merge(%{
      id: "lb-pair-#{tile.round}-#{tile.board}",
      kind: :board,
      featured?: tile.board == featured
    })
  end

  defp matches?(_tile, ""), do: true

  defp matches?(tile, query) do
    needle = String.downcase(query)

    [tile.white, tile.black]
    |> Enum.flat_map(fn
      nil -> []
      person -> [person.name, person.federation, person.title]
    end)
    |> Enum.concat(match_teams(tile))
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
  end

  defp match_teams(tile), do: Map.get(tile, :team_names, [])

  # --- messages ----------------------------------------------------------------

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

  def handle_info({:refresh_board, board}, socket),
    do: {:noreply, refresh_board(socket, board)}

  def handle_info({:live_delay, _slug}, socket),
    do: {:noreply, load(socket, socket.assigns.board)}

  def handle_info({:tournament_changed, slug}, %{assigns: %{slug: slug}} = socket) do
    if Tournaments.public_latest(slug) |> then(&(&1 && &1.id)) == socket.assigns.snapshot_id,
      do: {:noreply, socket},
      else: {:noreply, load(socket, socket.assigns.board)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, refresh_all(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- events ------------------------------------------------------------------

  @impl true
  def handle_event("goto", %{"ply" => ply}, socket), do: {:noreply, select(socket, parse(ply))}
  def handle_event("first", _params, socket), do: {:noreply, select(socket, 0)}
  def handle_event("last", _params, socket), do: {:noreply, assign(socket, selected: nil)}
  def handle_event("live", _params, socket), do: {:noreply, assign(socket, selected: nil)}
  def handle_event("prev", _params, socket), do: {:noreply, step(socket, -1)}
  def handle_event("next", _params, socket), do: {:noreply, step(socket, 1)}

  def handle_event("flip", _params, socket),
    do: {:noreply, assign(socket, flip: !socket.assigns.flip)}

  def handle_event("key", %{"key" => key}, socket) do
    case key do
      "ArrowLeft" -> {:noreply, step(socket, -1)}
      "ArrowRight" -> {:noreply, step(socket, 1)}
      k when k in ["ArrowUp", "Home"] -> {:noreply, select(socket, 0)}
      k when k in ["ArrowDown", "End"] -> {:noreply, assign(socket, selected: nil)}
      k when k in ["f", "F"] -> {:noreply, assign(socket, flip: !socket.assigns.flip)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["moves", "info"],
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("search", %{"search" => %{"q" => q}}, socket) do
    query = q |> to_string() |> String.trim() |> String.slice(0, 60)
    %{payload: payload, slug: slug, round: round} = socket.assigns

    tiles =
      if payload && round, do: LiveBoardsData.tiles(payload, slug, round, plies: false), else: []

    {:noreply,
     socket
     |> assign(query: query, search_form: to_form(%{"q" => q}, as: :search))
     |> stream(:pairings, items(query, tiles, socket.assigns.board, payload, round), reset: true)}
  end

  def handle_event("pieces", %{"set" => set}, socket) do
    case OpenResultsWeb.Pieces.known(set) do
      nil -> {:noreply, socket}
      set -> {:noreply, assign(socket, :pieces, set)}
    end
  end

  def handle_event("projector_" <> _ = event, params, socket),
    do: {:noreply, ProjectorPicker.handle_event(event, params, socket)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp step(socket, by), do: select(socket, current_ply(socket.assigns) + by)

  defp select(%{assigns: %{featured: %{view: %{plies: plies, ply: ply}}}} = socket, n)
       when is_integer(n) and length(plies) == ply do
    cond do
      n >= ply -> assign(socket, selected: nil)
      n <= 0 -> assign(socket, selected: 0)
      true -> assign(socket, selected: n)
    end
  end

  defp select(socket, _n), do: socket

  defp current_ply(%{featured: %{view: %{ply: ply}}, selected: nil}), do: ply
  defp current_ply(%{selected: n}) when is_integer(n), do: n
  defp current_ply(_assigns), do: 0

  # --- what is on the board ----------------------------------------------------

  # {fen, highlighted squares, ply shown}
  defp shown(%{plies: plies, ply: ply} = view, selected) do
    n = selected || ply

    cond do
      n >= ply ->
        {view.fen, view.last, ply}

      n <= 0 ->
        {view.start_fen, nil, 0}

      true ->
        entry = Enum.at(plies, n - 1)
        {entry["fen"], {entry["from"], entry["to"]}, n}
    end
  end

  # The move list as rows: `%{number, white: {ply, san} | nil, black: ...}`.
  defp rows(%{plies: plies, start_fen: start}) do
    {turn, number} =
      case Chess.parse_fen(start) do
        {:ok, position} -> {position.turn, position.fullmove}
        _error -> {:w, 1}
      end

    entries =
      plies
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, ply} -> {ply, entry["san"]} end)

    entries = if turn == :b, do: [nil | entries], else: entries

    entries
    |> Enum.chunk_every(2)
    |> Enum.with_index(number)
    |> Enum.map(fn {pair, n} ->
      %{number: n, white: Enum.at(pair, 0), black: Enum.at(pair, 1)}
    end)
  end

  defp assign_view(%{featured: nil} = assigns) do
    assign(assigns,
      status: :waiting,
      result: nil,
      scores: nil,
      clocks: nil,
      fen: Chess.start_fen(),
      marked: nil,
      rows: [],
      steps: 0,
      shown_ply: 0,
      following?: true,
      unplayed?: false,
      blank?: false,
      top: "black",
      bottom: "white"
    )
  end

  defp assign_view(%{featured: tile} = assigns) do
    unplayed? = unplayed?(tile)
    view = if unplayed?, do: nil, else: tile.view
    blank? = unplayed? or (is_nil(view) and status(tile) == :finished)

    {fen, marked, shown_ply} =
      case view do
        nil -> {Chess.start_fen(), nil, 0}
        view -> shown(view, assigns.selected)
      end

    steps = if view && length(view.plies) == view.ply, do: view.ply, else: 0

    assign(assigns,
      status: status(tile),
      result: LiveBoardsData.result(tile),
      scores: LiveBoardsData.scores(tile),
      clocks: view && view.clocks,
      fen: fen,
      marked: marked,
      rows: if(view && steps > 0, do: rows(view), else: []),
      steps: steps,
      shown_ply: shown_ply,
      following?: assigns.selected == nil,
      unplayed?: unplayed?,
      blank?: blank?,
      top: if(assigns.flip, do: "white", else: "black"),
      bottom: if(assigns.flip, do: "black", else: "white")
    )
  end

  # --- the page ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign_view(assigns)

    ~H"""
    <div id="lb-game-page" phx-hook=".GameKeys">
      <.shell
        locale={@locale}
        path={current_path(@slug, @round, @board, @live_action)}
        slug={@slug}
        title={@title}
        pieces={@pieces}
        wide={true}
      >
        <header class="lb-bc-head">
          <div class="lb-bc-heading">
            <p class="lb-eyebrow">
              <span class="lb-live-dot" aria-hidden="true"></span>{gettext("Live boards")}
            </p>

            <h1 id="lb-title" class="lb-bc-title">
              <a href={~p"/t/#{@slug}"}>{@title}</a>
            </h1>
          </div>

          <div :if={@round} class="lb-head-tools">
            <.view_switch slug={@slug} round={@round} board={@board} current={:broadcast} />
            <ProjectorPicker.button />
          </div>
        </header>
        <ProjectorPicker.picker picker={@projector} slug={@slug} round={@round} pieces={@pieces} />
        <p :if={is_nil(@payload)} id="lb-unavailable" class="empty">
          {gettext("Nothing is published for this tournament at the moment.")}
        </p>

        <p :if={@payload && @rounds == []} id="lb-no-rounds" class="empty">
          {gettext("No round has been published yet, so there are no boards to follow.")}
        </p>

        <p :if={@unknown_round?} id="lb-unknown-round" class="empty">
          {gettext("This round has not been published.")}
        </p>

        <div :if={@round} id="lb-broadcast" class="lb-bc">
          <nav id="lb-rail" class="lb-rail" aria-label={gettext("Rounds and games")}>
            <div class="lb-panel lb-rounds-panel">
              <p class="lb-panel-label" id="lb-rounds-label">{gettext("Round")}</p>

              <ul id="lb-rounds" class="lb-pills" aria-labelledby="lb-rounds-label">
                <li :for={n <- @rounds}>
                  <.link
                    patch={~p"/t/#{@slug}/live/#{n}"}
                    class={["lb-pill", n == @round && "is-current"]}
                    aria-current={n == @round && "page"}
                    aria-label={Tournament.round_heading(@payload, n)}
                  >
                    {Tournament.round_label(@payload, n)}
                  </.link>
                </li>
              </ul>
            </div>

            <button
              type="button"
              id="lb-pairings-toggle"
              class="lb-drawer-toggle"
              aria-controls="lb-rail-panel"
              aria-expanded="false"
              phx-click={
                JS.toggle_class("is-open", to: "#lb-rail-panel")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"})
              }
            >
              <span>
                {ngettext("%{count} game in this round", "%{count} games in this round", @game_count)}
              </span>
              <span class="lb-chevron" aria-hidden="true"></span>
            </button>

            <div id="lb-rail-panel" class="lb-panel lb-rail-panel">
              <.form
                for={@search_form}
                id="lb-search"
                class="lb-search"
                role="search"
                phx-change="search"
                phx-submit="search"
              >
                <label for="lb-search-q" class="visually-hidden">
                  {if @team?,
                    do: gettext("Find a player or a team"),
                    else: gettext("Find a player")}
                </label>

                <input
                  type="search"
                  id="lb-search-q"
                  name={@search_form[:q].name}
                  value={@search_form[:q].value}
                  placeholder={
                    if @team?,
                      do: gettext("Find a player or a team"),
                      else: gettext("Find a player")
                  }
                  autocomplete="off"
                  phx-debounce="200"
                />
              </.form>

              <ul id="lb-pairings" class="lb-pairings" phx-update="stream">
                <li id="lb-pairings-empty" class="lb-pairings-empty">
                  {gettext("No game matches that name.")}
                </li>

                <li
                  :for={{id, item} <- @streams.pairings}
                  id={id}
                  class={[
                    "lb-pairing-item",
                    item.kind == :match && "lb-pairing-match"
                  ]}
                >
                  <.pairing_row item={item} slug={@slug} round={@round} />
                </li>
              </ul>
            </div>
          </nav>

          <section
            id="lb-stage"
            class="lb-stage"
            aria-labelledby={@featured && "lb-game-title"}
            aria-label={is_nil(@featured) && gettext("Board")}
          >
            <p :if={is_nil(@featured)} id="lb-no-game" class="empty">
              {gettext("This board is not published.")}
            </p>

            <div :if={@featured} id="lb-game" class="lb-game">
              <header class="lb-stage-head">
                <h2 id="lb-game-title" class="lb-stage-title">
                  {gettext("Round %{round}, board %{board}",
                    round: @featured.round,
                    board: @featured.label
                  )}
                </h2>
                <.status_badge id="lb-game-status" status={@status} />
                <.result_mark
                  :if={@result}
                  id="lb-game-result"
                  result={@result}
                  tile={@featured}
                  class="lb-stage-result"
                /> <span class="lb-stage-spacer"></span>
                <button
                  type="button"
                  id="lb-fullscreen"
                  class="lb-icon-btn"
                  phx-hook=".Fullscreen"
                  phx-update="ignore"
                  data-target="lb-stage"
                  aria-label={gettext("Full screen")}
                  title={gettext("Full screen")}
                >
                  <svg viewBox="0 0 24 24" aria-hidden="true" class="lb-icon">
                    <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />
                  </svg>
                </button>
              </header>

              <p :if={@delay > 0 or @status == :waiting} class="lb-stage-note">
                <span :if={@status == :waiting} id="lb-not-started">
                  {gettext("The game has not started yet.")}
                </span>

                <span :if={@delay > 0} id="lb-delay">
                  {ngettext(
                    "shown %{count} minute behind the game",
                    "shown %{count} minutes behind the game",
                    @delay
                  )}
                </span>
              </p>

              <div class="lb-board-column">
                <.player_bar
                  tile={@featured}
                  colour={@top}
                  clocks={@clocks}
                  score={@scores && side_score(@scores, @top)}
                />
                <div class="lb-board-frame">
                  <.board_svg
                    id="lb-game-board"
                    fen={@fen}
                    last={@marked}
                    flip={@flip}
                    coords={true}
                    label={tile_label(@featured)}
                    set={@pieces}
                    empty={@blank?}
                    class="lb-board-large"
                  />
                  <p :if={@unplayed?} id="lb-unplayed" class="lb-board-caption">
                    <span>{unplayed_note(@featured)}</span>
                  </p>
                </div>

                <.player_bar
                  tile={@featured}
                  colour={@bottom}
                  clocks={@clocks}
                  score={@scores && side_score(@scores, @bottom)}
                />
              </div>

              <div
                :if={not @unplayed?}
                class="lb-controls"
                role="group"
                aria-label={gettext("Step through the game")}
              >
                <button
                  type="button"
                  id="lb-first"
                  phx-click="first"
                  class="lb-btn"
                  disabled={@steps == 0}
                  aria-label={gettext("Start of the game")}
                  title={gettext("Start of the game")}
                >
                  &laquo;
                </button>

                <button
                  type="button"
                  id="lb-prev"
                  phx-click="prev"
                  class="lb-btn"
                  disabled={@steps == 0 or @shown_ply == 0}
                  aria-label={gettext("Previous move")}
                  title={gettext("Previous move")}
                >
                  &lsaquo;
                </button>

                <button
                  type="button"
                  id="lb-next"
                  phx-click="next"
                  class="lb-btn"
                  disabled={@steps == 0 or @following?}
                  aria-label={gettext("Next move")}
                  title={gettext("Next move")}
                >
                  &rsaquo;
                </button>

                <button
                  type="button"
                  id="lb-last"
                  phx-click="last"
                  class="lb-btn"
                  disabled={@steps == 0 or @following?}
                  aria-label={gettext("Latest move")}
                  title={gettext("Latest move")}
                >
                  &raquo;
                </button>

                <button type="button" id="lb-flip" phx-click="flip" class="lb-btn lb-btn-text">
                  {gettext("Flip board")}
                </button>

                <button
                  :if={not @following? and @status == :live}
                  type="button"
                  id="lb-follow"
                  phx-click="live"
                  class="lb-btn lb-btn-text lb-btn-live"
                >
                  {gettext("Follow live")}
                </button>
              </div>
            </div>
          </section>

          <aside id="lb-side" class="lb-side" aria-label={gettext("Moves and event")}>
            <section id="lb-event" class="lb-panel lb-event">
              <p class="lb-panel-label">{@round_heading}</p>

              <p class="lb-event-name">{@info.name}</p>

              <p :if={@info.start_date || @info.city} class="lb-event-meta">
                <span :if={@info.start_date}>
                  {if @info.end_date && @info.end_date != @info.start_date,
                    do: Format.date_range(@info.start_date, @info.end_date),
                    else: Format.date(@info.start_date)}
                </span>
                <span :if={@info.city}>{@info.city}</span>
              </p>

              <p :if={@info.round_date} class="lb-event-meta">
                {@round_heading}: {Format.date(@info.round_date)}
              </p>
            </section>

            <section :if={@featured} class="lb-panel lb-moves-panel">
              <div class="lb-tabs" role="tablist" aria-label={gettext("Game")}>
                <button
                  :for={{key, label} <- [{"moves", gettext("Moves")}, {"info", gettext("Game info")}]}
                  type="button"
                  role="tab"
                  id={"lb-tab-#{key}"}
                  class={["lb-tab", @tab == key && "is-current"]}
                  aria-selected={to_string(@tab == key)}
                  aria-controls={"lb-panel-#{key}"}
                  tabindex={if @tab == key, do: "0", else: "-1"}
                  phx-click="tab"
                  phx-value-tab={key}
                >
                  {label}
                </button>
              </div>

              <div
                id="lb-panel-moves"
                role="tabpanel"
                aria-labelledby="lb-tab-moves"
                hidden={@tab != "moves"}
                class="lb-tabpanel"
              >
                <p :if={@rows == []} id="lb-no-moves" class="lb-quiet-line">
                  {if @unplayed?, do: unplayed_note(@featured), else: gettext("No moves yet.")}
                </p>

                <div
                  :if={@rows != []}
                  id="lb-moves-scroll"
                  class="lb-moves-scroll"
                  phx-hook=".FollowMoves"
                >
                  <table id="lb-moves" class="lb-moves">
                    <caption class="visually-hidden">{gettext("Moves")}</caption>

                    <thead>
                      <tr>
                        <th scope="col" class="lb-move-number">
                          <span aria-hidden="true">#</span>
                          <span class="visually-hidden">{gettext("Move")}</span>
                        </th>

                        <th scope="col">{gettext("White")}</th>

                        <th scope="col">{gettext("Black")}</th>
                      </tr>
                    </thead>

                    <tbody>
                      <tr :for={row <- @rows} id={"lb-row-#{row.number}"}>
                        <th scope="row" class="lb-move-number">{row.number}</th>

                        <td>
                          <.move_button cell={row.white} colour="w" shown={@shown_ply} set={@pieces} />
                        </td>

                        <td>
                          <.move_button cell={row.black} colour="b" shown={@shown_ply} set={@pieces} />
                        </td>
                      </tr>
                    </tbody>

                    <tfoot :if={@result}>
                      <tr>
                        <td colspan="3" class="lb-moves-result">
                          {LiveBoardsData.result_text(elem(@result, 0))}
                        </td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              </div>

              <div
                id="lb-panel-info"
                role="tabpanel"
                aria-labelledby="lb-tab-info"
                hidden={@tab != "info"}
                class="lb-tabpanel"
              >
                <dl class="lb-facts">
                  <dt>{gettext("White")}</dt>

                  <dd>{person_line(@featured.white)}</dd>

                  <dt>{gettext("Black")}</dt>

                  <dd>{person_line(@featured.black)}</dd>

                  <dt>{gettext("Board")}</dt>

                  <dd>{@featured.label}</dd>

                  <dt>{gettext("Status")}</dt>

                  <dd>{status_label(@status, nil)}</dd>
                </dl>
              </div>

              <p class="lb-game-links">
                <a
                  :if={@featured.view && not @unplayed?}
                  id="lb-pgn"
                  class="lb-btn lb-btn-text"
                  href={~p"/t/#{@slug}/live/#{@featured.round}/#{@featured.board}/pgn"}
                  download
                >
                  {gettext("Download PGN")}
                </a>

                <.link
                  id="lb-back"
                  class="lb-btn lb-btn-text"
                  navigate={~p"/t/#{@slug}/live/#{@featured.round}/all"}
                >
                  {gettext("All boards of this round")}
                </.link>
              </p>
            </section>
          </aside>
        </div>

        <:foot>
          <a
            :if={@round}
            id="lb-round-pgn"
            class="feed-link"
            href={~p"/t/#{@slug}/live/#{@round}/pgn"}
            download
          >
            {gettext("PGN of the round")}
          </a>

          <a :if={@round} class="feed-link" href={~p"/t/#{@slug}/round/#{@round}"}>
            {gettext("Round page")}
          </a>
        </:foot>
      </.shell>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".GameKeys">
      const KEYS = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "f", "F"]

      // The keys step through the featured game - but not while someone is
      // typing a name in the search box, nor with a modifier held, which is
      // the browser's (or the screen reader's) business.
      export default {
        mounted() {
          this.onKey = (e) => {
            if (e.altKey || e.ctrlKey || e.metaKey || !KEYS.includes(e.key)) return
            const t = e.target
            if (t && t.closest && t.closest("input, textarea, select, [contenteditable], [role=tab]")) return
            if (e.key === "ArrowLeft" || e.key === "ArrowRight") e.preventDefault()
            this.pushEvent("key", {key: e.key})
          }
          window.addEventListener("keydown", this.onKey)

          // Where the featured game starts on the page, for the stylesheet's
          // --lb-stage-top: whatever sits above it (the site header, a
          // heading that wraps, a zoomed page) is measured, not assumed.
          this.fit = () => {
            const game = document.getElementById("lb-game")
            if (!game) return
            const top = game.getBoundingClientRect().top + window.scrollY
            this.el.style.setProperty("--lb-stage-top", `${Math.round(top)}px`)
          }
          this.fit()
          window.addEventListener("resize", this.fit)
        },
        updated() { this.fit() },
        destroyed() {
          window.removeEventListener("keydown", this.onKey)
          window.removeEventListener("resize", this.fit)
        }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".FollowMoves">
      // Keeps the current move in sight inside the list's own scroll box,
      // never by scrolling the page: on a phone the list is below the board
      // and a page that jumps on every move is unreadable.
      export default {
        mounted() { this.follow() },
        updated() { this.follow() },
        follow() {
          const box = this.el
          const cur = box.querySelector(".is-current")
          if (!cur || box.scrollHeight <= box.clientHeight) return
          const head = box.querySelector("thead")
          const top = box.getBoundingClientRect().top + (head ? head.offsetHeight : 0)
          const bottom = box.getBoundingClientRect().bottom
          const r = cur.getBoundingClientRect()
          if (r.top < top) box.scrollTop -= top - r.top + 8
          else if (r.bottom > bottom) box.scrollTop += r.bottom - bottom + 8
        }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Fullscreen">
      export default {
        mounted() {
          if (!document.fullscreenEnabled) { this.el.hidden = true; return }
          this.el.addEventListener("click", () => {
            const target = document.getElementById(this.el.dataset.target)
            if (document.fullscreenElement) document.exitFullscreen()
            else if (target) target.requestFullscreen().catch(() => {})
          })
          this.onChange = () =>
            this.el.setAttribute("aria-pressed", String(document.fullscreenElement != null))
          this.onChange()
          document.addEventListener("fullscreenchange", this.onChange)
        },
        destroyed() {
          if (this.onChange) document.removeEventListener("fullscreenchange", this.onChange)
        }
      }
    </script>
    """
  end

  defp side_score({white, _black}, "white"), do: white
  defp side_score({_white, black}, "black"), do: black

  defp person_line(nil), do: "-"

  defp person_line(person) do
    [person.title, person.name, person.federation && "(#{person.federation})", person.rating]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
  end

  attr :item, :map, required: true
  attr :slug, :string, required: true
  attr :round, :integer, required: true

  defp pairing_row(%{item: %{kind: :match}} = assigns) do
    ~H"""
    <p class="lb-match-head">
      <span class="lb-match-no">{@item.number}</span> <span class="lb-match-team">{@item.a}</span>
      <span class="lb-match-score">
        {if @item.score, do: "#{elem(@item.score, 0)}-#{elem(@item.score, 1)}", else: "-"}
      </span>
      <span class="lb-match-team lb-match-team-b">{@item.b}</span>
    </p>
    """
  end

  defp pairing_row(assigns) do
    item = assigns.item

    assigns =
      assign(assigns,
        status: status(item),
        scores: LiveBoardsData.scores(item),
        forfeit?: unplayed?(item)
      )

    ~H"""
    <.link
      patch={~p"/t/#{@slug}/live/#{@round}/#{@item.board}"}
      class={["lb-row", "lb-status-#{@status}", @item.featured? && "is-current"]}
      aria-current={@item.featured? && "true"}
      aria-label={row_label(@item, @status)}
      phx-click={
        JS.remove_class("is-open", to: "#lb-rail-panel")
        |> JS.set_attribute({"aria-expanded", "false"}, to: "#lb-pairings-toggle")
      }
    >
      <span class="lb-row-bd">
        {@item.label} <span :if={@status == :live} class="lb-live-dot" aria-hidden="true"></span>
      </span>

      <span class="lb-row-players">
        <.row_player person={@item.white} colour="white" />
        <.row_player person={@item.black} colour="black" />
      </span>

      <span class="lb-row-score" aria-hidden="true">
        <%= cond do %>
          <% @scores -> %>
            <span>{elem(@scores, 0)}</span> <span>{elem(@scores, 1)}</span>
            <span :if={@forfeit?} class="lb-ff">FF</span>
          <% @status == :live -> %>
            <span class="lb-row-live">{gettext("Live")}</span>
          <% true -> %>
            <span class="lb-row-none">-</span>
        <% end %>
      </span>
    </.link>
    """
  end

  defp row_label(item, status) do
    said =
      case LiveBoardsData.result(item) do
        {token, _provisional?} -> LiveBoardsData.result_text(token)
        nil -> status_label(status, nil)
      end

    tile_label(item) <> ", " <> said
  end

  attr :person, :map, default: nil
  attr :colour, :string, required: true

  defp row_player(assigns) do
    ~H"""
    <span class="lb-row-player">
      <span class={["lb-dot", "lb-dot-#{@colour}"]} aria-hidden="true"></span>
      <span :if={@person && @person.title} class="lb-title">{@person.title}</span>
      <span class="lb-row-name">{(@person && @person.name) || "-"}</span>
      <span :if={@person && @person.rating} class="lb-rating">{@person.rating}</span>
    </span>
    """
  end

  attr :cell, :any, default: nil
  attr :shown, :integer, required: true
  attr :colour, :string, required: true
  attr :set, :string, required: true

  defp move_button(%{cell: nil} = assigns), do: ~H|<span class="lb-move lb-move-empty"></span>|

  defp move_button(%{cell: {ply, san}} = assigns) do
    assigns = assign(assigns, ply: ply, san: san)

    ~H"""
    <button
      type="button"
      id={"lb-ply-#{@ply}"}
      class={["lb-move", @ply == @shown && "is-current"]}
      phx-click="goto"
      phx-value-ply={@ply}
      aria-current={@ply == @shown && "step"}
    >
      <.figurine san={@san} colour={@colour} set={@set} />
    </button>
    """
  end

  defp current_path(slug, _round, _board, :index), do: "/t/#{slug}/live"
  defp current_path(slug, nil, _board, _action), do: "/t/#{slug}/live"
  defp current_path(slug, round, nil, _action), do: "/t/#{slug}/live/#{round}"
  defp current_path(slug, round, board, _action), do: "/t/#{slug}/live/#{round}/#{board}"
end
