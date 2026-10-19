defmodule OpenResultsWeb.LiveBoardStampTest do
  @moduledoc """
  When a live-board page sends a tile again (`LiveBoardsData.stamp/1`). The
  2026-10-19 sweep found the boards and broadcast pages passing `force?:
  true` on every message about a board, so the comparison that was meant to
  skip repeats never ran. The pages now compare stamps; what a stamp has to
  tell apart is tested here, against real ingests.
  """

  use OpenResults.DataCase, async: false

  import OpenResults.PublicPublishingFixtures, only: [payload: 1, unique_slug: 1]

  alias OpenResults.LiveBoards
  alias OpenResults.Snapshots
  alias OpenResultsWeb.LiveBoardsData

  setup do
    slug = unique_slug("stamp")
    {:ok, _} = Snapshots.ingest(payload(slug))
    {:ok, slug: slug, payload: payload(slug)}
  end

  defp stamp(%{slug: slug, payload: payload}),
    do: payload |> LiveBoardsData.tile(slug, 5, 1, plies: false) |> LiveBoardsData.stamp()

  defp ingest!(%{slug: slug}, body, now),
    do:
      {:ok, _} =
        LiveBoards.ingest(slug, Map.merge(%{"round" => 5, "board" => 1}, body), now_ms: now)

  test "a repeat of the same report is the same stamp", context do
    now = System.os_time(:millisecond)
    ingest!(context, %{"moves" => ["e4"]}, now)
    first = stamp(context)

    ingest!(context, %{"moves" => ["e4"]}, now + 2_000)
    assert stamp(context) == first
  end

  test "a move, and a fresh clock report alone, each move the stamp", context do
    now = System.os_time(:millisecond)
    ingest!(context, %{"moves" => ["e4"], "white_ms" => 60_000, "black_ms" => 60_000}, now)
    first = stamp(context)

    # The same position, the clocks corrected: the browser cannot know.
    ingest!(
      context,
      %{"moves" => ["e4"], "black_ms" => 58_000, "running" => "black"},
      now + 2_000
    )

    second = stamp(context)
    refute second == first

    ingest!(context, %{"moves" => ["e4", "e5"]}, now + 4_000)
    refute stamp(context) == second
  end
end
