defmodule OpenResultsWeb.TournamentStatusTest do
  @moduledoc """
  Where a tournament sits in its own life cycle - live, upcoming or
  finished - derived from fields the snapshot already carries.

  `Tournament.status/2` takes `today` explicitly here, so every test is
  exact and never depends on the date this suite happens to run.
  """
  use ExUnit.Case, async: true

  alias OpenResults.SnapshotPayloads
  alias OpenResultsWeb.Tournament

  @today ~D[2026-06-15]

  defp payload(changes \\ %{}) do
    SnapshotPayloads.swiss()
    |> update_in(["tournament"], &Map.merge(&1, changes))
  end

  describe ":finished" do
    test "every round from 1 to rounds_count has been published" do
      # rounds_count 3 and rounds 1, 2, 3 published (the fixture also
      # carries round 5, which does not matter - 1..3 is all present).
      # `end_date` is pushed into the future so this is the rounds rule
      # alone, not the fixture's own (otherwise past) end_date agreeing by
      # coincidence.
      payload =
        payload(%{"rounds_count" => 3, "end_date" => "2099-01-01"}) |> SnapshotPayloads.decided()

      assert Tournament.status(payload, @today) == :finished
    end

    test "the highest published round reaching rounds_count is NOT enough on its own" do
      # The fixture's own shape: round 4 is withheld while round 5 is
      # already published and rounds_count is 5. A rule that only checked
      # "the highest number reached the total" would call this finished
      # while the standings still say "after round 3". `end_date` is pushed
      # out so the date rule cannot finish it either - this test is about
      # the round-counting rule alone.
      payload = payload(%{"rounds_count" => 5, "end_date" => "2099-01-01"})
      refute Tournament.status(payload, @today) == :finished
    end

    test "every round published is not finished while a board still waits for its result" do
      # A round robin's shape: the whole schedule is out on day one.
      payload =
        payload(%{"rounds_count" => 3, "end_date" => "2099-01-01"})
        |> SnapshotPayloads.decided()
        |> clear_one_result(3)

      assert Tournament.live?(payload)
      assert Tournament.status(payload, @today) == :live
    end

    test "a postponed board does not keep it open" do
      payload =
        payload(%{"rounds_count" => 3, "end_date" => "2099-01-01"})
        |> SnapshotPayloads.decided()
        |> clear_one_result(3, %{"postponed" => true})

      assert Tournament.status(payload, @today) == :finished
    end

    test "an end_date already in the past finishes it even mid-event" do
      payload = payload(%{"rounds_count" => 20, "end_date" => "2026-01-01"})
      assert Tournament.status(payload, @today) == :finished
    end

    test "an end_date of today is not yet past" do
      payload = payload(%{"rounds_count" => 20, "end_date" => Date.to_iso8601(@today)})
      refute Tournament.status(payload, @today) == :finished
    end
  end

  # Takes the result off round `number`'s first board, merging `extra` in.
  defp clear_one_result(payload, number, extra \\ %{}) do
    update_in(payload, ["rounds"], fn rounds ->
      Enum.map(rounds, fn
        %{"number" => ^number, "boards" => [first | rest]} = round ->
          %{round | "boards" => [first |> Map.delete("result") |> Map.merge(extra) | rest]}

        round ->
          round
      end)
    end)
  end

  describe ":upcoming" do
    test "a round robin's schedule published in advance, nothing played, start_date ahead" do
      payload =
        SnapshotPayloads.swiss()
        |> update_in(["rounds"], fn rounds ->
          Enum.map(rounds, fn round ->
            Map.update(round, "boards", [], fn boards ->
              Enum.map(boards, &Map.delete(&1, "result"))
            end)
          end)
        end)
        |> update_in(["tournament"], &Map.merge(&1, %{"start_date" => "2026-12-01"}))
        |> update_in(["tournament"], &Map.delete(&1, "end_date"))

      assert Tournament.status(payload, @today) == :upcoming
    end

    test "nothing published and a start_date in the future" do
      payload =
        SnapshotPayloads.swiss()
        |> Map.delete("rounds")
        |> update_in(["tournament"], &Map.merge(&1, %{"start_date" => "2026-12-01"}))
        |> update_in(["tournament"], &Map.delete(&1, "end_date"))

      assert Tournament.status(payload, @today) == :upcoming
    end

    test "nothing published and no dates at all - the only reading available" do
      payload =
        SnapshotPayloads.swiss()
        |> Map.delete("rounds")
        |> update_in(["tournament"], &Map.drop(&1, ["start_date", "end_date"]))

      assert Tournament.status(payload, @today) == :upcoming
    end

    test "a start_date of today is already started, not upcoming" do
      payload =
        SnapshotPayloads.swiss()
        |> Map.delete("rounds")
        |> update_in(
          ["tournament"],
          &Map.merge(&1, %{"start_date" => Date.to_iso8601(@today), "end_date" => "2099-01-01"})
        )

      refute Tournament.status(payload, @today) == :upcoming
    end

    test "rounds already published is never upcoming, whatever the dates say" do
      payload = payload(%{"start_date" => "2099-01-01", "end_date" => "2099-01-05"})
      refute Tournament.status(payload, @today) == :upcoming
    end
  end

  describe ":live" do
    test "the ordinary mid-event case: some rounds published, dates in range" do
      payload =
        payload(%{"rounds_count" => 20, "start_date" => "2026-06-01", "end_date" => "2099-01-01"})

      assert Tournament.status(payload, @today) == :live
    end

    test "rounds published, rounds_count absent, no dates - the honest default" do
      payload =
        payload()
        |> update_in(["tournament"], &Map.drop(&1, ["rounds_count", "start_date", "end_date"]))

      assert Tournament.status(payload, @today) == :live
    end
  end
end
