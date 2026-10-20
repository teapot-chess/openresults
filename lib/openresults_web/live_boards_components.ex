defmodule OpenResultsWeb.LiveBoardsComponents do
  @moduledoc """
  The pieces the live-board pages and the hall display share: the board as
  SVG, a clock that counts on its own, a tile for one game, and the page
  shell the two live pages sit in.

  ## The board

  Server-rendered SVG from a FEN, never from a script: a position is a few
  hundred bytes of markup, the page works while the socket reconnects, and a
  tile that has not changed costs nothing to keep. The pieces are not in the
  markup at all: each is a `<use>` of a symbol in the chosen set's sprite
  (`OpenResultsWeb.Pieces`), one cached static file per set, so a round of
  sixty boards does not repeat the shapes sixty times and the browser fetches
  them once.

  The piece art is third-party (Cburnett, Chessnut), shipped as
  separate static files with their own licences and never compiled into this
  module. See `NOTICE` and `priv/static/pieces/`.

  ## The clocks

  The server sends what a clock reads at the moment it renders and whether it
  is running; the browser counts it down (`.LiveClock`, below) and is
  corrected by the next update. Nothing here asks the server what time it is
  once a second.
  """

  use OpenResultsWeb, :html

  alias OpenResults.Chess
  alias OpenResultsWeb.LiveBoardsData
  alias OpenResultsWeb.Pieces

  # --- the board ---------------------------------------------------------------

  attr :fen, :string, required: true
  attr :last, :any, default: nil, doc: "`{from, to}` square indices to highlight, or nil"
  attr :flip, :boolean, default: false
  attr :coords, :boolean, default: false
  attr :id, :string, default: nil
  attr :label, :string, required: true, doc: "what a screen reader says about the picture"
  attr :class, :string, default: nil

  attr :set, :string,
    default: "cburnett",
    doc: "the piece set; one we do not ship means the default"

  attr :empty, :boolean,
    default: false,
    doc: "squares and no pieces: a board nobody played on, which is not the starting position"

  def board_svg(assigns) do
    pieces =
      case {assigns.empty, Chess.parse_fen(assigns.fen)} do
        {true, _fen} -> []
        {false, {:ok, position}} -> Chess.pieces(position)
        {false, {:error, _message}} -> []
      end

    assigns =
      assigns
      |> assign(
        :pieces,
        for({i, {colour, kind}} <- pieces, do: {square(i, assigns.flip), "#{colour}#{kind}"})
      )
      |> assign(:dark, dark_squares())
      |> assign(:marked, marked(assigns.last, assigns.flip))

    # Coordinates sit inside the edge squares, in the colour of the square
    # they are not on - the board stays square and fills its column.
    ~H"""
    <svg
      id={@id}
      class={["lb-board", @empty && "lb-board-muted", @class]}
      viewBox="0 0 8 8"
      role="img"
      aria-label={@label}
      preserveAspectRatio="xMidYMid meet"
    >
      <rect x="0" y="0" width="8" height="8" class="lb-sq-light" />
      <rect :for={{x, y} <- @dark} x={x} y={y} width="1" height="1" class="lb-sq-dark" />
      <rect :for={{x, y} <- @marked} x={x} y={y} width="1" height="1" class="lb-sq-last" />
      <g :if={@coords} class="lb-coords" aria-hidden="true">
        <text
          :for={n <- 0..7}
          x={n + 0.95}
          y="7.93"
          text-anchor="end"
          class={if(rem(n, 2) == 0, do: "on-dark", else: "on-light")}
        >
          {file_name(n, @flip)}
        </text>
        <text
          :for={n <- 0..7}
          x="0.05"
          y={n + 0.27}
          class={if(rem(n, 2) == 1, do: "on-dark", else: "on-light")}
        >
          {rank_name(n, @flip)}
        </text>
      </g>
      <use
        :for={{{x, y}, piece} <- @pieces}
        href={Pieces.href(@set, piece_id(piece))}
        x={x}
        y={y}
        width="1"
        height="1"
        class="lb-pc"
      />
    </svg>
    """
  end

  # `"wk"` as the sprites name it: `"wK"`.
  defp piece_id(<<colour, kind>>), do: <<colour, String.upcase(<<kind>>)::binary>>

  # (file, row) of square index `i` on screen. Row 0 is the top.
  defp square(i, false), do: {rem(i, 8), div(i, 8)}
  defp square(i, true), do: {7 - rem(i, 8), 7 - div(i, 8)}

  defp marked(nil, _flip), do: []
  defp marked({from, to}, flip), do: [square(from, flip), square(to, flip)]

  defp dark_squares, do: for(y <- 0..7, x <- 0..7, rem(x + y, 2) == 1, do: {x, y})

  defp file_name(n, flip), do: <<?a + if(flip, do: 7 - n, else: n)>>
  defp rank_name(n, flip), do: to_string(if(flip, do: n + 1, else: 8 - n))

  # --- the clock ---------------------------------------------------------------

  attr :id, :string, required: true
  attr :ms, :any, required: true, doc: "what it reads now, in ms, or nil when unknown"
  attr :running, :boolean, default: false
  attr :class, :any, default: nil

  def clock(assigns) do
    ~H"""
    <span
      id={@id}
      class={["lb-clock", @running && "is-running", @class]}
      phx-hook=".LiveClock"
      data-ms={@ms}
      data-running={to_string(@running and is_integer(@ms))}
    >
      {format_clock(@ms)}
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LiveClock">
      const format = (ms) => {
        const total = Math.floor(Math.max(0, ms) / 1000)
        const h = Math.floor(total / 3600)
        const m = Math.floor((total % 3600) / 60)
        const s = String(total % 60).padStart(2, "0")
        return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`
      }

      export default {
        mounted() { this.sync() },
        updated() { this.sync() },
        destroyed() { this.stop() },
        stop() { if (this.timer) { clearInterval(this.timer); this.timer = null } },
        sync() {
          this.stop()
          this.base = Number(this.el.dataset.ms)
          if (!Number.isFinite(this.base)) return
          this.from = performance.now()
          this.running = this.el.dataset.running === "true"
          this.paint()
          if (this.running) this.timer = setInterval(() => this.paint(), 200)
        },
        paint() {
          const left = Math.max(0, this.base - (this.running ? performance.now() - this.from : 0))
          const text = format(left)
          if (this.el.textContent !== text) this.el.textContent = text
          this.el.classList.toggle("is-low", this.running && left < 30000)
        }
      }
    </script>
    """
  end

  @doc "`7:05`, or `1:02:03` from an hour; `-:--` when unknown. The browser formats the same way."
  def format_clock(ms) when is_integer(ms) do
    total = div(max(ms, 0), 1000)
    {h, m, s} = {div(total, 3600), div(rem(total, 3600), 60), rem(total, 60)}
    secs = String.pad_leading(Integer.to_string(s), 2, "0")

    if h > 0,
      do: "#{h}:#{String.pad_leading(Integer.to_string(m), 2, "0")}:#{secs}",
      else: "#{m}:#{secs}"
  end

  def format_clock(_unknown), do: "-:--"

  # --- a game, as a tile -------------------------------------------------------

  attr :tile, :map, required: true
  attr :slug, :string, required: true
  attr :link?, :boolean, default: true
  attr :class, :string, default: nil
  attr :pieces, :string, default: "cburnett"

  def tile(assigns) do
    tile = assigns.tile
    unplayed? = unplayed?(tile)
    # A board published as never played has no position worth drawing, even
    # if a relay sent something for it: the arbiter's word wins.
    view = if unplayed?, do: nil, else: tile.view
    # Nor has a game the arbiter has a result for and the relay never saw:
    # the starting position would say it never began.
    blank? = unplayed? or (is_nil(view) and status(tile) == :finished)

    assigns =
      assigns
      |> assign(:fen, if(view, do: view.fen, else: Chess.start_fen()))
      |> assign(:last, view && view.last)
      |> assign(:clocks, view && view.clocks)
      |> assign(:result, LiveBoardsData.result(tile))
      |> assign(:status, status(tile))
      |> assign(:unplayed?, unplayed?)
      |> assign(:blank?, blank?)
      |> assign(:last_move, view && last_move_label(view))

    ~H"""
    <article id={@tile.id} class={["lb-tile", "lb-status-#{@status}", @class]}>
      <header class="lb-tile-head">
        <span class="lb-tile-board">{gettext("Bd %{board}", board: @tile.label)}</span>
        <.status_badge status={@status} />
      </header>
      <.player_line tile={@tile} colour="black" clocks={@clocks} />
      <.link
        :if={@link?}
        navigate={~p"/t/#{@slug}/live/#{@tile.round}/#{@tile.board}"}
        class="lb-tile-board-link"
        aria-label={tile_label(@tile)}
      >
        <.tile_board tile={@tile} fen={@fen} last={@last} pieces={@pieces} unplayed?={@blank?} />
      </.link>
      <div :if={not @link?} class="lb-tile-board-link">
        <.tile_board tile={@tile} fen={@fen} last={@last} pieces={@pieces} unplayed?={@blank?} />
      </div>
      <.player_line tile={@tile} colour="white" clocks={@clocks} />
      <footer class="lb-tile-foot">
        <span :if={@last_move} class="lb-last-move">{@last_move}</span>
        <span :if={@unplayed?} class="lb-unplayed-note">{unplayed_note(@tile)}</span>
        <span :if={is_nil(@last_move) and not @unplayed?}></span>
        <.result_mark :if={@result} result={@result} tile={@tile} />
      </footer>
    </article>
    """
  end

  attr :tile, :map, required: true
  attr :fen, :string, required: true
  attr :last, :any, default: nil
  attr :pieces, :string, required: true
  attr :unplayed?, :boolean, default: false

  defp tile_board(assigns) do
    ~H"""
    <.board_svg
      fen={@fen}
      last={@last}
      label={tile_label(@tile)}
      set={@pieces}
      empty={@unplayed?}
    />
    """
  end

  @doc """
  A result as the pages print it - `½-½`, `1-0` - with a forfeit's `FF` as a
  mark of its own and the relay's suggestion starred as provisional.
  """
  attr :result, :any, required: true, doc: "`LiveBoardsData.result/1`"
  attr :tile, :map, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  def result_mark(assigns) do
    {token, provisional?} = assigns.result

    assigns =
      assign(assigns,
        text: LiveBoardsData.result_text(token),
        provisional?: provisional?,
        forfeit?: unplayed?(assigns.tile)
      )

    ~H"""
    <span id={@id} class={["lb-result", @class]}>
      {@text}<abbr :if={@forfeit?} class="lb-ff" title={gettext("forfeit")}>FF</abbr><span
        :if={@provisional?}
        class="lb-provisional"
        title={gettext("not yet confirmed by the arbiter")}
      > *</span>
    </span>
    """
  end

  @doc "The status as a pill: a beating dot while live, the word always."
  attr :status, :atom, required: true
  attr :id, :string, default: nil

  def status_badge(assigns) do
    ~H"""
    <span id={@id} class={["lb-badge", "lb-status-#{@status}"]}>
      <span :if={@status == :live} class="lb-live-dot" aria-hidden="true"></span>
      {status_label(@status, nil)}
    </span>
    """
  end

  @doc "Whether the published pairing says this board was never played."
  def unplayed?(tile), do: Map.get(tile, :unplayed) != nil

  @doc "The line a board nobody played on carries instead of a position."
  def unplayed_note(tile) do
    case Map.get(tile, :unplayed) do
      :forfeit -> gettext("Not played - forfeit")
      :double_forfeit -> gettext("Not played - double forfeit")
      _withheld -> gettext("Not played")
    end
  end

  attr :tile, :map, required: true
  attr :colour, :string, required: true
  attr :clocks, :any, default: nil

  def player_line(assigns) do
    person = if assigns.colour == "white", do: assigns.tile.white, else: assigns.tile.black
    ms = assigns.clocks && Map.get(assigns.clocks, String.to_existing_atom(assigns.colour))
    running = assigns.clocks && assigns.clocks.running == assigns.colour

    assigns =
      assigns
      |> assign(:person, person)
      |> assign(:ms, ms)
      |> assign(:running, running || false)
      |> assign(:has_clock, assigns.clocks != nil and ms != nil)

    ~H"""
    <div class={["lb-player", "lb-player-#{@colour}", @running && "is-to-move"]}>
      <span class={["lb-dot", "lb-dot-#{@colour}"]} aria-hidden="true"></span>
      <span class="lb-name">
        <Flags.flag
          :if={@person && @person[:flag]}
          src={@person.flag}
          code={@person.federation}
          label
        />
        <span :if={@person && @person.title} class="lb-title">{@person.title}</span>
        <span class="lb-person">{(@person && @person.name) || "-"}</span>
        <span :if={@person && @person.rating} class="lb-rating">{@person.rating}</span>
      </span>
      <.clock
        :if={@has_clock}
        id={"#{@tile.id}-clock-#{@colour}"}
        ms={@ms}
        running={@running}
      />
    </div>
    """
  end

  @doc """
  One side of the featured game, as a broadcast prints it: the name large,
  title, federation and rating small, the clock in a box, and what this side
  scored in large type at the end once there is a result.
  """
  attr :tile, :map, required: true
  attr :colour, :string, required: true
  attr :clocks, :any, default: nil

  attr :idle_ms, :any,
    default: nil,
    doc: "the starting time to show, standing and unstarted, when no clock reports one"

  attr :score, :string, default: nil

  def player_bar(assigns) do
    colour = assigns.colour
    person = if colour == "white", do: assigns.tile.white, else: assigns.tile.black
    ms = assigns.clocks && Map.get(assigns.clocks, String.to_existing_atom(colour))
    running = (assigns.clocks && assigns.clocks.running == colour) || false

    # A clock that is reporting wins; the starting time stands in only where
    # none is, and then it is idle - never running, never highlighted.
    idle? = is_nil(ms) and is_integer(assigns.idle_ms)
    ms = ms || assigns.idle_ms

    assigns =
      assign(assigns,
        person: person,
        ms: ms,
        idle?: idle?,
        running: running,
        # A side whose clock is unknown still gets its box, as "-:--", while
        # the other side's is reporting: an empty space reads as a fault.
        has_clock: is_integer(ms) or reports_clock?(assigns.clocks)
      )

    ~H"""
    <div
      id={"lb-bar-#{@colour}"}
      class={["lb-player", "lb-bar", "lb-player-#{@colour}", @running && "is-to-move"]}
    >
      <span class={["lb-dot", "lb-dot-#{@colour}"]} aria-hidden="true"></span>
      <span class="visually-hidden">
        {if @colour == "white", do: gettext("White"), else: gettext("Black")}:
      </span>
      <div class="lb-bar-who">
        <p class="lb-bar-name" title={@person && @person.name}>
          <span :if={@person && @person.title} class="lb-title">{@person.title}</span>
          <span class="lb-person">{(@person && @person.name) || "-"}</span>
        </p>
        <p
          :if={@person && (@person.rating || @person.federation)}
          class="lb-bar-meta"
        >
          <span :if={@person.federation} class="lb-fed">
            <Flags.flag :if={@person[:flag]} src={@person.flag} />{@person.federation}
          </span>
          <span :if={@person.rating} class="lb-rating">{@person.rating}</span>
        </p>
      </div>
      <.clock
        :if={@has_clock}
        id={"lb-game-clock-#{@colour}"}
        ms={@ms}
        running={@running}
        class={["lb-clock-big", @idle? && "is-idle"]}
      />
      <span :if={@score} id={"lb-score-#{@colour}"} class="lb-bar-score">
        <span class="visually-hidden">{gettext("Score")}:</span>
        {@score}
      </span>
    </div>
    """
  end

  defp reports_clock?(%{white: w, black: b}), do: is_integer(w) or is_integer(b)
  defp reports_clock?(_none), do: false

  @doc """
  A move in figurine notation: the piece as the chosen set draws it, then
  the square - `Nf3` with a knight, a promotion with the piece it became.
  The plain SAN is there for a screen reader and for copying.
  """
  attr :san, :string, required: true

  attr :colour, :string,
    default: "w",
    doc: "the side that moved; the piece is drawn white either way, see the stylesheet"

  attr :set, :string, required: true

  def figurine(assigns) do
    assigns = assign(assigns, :parts, figurine_parts(assigns.san))

    ~H"""
    <span class="visually-hidden">{@san}</span><span class="lb-fig" aria-hidden="true"><%= for part <- @parts do %>
      <%= case part do %>
        <% {:piece, piece} -> %>
          <svg
            class="lb-fig-pc"
            aria-hidden="true"
            viewBox="0 0 1 1"
          ><use href={Pieces.href(@set, "w" <> piece)} width="1" height="1" /></svg>
        <% {:text, text} -> %>
          {text}
      <% end %>
    <% end %></span>
    """
  end

  @doc false
  def figurine_parts(san) when is_binary(san) do
    {head, rest} =
      case san do
        <<p, rest::binary>> when p in ~c"KQRBN" -> {[{:piece, <<p>>}], rest}
        _pawn_or_castling -> {[], san}
      end

    tail =
      case Regex.run(~r/^(.*)=([QRBN])(.*)$/, rest) do
        [_all, before, promoted, after_promotion] ->
          [{:text, before}, {:piece, promoted}, {:text, after_promotion}]

        nil ->
          [{:text, rest}]
      end

    Enum.reject(head ++ tail, &(&1 == {:text, ""}))
  end

  @doc false
  def tile_label(tile) do
    gettext("Board %{board}: %{white} against %{black}",
      board: tile.label,
      white: (tile.white && tile.white.name) || "-",
      black: (tile.black && tile.black.name) || "-"
    )
  end

  @doc """
  `:live`, `:finished`, `:waiting`, or - when the arbiter published the board
  as never played - `:forfeit` or `:double_forfeit`.

  The published pairing wins over the relay when it says the game was not
  played: a forfeited board has nobody at it, the relay sends nothing, and
  "nothing sent" read on its own says "not started" until the end of time. A
  forfeit in a round whose results are withheld is only `:finished`, like
  any other game there.
  """
  def status(%{unplayed: kind}) when kind in [:forfeit, :double_forfeit], do: kind
  def status(%{unplayed: :withheld}), do: :finished
  def status(%{view: nil, official: official}) when is_binary(official), do: :finished
  def status(%{view: nil}), do: :waiting
  def status(%{view: %{status: "finished"}}), do: :finished
  def status(%{view: %{ply: 0}}), do: :waiting
  def status(_tile), do: :live

  @doc false
  def status_label(:live, _result), do: gettext("Live")
  def status_label(:waiting, _result), do: gettext("Not started")
  def status_label(:finished, _result), do: gettext("Game over")
  def status_label(:forfeit, _result), do: gettext("Forfeit")
  def status_label(:double_forfeit, _result), do: gettext("Double forfeit")

  # "12. Nf3" or "12... Nf6": the move number from the position after it.
  @doc false
  def last_move_label(%{last_san: nil}), do: nil

  def last_move_label(%{last_san: san, fen: fen}) do
    case String.split(fen) do
      [_placement, "b" | rest] -> "#{fullmove(rest)}. #{san}"
      [_placement, "w" | rest] -> "#{max(fullmove(rest) - 1, 1)}... #{san}"
      _other -> san
    end
  end

  defp fullmove([_castling, _ep, _half, full]) do
    case Integer.parse(full) do
      {n, ""} -> n
      _bad -> 1
    end
  end

  defp fullmove(_other), do: 1

  @doc """
  The two ways to watch a round - one game large, or every board small -
  as a pair of links, the current one marked.
  """
  attr :slug, :string, required: true
  attr :round, :integer, required: true
  attr :board, :any, default: nil
  attr :current, :atom, required: true

  def view_switch(assigns) do
    ~H"""
    <nav id="lb-view-switch" class="lb-switch" aria-label={gettext("View")}>
      <.link
        id="lb-switch-broadcast"
        navigate={
          if @board,
            do: ~p"/t/#{@slug}/live/#{@round}/#{@board}",
            else: ~p"/t/#{@slug}/live/#{@round}"
        }
        class={["lb-switch-opt", @current == :broadcast && "is-current"]}
        aria-current={@current == :broadcast && "page"}
      >
        {gettext("Featured game")}
      </.link>
      <.link
        id="lb-switch-all"
        navigate={~p"/t/#{@slug}/live/#{@round}/all"}
        class={["lb-switch-opt", @current == :all && "is-current"]}
        aria-current={@current == :all && "page"}
      >
        {gettext("All boards")}
      </.link>
    </nav>
    """
  end

  # --- the page shell ----------------------------------------------------------

  attr :locale, :string, required: true
  attr :path, :string, required: true, doc: "this page's own path, for the language links"
  attr :slug, :string, required: true
  attr :title, :string, required: true, doc: "the tournament's name"
  attr :pieces, :string, default: "cburnett", doc: "the piece set in use, for the picker"
  attr :wide, :boolean, default: false, doc: "the broadcast page, which uses the whole screen"
  slot :inner_block, required: true
  slot :foot

  @doc """
  The site's masthead (brand, languages, theme) and footer around a live
  page. The same classes the rest of the site uses, so the page looks like
  it belongs; the theme picker is the same control, driven by a hook instead
  of the inline script the static pages carry.
  """
  def shell(assigns) do
    ~H"""
    <a class="skip-link" href="#main">{gettext("Skip to content")}</a>
    <div class={["page lb-page", @wide && "lb-page-wide"]}>
      <header class="masthead-bar">
        <a class="brand" href={~p"/"}>
          <.logo /> OpenResults
        </a>
        <div class="masthead-tools">
          <nav class="lang-picker" aria-label={gettext("Language")}>
            <a
              :for={{code, name} <- OpenResultsWeb.Locale.locales()}
              href={@path <> "?" <> URI.encode_query([{OpenResultsWeb.Locale.param(), code}])}
              hreflang={code}
              lang={code}
              title={name}
              class={["lang-opt", code == @locale && "is-current"]}
              aria-current={code == @locale && "true"}
            >
              <span aria-hidden="true">{String.upcase(code)}</span>
              <span class="visually-hidden">{name}</span>
            </a>
          </nav>
          <.pieces_picker pieces={@pieces} />
          <.theme_picker />
        </div>
      </header>
      <main id="main" tabindex="-1" class="lb-main">
        <p :if={not @wide} class="admin-crumbs lb-crumbs">
          <a href={~p"/t/#{@slug}"}>{@title}</a>
        </p>
        {render_slot(@inner_block)}
      </main>
      <footer class="site-foot">
        <span>{gettext("Published by the arbiter. Results are theirs, not this site's.")}</span>
        <span class="spacer"></span>
        {render_slot(@foot)}
        <a class="terms-link" href={~p"/terms"}>{gettext("Terms and privacy")}</a>
      </footer>
    </div>
    """
  end

  attr :pieces, :string, required: true

  defp pieces_picker(assigns) do
    ~H"""
    <details
      class="theme-picker pieces-picker"
      id="lb-pieces-picker"
      phx-hook=".PiecesPicker"
      phx-update="ignore"
      data-current={@pieces}
    >
      <summary
        class="theme-picker-trigger"
        title={gettext("Chess pieces")}
        aria-label={gettext("Chess pieces")}
      >
        <svg class="pieces-picker-icon" viewBox="0 0 1 1" aria-hidden="true">
          <use href={Pieces.href(@pieces, "wN")} width="1" height="1" />
        </svg>
        {gettext("Pieces")}
      </summary>
      <div class="theme-picker-panel" role="group" aria-label={gettext("Chess pieces")}>
        <button
          :for={{key, name, _designer} <- Pieces.sets()}
          type="button"
          class="theme-picker-item"
          data-pieces-opt={key}
        >
          <svg class="pieces-picker-icon" viewBox="0 0 1 1" aria-hidden="true">
            <use href={Pieces.href(key, "wN")} width="1" height="1" />
          </svg>
          {name}
        </button>
      </div>
    </details>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PiecesPicker">
      const KEY = "openresults:pieces"

      export default {
        mounted() {
          const trigger = this.el.querySelector("summary")
          const icon = trigger.querySelector("use")
          const options = [...this.el.querySelectorAll("[data-pieces-opt]")].map((o) => o.dataset.piecesOpt)

          let stored = null
          try { stored = localStorage.getItem(KEY) } catch (_) {}
          // `?pieces=` in the URL wins over what the browser remembered, as
          // it does on the server; the picker shows what is on the board.
          const fromUrl = new URLSearchParams(location.search).get("pieces")
          let current = options.includes(fromUrl) ? fromUrl
            : options.includes(stored) ? stored : this.el.dataset.current

          const mark = () => {
            this.el.querySelectorAll("[data-pieces-opt]").forEach((o) => {
              o.setAttribute("aria-pressed", String(o.dataset.piecesOpt === current))
            })
            icon.setAttribute("href", icon.getAttribute("href").replace(/\/pieces\/[a-z]+\.svg/, `/pieces/${current}.svg`))
          }
          mark()

          this.el.addEventListener("click", (e) => {
            const button = e.target.closest("[data-pieces-opt]")
            if (!button) return
            current = button.dataset.piecesOpt
            try { localStorage.setItem(KEY, current) } catch (_) {}
            this.pushEvent("pieces", {set: current})
            mark()
            this.el.removeAttribute("open")
            trigger.focus()
          })

          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Escape" && this.el.open) {
              this.el.removeAttribute("open")
              trigger.focus()
            }
          })
        }
      }
    </script>
    """
  end

  defp theme_picker(assigns) do
    ~H"""
    <details class="theme-picker" id="lb-theme-picker" phx-hook=".ThemePicker" phx-update="ignore">
      <summary
        class="theme-picker-trigger"
        title={gettext("Colour theme")}
        aria-label={gettext("Colour theme")}
      >
        <span class="theme-picker-swatch" aria-hidden="true"></span> {gettext("Theme")}
      </summary>
      <div class="theme-picker-panel" role="group" aria-label={gettext("Colour theme")}>
        <button
          :for={
            {key, label} <- [
              {"system", gettext("Match device")},
              {"paper", gettext("Paper")},
              {"night", gettext("Night")},
              {"board", gettext("Board")},
              {"slate", gettext("Slate")},
              {"contrast", gettext("High contrast")}
            ]
          }
          type="button"
          class="theme-picker-item"
          data-theme-opt={key}
        >
          <span class={"theme-dot theme-dot-#{key}"} aria-hidden="true"></span>
          {label}
        </button>
      </div>
    </details>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ThemePicker">
      const KEY = "openresults:theme"

      export default {
        mounted() {
          const root = document.documentElement
          const trigger = this.el.querySelector("summary")

          const mark = () => {
            const source = root.getAttribute("data-theme-source")
            const current = source === "system" ? "system"
              : source === "default" ? "paper" : root.getAttribute("data-theme")
            this.el.querySelectorAll("[data-theme-opt]").forEach((o) => {
              o.setAttribute("aria-pressed", String(o.dataset.themeOpt === current))
            })
          }
          mark()

          this.el.addEventListener("click", (e) => {
            const button = e.target.closest("[data-theme-opt]")
            if (!button) return
            const value = button.dataset.themeOpt
            try { localStorage.setItem(KEY, value) } catch (_) {}
            if (value === "system") {
              root.removeAttribute("data-theme")
              root.setAttribute("data-theme-source", "system")
            } else {
              root.setAttribute("data-theme", value)
              root.setAttribute("data-theme-source", "user")
            }
            mark()
            this.el.removeAttribute("open")
            if (trigger) trigger.focus()
          })

          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Escape" && this.el.open) {
              this.el.removeAttribute("open")
              if (trigger) trigger.focus()
            }
          })
        }
      }
    </script>
    """
  end
end
