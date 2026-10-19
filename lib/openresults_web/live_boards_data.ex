defmodule OpenResultsWeb.LiveBoardsData do
  @moduledoc """
  What the live-board pages show: a published round's boards (the snapshot's
  say-so: who sits where) joined with the live game on each
  (`OpenResults.LiveBoards`'s say-so: what is being played).

  ## What a spectator may see

  A live game is shown only if its board is in the published snapshot. A round
  the arbiter has not published, a hidden board, and every game of a
  tournament whose pairings are switched off (`display.pairings`) simply have
  no tile, whatever the relay has reported - the relay may know a pairing the
  arbiter has not released.

  Names, titles, ratings and federations follow the same ticks as every other
  public page. A result follows the round's own rule: where the round's
  results are not public (`rounds[].results_public: false`), neither the
  published result nor the relay's suggestion is shown, only that the game is
  over.
  """

  alias OpenResults.LiveBoards
  alias OpenResultsWeb.Flags
  alias OpenResultsWeb.Tournament

  @doc "Whether this tournament's pairings - and so its live boards - are public."
  def public?(payload), do: Tournament.show?(payload, "pairings")

  @doc "The published rounds that have boards, in order."
  def rounds(payload) do
    if public?(payload) do
      payload |> Tournament.rounds() |> Enum.filter(&(Tournament.boards(&1) != []))
    else
      []
    end
  end

  @doc "The newest published round with boards, or `nil`."
  def latest_round(payload), do: payload |> rounds() |> List.last()

  @doc """
  The tiles of round `number`: one per published board, in board order, each
  with its `:view` (`nil` while nothing has been reported).

  Options: `:now_ms`, for tests; `:plies` (default `true`), which `false`
  turns into a read that leaves the move lists out when no delay is set - the
  views then carry `plies: []` but everything a tile is drawn from; `:only`,
  one board number, which reads that game alone (`tile/5` sets it).
  """
  def tiles(payload, slug, number, opts \\ []) do
    case Tournament.round(payload, number) do
      nil -> []
      round -> build(payload, slug, round, opts)
    end
  end

  defp build(payload, slug, round, opts) do
    if public?(payload) do
      number = Map.get(round, "number")
      now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.os_time(:millisecond) end)
      delay_ms = :timer.minutes(LiveBoards.delay_minutes(slug))
      # Move lists are read only when they are used: always for one game's own
      # page, and for a tile only while a delay makes the arrival time of
      # each move matter.
      plies? = Keyword.get(opts, :plies, true) or delay_ms > 0
      games = games(slug, number, Keyword.get(opts, :only), plies?)
      players = Tournament.players_by_no(payload)
      show = show(payload)
      results? = Tournament.results_public?(round)

      in_match =
        if Tournament.team_event?(payload), do: Tournament.board_matches(round), else: %{}

      teams = if in_match == %{}, do: %{}, else: Tournament.teams_by_no(payload)

      for board <- Tournament.boards(round), is_integer(Map.get(board, "board")) do
        no = Map.get(board, "board")
        game = Map.get(games, no)
        view = game && LiveBoards.view(game, delay_ms, now_ms)
        match = Map.get(in_match, no)

        %{
          id: "live-#{number}-#{no}",
          round: number,
          board: no,
          label: label(board, match),
          match: match && match.match,
          team_names: team_names(teams, match),
          white: person(players, Map.get(board, "white"), show),
          black: person(players, Map.get(board, "black"), show),
          official: if(results?, do: string(board, "result")),
          results?: results?,
          unplayed: unplayed(string(board, "result"), results?),
          view: view,
          signature: signature(view)
        }
      end
    else
      []
    end
  end

  defp team_names(_teams, nil), do: []

  defp team_names(teams, %{match: match}) do
    for key <- ["team_a", "team_b"],
        team = Map.get(teams, Map.get(match, key)),
        do: Tournament.team_label(team)
  end

  defp label(board, nil), do: Tournament.board_label(board)
  defp label(_board, %{match: match, k: k}), do: "#{match["number"]}/#{k}"

  # One round's games by board number - or one game's, for a refresh that
  # concerns one board.
  defp games(slug, number, nil, plies?),
    do: Map.new(LiveBoards.games_for_round(slug, number, plies: plies?), &{&1.board, &1})

  defp games(slug, number, board, _plies?) do
    case LiveBoards.get_game(slug, number, board) do
      nil -> %{}
      game -> %{game.board => game}
    end
  end

  @doc """
  One tile, or `nil` when the board is not published. Options as `tiles/4`.
  """
  def tile(payload, slug, number, board, opts \\ []) do
    payload
    |> tiles(slug, number, Keyword.put(opts, :only, board))
    |> Enum.find(&(&1.board == board))
  end

  # What changes what a tile looks like, apart from the clocks, which count on
  # in the browser.
  defp signature(nil), do: nil

  defp signature(view),
    do: {view.ply, view.fen, view.status, view.result, view.clocks.running}

  @doc """
  When a tile has to be sent again: its `signature` moved, or the relay
  reported its clocks afresh (`view.clock_at`) - a correction the browser
  cannot work out by counting down. A message about a board whose stamp is
  unchanged is a repeat, and sending the tile again is wasted bytes on every
  open page (the 2026-10-19 sweep: the pages forced every one through).
  """
  @spec stamp(map()) :: term()
  def stamp(%{signature: signature, view: view}), do: {signature, view && view.clock_at}

  @doc """
  The result to print on a tile: the published one, else - once the game is
  over and the round's results are public - the relay's suggestion, marked
  `provisional`.
  """
  def result(%{official: official}) when is_binary(official), do: {official, false}

  def result(%{results?: true, view: %{status: "finished", result: result}})
      when is_binary(result) and result != "*",
      do: {result, true}

  def result(_tile), do: nil

  @doc """
  Whether the arbiter has published this board as never played - a forfeit
  (`1-0FF`, `0-1FF`) or a double forfeit (`0-0FF`) - and so whether the relay
  will ever send a game for it: `:forfeit`, `:double_forfeit`, `:withheld`
  (unplayed, but the round's results are not public, so the page may say the
  game is over and nothing about who won it), or `nil` for a game that is, or
  will be, played.

  Read off the published token, never off the relay: a board nobody sits at
  sends nothing, and "nothing has been sent" used to read as "not started"
  until the end of time.
  """
  def unplayed(token, results?) when is_binary(token) do
    kind =
      cond do
        token == "0-0FF" -> :double_forfeit
        String.ends_with?(token, "FF") -> :forfeit
        true -> nil
      end

    if kind && not results?, do: :withheld, else: kind
  end

  def unplayed(_no_result, _results?), do: nil

  @doc """
  What each side scored, as a reader writes it: `{"1", "0"}`, `{"½", "½"}`,
  from the tile's result (`result/1`), or `nil` while there is none.
  """
  def scores(tile) do
    with {token, _provisional?} <- result(tile),
         [white, black] <- token |> Tournament.result_parts() |> elem(0) |> split_token() do
      {glyph(white), glyph(black)}
    else
      _none -> nil
    end
  end

  defp split_token(nil), do: nil
  defp split_token(base), do: String.split(base, "-", parts: 2)

  @doc "A result token as it is printed: `1/2-1/2` is `½-½`; a forfeit's `FF` is left to a badge."
  def result_text(token) when is_binary(token) do
    case token |> Tournament.result_parts() |> elem(0) |> split_token() do
      [white, black] -> glyph(white) <> "-" <> glyph(black)
      _other -> token
    end
  end

  def result_text(_none), do: nil

  defp glyph("1/2"), do: "½"
  defp glyph(other), do: other

  @doc """
  The tournament's facts for a live page's info panel - each `nil` where the
  arbiter's ticks keep it off the pages: `%{name, dates, city, round_date}`.
  """
  def event_info(payload, round_number) do
    info = Tournament.info(payload)
    dates? = Tournament.show?(payload, "dates")
    round = (round_number && Tournament.round(payload, round_number)) || %{}

    %{
      name: Tournament.name(payload),
      start_date: if(dates?, do: string(info, "start_date")),
      end_date: if(dates?, do: string(info, "end_date")),
      city: if(Tournament.show?(payload, "city"), do: string(info, "city")),
      round_date: if(dates?, do: string(round, "date"))
    }
  end

  @doc """
  The heading of a team match for the pairing list: `%{id, kind: :match,
  number, a, b, score}` - `score` `{a, b}` in game points, `nil` while the
  round's results are withheld or the match has none yet.
  """
  def match_header(payload, round_number, %{} = match, results?) do
    teams = Tournament.teams_by_no(payload)

    score =
      case {results?, Map.get(match, "game_points")} do
        {true, %{"a" => a, "b" => b}} when is_number(a) and is_number(b) -> {points(a), points(b)}
        _withheld_or_undecided -> nil
      end

    %{
      id: "lb-match-#{round_number}-#{Map.get(match, "number")}",
      kind: :match,
      number: Map.get(match, "number"),
      a: Tournament.team_label(Map.get(teams, Map.get(match, "team_a"))),
      b: Tournament.team_label(Map.get(teams, Map.get(match, "team_b"))),
      score: score
    }
  end

  # 2.5 as a scoreboard writes it: "2½". Whole numbers stay whole.
  defp points(n) when is_number(n) do
    whole = trunc(n)
    half? = n - whole >= 0.5

    cond do
      half? and whole == 0 -> "½"
      half? -> "#{whole}½"
      true -> "#{whole}"
    end
  end

  @doc "Whether the game is on the boards right now."
  def live?(%{view: %{status: "live"}}), do: true
  def live?(_tile), do: false

  defp show(payload) do
    ~w(rating title federation)
    |> Map.new(&{String.to_atom(&1), Tournament.show?(payload, &1)})
    # Absent means off for this one - see `Tournament.flags?/1`.
    |> Map.put(:flags, Tournament.flags?(payload))
  end

  defp person(_players, nil, _show), do: nil

  defp person(players, no, show) do
    player = Map.get(players, no, %{})

    %{
      no: no,
      name: string(player, "name") || "#" <> to_string(no),
      title: if(show.title, do: string(player, "title")),
      rating: if(show.rating, do: positive(Map.get(player, "rating"))),
      federation: if(show.federation, do: string(player, "federation")),
      flag: if(show.federation, do: Flags.path(string(player, "federation"), show.flags))
    }
  end

  @doc """
  What a clock reads before anyone has moved, in ms, or `nil` when the
  snapshot does not say.

  The snapshot has no structured time control today: OpenPairings publishes
  `tournament.time_control`, the prose an arbiter typed ("90 min + 30 s per
  move"). A structured `time_control_minutes` (positive integer) on the round
  or on `tournament` wins when it arrives; until then the prose is read for
  its base time, and a text that does not start with one yields `nil` rather
  than a guess.
  """
  def start_ms(payload, round_number) do
    this = Tournament.round(payload, round_number) || %{}
    info = Tournament.info(payload)

    base =
      Enum.find(
        [
          minutes(Map.get(this, "time_control_minutes")),
          minutes(Map.get(info, "time_control_minutes")),
          base_minutes(string(this, "time_control")),
          base_minutes(string(info, "time_control"))
        ],
        & &1
      )

    base && round(base * 60_000)
  end

  defp minutes(n) when is_number(n) and n > 0, do: n
  defp minutes(_other), do: nil

  # The base time at the head of "90 min + 30 s", "90'+30", "15+10", "1h30",
  # "1 hour". Only a number with a unit, or one followed by an increment,
  # counts: "40 moves in 90 minutes" is not a base time this will invent.
  defp base_minutes(nil), do: nil

  defp base_minutes(text) do
    text = String.downcase(text)

    cond do
      m = Regex.run(~r/^\s*(\d{1,2})\s*(?:hours?|hrs?|uur|h|u)\s*(\d{1,2})?/u, text) ->
        [_, hours | rest] = m
        extra = if rest in [[], [""]], do: 0, else: String.to_integer(hd(rest))
        minutes(String.to_integer(hours) * 60 + extra)

      m = Regex.run(~r/^\s*(\d{1,3})\s*(?:minutes?|minuten|mins?|m\b|'|\x{2019}|\+)/u, text) ->
        minutes(String.to_integer(Enum.at(m, 1)))

      true ->
        nil
    end
  end

  @doc "The PGN tags for a tile's game, honouring the same ticks as the page."
  def pgn_tags(payload, tile) do
    round = Tournament.round(payload, tile.round) || %{}
    players = Tournament.players_by_no(payload)
    info = Tournament.info(payload)
    show = show(payload)
    result = result(tile)

    side = fn colour, person ->
      raw = person && Map.get(players, person.no, %{})

      [
        {colour, person && person.name},
        {"#{colour}Title", person && person.title},
        {"#{colour}Elo", person && person.rating},
        {"#{colour}FideId", if(person && show.federation, do: raw && Map.get(raw, "fide_id"))}
      ]
    end

    date = string(round, "date") || string(info, "start_date")
    date = if Tournament.show?(payload, "dates"), do: date
    city = if Tournament.show?(payload, "city"), do: string(info, "city")

    [
      {"Event", Tournament.name(payload)},
      {"Site", city},
      {"Date", date && String.replace(date, "-", ".")},
      {"Round", "#{tile.round}.#{tile.board}"}
    ] ++
      side.("White", tile.white) ++
      side.("Black", tile.black) ++
      [{"Result", result && elem(result, 0)}]
  end

  defp string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp string(_other, _key), do: nil

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_other), do: nil
end
