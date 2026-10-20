defmodule OpenResultsWeb.Meta do
  @moduledoc """
  What a link to one of these pages says when it is pasted somewhere else.

  Club WhatsApp groups and Facebook posts are how people actually find this
  site, and until this existed a link rendered as a bare URL: no title beyond
  "OpenResults", no sentence, nothing saying which tournament or which round.
  Somebody forwarding the standings had to type that themselves.

  ## Nothing new is computed here

  Every sentence is assembled from values the snapshot already carries and
  the same accessors the pages themselves use - the tournament's name, the
  round the standings were taken after, a player's rank and points. A
  description that worked something out would be a second opinion about the
  tournament, and this app does not have opinions about tournaments.

  ## The display switches are not decoration

  `city` and `dates` are ticks an arbiter can turn off, and the front page
  once printed both after every other page had stopped - the comment in
  `index.html.heex` is about exactly that bug. A meta description is a worse
  place for the same mistake: it travels off the site entirely, into a chat
  app, where nobody who could notice will ever see it. So the two facts an
  arbiter can withhold pass through `Tournament.show?/2` here as well, and
  nothing else about the tournament is ever put in a description.

  Ratings, titles, clubs and federations are not here at all. A player's name
  and their placing are what a card is about; every other field they might
  have hidden simply never reaches this module.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  alias OpenResultsWeb.Tournament
  alias OpenResultsWeb.TournamentHTML

  @doc "The front page."
  def index do
    gettext(
      "Live chess results published by arbiters: standings, round pairings and a card for every player."
    )
  end

  @doc """
  The standings page - the one that gets shared.

  Before round one, `Tournament.starting_rank?/1` holds and the page shows
  the field in starting order rather than an empty table - the description
  says so in the same terms rather than naming a separate page.
  """
  def standings(payload) do
    cond do
      Tournament.starting_rank?(payload) ->
        gettext("Standings of %{tournament}, before round 1.",
          tournament: Tournament.name(payload)
        )

      round = Tournament.after_round(payload) ->
        gettext("Standings after round %{round} of %{tournament}.",
          round: round,
          tournament: Tournament.name(payload)
        )

      true ->
        gettext("Standings of %{tournament}.", tournament: Tournament.name(payload))
    end
    |> with_where(payload)
  end

  @doc """
  The cross-table.

  No round number in it, deliberately. The published rounds can have gaps -
  an arbiter who has posted 1, 2, 3 and 5 is the fixture this repo tests
  against - so "after round 5" would be a claim the grid does not make.
  `standings.after_round` is not the answer either: it is about the placings,
  and this page has none.
  """
  def crosstable(payload) do
    gettext("Every published result of %{tournament}, round by round, as one cross-table.",
      tournament: Tournament.name(payload)
    )
    |> with_where(payload)
  end

  @doc """
  One round.

  `Tournament.round_heading/2` rather than the bare number, so a match-format
  event says "Match 2, game 1" here exactly as it does in the heading a
  reader will see when they follow the link.
  """
  def round(payload, number) do
    gettext("Pairings - %{round}, %{tournament}.",
      round: Tournament.round_heading(payload, number),
      tournament: Tournament.name(payload)
    )
    |> with_where(payload)
  end

  @doc """
  One round's page as it is shared: `round/2`, then who is on board 1 and,
  when the arbiter has made the round's results public, how that game ended.

  Board 1 because it is the one a share is usually about, and because it is
  on the page the link opens - nothing here is not already in the table.
  Names only, the rule this module keeps everywhere else.
  """
  def round_page(payload, number) do
    case board_one(payload, number) do
      nil -> round(payload, number)
      line -> round(payload, number) <> " " <> line
    end
  end

  @doc """
  The feed entry for a round whose every board has a result - see
  `OpenResultsWeb.FeedController`.
  """
  def round_results(payload, number) do
    gettext("Results - %{round}, %{tournament}.",
      round: Tournament.round_heading(payload, number),
      tournament: Tournament.name(payload)
    )
  end

  defp board_one(payload, number) do
    with round when is_map(round) <- Tournament.round(payload, number),
         %{} = board <- Enum.find(Tournament.boards(round), &(Map.get(&1, "board") == 1)),
         white when is_binary(white) <- player_name(payload, board["white"]),
         black when is_binary(black) <- player_name(payload, board["black"]) do
      result = Tournament.results_public?(round) && board["result"]

      if is_binary(result) do
        gettext("Board 1: %{white} - %{black}, %{result}.",
          white: white,
          black: black,
          result: result
        )
      else
        gettext("Board 1: %{white} - %{black}.", white: white, black: black)
      end
    else
      _no_board_one -> nil
    end
  end

  defp player_name(payload, no) when is_integer(no) do
    case Tournament.player(payload, no) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _unnamed -> nil
    end
  end

  defp player_name(_payload, _not_a_player), do: nil

  @doc """
  One player's card.

  Their placing when the standings carry one, their name and the tournament
  when they do not - a player entered but not yet placed is the ordinary case
  before round one.
  """
  def player(payload, player) do
    name = Map.get(player, "name") || gettext("Player %{number}", number: Map.get(player, "no"))

    row = Tournament.standings_row(payload, Map.get(player, "no"))

    # A row that is not counted (C.05 6.6) has no place to describe.
    case if(Tournament.uncounted?(row), do: nil, else: row) do
      nil ->
        gettext("%{player} in %{tournament}.", player: name, tournament: Tournament.name(payload))

      row ->
        gettext("%{player} - score %{points}, place %{rank} of %{total}, %{tournament}.",
          player: name,
          points: TournamentHTML.number(row["points"]),
          rank: row["rank"],
          total: Tournament.ranked_total(payload),
          tournament: Tournament.name(payload)
        )
    end
  end

  @doc "One team's page: its roster and, when placed, its rank and match points."
  def team(payload, team) do
    label = Tournament.team_label(team)

    case Tournament.team_standings_row(payload, Map.get(team, "no")) do
      nil ->
        gettext("%{team} in %{tournament}.", team: label, tournament: Tournament.name(payload))

      row ->
        gettext("%{team} - %{mp} match points, place %{rank} of %{total}, %{tournament}.",
          team: label,
          mp: TournamentHTML.number(row["mp"]),
          rank: row["rank"],
          total: length(Tournament.team_standings_rows(payload)),
          tournament: Tournament.name(payload)
        )
    end
  end

  @doc "The team list: every team of the event with its roster."
  def teams(payload) do
    gettext("The teams of %{tournament}, their places and their players.",
      tournament: Tournament.name(payload)
    )
    |> with_where(payload)
  end

  @doc "The board prizes page."
  def board_prizes(payload) do
    gettext("Board prizes for %{tournament}, each board's players and their results.",
      tournament: Tournament.name(payload)
    )
    |> with_where(payload)
  end

  @doc "A page the arbiter has switched off. Says the tournament exists, and no more."
  def withheld(payload) do
    gettext("%{tournament} on OpenResults.", tournament: Tournament.name(payload))
  end

  @doc """
  The cross-tournament player history page, by FIDE id.

  Says how many tournaments are listed and nothing about who the player is -
  see `OpenResultsWeb.PlayerHistory` for why a name is never a safe thing to
  assert from a FIDE id alone.
  """
  def player_history(fide_id, entries) do
    ngettext(
      "%{count} published tournament carries FIDE %{id}.",
      "%{count} published tournaments carry FIDE %{id}.",
      length(entries),
      id: fide_id
    )
  end

  @doc "The entry form."
  def register(payload) do
    gettext(
      "Send your details to the organisers of %{tournament}. They decide who plays; this form only carries the message.",
      tournament: Tournament.name(payload)
    )
  end

  @doc "The page after an entry has been queued."
  def received(payload) do
    gettext("Your entry for %{tournament} is with the organisers.",
      tournament: Tournament.name(payload)
    )
  end

  @doc "Entries shut."
  def entries_closed, do: gettext("This tournament is no longer taking entries here.")

  @doc "The rate limiter's page."
  def too_many, do: gettext("Too many entries have arrived from this connection.")

  @doc "The page for a tournament whose queue is full."
  def queue_full,
    do: gettext("This form is holding as many entries as it can and is not taking more just now.")

  @doc "Anything that is not here."
  def not_found, do: gettext("This page is not published here.")

  @doc "The changelog."
  def changelog, do: gettext("What has changed on this site, release by release.")

  @doc "The terms and privacy page."
  def terms,
    do:
      gettext(
        "Who runs this site, what may be published on it, how to have something removed, and what it keeps about you."
      )

  # City and dates, each behind the arbiter's own tick, appended to a
  # sentence that is already complete without them. Empty is the ordinary
  # answer for a club event and for any tournament whose arbiter said no.
  defp with_where(sentence, payload) do
    info = Tournament.info(payload)

    [
      Tournament.show?(payload, "city") && info["city"],
      Tournament.show?(payload, "dates") && TournamentHTML.dates(info)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> sentence
      parts -> sentence <> " " <> Enum.join(parts, ", ") <> "."
    end
  end
end
