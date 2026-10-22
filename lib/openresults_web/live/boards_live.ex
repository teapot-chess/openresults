defmodule OpenResultsWeb.BoardsLive do
  @moduledoc """
  A round's live boards, all of them: a grid of small boards with names,
  clocks, the last move and the result, each opening that game in the
  broadcast (`OpenResultsWeb.BroadcastLive`). `GET /t/:slug/live/:round/all` -
  the "All boards" view; the round's own address is the broadcast.

  ## Why this is a LiveView and not a cached page

  The static pages are documents revalidated against the snapshot id and
  cached in ETS (`OpenResultsWeb.Plugs.Revalidate`) - exactly right for
  something that changes when an arbiter publishes, and exactly wrong for
  something that changes every few seconds without a publish. This page is
  outside that scope: it holds a socket, subscribes to the tournament's live
  topic (`OpenResults.LiveBoards.topic/1`) and re-reads the one board that
  changed. Nothing it shows passes through the page cache, so nothing it
  shows can be served stale from it.

  ## Updates

    * a board changed: only that board's tile is re-rendered and sent;
    * the broadcast delay is applied by reading, not by sending late: the
      page asks for the game as it stood `delay` ago, and on a change
      schedules the same read for `delay` later, when the change becomes
      visible;
    * a tick every #{15} seconds re-reads the round and sends the tiles whose
      picture changed - the net under a lost message and the way a delayed
      move appears on time after a reconnect;
    * a publish (`{:tournament_changed, slug}`) re-reads names and pairings.

  What may be shown is `OpenResultsWeb.LiveBoardsData`'s rule.
  """

  use OpenResultsWeb, :live_view

  import OpenResultsWeb.LiveBoardsComponents

  alias OpenResults.LiveBoards
  alias OpenResults.TournamentEvents
  alias OpenResults.Tournaments
  alias OpenResultsWeb.LiveBoardsData
  alias OpenResultsWeb.ProjectorPicker
  alias OpenResultsWeb.Tournament

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
        round_param: params["round"],
        snapshot_id: nil,
        payload: nil,
        title: slug,
        round: nil,
        rounds: [],
        round_heading: nil,
        delay: 0,
        sigs: %{},
        empty?: true,
        unknown_round?: false,
        page_title: gettext("Live boards")
      )
      |> stream_configure(:tiles, dom_id: & &1.id)
      |> stream(:tiles, [])
      |> ProjectorPicker.init()
      |> load()

    {:ok, socket, layout: false}
  end

  # --- reading -----------------------------------------------------------------

  defp load(socket) do
    case Tournaments.public_latest(socket.assigns.slug) do
      nil ->
        socket
        |> assign(payload: nil, snapshot_id: nil, rounds: [], round: nil, sigs: %{}, empty?: true)
        |> stream(:tiles, [], reset: true)

      snapshot ->
        payload = snapshot.payload
        numbers = payload |> LiveBoardsData.rounds() |> Enum.map(&Map.get(&1, "number"))
        round = pick_round(socket.assigns.round_param, numbers)

        tiles =
          if round,
            do: LiveBoardsData.tiles(payload, socket.assigns.slug, round, plies: false),
            else: []

        socket
        |> assign(
          payload: payload,
          snapshot_id: snapshot.id,
          title: Tournament.name(payload),
          rounds: numbers,
          round: round,
          round_heading: round && Tournament.round_heading(payload, round),
          delay: LiveBoards.delay_minutes(socket.assigns.slug),
          unknown_round?: socket.assigns.round_param != nil and round == nil,
          sigs: signatures(tiles),
          empty?: tiles == [],
          page_title: gettext("Live boards") <> " - " <> Tournament.name(payload)
        )
        |> stream(:tiles, tiles, reset: true)
    end
  end

  defp pick_round(nil, numbers), do: List.last(numbers)

  defp pick_round(param, numbers) do
    case Integer.parse(param) do
      {n, ""} -> if n in numbers, do: n
      _junk -> nil
    end
  end

  defp signatures(tiles), do: Map.new(tiles, &{&1.board, LiveBoardsData.stamp(&1)})

  # Re-reads one board, and sends it when its stamp moved: the picture, or a
  # fresh clock report (`LiveBoardsData.stamp/1`). A repeat sends nothing.
  defp refresh_board(%{assigns: %{payload: nil}} = socket, _board), do: socket
  defp refresh_board(%{assigns: %{round: nil}} = socket, _board), do: socket

  defp refresh_board(socket, board) do
    %{payload: payload, slug: slug, round: round, sigs: sigs} = socket.assigns

    case LiveBoardsData.tile(payload, slug, round, board, plies: false) do
      nil ->
        socket

      tile ->
        stamp = LiveBoardsData.stamp(tile)

        if Map.get(sigs, board) != stamp do
          socket
          |> stream_insert(:tiles, tile)
          |> assign(sigs: Map.put(sigs, board, stamp), empty?: false)
        else
          socket
        end
    end
  end

  defp refresh_all(%{assigns: %{payload: nil}} = socket), do: socket
  defp refresh_all(%{assigns: %{round: nil}} = socket), do: socket

  defp refresh_all(socket) do
    %{payload: payload, slug: slug, round: round, sigs: sigs} = socket.assigns
    tiles = LiveBoardsData.tiles(payload, slug, round, plies: false)

    changed = Enum.filter(tiles, &(Map.get(sigs, &1.board) != LiveBoardsData.stamp(&1)))

    Enum.reduce(changed, socket, fn tile, socket -> stream_insert(socket, :tiles, tile) end)
    |> assign(sigs: signatures(tiles), delay: LiveBoards.delay_minutes(slug))
  end

  # --- the viewer ---

  # A new set means every tile's markup changes, so the grid is sent again;
  # the picker has already remembered the choice in the browser.
  @impl true
  def handle_event("pieces", %{"set" => set}, socket) do
    case OpenResultsWeb.Pieces.known(set) do
      nil -> {:noreply, socket}
      set -> {:noreply, socket |> assign(:pieces, set) |> load()}
    end
  end

  def handle_event("projector_" <> _ = event, params, socket),
    do: {:noreply, ProjectorPicker.handle_event(event, params, socket)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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

  def handle_info({:live_delay, _slug}, socket), do: {:noreply, socket |> load()}

  def handle_info({:tournament_changed, slug}, %{assigns: %{slug: slug}} = socket) do
    if Tournaments.public_latest(slug) |> then(&(&1 && &1.id)) == socket.assigns.snapshot_id,
      do: {:noreply, socket},
      else: {:noreply, load(socket)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick)
    {:noreply, refresh_all(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- the page ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      locale={@locale}
      path={current_path(@slug, @round_param)}
      slug={@slug}
      title={@title}
      pieces={@pieces}
      wide={true}
    >
      <header class="lb-bc-head">
        <div class="lb-bc-heading">
          <p class="lb-eyebrow">
            <span class="lb-live-dot" aria-hidden="true"></span>{gettext("Live boards")}
            <.offline_note />
          </p>

          <h1 id="lb-title" class="lb-bc-title">
            <a href={~p"/t/#{@slug}"}>{@title}</a>
          </h1>
        </div>

        <div :if={@round} class="lb-head-tools">
          <.view_switch slug={@slug} round={@round} current={:all} /> <ProjectorPicker.button />
        </div>
      </header>
      <ProjectorPicker.picker picker={@projector} slug={@slug} round={@round} pieces={@pieces} />
      <p :if={@round_heading} id="lb-round" class="details lb-grid-details">
        <span>{@round_heading}</span>
        <span :if={@delay > 0} id="lb-delay">
          {ngettext(
            "shown %{count} minute behind the game",
            "shown %{count} minutes behind the game",
            @delay
          )}
        </span>
      </p>

      <nav :if={length(@rounds) > 1} class="lb-grid-rounds" aria-label={gettext("Rounds")}>
        <ul id="lb-rounds" class="lb-pills">
          <li :for={n <- @rounds}>
            <.link
              navigate={~p"/t/#{@slug}/live/#{n}/all"}
              class={["lb-pill", n == @round && "is-current"]}
              aria-current={n == @round && "page"}
              aria-label={@payload && Tournament.round_heading(@payload, n)}
            >
              {n}
            </.link>
          </li>
        </ul>
      </nav>

      <p :if={is_nil(@payload)} id="lb-unavailable" class="empty">
        {gettext("Nothing is published for this tournament at the moment.")}
      </p>

      <p :if={@payload && @rounds == []} id="lb-no-rounds" class="empty">
        {gettext("No round has been published yet, so there are no boards to follow.")}
      </p>

      <p :if={@unknown_round?} id="lb-unknown-round" class="empty">
        {gettext("This round has not been published.")}
      </p>
      <p :if={@unknown_round? and @rounds != []} id="lb-latest-round">
        <.link navigate={~p"/t/#{@slug}/live/#{Enum.max(@rounds)}/all"}>{gettext(
          "Go to the latest round"
        )}</.link>
      </p>

      <div id="lb-grid" class="lb-grid" phx-update="stream">
        <.tile :for={{_id, tile} <- @streams.tiles} tile={tile} slug={@slug} pieces={@pieces} />
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
    """
  end

  defp current_path(slug, nil), do: "/t/#{slug}/live"
  defp current_path(slug, round), do: "/t/#{slug}/live/#{round}/all"
end
