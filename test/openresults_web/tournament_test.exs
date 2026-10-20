defmodule OpenResultsWeb.TournamentTest do
  use ExUnit.Case, async: true

  alias OpenResults.SnapshotPayloads
  alias OpenResultsWeb.Tournament

  setup do
    {:ok, swiss: SnapshotPayloads.swiss(), keizer: SnapshotPayloads.keizer()}
  end

  # The fixture's own `after_round` is 2. Several player-card tests below are
  # about `card_entry/4`'s own logic - colour, a bye's value, a withheld
  # board, a gap where a round was never published - which round 1 and round
  # 2 alone do not exercise fully, so those tests read the card through the
  # LAST published round instead. The gate itself, using the fixture exactly
  # as it arrived, has a describe block of its own below.
  defp through_last_round(payload) do
    last = payload["rounds"] |> Enum.map(& &1["number"]) |> Enum.max()
    put_in(payload, ["standings", "after_round"], last)
  end

  describe "result tokens" do
    test "every token the contract lists is read, and none other" do
      # The table in docs/snapshot-schema.md, copied out by hand so a token
      # quietly dropped from the module shows up here rather than as a player
      # card whose score stops for no visible reason.
      assert Tournament.result_points("1-0") == {1.0, 0.0}
      assert Tournament.result_points("0-1") == {0.0, 1.0}
      assert Tournament.result_points("1/2-1/2") == {0.5, 0.5}
      assert Tournament.result_points("1-0U") == {1.0, 0.0}
      assert Tournament.result_points("0-1U") == {0.0, 1.0}
      assert Tournament.result_points("1/2-1/2U") == {0.5, 0.5}
      assert Tournament.result_points("1/2-0") == {0.5, 0.0}
      assert Tournament.result_points("0-1/2") == {0.0, 0.5}
      assert Tournament.result_points("0-0") == {0.0, 0.0}
      assert Tournament.result_points("1-0FF") == {1.0, 0.0}
      assert Tournament.result_points("0-1FF") == {0.0, 1.0}
      assert Tournament.result_points("0-0FF") == {0.0, 0.0}
    end

    test "the legacy spellings are not accepted, because the publish path normalises them" do
      assert Tournament.result_points("+--") == nil
      assert Tournament.result_points("--+") == nil
    end

    test "an unreported game has no points" do
      assert Tournament.result_points(nil) == nil
    end

    test "forfeits and unrated games are annotated, ordinary ones are not" do
      assert Tournament.result_parts("1-0") == {"1-0", nil}
      assert Tournament.result_parts("1/2-1/2") == {"1/2-1/2", nil}
      assert Tournament.result_parts("1-0FF") == {"1-0", "forfeit"}
      assert Tournament.result_parts("0-0FF") == {"0-0", "forfeit"}
      assert Tournament.result_parts("0-1U") == {"0-1", "unrated"}
      assert Tournament.result_parts("1/2-1/2U") == {"1/2-1/2", "unrated"}
    end

    test "a token from a newer client survives verbatim rather than being guessed at" do
      assert Tournament.result_parts("1-0ADJ") == {"1-0ADJ", nil}
      assert Tournament.result_parts("2-0") == {"2-0", nil}
    end
  end

  describe "rounds" do
    test "only published rounds are present", %{swiss: swiss} do
      assert Tournament.round_numbers(swiss) == [1, 2, 3, 5]
      assert Tournament.round(swiss, 4) == nil
      assert Tournament.round(swiss, 3)["number"] == 3
    end

    test "the round strip covers the withheld round too", %{swiss: swiss} do
      assert Tournament.round_slots(swiss) == [1, 2, 3, 4, 5]
    end

    test "a round beyond the declared count still gets a slot", %{keizer: keizer} do
      extra = update_in(keizer, ["rounds"], &(&1 ++ [%{"number" => 9, "boards" => []}]))

      assert Tournament.rounds_count(extra) == 3
      assert Tournament.round_slots(extra) == [1, 2, 3, 9]
    end
  end

  describe "standings" do
    test "rows come back in the order they arrived", %{swiss: swiss} do
      shuffled = update_in(swiss, ["standings", "rows"], &Enum.reverse/1)

      assert Enum.map(Tournament.standings_rows(shuffled), & &1["rank"]) ==
               [10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
    end

    test "tiebreak columns are whatever the payload declared", %{swiss: swiss} do
      assert Enum.map(Tournament.tiebreaks(swiss), &Tournament.tiebreak_label/1) ==
               ["Buchholz Cut-1", "Buchholz", "Sonneborn-Berger", "Progressive score"]
    end

    test "a tiebreak with no label falls back to its code" do
      assert Tournament.tiebreak_label(%{"code" => "ARO"}) == "ARO"
    end

    test "a phone's short heading is the code, cut written as the regulations write it" do
      assert Tournament.tiebreak_short(%{"code" => "BHC1", "label" => "Buchholz Cut-1"}) ==
               "BH-C1"

      assert Tournament.tiebreak_short(%{"code" => "AROC1"}) == "ARO-C1"
      assert Tournament.tiebreak_short(%{"code" => "SB", "label" => "Sonneborn-Berger"}) == "SB"
      assert Tournament.tiebreak_short(%{"code" => "MBH"}) == "MBH"
      assert Tournament.tiebreak_short(%{"label" => "Wins"}) == "Wins"
    end

    test "row values are read positionally and short rows blank out", %{swiss: swiss} do
      row = hd(Tournament.standings_rows(swiss))

      assert Tournament.tiebreak_value(row, 0) == 1.0
      assert Tournament.tiebreak_value(row, 3) == 3.0
      assert Tournament.tiebreak_value(row, 4) == nil
    end

    test "after_round/1 reads the published round", %{swiss: swiss} do
      assert Tournament.after_round(swiss) == 2
    end

    test "after_round/1 is nil for 0, not the round that never existed", %{swiss: swiss} do
      # OpenPairings writes 0 for a tournament nobody has closed a round of
      # yet, not `null` - so 0 has to read the same way absence does.
      zero = put_in(swiss, ["standings", "after_round"], 0)
      absent = update_in(swiss, ["standings"], &Map.delete(&1, "after_round"))

      assert Tournament.after_round(zero) == nil
      assert Tournament.after_round(absent) == nil
    end
  end

  describe "the starting rank" do
    test "a tournament with real standings does not fall back to it", %{swiss: swiss} do
      refute Tournament.starting_rank?(swiss)
    end

    test "an after_round of 0 with players entered triggers the fallback", %{swiss: swiss} do
      before_round_one =
        swiss
        |> put_in(["standings", "after_round"], 0)
        |> put_in(["standings", "rows"], [])

      assert Tournament.starting_rank?(before_round_one)
    end

    test "a payload that has never sent standings at all also triggers it", %{swiss: swiss} do
      no_standings = Map.delete(swiss, "standings")

      assert Tournament.starting_rank?(no_standings)
    end

    test "a tournament with no players at all does not - there is nothing to rank", %{
      swiss: swiss
    } do
      empty = swiss |> Map.delete("standings") |> Map.put("players", [])

      refute Tournament.starting_rank?(empty)
    end

    test "starting_rank/1 lists every player in pairing-number order", %{swiss: swiss} do
      shuffled = update_in(swiss["players"], &Enum.shuffle/1)

      assert Enum.map(Tournament.starting_rank(shuffled), &Map.get(&1, "no")) ==
               Enum.to_list(1..10)
    end

    test "a player with no `no` is left out rather than sorted first" do
      payload = %{"players" => [%{"name" => "Nobody"}, %{"no" => 2, "name" => "Someone"}]}

      assert Enum.map(Tournament.starting_rank(payload), &Map.get(&1, "no")) == [2]
    end
  end

  describe "the player card" do
    test "colour, opponent and result come straight off the board", %{swiss: swiss} do
      [round_one | _rest] = Tournament.card(swiss, 1)

      assert round_one.kind == :game
      assert round_one.colour == :white
      assert round_one.opponent_no == 6
      assert round_one.opponent["name"] == "Ștefănescu, Ioana"
      assert round_one.result == "1-0"
    end

    test "a bye carries the arbiter's own value", %{swiss: swiss} do
      entry = Enum.at(Tournament.card(swiss, 4), 1)

      assert entry.kind == :bye
      assert entry.bye == "pairing-allocated"
      assert entry.points == 1.0
    end

    test "where the running score is knowable it agrees with the arbiter", %{swiss: swiss} do
      # Not an assertion the app makes anywhere - it never checks the arbiter.
      # It is here because a decoding table with a seat the wrong way round
      # would still look plausible on the page, and this is what catches it.
      #
      # Only the players whose every round is public are checked - which, now
      # that standings sit after round 2, is all ten: round 3's gaps (two
      # players missing the round entirely, two on the board with no result
      # yet) sit past the round these standings cover. Those gaps are still
      # exercised directly, by the two tests below and "a withheld board
      # leaves the arbiter's total the only one there is".
      after_round = swiss["standings"]["after_round"]

      checked =
        for row <- swiss["standings"]["rows"],
            entry = Enum.at(Tournament.card(swiss, row["player"]), after_round - 1),
            entry.score != nil do
          assert entry.score == row["points"],
                 "player #{row["player"]} scored #{inspect(entry.score)} after round " <>
                   "#{after_round}, standings say #{row["points"]}"

          row["player"]
        end

      assert length(checked) == 10
    end

    test "a withheld board leaves the arbiter's total the only one there is", %{swiss: swiss} do
      # Round 3 is published with three boards and two byes, which accounts
      # for eight of ten players. Players 7 and 10 played a board the arbiter
      # did not publish, so the page can show their standing but not derive
      # their total - and it says so rather than guessing.
      bumped = through_last_round(swiss)

      for no <- [7, 10] do
        entry = Enum.at(Tournament.card(bumped, no), 2)

        assert entry.kind == :no_game
        assert entry.score == nil
      end

      assert Enum.find(swiss["standings"]["rows"], &(&1["player"] == 7))["points"] == 1.0
    end

    test "the running score stops at a round the arbiter withheld", %{swiss: swiss} do
      card = Tournament.card(through_last_round(swiss), 1)

      assert Enum.map(card, & &1.score) == [1.0, 1.5, 2.5, nil, nil]
      assert Enum.at(card, 3).kind == :unpublished
      # Round 5 is published and its game is shown; only the total is unknown.
      assert Enum.at(card, 4).kind == :game
    end

    test "the running score stops at a game with no result yet", %{swiss: swiss} do
      # Board 3 of round 3 has a null result, so player 8's total is unknown
      # from there even though every round is published.
      card = Tournament.card(through_last_round(swiss), 8)

      assert Enum.at(card, 2).result == nil
      assert Enum.map(card, & &1.score) == [0.5, 0.5, nil, nil, nil]
    end

    test "a player absent from a published round is said to have no game published" do
      payload =
        SnapshotPayloads.swiss()
        |> update_in(["rounds", Access.at(0), "boards"], &Enum.drop(&1, 1))

      card = Tournament.card(payload, 1)

      assert hd(card).kind == :no_game
      assert hd(card).score == nil
    end

    test "every round up to the standings gets a row, including a gap", %{swiss: swiss} do
      assert Enum.map(Tournament.card(through_last_round(swiss), 10), & &1.round) ==
               [1, 2, 3, 4, 5]
    end
  end

  describe "the player card obeys the standings gate" do
    test "stops at the round the standings cover, even though later rounds are live", %{
      swiss: swiss
    } do
      # The fixture's own shape, unmodified: standings stop after round 2
      # while rounds 1, 2, 3 and 5 are already published. Round 5's game is
      # real and readable from its own page, but it may not reach this card.
      assert Enum.map(Tournament.card(swiss, 1), & &1.round) == [1, 2]
    end

    test "is empty before the first standings are published, even with rounds live", %{
      swiss: swiss
    } do
      before_round_one =
        swiss
        |> put_in(["standings", "after_round"], 0)
        |> put_in(["standings", "rows"], [])

      assert Tournament.card(before_round_one, 1) == []
    end

    test "within_standings?/2 is the boundary both the gate and the card read", %{swiss: swiss} do
      refute Tournament.within_standings?(swiss, 3)
      assert Tournament.within_standings?(swiss, 2)
      assert Tournament.within_standings?(swiss, 1)

      absent = update_in(swiss, ["standings"], &Map.delete(&1, "after_round"))
      refute Tournament.within_standings?(absent, 1)
    end
  end

  describe "rounds[].results_public" do
    defp flag(payload, number, value) do
      update_in(payload, ["rounds"], fn rounds ->
        Enum.map(rounds, fn
          %{"number" => ^number} = round -> Map.put(round, "results_public", value)
          round -> round
        end)
      end)
    end

    test "absent means true; only a literal false withholds", %{swiss: swiss} do
      assert Tournament.results_public?(%{"number" => 1})
      assert Tournament.results_public?(%{"number" => 1, "results_public" => true})
      assert Tournament.results_public?(%{"number" => 1, "results_public" => nil})
      refute Tournament.results_public?(%{"number" => 1, "results_public" => false})

      assert Tournament.withheld_result_rounds(swiss) == []
      assert Tournament.withheld_result_rounds(flag(swiss, 5, false)) == [5]
    end

    test "live is counting boards with a result, and a withheld round is never live", %{
      swiss: swiss
    } do
      round3 = Tournament.round(swiss, 3)

      assert Tournament.results_progress(round3) == {2, 3}
      assert Tournament.live_round?(round3)
      refute Tournament.live_round?(Tournament.round(swiss, 5))
      assert Enum.map(Tournament.live_rounds(swiss), & &1["number"]) == [3]
      assert Tournament.live?(swiss)

      refute Tournament.live_round?(Tournament.round(flag(swiss, 3, false), 3))
      refute Tournament.live?(flag(swiss, 3, false))
    end

    test "the running score into a later round stops at a withheld round, bye or no bye", %{
      swiss: swiss
    } do
      # Player 4 has a pairing-allocated bye in round 2, worth 1.0, and it
      # still travels in a withheld round - but it must not move the score.
      assert Tournament.scores_before(swiss, 3)[4] != nil
      assert Tournament.scores_before(flag(swiss, 2, false), 3)[4] == nil
      assert Tournament.scores_before(flag(swiss, 2, false), 3)[1] == nil
    end

    test "a late entrant's not-joined round counts as zero, not as a gap", %{swiss: swiss} do
      late = %{"no" => 99, "name" => "Late, Entrant"}

      add_bye = fn payload, round, row ->
        update_in(payload, ["rounds"], fn rounds ->
          Enum.map(rounds, fn r ->
            if r["number"] == round, do: Map.update(r, "byes", [row], &[row | &1]), else: r
          end)
        end)
      end

      joined_in_2 =
        swiss
        |> update_in(["players"], &(&1 ++ [late]))
        |> add_bye.(2, %{"player" => 99, "kind" => "full-point", "points" => 1.0})

      # Missing from round 1 altogether: nobody can say what that round was worth.
      assert Tournament.scores_before(joined_in_2, 3)[99] == nil

      # Published as not yet joined: worth nothing, and the total carries on.
      published =
        add_bye.(joined_in_2, 1, %{"player" => 99, "kind" => "not-joined", "points" => 0.0})

      assert Tournament.scores_before(published, 3)[99] == 1.0
      assert OpenResultsWeb.TournamentHTML.bye_kind("not-joined") == "not yet joined"
    end

    test "a not-paired round counts as zero, not as a gap", %{swiss: swiss} do
      # Player 1's round 2, replayed as "no board and no bye": the board goes
      # and a not-paired row takes its place.
      unpaired =
        update_in(swiss, ["rounds"], fn rounds ->
          Enum.map(rounds, fn
            %{"number" => 2} = round ->
              round
              |> Map.update!("boards", fn boards ->
                Enum.reject(boards, &(1 in [&1["white"], &1["black"]]))
              end)
              |> Map.update("byes", [], fn byes -> Enum.reject(byes, &(&1["player"] == 1)) end)

            round ->
              round
          end)
        end)

      # Nothing said about the round: the total cannot be carried past it.
      assert Tournament.scores_before(unpaired, 3)[1] == nil

      row = %{"player" => 1, "kind" => "not-paired", "points" => 0.0}

      published =
        update_in(unpaired, ["rounds"], fn rounds ->
          Enum.map(rounds, fn r ->
            if r["number"] == 2, do: Map.update(r, "byes", [row], &[row | &1]), else: r
          end)
        end)

      # Said: round 2 was worth nothing, and the score before round 3 is
      # what it was before round 2.
      assert Tournament.scores_before(published, 3)[1] == Tournament.scores_before(swiss, 2)[1]
      assert Tournament.scores_before(published, 3)[1] != nil
      assert OpenResultsWeb.TournamentHTML.bye_kind("not-paired") == "not paired"
    end

    test "a player's card stops at a withheld round inside the standings", %{swiss: swiss} do
      payload = swiss |> through_last_round() |> flag(3, false)

      assert Enum.map(Tournament.card(payload, 1), & &1.round) == [1, 2]
    end

    test "the cross-table has no column for a withheld round", %{swiss: swiss} do
      payload = swiss |> through_last_round() |> flag(3, false)

      assert Tournament.crosstable_rounds(payload) == [1, 2, 5]
      assert payload |> Tournament.crosstable() |> hd() |> Map.fetch!(:cells) |> length() == 3
    end

    test "every round published is not finished while one round's results are withheld", %{
      swiss: swiss
    } do
      payload =
        update_in(
          swiss,
          ["tournament"],
          &Map.merge(&1, %{"rounds_count" => 3, "end_date" => "2099-01-01"})
        )
        |> OpenResults.SnapshotPayloads.decided()

      assert Tournament.status(payload, ~D[2026-06-15]) == :finished
      assert Tournament.status(flag(payload, 3, false), ~D[2026-06-15]) == :live
    end
  end

  describe "tolerance" do
    test "keizer is keyed off system, not off which keys a row happens to have", %{
      swiss: swiss,
      keizer: keizer
    } do
      assert Tournament.keizer?(keizer)
      refute Tournament.keizer?(swiss)
    end

    test "a payload from a newer client reads exactly as it did before", %{swiss: swiss} do
      future = SnapshotPayloads.from_the_future(swiss)

      assert Tournament.name(future) == Tournament.name(swiss)
      assert Tournament.round_slots(future) == Tournament.round_slots(swiss)
      assert Tournament.card(future, 1) == Tournament.card(swiss, 1)
    end

    test "an older client that has not sent standings yet is not an error", %{swiss: swiss} do
      early = Map.delete(swiss, "standings")

      assert Tournament.standings_rows(early) == []
      assert Tournament.tiebreaks(early) == []
    end

    test "a key of the wrong shape costs that key and nothing else" do
      assert Tournament.name(%{"tournament" => "not an object"}) == "Tournament"
      assert Tournament.rounds(%{"rounds" => "not a list"}) == []
      assert Tournament.players(%{"players" => nil}) == []
      assert Tournament.round_slots(%{}) == []
    end
  end
end
