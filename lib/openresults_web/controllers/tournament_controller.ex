defmodule OpenResultsWeb.TournamentController do
  @moduledoc """
  The public pages: standings, the cross-table, one round, one player.

  Each action does the same three things - fetch the current snapshot, refuse
  what is not in it, hand the payload to a template. There is no query beyond
  `Snapshots.latest/1`, because everything a page shows was decided on the
  arbiter's machine and travelled whole.

  A 404 here is a real answer, not a failure. An unpublished round is absent
  from the payload, so `/round/4` on a tournament whose arbiter has published
  rounds 1-3 and 5 has nothing to render, and saying "not published" is more
  honest than an empty table that looks like a round nobody turned up to.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.Snapshots
  alias OpenResults.Tournaments
  alias OpenResultsWeb.FilterParams
  alias OpenResultsWeb.Meta
  alias OpenResultsWeb.Tournament

  @doc """
  `GET /` - the tournaments that have published, grouped by where each one
  sits in its own life cycle.

  Grouping and search both happen from this one list - see
  `Tournament.status/1` for how a snapshot becomes `:live`, `:upcoming` or
  `:finished`, and `tournament_html/index.html.heex` for the search box,
  which is client-side for the same reason `standings_table/1`'s sort and
  filter are: the server renders one page regardless of what a reader later
  types into it.
  """
  def index(conn, params) do
    # Filtered here rather than in `Snapshots.list_current/0`: which
    # tournaments exist is a storage question and which ones are advertised is
    # a presentation one. A storage function that silently omits rows is a
    # trap for the next caller - a takedown sweep or an admin view would
    # quietly skip every unlisted tournament and give no reason.
    #
    # Two filters, with two different owners: `listed?` is the ARBITER'S
    # choice, carried in the payload, and `visible_only` is MODERATION'S - a
    # hidden tournament is not there at all. A pending one is: since the admin
    # upgrade (2026-09-13) pending keeps a tournament off the cross-tournament
    # player pages and nowhere else. See `OpenResults.Tournaments`.
    #
    # Rendered on every request, never cached, so a tournament appears here
    # the moment it publishes and stays through approval with no invalidation.
    listed =
      Enum.filter(Snapshots.list_current(visible_only: true), &Tournament.listed?(&1.payload))

    # The archive: a tournament's year is its start date's, and only where
    # the arbiter shows dates at all - a tournament with the dates tick off
    # is under "all years" and no year, rather than filed by a date the page
    # itself would not print. Plain links, no script: `?year=` is the whole
    # state, so a filtered front page is a URL somebody can pass on.
    years =
      listed
      |> Enum.map(&year(&1.payload))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort(:desc)

    year = if params["year"] in years, do: params["year"]
    shown = if year, do: Enum.filter(listed, &(year(&1.payload) == year)), else: listed

    grouped = Enum.group_by(shown, &Tournament.status(&1.payload))

    # The tournaments that are sections of one event stand together under
    # its name - see `OpenResultsWeb.EventGroup`. Decided over the whole page,
    # so an event with one section finished and one running is named in both
    # parts.
    memberships = OpenResultsWeb.EventGroup.memberships(shown)

    render(conn, :index,
      page_title: gettext("Tournaments"),
      page_description: Meta.index(),
      snapshots: shown,
      # Only worth offering once there is more than one year to choose from.
      years: if(length(years) > 1, do: years, else: []),
      year: year,
      # Live first (the most immediately relevant), then upcoming, then
      # finished - and in that fixed order regardless of how many of each
      # there are, so the page's shape does not shuffle between visits.
      groups:
        for kind <- [:live, :upcoming, :finished] do
          {kind, OpenResultsWeb.EventGroup.gather(Map.get(grouped, kind, []), memberships)}
        end
    )
  end

  defp year(payload) do
    with true <- Tournament.show?(payload, "dates"),
         <<year::binary-size(4), "-", _rest::binary>> <- Tournament.info(payload)["start_date"],
         {_number, ""} <- Integer.parse(year) do
      year
    else
      _no_year -> nil
    end
  end

  @doc """
  `GET /t/:slug` - the standings, exactly as the arbiter computed them.
  """
  def standings(conn, %{"slug" => slug} = params) do
    with_payload(conn, slug, fn conn, payload ->
      if Tournament.show?(payload, "standings") do
        render_standings(conn, payload, slug, FilterParams.parse(params))
      else
        withheld(conn, payload, slug, :standings)
      end
    end)
  end

  defp render_standings(conn, payload, slug, filters) do
    render(conn, :standings,
      page_title: Tournament.name(payload),
      page_description: Meta.standings(payload),
      payload: payload,
      slug: slug,
      current: :standings,
      filters: filters
    )
  end

  @doc """
  `GET /t/:slug/crosstable` - every published result as one grid.

  Refused with the pairings message rather than one of its own, and that is
  the honest wording: what is withheld here is the boards, whichever of the
  two ticks did it. See `Tournament.crosstable?/1`.
  """
  def crosstable(conn, %{"slug" => slug} = params) do
    with_payload(conn, slug, fn conn, payload ->
      if Tournament.crosstable?(payload) do
        render_crosstable(conn, payload, slug, FilterParams.parse(params))
      else
        withheld(conn, payload, slug, :pairings)
      end
    end)
  end

  defp render_crosstable(conn, payload, slug, filters) do
    render(conn, :crosstable,
      page_title: "#{Tournament.name(payload)} - #{gettext("Cross-table")}",
      page_description: Meta.crosstable(payload),
      payload: payload,
      slug: slug,
      current: :crosstable,
      filters: filters
    )
  end

  @doc """
  `GET /t/:slug/round/:n` - one round's pairings and byes.

  `?display=1` reaches the projector view of the same round rather than a
  route of its own: it is the same document and the same 404s, read from
  across a hall instead of a desk. See `TournamentHTML.projector_round/1` for
  what that renders.
  """
  def round(conn, %{"slug" => slug, "n" => n} = params) do
    with_payload(conn, slug, fn conn, payload ->
      if Tournament.show?(payload, "pairings") do
        render_round(conn, payload, slug, n, display?(params), FilterParams.parse(params))
      else
        withheld(conn, payload, slug, :pairings)
      end
    end)
  end

  defp render_round(conn, payload, slug, n, display?, filters) do
    number = integer(n)

    case number && Tournament.round(payload, number) do
      nil ->
        not_found(
          conn,
          gettext("Round %{number} of %{tournament} has not been published.",
            number: n,
            tournament: Tournament.name(payload)
          ),
          back: ~p"/t/#{slug}"
        )

      round ->
        render(conn, :round,
          page_title:
            "#{Tournament.name(payload)} - #{Tournament.round_heading(payload, number)}",
          page_description: Meta.round_page(payload, number),
          payload: payload,
          slug: slug,
          round: round,
          players: Tournament.players_by_no(payload),
          current: {:round, number},
          display?: display?,
          filters: filters
        )
    end
  end

  @doc """
  `GET /t/:slug/team/:no` - one team's roster, in board order, and its match
  history.

  Behind the same `"standings"` switch a player's own card is behind (see
  `player/2` below): a team's roster and match record is exactly the kind of
  standings-derived thing that switch already withholds.
  """
  def team(conn, %{"slug" => slug, "no" => no}) do
    with_payload(conn, slug, fn conn, payload ->
      if Tournament.show?(payload, "standings") do
        render_team(conn, payload, slug, no, integer(no))
      else
        withheld(conn, payload, slug, :standings)
      end
    end)
  end

  defp render_team(conn, payload, slug, no, number) do
    case number && Tournament.team(payload, number) do
      nil ->
        not_found(
          conn,
          gettext("%{tournament} has no team %{number}.",
            tournament: Tournament.name(payload),
            number: no
          ),
          back: ~p"/t/#{slug}"
        )

      team ->
        render(conn, :team,
          page_title: "#{Tournament.team_label(team)} - #{Tournament.name(payload)}",
          page_description: Meta.team(payload, team),
          payload: payload,
          slug: slug,
          team: team,
          current: {:team, number}
        )
    end
  end

  @doc """
  `GET /t/:slug/teams` - every team with its place, its match and game
  points and its roster, and the teams-by-board grid.

  Behind the `"standings"` switch, same reasoning as `team/2` above: a list
  of the teams is the team standings by another name. An individual
  tournament has no teams, and answers as an unknown page rather than an
  empty list.
  """
  def teams(conn, %{"slug" => slug}) do
    with_payload(conn, slug, fn conn, payload ->
      cond do
        not Tournament.show?(payload, "standings") ->
          withheld(conn, payload, slug, :standings)

        not Tournament.team_event?(payload) ->
          not_found(
            conn,
            gettext("%{tournament} is not a team tournament.",
              tournament: Tournament.name(payload)
            ),
            back: ~p"/t/#{slug}"
          )

        true ->
          render(conn, :teams,
            page_title: "#{gettext("Teams")} - #{Tournament.name(payload)}",
            page_description: Meta.teams(payload),
            payload: payload,
            slug: slug,
            current: :teams
          )
      end
    end)
  end

  @doc """
  `GET /t/:slug/board-prizes` - `board_stats`, one table per board.

  Behind the `"standings"` switch, same reasoning as `team/2` above.
  """
  def board_prizes(conn, %{"slug" => slug}) do
    with_payload(conn, slug, fn conn, payload ->
      if Tournament.show?(payload, "standings") do
        render(conn, :board_prizes,
          page_title: "#{gettext("Board prizes")} - #{Tournament.name(payload)}",
          page_description: Meta.board_prizes(payload),
          payload: payload,
          slug: slug,
          current: :board_prizes
        )
      else
        withheld(conn, payload, slug, :standings)
      end
    end)
  end

  # Anything else - unset, "0", a stray value - is the ordinary page. Being
  # picky here rather than truthy-checking any presence at all means a URL
  # copied with `?display=` left blank, or a future `?display=list`, does not
  # silently land somebody on the projector view.
  defp display?(params), do: params["display"] in ["1", "true"]

  @doc """
  `GET /t/:slug/player/:no` - one player's card.

  `:no` is the tournament pairing number, the TRF start number. It is the only
  handle the document offers, and it means nothing outside this event, which
  is the point.
  """
  def player(conn, %{"slug" => slug, "no" => no}) do
    with_payload(conn, slug, fn conn, payload ->
      # Links to a page the arbiter has switched off are not rendered, but a
      # link is a courtesy and a bookmarked or guessed URL is not. This is the
      # enforcement, and it is why every page in the `:pages` group is checked
      # in the controller rather than only in the markup.
      if Tournament.show?(payload, "player_cards") do
        render_player(conn, payload, slug, no, integer(no))
      else
        withheld(conn, payload, slug, :player_cards)
      end
    end)
  end

  @doc """
  `GET /t/:slug/player/:no/board` - wherever this player sits now.

  A link a player can bookmark, or an arbiter can print beside a name, that
  keeps working all tournament: it redirects to the latest published round,
  scrolled to the player's board. Nothing is worked out - the latest round is
  the highest-numbered one in the payload, and the board is the one that
  names this player. A player not on a board that round (a bye, a late entry)
  still lands on the round, where the byes table says why.

  Behind the pairings switch, because it is a way into the pairings. Not in
  the revalidated scope: a redirect is not a document and its answer moves
  with every round.
  """
  def board(conn, %{"slug" => slug, "no" => no}) do
    with_payload(conn, slug, fn conn, payload ->
      number = integer(no)

      cond do
        not Tournament.show?(payload, "pairings") ->
          withheld(conn, payload, slug, :pairings)

        is_nil(number) or is_nil(Tournament.player(payload, number)) ->
          not_found(
            conn,
            gettext("%{tournament} has no player %{number}.",
              tournament: Tournament.name(payload),
              number: no
            ),
            back: ~p"/t/#{slug}"
          )

        true ->
          conn
          |> put_resp_header("cache-control", "private, no-cache")
          |> redirect(to: current_board_path(payload, slug, number))
      end
    end)
  end

  defp current_board_path(payload, slug, number) do
    case List.last(Tournament.rounds(payload)) do
      %{"number" => n} = round when is_integer(n) ->
        case Enum.find(Tournament.boards(round), &(number in [&1["white"], &1["black"]])) do
          %{"board" => board} when is_integer(board) ->
            ~p"/t/#{slug}/round/#{n}" <> "#board-#{board}"

          _not_on_a_board ->
            ~p"/t/#{slug}/round/#{n}"
        end

      _no_rounds_yet ->
        ~p"/t/#{slug}"
    end
  end

  # Not a 404: the tournament is right there, and telling somebody it does not
  # exist sends them hunting for a link that was never broken. The arbiter has
  # chosen not to publish this part of it, which is a different thing and worth
  # saying.
  defp withheld(conn, payload, slug, page) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OpenResultsWeb.TournamentHTML)
    |> render(:not_found,
      page_title: Tournament.name(payload),
      page_description: Meta.withheld(payload),
      message: withheld_message(page, Tournament.name(payload)),
      back: ~p"/t/#{slug}"
    )
  end

  # Three whole sentences rather than one sentence and a noun slot. The noun
  # is what moves: Dutch puts the negation after it and French needs an
  # article that changes with the word, so a translator handed "standings" on
  # its own could not produce a correct sentence in either language.
  defp withheld_message(:standings, name),
    do: gettext("%{tournament} does not publish standings.", tournament: name)

  defp withheld_message(:pairings, name),
    do: gettext("%{tournament} does not publish round pairings.", tournament: name)

  defp withheld_message(:player_cards, name),
    do: gettext("%{tournament} does not publish player cards.", tournament: name)

  defp render_player(conn, payload, slug, no, number) do
    case number && Tournament.player(payload, number) do
      nil ->
        not_found(
          conn,
          gettext("%{tournament} has no player %{number}.",
            tournament: Tournament.name(payload),
            number: no
          ),
          back: ~p"/t/#{slug}"
        )

      player ->
        render(conn, :player,
          page_title: "#{Map.get(player, "name")} - #{Tournament.name(payload)}",
          page_description: Meta.player(payload, player),
          payload: payload,
          slug: slug,
          player: player,
          card: Tournament.card(payload, number),
          # The follow switch pins rows on the standings and the pairings, so
          # it is offered only where the player cards and one of those exist.
          follow?:
            Tournament.show?(payload, "player_cards") and
              (Tournament.show?(payload, "standings") or Tournament.show?(payload, "pairings")),
          current: {:player, number}
        )
    end
  end

  # `public_latest/1` rather than `Snapshots.latest/1`: a hidden tournament
  # gets this same 404, word for word, as a slug that never published.
  #
  # The report link goes on here and only here - on a page of a tournament the
  # public can see, withheld pages included - so a 404 for an unknown slug
  # cannot carry one and differ from a hidden one's by it.
  defp with_payload(conn, slug, render_fun) do
    case Tournaments.public_latest(slug) do
      nil ->
        not_found(conn, gettext("No tournament has published under %{slug}.", slug: slug),
          back: ~p"/"
        )

      snapshot ->
        conn
        |> assign(:report_path, ~p"/t/#{slug}/report")
        |> assign(:feed_path, ~p"/t/#{slug}/feed.xml")
        |> render_fun.(snapshot.payload)
    end
  end

  defp not_found(conn, message, back: back) do
    conn
    |> put_status(:not_found)
    |> render(:not_found,
      page_title: gettext("Not found"),
      page_description: Meta.not_found(),
      message: message,
      back: back
    )
  end

  # A pairing number or a round number, or `nil` for anything else. Whole
  # string only: `"3x"` is not round 3, and `String.to_integer/1` would raise
  # on it where a 404 is the right answer.
  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end
end
