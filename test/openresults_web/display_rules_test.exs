defmodule OpenResultsWeb.DisplayRulesTest do
  @moduledoc """
  What the arbiter allows this site to show.

  Two rules carry the whole feature, and both are about the direction things
  fail in:

    * **absent means shown** - a payload from before the field existed, or a
      key one side knows and the other does not, renders as it always did;
    * **hiding a column is not hiding the data** - the page stops printing
      it, and that is all it claims to do.

  The second rule is why `player_cards` is enforced in the controller rather
  than only in the markup. A link is a courtesy; a bookmarked URL is not.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp hiding(keys) do
    display = Map.new(keys, &{&1, false})
    put_in(SnapshotPayloads.swiss(), ["tournament", "display"], display)
  end

  # "The page still works" needs more than the word "Standings" appearing
  # somewhere in the response - that string is also in the masthead's own
  # nav link, and in the withheld-standings 404 page's own explanation. Only
  # a correctly rendered table has one row per player.
  defp standings_row_count(html) do
    # Direct children only - each tiebreak cell can carry its own nested
    # `table.working-table` breakdown (see `tiebreak_cell/1`), so a bare
    # descendant selector counts those rows too.
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("table.standings > tbody > tr")
    |> Enum.count()
  end

  describe "withholding the standings" do
    # The tick's own hint in OpenPairings says what it is for: "some arbiters
    # withhold standings until the last round is in". That is a decision about
    # who may know the placings yet, not about which pages exist - so a
    # surface that leaks the placings back defeats it whether or not the
    # standings PAGE is gone.
    #
    # The player card carried each opponent's running total, straight out of
    # `standings.rows`. Twelve cards is twelve rows of the table the arbiter
    # is withholding, assembled by anybody willing to click twelve times.
    test "takes the opponents' totals off the player cards too" do
      slug = publish(hiding(["standings"]))

      html = build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      # The column's title attribute, not its label: the label sits on its
      # own line in the template, so whitespace makes ">Pts<" a brittle way
      # to ask the question.
      refute html =~ "Opponent&#39;s total"
    end

    test "and the cards still work - this hides a column, not the page" do
      # The other half of the rule this file exists for. Hiding the totals
      # must not take the card, the opponents or the results with it.
      slug = publish(hiding(["standings"]))

      html = build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      assert html =~ "Opponent"
      assert html =~ "Result"
      assert html =~ "Rd"
    end

    test "showing the standings shows the totals, as it always did" do
      # The control. A gate that hid the column unconditionally would pass
      # both tests above.
      slug = publish(SnapshotPayloads.swiss())

      html = build_conn() |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      assert html =~ "Opponent&#39;s total"
    end
  end

  describe "absent means shown" do
    test "a payload with no display map shows everything" do
      payload = update_in(SnapshotPayloads.swiss(), ["tournament"], &Map.delete(&1, "display"))

      for key <- ~w(rating title federation club category tiebreaks player_cards) do
        assert Tournament.show?(payload, key)
      end
    end

    test "a key the map does not mention is shown" do
      # The case that matters when a key is added later: every snapshot
      # already published is silent about it, and a new column must not
      # arrive switched off across the whole site.
      payload = put_in(SnapshotPayloads.swiss(), ["tournament", "display"], %{"club" => false})

      assert Tournament.show?(payload, "added_in_2027")
      assert Tournament.show?(payload, "rating")
      refute Tournament.show?(payload, "club")
    end

    test "junk where the map should be does not blank the page" do
      for junk <- ["nope", 42, [], nil] do
        payload = put_in(SnapshotPayloads.swiss(), ["tournament", "display"], junk)
        assert Tournament.show?(payload, "rating")
      end
    end
  end

  describe "the federation listing" do
    test "a listed tournament appears", %{conn: conn} do
      _slug = publish(SnapshotPayloads.swiss())

      assert conn |> get(~p"/f/BEL") |> html_response(200) =~ "Gent Spring Open 2026"
    end

    test "an unlisted one does not, but its own page still works", %{conn: conn} do
      payload = put_in(SnapshotPayloads.swiss(), ["tournament", "listed"], false)
      slug = publish(payload)

      refute conn |> get(~p"/f/BEL") |> html_response(200) =~ "Gent Spring Open 2026"

      # Unlisting is not taking down, and the settings page that offers it
      # says so in as many words: the address still works for anyone holding
      # it. This hides an event from somebody browsing, not from somebody
      # who was sent the link.
      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "Gent Spring Open 2026"
    end

    test "absent means listed, for payloads that predate the field", %{conn: conn} do
      payload = update_in(SnapshotPayloads.swiss(), ["tournament"], &Map.delete(&1, "listed"))
      _slug = publish(payload)

      assert conn |> get(~p"/f/BEL") |> html_response(200) =~ "Gent Spring Open 2026"
    end

    test "honours the city and dates ticks, like every other page", %{conn: conn} do
      _slug = publish(hiding(["city", "dates"]))

      html = conn |> get(~p"/f/BEL") |> html_response(200)

      # This list printed both regardless. An arbiter who unticked them saw
      # them gone from their tournament's own pages and still here, on the
      # page everybody arrives at - which is the one place a display rule
      # being half-applied is most visible and least explicable.
      refute html =~ "Ghent"
      refute html =~ "2026-03-01"

      # And the entry itself is still an entry.
      assert html =~ "Gent Spring Open 2026"
    end

    test "still shows them when nothing is hidden", %{conn: conn} do
      # The control. The list is mostly clubs with a city and a weekend, and
      # a fix that dropped those details for everybody would be a worse page
      # than the one with the bug.
      _slug = publish(SnapshotPayloads.swiss())

      html = conn |> get(~p"/f/BEL") |> html_response(200)

      assert html =~ "Ghent"
      assert html =~ "2026-03-01"
    end
  end

  describe "ratings" do
    test "are shown by default on standings and pairings", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "Rating"
      assert conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ "Elo"
    end

    test "disappear from every table when turned off", %{conn: conn} do
      slug = publish(hiding(["rating"]))

      standings = conn |> get(~p"/t/#{slug}") |> html_response(200)
      round = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)
      card = conn |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      refute standings =~ "2601"
      refute round =~ "2601"
      refute card =~ "2033"

      # The tournament is still perfectly readable - this hides a column, not
      # the event. A bare `=~ "Standings"` is satisfied by the masthead's own
      # nav link even on a page that rendered no rows at all - check the
      # actual table instead.
      assert standings_row_count(standings) == 10
      assert round =~ "Round 1"
    end
  end

  describe "clubs, federations, titles and categories" do
    test "each disappears on its own without taking the others", %{conn: conn} do
      slug = publish(hiding(["club"]))
      html = conn |> get(~p"/t/#{slug}/player/1") |> html_response(200)

      refute html =~ "SF Berlin"

      # Still there: unticking one box must not quietly clear the row. Bare
      # `=~ "GER"` / `=~ "GM"` are satisfiable by unrelated text anywhere on
      # the page - scope each to the element that actually carries it: the
      # title beside the player's name, and the federation in the details
      # line (the same paragraph that would have carried the now-hidden
      # club).
      doc = LazyHTML.from_document(html)

      [title] = doc |> LazyHTML.query("#player-summary h2 span.title") |> Enum.to_list()
      assert LazyHTML.text(title) =~ "GM"

      [details] = doc |> LazyHTML.query("#player-summary p.details") |> Enum.to_list()
      details_text = LazyHTML.text(details)
      assert details_text =~ "GER"
      refute details_text =~ "SF Berlin"
    end

    test "federations go from the masthead as well as the card", %{conn: conn} do
      slug = publish(hiding(["federation"]))

      # The masthead prints the tournament's own federation, which is the
      # same field by a different route and would otherwise survive.
      refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ ">BEL<"
    end

    test "titles go from beside every name", %{conn: conn} do
      slug = publish(hiding(["title"]))

      refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ ">GM<"
      refute conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ ">GM<"
    end

    test "categories go from the player page", %{conn: conn} do
      slug = publish(hiding(["category"]))

      refute conn |> get(~p"/t/#{slug}/player/1") |> html_response(200) =~ "Category A"
    end
  end

  describe "tiebreak columns" do
    test "hiding them leaves the placings exactly as the arbiter computed them", %{conn: conn} do
      open = publish(SnapshotPayloads.swiss())
      open_html = conn |> get(~p"/t/#{open}") |> html_response(200)

      hidden = publish(hiding(["tiebreaks"]))
      hidden_html = conn |> get(~p"/t/#{hidden}") |> html_response(200)

      assert open_html =~ "Buchholz"
      refute hidden_html =~ "Buchholz"

      # The arbiter is hiding the arithmetic, not the result. Same order,
      # same points, same names - and, unlike a bare `=~ "Standings"`, a
      # full table of rows to prove it.
      assert standings_row_count(hidden_html) == 10

      for row <- Tournament.standings_rows(SnapshotPayloads.swiss()) do
        name = Tournament.players_by_no(SnapshotPayloads.swiss())[row["player"]]["name"]
        assert hidden_html =~ name
      end
    end
  end

  describe "whole pages" do
    test "standings can be withheld while the rounds stay", %{conn: conn} do
      slug = publish(hiding(["standings"]))

      # Some arbiters hold the league table back until the last round is in.
      html = conn |> get(~p"/t/#{slug}") |> html_response(404)
      assert html =~ "does not publish standings"

      # The rounds are untouched, and reachable.
      assert conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ "Round 1"
    end

    test "round pairings can be withheld while the standings stay", %{conn: conn} do
      slug = publish(hiding(["pairings"]))

      assert conn |> get(~p"/t/#{slug}/round/1") |> html_response(404) =~
               "does not publish round pairings"

      standings = conn |> get(~p"/t/#{slug}") |> html_response(200)
      assert standings_row_count(standings) == 10

      # And the round strip stops offering rounds nobody can open.
      refute standings =~ ~s|href="/t/#{slug}/round/1"|
    end

    test "the round strip disappears entirely when both pages are off", %{conn: conn} do
      slug = publish(hiding(["standings", "pairings"]))

      # A navigation strip with nothing to navigate to is furniture.
      html = conn |> get(~p"/t/#{slug}/player/1") |> html_response(200)
      refute html =~ ~s|aria-label="Rounds"|
    end

    test "byes can be hidden without hiding the boards", %{conn: conn} do
      # Round 2, because the fixture's round 1 has no byes: asked of round 1,
      # and refuting the CSS selector "table.byes" rather than the markup, this
      # held whether or not the tick did anything.
      slug = publish(SnapshotPayloads.swiss())
      assert conn |> get(~p"/t/#{slug}/round/2") |> html_response(200) =~ ~s(<table class="byes">)

      slug = publish(hiding(["byes"]))
      html = conn |> get(~p"/t/#{slug}/round/2") |> html_response(200)

      refute html =~ ~s(<table class="byes">)
      assert html =~ ~s(<table id="pairings" class="pairings">)
    end

    test "a withheld page says so rather than claiming not to exist", %{conn: conn} do
      slug = publish(hiding(["standings"]))
      html = conn |> get(~p"/t/#{slug}") |> html_response(404)

      # The tournament IS there. Telling somebody it is not sends them hunting
      # for a link that was never broken.
      assert html =~ "Gent Spring Open 2026"
      assert html =~ ~s|href="/t/#{slug}"|
    end
  end

  describe "the tournament's own details" do
    test "each can be hidden on its own", %{conn: conn} do
      slug = publish(hiding(["city", "arbiter"]))
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      refute html =~ "Ghent"
      refute html =~ "Jorian Burssens"

      # Unticking two must not clear the line.
      assert html =~ "2026-03-01"
    end

    test "dates, tempo and the FIDE badge too", %{conn: conn} do
      slug = publish(hiding(["dates", "fide_badge"]))
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      refute html =~ "2026-03-01 to 2026-03-05"
      refute html =~ "FIDE rated"
      assert html =~ "Ghent"
    end

    test "the dates tick covers a round's own date, on the page and the screen",
         %{conn: conn} do
      slug = publish(hiding(["dates"]))

      round = conn |> get(~p"/t/#{slug}/round/1") |> html_response(200)
      projector = conn |> get(~p"/t/#{slug}/round/1?display=1") |> html_response(200)

      # The masthead honoured the tick and the heading right underneath it
      # did not, so hiding the dates hid them from one line and left them on
      # the next. The arbiter's own settings page promises this covers "the
      # tournament's own dates, and each round's".
      refute round =~ "2026-03-01"
      refute projector =~ "2026-03-01"

      # Neither page loses anything else.
      assert round =~ "Round 1"
      assert projector =~ "Round 1"
    end

    test "and shows a round's date when the tick is on", %{conn: conn} do
      # The control: a round page's date is the commonest thing on it after
      # the boards, and it has to survive the fix.
      slug = publish(SnapshotPayloads.swiss())

      assert conn |> get(~p"/t/#{slug}/round/1") |> html_response(200) =~ "2026-03-01"
      assert conn |> get(~p"/t/#{slug}/round/1?display=1") |> html_response(200) =~ "2026-03-01"
    end
  end

  describe "columns inside a page" do
    test "the running scores on the pairings are their own tick", %{conn: conn} do
      open = publish(SnapshotPayloads.swiss())
      assert conn |> get(~p"/t/#{open}/round/1") |> html_response(200) =~ "Points going into"

      hidden = publish(hiding(["pairing_scores"]))
      html = conn |> get(~p"/t/#{hidden}/round/1") |> html_response(200)

      refute html =~ "Points going into"
      # The boards themselves are untouched.
      assert html =~ "1-0"
    end
  end

  describe "player cards" do
    test "the link is not offered when they are off", %{conn: conn} do
      slug = publish(hiding(["player_cards"]))

      refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "/player/1"
    end

    test "and the page itself refuses, not just the link", %{conn: conn} do
      slug = publish(hiding(["player_cards"]))

      # A link is a courtesy. A bookmarked or guessed URL is not, and the
      # markup gate alone would leave the page serving to anyone who typed it.
      assert conn |> get(~p"/t/#{slug}/player/1") |> html_response(404) =~
               "does not publish player cards"
    end

    test "names still render, just without links", %{conn: conn} do
      slug = publish(hiding(["player_cards"]))
      html = conn |> get(~p"/t/#{slug}") |> html_response(200)

      # Turning cards off must not turn the standings into a list of numbers.
      assert html =~ "Müller, Jörg"
    end
  end
end
