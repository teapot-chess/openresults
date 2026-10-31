defmodule OpenResultsWeb.Hall do
  @moduledoc """
  What the hall display shows, worked out from a published snapshot.

  Pure functions and no rendering, so the rules - which views exist, what is
  on each page, when the cycle holds still - are tested here without a
  socket, and `OpenResultsWeb.HallLive` only keeps time and draws.

  ## Settings

  The arbiter's choices travel in the snapshot as `tournament.hall` (see
  `docs/snapshot-schema.md`), set on OpenPairings' Results-site settings page
  beside the "what the public page shows" ticks. Absent - an OpenPairings
  that predates the display, or a key it does not send - means the defaults
  below, the same "absent means the old behaviour" reading every other key
  in the contract gets.

  ## Never more than the public pages show

  These settings only ever choose among things the public may already see.
  The arbiter's `display` ticks and round levels decide that, and are read
  here exactly as the ordinary pages read them: no pairings, names or
  results view when round pages are withheld (`display.pairings`), no
  standings view when the standings are (`display.standings`), no rating,
  title or federation beside a name whose tick is off, no bye in the name
  list when byes are hidden, and no result from a round whose results are
  not public - the snapshot does not even carry those.

  ## Pages

  Fixed numbers of rows per page rather than rows measured on the glass. The
  display's type is sized in viewport units (see "Hall display" in app.css),
  so twelve boards fill a 1080p television and a 4K one alike, and the server
  can decide the pages - which is what lets it hold, skip and resume the
  cycle, and lets a test check all of it.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  alias OpenResultsWeb.Flags
  alias OpenResultsWeb.Tournament

  @boards_per_page 10
  @names_per_page 28
  @standings_per_page 12
  @latest_results 12
  @live_per_page 4

  # A result that came in within this long is marked as new on the results
  # view. Long enough to survive a whole cycle past the other views.
  @fresh_ms :timer.minutes(5)

  # `:live` is last of the cycle and skipped - it has no pages - until the
  # relay has reported a game in progress on a board of this round. See
  # `OpenResultsWeb.LiveBoardsData`; an arbiter switches it off with
  # `tournament.hall.live: false`.
  @cycle_views [:pairings, :names, :results, :standings, :live]
  @views @cycle_views ++ [:announcement]
  # The live boards are among them: a round that has just started is exactly
  # when the games are worth watching, and the view has no pages - so is not
  # in the cycle at all - until one is being played.
  @hold_views [:pairings, :names, :live, :announcement]

  @default_seconds 15
  @default_top 10
  @seconds_range 5..120
  @top_range 3..50
  @announcement_max 500

  @type view :: :pairings | :names | :results | :standings | :live | :announcement
  @type slide :: {view(), non_neg_integer()}

  def boards_per_page, do: @boards_per_page
  def names_per_page, do: @names_per_page
  def standings_per_page, do: @standings_per_page
  def latest_results, do: @latest_results
  def live_per_page, do: @live_per_page

  @doc "Every view, in cycle order."
  @spec views() :: [view()]
  def views, do: @views

  @doc """
  The display's settings for this snapshot: `tournament.hall`, defaults filled
  in, out-of-range and junk values ignored.

  `only` narrows the views further - the hall URL's `?views=` - so one screen
  can show only the name list while another cycles. It can only take views
  away: a view the arbiter switched off stays off whatever the URL says.
  """
  @spec settings(map(), [view()] | nil) :: map()
  def settings(payload, only \\ nil) do
    hall =
      case Map.get(Tournament.info(payload), "hall") do
        %{} = hall -> hall
        _absent_or_junk -> %{}
      end

    announcement = announcement(hall)

    views =
      Enum.filter(@cycle_views, &flag(hall, Atom.to_string(&1))) ++
        if(announcement, do: [:announcement], else: [])

    %{
      views: if(only, do: Enum.filter(views, &(&1 in only)), else: views),
      page_seconds: integer(hall, "page_seconds", @seconds_range, @default_seconds),
      standings_top: integer(hall, "standings_top", @top_range, @default_top),
      hold_new_round?: flag(hall, "hold_new_round"),
      announcement: announcement
    }
  end

  @doc """
  Reads the hall URL's `?views=` - a comma-separated list of view names - or
  `nil` when there is none or nothing in it is a view. Unknown names are
  ignored; nothing here creates an atom.
  """
  @spec parse_views(term()) :: [view()] | nil
  def parse_views(param) when is_binary(param) do
    names = Map.new(@views, &{Atom.to_string(&1), &1})

    param
    |> String.split(",", trim: true)
    |> Enum.map(&Map.get(names, &1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      views -> Enum.uniq(views)
    end
  end

  def parse_views(_absent), do: nil

  defp flag(hall, key) do
    case Map.get(hall, key) do
      false -> false
      _true_or_absent -> true
    end
  end

  defp integer(hall, key, range, default) do
    case Map.get(hall, key) do
      n when is_integer(n) -> if n in range, do: n, else: default
      _absent_or_junk -> default
    end
  end

  defp announcement(hall) do
    case Map.get(hall, "announcement") do
      text when is_binary(text) ->
        case String.trim(text) do
          "" -> nil
          trimmed -> String.slice(trimmed, 0, @announcement_max)
        end

      _absent ->
        nil
    end
  end

  @doc """
  Everything the display draws, from one snapshot's payload.

  Takes the settings for the standings' length; every other choice about
  what to show was made by the arbiter's `display` ticks, read here.
  """
  @spec build(map(), map()) :: map()
  def build(payload, settings) do
    show = show(payload)
    players = Tournament.players_by_no(payload)
    round = if show.pairings, do: List.last(Tournament.rounds(payload))
    results? = round != nil and Tournament.results_public?(round)
    boards = if round, do: Tournament.boards(round), else: []

    # In a team event a board is a seat of a match, and a match is a table:
    # "match 3, board 2" is what a captain's sheet says and what a player
    # looks for. The round-wide board number means nothing to them.
    in_match =
      if round && Tournament.team_event?(payload), do: Tournament.board_matches(round), else: %{}

    %{
      name: Tournament.name(payload),
      round: round_info(payload, round, show),
      results?: results?,
      progress: if(round, do: Tournament.results_progress(round), else: {0, 0}),
      boards: Enum.map(boards, &board_row(&1, players, show, results?, in_match)),
      matches: matches(payload, round, results?),
      names: if(round, do: names(round, boards, players, show, in_match), else: []),
      reported: if(results?, do: reported(boards, players, show, in_match), else: []),
      standings: standings(payload, players, show, settings.standings_top),
      announcement: settings.announcement,
      # The games on the boards right now - the tiles of
      # `OpenResultsWeb.LiveBoardsData`. Not worked out here: they come from
      # the live games, not the snapshot, and the display fills them in.
      live: []
    }
  end

  # The arbiter's ticks, resolved once - absent means shown, as everywhere.
  defp show(payload) do
    Map.new(
      ~w(pairings standings byes rating title federation dates),
      &{String.to_atom(&1), Tournament.show?(payload, &1)}
    )
    # Absent means off for this one - see `Tournament.flags?/1`.
    |> Map.put(:flags, Tournament.flags?(payload))
  end

  defp round_info(_payload, nil, _show), do: nil

  defp round_info(payload, round, show) do
    number = Map.get(round, "number")
    count = Tournament.rounds_count(payload)

    %{
      number: number,
      heading: Tournament.round_heading(payload, number),
      label: Tournament.round_label(payload, number),
      date: if(show.dates, do: string(round, "date")),
      # Only when the tournament says how many rounds it has: a round-robin
      # or swiss with no count cannot know its last round is the last.
      final?: is_integer(number) and count > 1 and number == count
    }
  end

  defp board_row(board, players, show, results?, in_match) do
    postponed? = Tournament.postponed?(board)
    seat = Map.get(in_match, Map.get(board, "board"))

    %{
      id: "board-#{Map.get(board, "board")}",
      label: board_label(board, seat),
      match: seat && seat.match["number"],
      k: seat && seat.k,
      white: person(players, Map.get(board, "white"), show),
      black: person(players, Map.get(board, "black"), show),
      result: if(results?, do: string(board, "result")),
      postponed?: results? and postponed?,
      postponed_date: if(results? and show.dates, do: Tournament.postponed_date(board))
    }
  end

  # "3/2" - board 2 of match 3 - for a team event's board, the board's own
  # label otherwise.
  defp board_label(board, nil), do: Tournament.board_label(board)
  defp board_label(_board, %{match: match, k: k}), do: "#{match["number"]}/#{k}"

  # A player as the display prints them: the name always, the rest only where
  # the arbiter's tick allows it. `nil` for an empty seat.
  defp person(_players, nil, _show), do: nil

  defp person(players, no, show) do
    player = Map.get(players, no, %{})

    %{
      no: no,
      name: string(player, "name") || gettext("Player %{number}", number: no),
      title: if(show.title, do: string(player, "title")),
      rating: if(show.rating, do: positive(Map.get(player, "rating"))),
      federation: if(show.federation, do: string(player, "federation")),
      flag: if(show.federation, do: Flags.path(string(player, "federation"), show.flags))
    }
  end

  # A team event's matches, when the round has any. A round without them
  # (nothing paired as teams yet) shows its boards.
  defp matches(payload, round, results?) do
    if round && Tournament.team_event?(payload) do
      teams = Tournament.teams_by_no(payload)

      round
      |> Tournament.matches()
      |> Enum.map(fn match ->
        points = if results?, do: Map.get(match, "game_points")

        %{
          id: "match-#{Map.get(match, "number")}",
          number: Map.get(match, "number"),
          team_a: Tournament.team_label(Map.get(teams, Map.get(match, "team_a"))),
          team_b: Tournament.team_label(Map.get(teams, Map.get(match, "team_b"))),
          bye?: Map.get(match, "bye") == true,
          # Which team has White on board 1 (so Black on the next, and so on).
          colour_a: board1_colour(match, "team_a"),
          colour_b: board1_colour(match, "team_b"),
          score_a: if(is_map(points), do: Map.get(points, "a")),
          score_b: if(is_map(points), do: Map.get(points, "b"))
        }
      end)
    else
      []
    end
  end

  # The colour a side has on board 1 of its match, or `nil` for a bye and for
  # a match that does not say.
  defp board1_colour(match, side) do
    white = Map.get(match, "board1_white_team")

    cond do
      Map.get(match, "bye") == true or not is_integer(white) -> nil
      white == Map.get(match, side) -> :white
      true -> :black
    end
  end

  # Everybody in the round, alphabetically, with where to sit. Byes only when
  # the byes table is public - a name listed with "bye" beside it is that
  # table, one row at a time.
  defp names(round, boards, players, show, in_match) do
    seated =
      Enum.flat_map(boards, fn board ->
        label = Tournament.board_label(board)
        seat = Map.get(in_match, Map.get(board, "board"))

        [{Map.get(board, "white"), :white}, {Map.get(board, "black"), :black}]
        |> Enum.reject(fn {no, _colour} -> is_nil(no) end)
        |> Enum.map(fn {no, colour} ->
          Map.merge(person(players, no, show), %{
            board: label,
            match: seat && seat.match["number"],
            k: seat && seat.k,
            colour: colour,
            bye: nil
          })
        end)
      end)

    byes =
      if show.byes do
        round
        |> Tournament.byes()
        |> Enum.reject(&is_nil(Map.get(&1, "player")))
        |> Enum.map(fn bye ->
          players
          |> person(Map.get(bye, "player"), show)
          |> Map.merge(%{
            board: nil,
            match: nil,
            k: nil,
            colour: nil,
            bye: string(bye, "kind") || "bye"
          })
        end)
      else
        []
      end

    (seated ++ byes)
    |> Enum.uniq_by(& &1.no)
    |> Enum.sort_by(&{sort_key(&1.name), &1.no})
    |> Enum.map(&Map.put(&1, :id, "name-#{&1.no}"))
  end

  # Alphabetical the way a reader scanning for their surname expects it:
  # accents do not move a name, and case does not either. "Ångström" sits
  # with the As, not after the Zs where a byte comparison puts it. The
  # letters Unicode does not decompose into a base and an accent - Đ, Ł, Ø -
  # are folded by hand, or Đurić would come after Zeeuw.
  @folded %{
    "đ" => "d",
    "ł" => "l",
    "ø" => "o",
    "æ" => "ae",
    "œ" => "oe",
    "ß" => "ss",
    "þ" => "th"
  }

  @doc false
  def sort_key(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(Map.keys(@folded), &Map.fetch!(@folded, &1))
  end

  defp reported(boards, players, show, in_match) do
    boards
    |> Enum.filter(&is_binary(Map.get(&1, "result")))
    |> Enum.map(&board_row(&1, players, show, true, in_match))
  end

  defp standings(payload, players, show, top) do
    cond do
      not show.standings ->
        nil

      Tournament.team_event?(payload) ->
        team_standings(payload, top)

      Tournament.starting_rank?(payload) or Tournament.standings_rows(payload) == [] ->
        nil

      true ->
        {provisional?, _count} = Tournament.standings_provisional(payload)

        %{
          kind: if(Tournament.keizer?(payload), do: :keizer, else: :points),
          after_round: Tournament.after_round(payload),
          provisional?: provisional?,
          rows:
            payload
            |> Tournament.standings_rows()
            # A wall of places has no line for a row without one (C.05 6.6);
            # the standings page lists it, marked.
            |> Enum.reject(&Tournament.uncounted?/1)
            |> Enum.take(top)
            |> Enum.map(fn row ->
              no = Map.get(row, "player")

              %{
                id: "standing-#{no}",
                rank: Map.get(row, "rank"),
                person: person(players, no, show),
                points: Map.get(row, "points")
              }
            end)
        }
    end
  end

  defp team_standings(payload, top) do
    case Tournament.team_standings_rows(payload) do
      [] ->
        nil

      rows ->
        teams = Tournament.teams_by_no(payload)

        %{
          kind: :teams,
          after_round: Tournament.team_after_round(payload),
          provisional?: false,
          rows:
            rows
            |> Enum.take(top)
            |> Enum.map(fn row ->
              no = Map.get(row, "team")

              %{
                id: "team-standing-#{no}",
                rank: Map.get(row, "rank"),
                team: Tournament.team_label(Map.get(teams, no)),
                mp: Map.get(row, "mp"),
                gp: Map.get(row, "gp")
              }
            end)
        }
    end
  end

  @doc """
  When each reported result of the current round was first seen, as
  `%{{round, board_id} => millis}`, updated for a fresh `data`.

  Results already in when the display started carry `nil` - when they
  arrived is unknown, and they are not "new". `now` is any clock that only
  moves forward; the LiveView uses the monotonic one. Results of an earlier round are
  forgotten once a new round is on the screen.
  """
  @spec arrivals(map(), map(), integer(), boolean()) :: %{
          {integer(), String.t()} => integer() | nil
        }
  def arrivals(known, data, now, initial?) do
    case data.round do
      nil ->
        %{}

      %{number: number} ->
        Map.new(data.reported, fn row ->
          key = {number, row.id}
          {key, Map.get(known, key, if(initial?, do: nil, else: now))}
        end)
    end
  end

  @doc """
  The newest results first, at most `latest_results/0` of them, each marked
  `fresh?` when it arrived in the last few minutes.
  """
  @spec latest(map(), map(), integer()) :: [map()]
  def latest(data, arrivals, now) do
    number = data.round && data.round.number

    data.reported
    |> Enum.map(fn row ->
      at = Map.get(arrivals, {number, row.id})
      Map.merge(row, %{at: at, fresh?: is_integer(at) and now - at < @fresh_ms})
    end)
    |> Enum.with_index()
    # Arrived while watched, newest first; then the rest in board order.
    |> Enum.sort_by(fn {row, index} ->
      if row.at, do: {0, -row.at, index}, else: {1, 0, index}
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(@latest_results)
  end

  @doc """
  Whether the cycle holds on the pairings: the newest round is paired, its
  results are public, and none is in yet. The moment a round is paired is
  the moment everybody in the hall wants one thing from the screen - which
  board they are on - and cycling past it to standings they already know
  sends them looking elsewhere.
  """
  @spec hold?(map(), map()) :: boolean()
  def hold?(data, settings) do
    settings.hold_new_round? and data.round != nil and data.results? and
      data.boards != [] and elem(data.progress, 0) == 0 and
      Enum.any?(settings.views, &(&1 in [:pairings, :names]))
  end

  @doc """
  The cycle: every page of every view that has something to show, in order,
  as `{view, page}`. Only the pairings, the names and the announcement while
  `hold?/2` is true.
  """
  @spec slides(map(), map()) :: [slide()]
  def slides(data, settings) do
    views =
      if hold?(data, settings),
        do: Enum.filter(settings.views, &(&1 in @hold_views)),
        else: settings.views

    for view <- views, page <- pages(data, view), do: {view, page}
  end

  defp pages(data, view) do
    case count(data, view) do
      0 -> []
      n -> Enum.to_list(0..(n - 1))
    end
  end

  @doc "How many pages `view` has for `data`; `0` means the view is skipped."
  @spec count(map(), view()) :: non_neg_integer()
  def count(data, :pairings), do: page_count(pairing_rows(data), @boards_per_page)
  def count(data, :names), do: page_count(data.names, @names_per_page)
  def count(%{reported: []}, :results), do: 0
  def count(_data, :results), do: 1
  def count(%{standings: nil}, :standings), do: 0
  def count(data, :standings), do: page_count(data.standings.rows, @standings_per_page)
  def count(data, :live), do: page_count(Map.get(data, :live, []), @live_per_page)
  def count(%{announcement: nil}, :announcement), do: 0
  def count(_data, :announcement), do: 1

  defp page_count(rows, per_page), do: div(length(rows) + per_page - 1, per_page)

  @doc """
  The rows on one page of one view. For `:results` pass the arrivals map and
  the clock; the other views ignore both.
  """
  @spec rows(map(), slide(), map(), integer()) :: [map()]
  def rows(data, slide, arrivals \\ %{}, now \\ 0)

  def rows(data, {:pairings, page}, _arrivals, _now),
    do: data |> pairing_rows() |> page(page, @boards_per_page)

  def rows(data, {:names, page}, _arrivals, _now), do: page(data.names, page, @names_per_page)
  def rows(data, {:results, _page}, arrivals, now), do: latest(data, arrivals, now)

  def rows(%{standings: %{rows: rows}}, {:standings, page}, _arrivals, _now),
    do: page(rows, page, @standings_per_page)

  def rows(data, {:live, page}, _arrivals, _now),
    do: data |> Map.get(:live, []) |> page(page, @live_per_page)

  def rows(_data, _slide, _arrivals, _now), do: []

  @doc "Whether the pairings view shows team matches rather than boards."
  @spec matches?(map()) :: boolean()
  def matches?(data), do: data.matches != []

  defp pairing_rows(data), do: if(matches?(data), do: data.matches, else: data.boards)

  defp page(rows, page, per_page), do: rows |> Enum.drop(page * per_page) |> Enum.take(per_page)

  @doc """
  The first letters of the first and last name on a page of the name list -
  "A - De" - so somebody waiting for their page knows whether this is it.
  """
  @spec name_range([map()]) :: {String.t(), String.t()} | nil
  def name_range([]), do: nil

  def name_range(rows) do
    {initials(List.first(rows).name), initials(List.last(rows).name)}
  end

  defp initials(name), do: name |> String.trim() |> String.slice(0, 2)

  defp string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_absent_or_zero), do: nil
end
