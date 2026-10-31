defmodule OpenResultsWeb.Export do
  @moduledoc """
  A tournament's lists as rows for a spreadsheet - the CSV exports of
  `OpenResultsWeb.ExportController`.

  ## The rule

  **A file holds nothing its page does not show.** Each export is its page
  in another shape, built from the same accessors (`OpenResultsWeb.Tournament`)
  behind the same display ticks:

    * a column the arbiter hides on the page (rating, club, federation,
      title, tie-breaks, ...) is not in the file - not empty, absent;
    * the standings stop where the published standings stop, the
      cross-table at `Tournament.within_standings?/2`, exactly as the grid
      does;
    * a round whose results are withheld has its pairings and no results;
    * the FIDE id is in the player list only when the player cards are
      published, because the card is the one page that prints it.

  Nothing is computed here either. Ranks, points and tie-breaks are copied
  from the snapshot as the arbiter's app sent them.

  ## Numbers and cells

  Numbers are written with a decimal point whatever the reader's language
  (`2.5`, never `2,5`): a CSV is read by programs as often as by people, and
  a comma inside a number is the one ambiguity the format cannot afford.
  Headings are in the reader's language. A text cell starting with `=`, `+`,
  `-`, `@`, a tab or a carriage return gets a leading apostrophe, so a name
  somebody published as a formula stays text when a spreadsheet opens it.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  alias OpenResultsWeb.Tournament
  alias OpenResultsWeb.TournamentHTML

  @typedoc "One line of the file: each cell a string, a number or nil."
  @type row :: [String.t() | number() | nil]

  ## ---------- standings ----------

  @doc """
  The standings as on `/t/:slug`: the team standings for a team event, the
  starting list before the first standings, the individual standings
  otherwise. `[]` beyond the heading when nothing is published yet.
  """
  @spec standings(map()) :: [row()]
  def standings(payload) do
    cond do
      Tournament.team_event?(payload) -> team_standings(payload)
      Tournament.starting_rank?(payload) -> players(payload)
      true -> individual_standings(payload)
    end
  end

  defp individual_standings(payload) do
    show = shown(payload)
    rows = Tournament.standings_rows(payload)
    players = Tournament.players_by_no(payload)
    tiebreaks = if show.tiebreaks, do: Tournament.tiebreaks(payload), else: []
    keizer? = Tournament.keizer?(payload)
    categories? = show.category and Enum.any?(rows, & &1["category"])
    rounds_played? = Enum.any?(rows, &Map.has_key?(&1, "rounds_played"))
    performance? = not keizer? and Enum.any?(rows, &Map.has_key?(&1, "performance"))

    heading =
      [gettext("Rank"), gettext("No"), gettext("Name")] ++
        player_headings(show) ++
        if(show.sex, do: [gettext("Sex")], else: []) ++
        if(categories?, do: [gettext("Category")], else: []) ++
        if(rounds_played?, do: [gettext("Rounds played")], else: []) ++
        if(performance?, do: [gettext("Performance")], else: []) ++
        if(keizer?,
          do: [gettext("Value"), gettext("Keizer points"), gettext("Score")],
          else: [gettext("Points") | Enum.map(tiebreaks, &Tournament.tiebreak_short/1)]
        )

    body =
      for row <- rows do
        player = Map.get(players, row["player"], %{})

        [
          if(Tournament.uncounted?(row), do: nil, else: row["rank"]),
          row["player"],
          player["name"]
        ] ++
          player_cells(player, show) ++
          if(show.sex, do: [player["sex"]], else: []) ++
          if(categories?, do: [row["category"]], else: []) ++
          if(rounds_played?, do: [row["rounds_played"]], else: []) ++
          if(performance?, do: [row["performance"]], else: []) ++
          if(keizer?,
            do: [row["value"], row["points"], row["score"]],
            else: [
              row["points"]
              | Enum.map(0..(length(tiebreaks) - 1)//1, &Tournament.tiebreak_value(row, &1))
            ]
          )
      end

    [heading | body]
  end

  defp team_standings(payload) do
    tiebreaks = Tournament.team_tiebreaks(payload)
    teams = Tournament.teams_by_no(payload)

    heading =
      [gettext("Rank"), gettext("Team"), gettext("Match points"), gettext("Game points")] ++
        Enum.map(tiebreaks, &Tournament.tiebreak_short/1)

    body =
      for row <- Tournament.team_standings_rows(payload) do
        [row["rank"], Tournament.team_label(teams[row["team"]]), row["mp"], row["gp"]] ++
          Enum.map(0..(length(tiebreaks) - 1)//1, &Tournament.tiebreak_value(row, &1))
      end

    [heading | body]
  end

  ## ---------- the player list ----------

  @doc """
  Every player in starting-number order - the starting list the standings
  page shows before round 1, with the columns it shows, and the FIDE id
  where the player cards (which print it) are published.
  """
  @spec players(map()) :: [row()]
  def players(payload) do
    show = shown(payload)
    rows = Tournament.starting_rank(payload)
    categories? = show.category and Enum.any?(rows, &(&1["category"] not in [nil, ""]))

    heading =
      [gettext("No"), gettext("Name")] ++
        player_headings(show) ++
        if(show.sex, do: [gettext("Sex")], else: []) ++
        if(categories?, do: [gettext("Category")], else: []) ++
        if(show.player_cards, do: [gettext("FIDE ID")], else: [])

    body =
      for player <- rows do
        [player["no"], player["name"]] ++
          player_cells(player, show) ++
          if(show.sex, do: [player["sex"]], else: []) ++
          if(categories?, do: [player["category"]], else: []) ++
          if(show.player_cards, do: [positive(player["fide_id"])], else: [])
      end

    [heading | body]
  end

  ## ---------- the cross-table ----------

  @doc """
  The cross-table as on `/t/:slug/crosstable`: a column per round it shows,
  each cell the opponent's number, the colour and the points
  (`12w 1`, `7b 0.5 forfeit`), a bye as its points and its kind.
  """
  @spec crosstable(map()) :: [row()]
  def crosstable(payload) do
    show = shown(payload)
    numbers = Tournament.crosstable_rounds(payload)

    heading =
      [gettext("Rank"), gettext("No"), gettext("Name")] ++
        player_headings(show) ++
        Enum.map(numbers, &Tournament.round_label(payload, &1)) ++ [gettext("Points")]

    body =
      for row <- Tournament.crosstable(payload) do
        [row.rank, row.no, row.player["name"]] ++
          player_cells(row.player, show) ++
          Enum.map(row.cells, &cell/1) ++ [row.points]
      end

    [heading | body]
  end

  defp cell(%{kind: :game} = cell) do
    {token, note} = Tournament.result_parts(cell.result)

    score =
      cond do
        not is_nil(cell.points) -> number(cell.points)
        cell.postponed -> gettext("postponed")
        token -> token
        true -> "-"
      end

    [
      "#{cell.opponent_no || "-"}#{colour(cell.colour)}",
      score,
      note && note_word(note)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp cell(%{kind: :bye} = cell) do
    [number(cell.points), TournamentHTML.bye_kind(cell.bye)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp cell(_nothing), do: nil

  defp colour(:white), do: "w"
  defp colour(:black), do: "b"
  defp colour(_none), do: ""

  defp note_word("forfeit"), do: gettext("forfeit")
  defp note_word("unrated"), do: gettext("unrated")
  defp note_word(other), do: other

  ## ---------- pairings ----------

  @doc """
  Every published round's boards and byes, one line each, as on the round
  pages: the board's label, both players and the result - empty for a round
  whose results are withheld, and for a game not yet reported. Byes only
  where the arbiter publishes them.
  """
  @spec pairings(map()) :: [row()]
  def pairings(payload) do
    show = shown(payload)
    players = Tournament.players_by_no(payload)

    heading = [
      gettext("Round"),
      gettext("Board"),
      gettext("White no"),
      gettext("White"),
      gettext("Result"),
      gettext("Black no"),
      gettext("Black")
    ]

    body =
      for round <- Tournament.rounds(payload),
          number = round["number"],
          is_integer(number),
          line <- round_lines(payload, round, number, players, show),
          do: line

    [heading | body]
  end

  defp round_lines(payload, round, number, players, show) do
    label = Tournament.round_label(payload, number)
    public? = Tournament.results_public?(round)

    boards =
      for board <- Tournament.boards(round) do
        [
          label,
          Tournament.board_label(board),
          board["white"],
          name(players, board["white"]),
          board_result(board, public?),
          board["black"],
          name(players, board["black"])
        ]
      end

    byes =
      if show.byes do
        for bye <- Tournament.byes(round), no = bye["player"], not is_nil(no) do
          [label, nil, no, name(players, no), TournamentHTML.bye_kind(bye["kind"]), nil, nil]
        end
      else
        []
      end

    boards ++ byes
  end

  defp board_result(_board, false), do: nil

  defp board_result(board, true) do
    cond do
      Tournament.outstanding?(board) -> gettext("postponed")
      is_binary(board["result"]) -> board["result"]
      true -> nil
    end
  end

  defp name(_players, nil), do: nil
  defp name(players, no), do: get_in(players, [no, "name"])

  ## ---------- the shared columns ----------

  # The columns a player carries on every list, in the standings' order,
  # each behind its tick.
  defp player_headings(show) do
    [
      show.title && gettext("Title"),
      show.federation && gettext("Federation"),
      show.club && gettext("Club"),
      show.rating && gettext("Rating")
    ]
    |> Enum.filter(& &1)
  end

  defp player_cells(player, show) do
    [
      {show.title, player["title"]},
      {show.federation, player["federation"]},
      {show.club, player["club"]},
      {show.rating, player["rating"]}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp shown(payload) do
    [
      rating: "rating",
      title: "title",
      federation: "federation",
      club: "club",
      category: "category",
      tiebreaks: "tiebreaks",
      player_cards: "player_cards",
      byes: "byes"
    ]
    |> Map.new(fn {key, name} -> {key, Tournament.show?(payload, name)} end)
    |> Map.put(:sex, Tournament.sex?(payload))
  end

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_absent), do: nil

  ## ---------- writing the file ----------

  @doc """
  `rows` as RFC 4180 CSV: comma separated, CRLF line ends, every text cell
  quoted, a byte order mark first so a spreadsheet reads the names as UTF-8.
  """
  @spec to_csv([row()]) :: iodata()
  def to_csv(rows) do
    ["﻿" | Enum.map(rows, fn row -> [Enum.map_intersperse(row, ",", &field/1), "\r\n"] end)]
  end

  defp field(nil), do: ""
  defp field(value) when is_integer(value), do: Integer.to_string(value)
  defp field(value) when is_float(value), do: number(value)
  defp field(true), do: "1"
  defp field(false), do: "0"

  defp field(value) when is_binary(value) do
    text = if value =~ ~r/\A[=+\-@\t\r]/, do: "'" <> value, else: value
    [?", String.replace(text, "\"", "\"\""), ?"]
  end

  defp field(_other), do: ""

  # `2.5`, `17`, `22.25` - always a point, never the reader's comma.
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) when is_float(value) do
    if trunc(value) == value,
      do: Integer.to_string(trunc(value)),
      else: :erlang.float_to_binary(value, [:short])
  end

  defp number(_other), do: nil
end
