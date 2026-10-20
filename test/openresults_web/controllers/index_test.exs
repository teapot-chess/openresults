defmodule OpenResultsWeb.IndexTest do
  @moduledoc """
  The front page: grouped into live, upcoming and finished, and searchable.

  `Tournament.status/2` is tested in full, with an explicit `today`, in
  `tournament_status_test.exs`. This file is about the PAGE: that each group
  gets its own section headed correctly, that a group nobody is in does not
  render an empty heading, that the search box ships the data a script needs
  and honours the same display rules and takedown as everywhere else, and
  that the page is still deterministic HTML.

  Every payload here pins its own dates safely into the past or the future
  rather than relying on the fixture's own - the real clock decides which
  group a tournament lands in on this page, and a test that left that to
  chance would start failing the day the fixture's dates did.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots, Takedown}

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp attr(elements, name), do: elements |> LazyHTML.attribute(name) |> Enum.reject(&is_nil/1)

  # rounds_count reached, so `Tournament.status/2` calls this :finished by
  # the round-counting rule alone - true on any calendar day.
  defp finished(slug) do
    SnapshotPayloads.swiss()
    |> put_in(["tournament", "slug"], slug)
    |> put_in(["tournament", "name"], "Finished Open")
    |> put_in(["tournament", "rounds_count"], 3)
    |> put_in(["tournament", "end_date"], "2099-01-01")
    |> SnapshotPayloads.decided()
  end

  # Nothing published, start_date safely in the future on any real calendar.
  defp upcoming(slug) do
    SnapshotPayloads.swiss()
    |> Map.delete("rounds")
    |> put_in(["tournament", "slug"], slug)
    |> put_in(["tournament", "name"], "Upcoming Open")
    |> put_in(["tournament", "start_date"], "2099-06-01")
    |> update_in(["tournament"], &Map.delete(&1, "end_date"))
  end

  # Some rounds published, rounds_count well beyond them, dates spanning any
  # real today.
  defp live(slug) do
    SnapshotPayloads.swiss()
    |> put_in(["tournament", "slug"], slug)
    |> put_in(["tournament", "name"], "Live Open")
    |> put_in(["tournament", "rounds_count"], 40)
    |> put_in(["tournament", "start_date"], "2000-01-01")
    |> put_in(["tournament", "end_date"], "2099-01-01")
  end

  describe "grouping" do
    test "each tournament lands in the section its own fields say it should", %{conn: conn} do
      publish(live("live-open"))
      publish(upcoming("upcoming-open"))
      publish(finished("finished-open"))

      document = conn |> get(~p"/") |> doc()

      live_names = document |> LazyHTML.query(~s([data-group="live"] .tournaments a)) |> texts()

      upcoming_names =
        document |> LazyHTML.query(~s([data-group="upcoming"] .tournaments a)) |> texts()

      finished_names =
        document |> LazyHTML.query(~s([data-group="finished"] .tournaments a)) |> texts()

      assert live_names == ["Live Open"]
      assert upcoming_names == ["Upcoming Open"]
      assert finished_names == ["Finished Open"]
    end

    test "a group with nothing in it renders no section at all", %{conn: conn} do
      publish(live("only-live"))

      document = conn |> get(~p"/") |> doc()

      assert document |> LazyHTML.query(~s([data-group="upcoming"])) |> Enum.empty?()
      assert document |> LazyHTML.query(~s([data-group="finished"])) |> Enum.empty?()
      refute document |> LazyHTML.query(~s([data-group="live"])) |> Enum.empty?()
    end

    test "each section is headed in the reader's own language" do
      publish(live("live-open-2"))
      publish(upcoming("upcoming-open-2"))
      publish(finished("finished-open-2"))

      html =
        build_conn()
        |> put_req_header("accept-language", "nl")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ "Nu bezig"
      assert html =~ "Binnenkort"
      assert html =~ "Afgelopen"
    end
  end

  describe "the search box" do
    test "each row carries its own name for the script to match against", %{conn: conn} do
      slug = publish(live("searchable-open"))
      document = conn |> get(~p"/") |> doc()

      row = LazyHTML.query(document, ~s(li[data-name="Live Open"]))
      refute Enum.empty?(row)
      assert LazyHTML.query(row, "a") |> texts() == ["Live Open"]
      assert slug == "searchable-open"
    end

    test "the search input and empty-state message both ship, for the script to use", %{
      conn: conn
    } do
      publish(live("has-a-search-box"))
      document = conn |> get(~p"/") |> doc()

      assert document |> LazyHTML.query("[data-index-search]") |> Enum.count() == 1
      assert document |> LazyHTML.query("[data-index-empty]") |> Enum.count() == 1
    end

    test "with nothing published, there is no search box to find", %{conn: conn} do
      document = conn |> get(~p"/") |> doc()
      assert document |> LazyHTML.query("[data-index-search]") |> Enum.empty?()
    end
  end

  describe "the display-rule leak case" do
    test "hiding the city takes it off the search data too", %{conn: conn} do
      hidden =
        live("no-city")
        |> put_in(["tournament", "display"], %{"city" => false})

      publish(hidden)
      document = conn |> get(~p"/") |> doc()

      row = LazyHTML.query(document, ~s(li[data-name="Live Open"]))
      assert attr(row, "data-city") == []
      refute LazyHTML.text(row) =~ "Ghent"
    end

    test "hiding the federation takes it off the search data too", %{conn: conn} do
      hidden =
        live("no-federation")
        |> put_in(["tournament", "display"], %{"federation" => false})

      publish(hidden)
      document = conn |> get(~p"/") |> doc()

      row = LazyHTML.query(document, ~s(li[data-name="Live Open"]))
      assert attr(row, "data-federation") == []
    end

    test "an unlisted tournament is in none of the three groups", %{conn: conn} do
      unlisted = live("stays-unlisted") |> put_in(["tournament", "listed"], false)
      publish(unlisted)

      html = conn |> get(~p"/") |> html_response(200)
      refute html =~ "Live Open"
    end
  end

  describe "takedown" do
    test "a taken-down tournament is in no group at all", %{conn: conn} do
      slug = publish(live("goes-away"))
      assert conn |> get(~p"/") |> html_response(200) =~ "Live Open"

      Takedown.purge(slug)

      refute conn |> get(~p"/") |> html_response(200) =~ "Live Open"
    end
  end

  describe "the cache" do
    test "two readers of the front page get identical bytes", %{conn: conn} do
      publish(live("cache-check-live"))
      publish(upcoming("cache-check-upcoming"))
      publish(finished("cache-check-finished"))

      first = conn |> get(~p"/") |> html_response(200)
      second = build_conn() |> get(~p"/") |> html_response(200)

      assert first == second
    end
  end

  defp texts(elements), do: Enum.map(elements, &(&1 |> LazyHTML.text() |> String.trim()))
end
