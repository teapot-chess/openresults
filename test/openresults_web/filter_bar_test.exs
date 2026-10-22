defmodule OpenResultsWeb.FilterBarTest do
  @moduledoc """
  The filter/sort bar on the standings, round pairings and cross-table
  pages - `OpenResultsWeb.FilterParams`, `OpenResultsWeb.Tournament.Filter`
  and `OpenResultsWeb.Components.FilterBar`.

  Every request here is a plain `Phoenix.ConnTest` GET with query params -
  the whole point of building this server-side rather than with a script:
  proving it needs no browser, exactly as `docs/snapshot-schema.md`'s
  contract needs no OpenPairings running to test against.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots}

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp attr(elements, name) do
    elements |> LazyHTML.attribute(name) |> Enum.reject(&is_nil/1)
  end

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  defp with_categories(payload, categories) do
    put_in(payload, ["tournament", "categories"], categories)
  end

  defp player_names(document) do
    document
    |> LazyHTML.query("table.standings > tbody > tr > th.row-head span.name")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  describe "standings: each filter on its own" do
    setup %{conn: conn} do
      payload = SnapshotPayloads.swiss() |> with_categories(["A", "B"])
      slug = publish(payload)
      {:ok, conn: conn, slug: slug, payload: payload}
    end

    test "category narrows to the players carrying it, and offers place-in-group", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?category=A") |> doc()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")

      # Five players carry category "A" in the fixture (players 1-5).
      assert Enum.count(rows) == 5

      assert document
             |> LazyHTML.query(~s(select[name="category"] option[selected]))
             |> Enum.count() == 1

      # Every row's rank cell also states its place within "A".
      places = texts(document, "table.standings > tbody > tr > td.rank")
      assert Enum.all?(places, &(&1 =~ "in A"))
    end

    test "an unknown category matches nobody, and shows the empty state - not a 500", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?category=Z") |> doc()

      assert LazyHTML.query(document, "table.standings") |> Enum.empty?()
      assert texts(document, ".filter-empty") |> Enum.any?(&(&1 =~ "No players match"))
      assert LazyHTML.query(document, ".filter-empty a") != []
    end

    test "federation narrows to the players carrying it", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?fed=BEL") |> doc()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")

      # Players 5 and 9 are BEL in the fixture.
      assert Enum.count(rows) == 2
    end

    test "club narrows to the players carrying it", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?club=SF+Berlin") |> doc()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")

      assert Enum.count(rows) == 1
    end

    test "the name search is a case-insensitive substring match", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?q=m%C3%BCller") |> doc()
      names = player_names(document)

      assert Enum.count(names) == 1
      assert hd(names) =~ "Müller"
    end

    test "combining two filters intersects rather than unions", %{conn: conn, slug: slug} do
      # Category A (players 1-5) intersected with federation BEL (players 5
      # and 9): only player 5.
      document = conn |> get(~p"/t/#{slug}?category=A&fed=BEL") |> doc()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      assert Enum.count(rows) == 1
    end
  end

  describe "standings: sorting" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, conn: conn, slug: slug}
    end

    test "rank is the default and leaves the arbiter's own order untouched", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}") |> doc()
      ranks = texts(document, "table.standings > tbody > tr > td.rank")
      # Every rank cell starts with the number itself (place-in-group text
      # only appears when a category filter is active).
      assert ranks == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
    end

    test "rating sorts highest first, and never touches the rank column", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?sort=rating") |> doc()
      # Player 10 carries no rating in the fixture and renders "-" - it
      # sorts to the bottom regardless of direction, per `Filter.standings/2`.
      cells = texts(document, "table.standings > tbody > tr > td.num:nth-child(3)")
      assert List.last(cells) == "-"

      ratings = cells |> Enum.reject(&(&1 == "-")) |> Enum.map(&String.to_integer/1)
      assert ratings == Enum.sort(ratings, :desc)

      # The rank column still prints the arbiter's own placing, not 1..10 in
      # the new row order.
      ranks = texts(document, "table.standings > tbody > tr > td.rank")
      refute ranks == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
      assert Enum.sort(ranks) == Enum.sort(["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"])
    end

    test "name sorts alphabetically", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?sort=name") |> doc()
      names = player_names(document)
      # `String.downcase/1` collation, the same convention the name search
      # and `index.html.heex`'s own search box use.
      assert names == Enum.sort_by(names, &String.downcase/1)
    end

    test "an unrecognised sort key falls back to rank silently, never a 500", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?sort=nonsense") |> doc()
      ranks = texts(document, "table.standings > tbody > tr > td.rank")
      assert ranks == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
    end
  end

  describe "standings: category fallback" do
    test "tournament.categories absent: no category control, nothing errors", %{conn: conn} do
      # The players carry `categories` (added in OpenPairings 0.53.0) but the
      # tournament has no `tournament.categories`: what an OpenPairings from
      # before that field sends. Removed explicitly, since the generated
      # fixture now carries it.
      slug =
        SnapshotPayloads.swiss()
        |> update_in(["tournament"], &Map.delete(&1, "categories"))
        |> publish()

      document = conn |> get(~p"/t/#{slug}") |> doc()
      assert LazyHTML.query(document, ~s(select[name="category"])) |> Enum.empty?()

      # A stale or hand-typed `?category=A` link still renders correctly
      # rather than erroring - matching nobody, since there is no vocabulary
      # to check it against.
      empty_doc = conn |> get(~p"/t/#{slug}?category=A") |> doc()
      assert LazyHTML.query(empty_doc, "table.standings") |> Enum.empty?()
    end

    test "no fallback to the players' own categories when the publisher sends none", %{conn: conn} do
      # Decision 2026-10-22: a missing `tournament.categories` can mean the
      # arbiter hid them on purpose, so the control must not be rebuilt from
      # what the players carry - even though they plainly carry some.
      payload =
        SnapshotPayloads.swiss()
        |> update_in(["tournament"], &Map.delete(&1, "categories"))
        |> update_in(["players", Access.all()], &Map.put(&1, "categories", ["A", "B"]))
        |> update_in(["players", Access.all()], &Map.put(&1, "category", "A"))

      assert OpenResultsWeb.Tournament.Filter.categories(payload) == []

      slug = publish(payload)
      document = conn |> get(~p"/t/#{slug}") |> doc()
      assert LazyHTML.query(document, ~s([name="category"])) |> Enum.empty?()
    end

    test "players[].category (no categories array) is the fallback the filter itself uses", %{
      conn: conn
    } do
      payload =
        SnapshotPayloads.swiss()
        |> with_categories(["A", "B"])
        |> update_in(["players", Access.all()], &Map.delete(&1, "categories"))

      slug = publish(payload)

      document = conn |> get(~p"/t/#{slug}?category=A") |> doc()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      # Still five players in category A, read off `category` alone.
      assert Enum.count(rows) == 5
    end
  end

  describe "standings: place-in-group with ties" do
    test "arbiter-equal ranks share a place, and the next place advances by exactly one", %{
      conn: conn
    } do
      payload =
        SnapshotPayloads.swiss()
        |> with_categories(["A", "B"])
        # Player 4's own tag, not only their standings row's `category` -
        # `Filter.standings/2`'s `places` reads `players[].categories`
        # (falling back to `players[].category`), never the standings row.
        |> update_in(
          ["players", Access.at(3)],
          &(&1 |> Map.put("categories", ["B"]) |> Map.put("category", "B"))
        )
        |> put_in(
          ["standings", "rows"],
          [
            %{"rank" => 1, "player" => 1, "points" => 5.0, "tiebreaks" => [], "category" => "A"},
            %{"rank" => 1, "player" => 2, "points" => 5.0, "tiebreaks" => [], "category" => "A"},
            %{"rank" => 3, "player" => 3, "points" => 4.0, "tiebreaks" => [], "category" => "A"},
            %{"rank" => 4, "player" => 4, "points" => 3.0, "tiebreaks" => [], "category" => "B"}
          ]
        )

      slug = publish(payload)

      document = conn |> get(~p"/t/#{slug}?category=A") |> doc()
      # The "·" between the rank and the place-in-group is CSS-drawn
      # (`.category-place::before`, matching the masthead's own detail-line
      # convention), so it is not in the text - the two numbers are.
      places = texts(document, "table.standings > tbody > tr > td.rank")

      assert places == ["1 1 in A", "1 1 in A", "3 2 in A"]
    end
  end

  describe "standings: hostile and out-of-bounds query values" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, conn: conn, slug: slug}
    end

    test "a script tag in a filter value is never reflected unescaped", %{conn: conn, slug: slug} do
      body =
        conn
        |> get(~p"/t/#{slug}?q=" <> URI.encode_www_form("<script>alert(1)</script>"))
        |> html_response(200)

      refute body =~ "<script>alert(1)</script>"
    end

    test "an absurdly long q is ignored rather than crashing the page", %{conn: conn, slug: slug} do
      long = String.duplicate("a", 5000)
      conn = get(conn, ~p"/t/#{slug}?q=#{long}")
      assert conn.status == 200
      # Every row still shows - the oversized value was dropped, not applied.
      document = doc(conn)
      assert LazyHTML.query(document, "table.standings > tbody > tr") |> Enum.count() == 10
    end

    test "repeated params resolve to a plain value rather than crashing", %{
      conn: conn,
      slug: slug
    } do
      conn = get(conn, ~p"/t/#{slug}?category=A&category=B")
      assert conn.status == 200
    end
  end

  describe "standings: Keizer" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.keizer())
      {:ok, conn: conn, slug: slug}
    end

    test "federation filters a Keizer table the same way", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?fed=BEL") |> doc()
      rows = LazyHTML.query(document, "table.standings > tbody > tr")
      assert Enum.count(rows) == 1
    end

    test "sort=rating reorders a Keizer table without touching its rank column", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?sort=rating") |> doc()
      ranks = texts(document, "table.standings > tbody > tr > td.rank")
      assert Enum.sort(ranks) == Enum.sort(["1", "2", "3", "4", "5", "6"])
    end
  end

  describe "round pairings" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, conn: conn, slug: slug}
    end

    test "a board shows when either seat matches, others are dropped", %{conn: conn, slug: slug} do
      # Player 5's club is "KGSRL" - round 1 has them on board 5 (5 v 10).
      document = conn |> get(~p"/t/#{slug}/round/1?club=KGSRL") |> doc()
      boards = texts(document, "table.pairings > tbody > tr > th")
      assert boards == ["5"]
    end

    test "the matching seat is highlighted and announced, the other seat is not", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1?club=KGSRL") |> doc()
      row = document |> LazyHTML.query("table.pairings > tbody > tr") |> Enum.at(0)
      cells = LazyHTML.query(row, "td")

      matches = attr(cells, "aria-current")
      assert matches == ["true"]
    end

    test "no filter active: every board shows, nothing is highlighted", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()
      boards = texts(document, "table.pairings > tbody > tr > th")
      assert Enum.count(boards) == 5
      assert LazyHTML.query(document, "td.pairing-match") |> Enum.empty?()
    end

    test "there is no sort control on the round page", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/round/1") |> doc()
      assert LazyHTML.query(document, ~s(select[name="sort"])) |> Enum.empty?()
    end

    test "a filter matching nobody shows the empty state with a clear-filters link", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/round/1?club=Nonexistent+FC") |> doc()
      assert texts(document, ".empty") |> Enum.any?(&(&1 =~ "No players match"))
    end
  end

  describe "cross-table" do
    setup %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      {:ok, conn: conn, slug: slug}
    end

    test "filters ROWS only - the opponent numbers inside cells are untouched", %{
      conn: conn,
      slug: slug
    } do
      plain = conn |> get(~p"/t/#{slug}/crosstable") |> doc()
      filtered = build_conn() |> get(~p"/t/#{slug}/crosstable?club=SF+Berlin") |> doc()

      assert LazyHTML.query(plain, "table.crosstable > tbody > tr") |> Enum.count() == 10
      assert LazyHTML.query(filtered, "table.crosstable > tbody > tr") |> Enum.count() == 1

      # Every opponent number that appears anywhere in the filtered grid
      # still refers to the same pairing numbers as the unfiltered one -
      # nothing was renumbered just because its own row is hidden.
      opponents_filtered = attr(LazyHTML.query(filtered, "a.xt-opp"), "data-player")
      opponents_plain = attr(LazyHTML.query(plain, "a.xt-opp"), "data-player")
      assert Enum.all?(opponents_filtered, &(&1 in opponents_plain))
    end

    test "there is no sort control on the cross-table page", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/crosstable") |> doc()
      assert LazyHTML.query(document, ~s(select[name="sort"])) |> Enum.empty?()
    end
  end

  describe "the shared query string across pages" do
    test "the standings/cross-table/round nav links carry the current filter and sort", %{
      conn: conn
    } do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}?fed=BEL&sort=rating") |> doc()

      crosstable_href =
        document
        |> LazyHTML.query(~s(nav.rounds a))
        |> attr("href")
        |> Enum.find(&(&1 =~ "crosstable"))

      round_href =
        document
        |> LazyHTML.query(~s(nav.rounds a))
        |> attr("href")
        |> Enum.find(&(&1 =~ "/round/1"))

      assert crosstable_href =~ "fed=BEL"
      assert crosstable_href =~ "sort=rating"
      assert round_href =~ "fed=BEL"
    end

    test "an unfiltered page's nav links carry no query string at all", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}") |> doc()

      hrefs = document |> LazyHTML.query(~s(nav.rounds a)) |> attr("href")
      refute Enum.any?(hrefs, &(&1 =~ "?"))
    end
  end

  describe "chips" do
    setup %{conn: conn} do
      payload = SnapshotPayloads.swiss() |> with_categories(["A", "B"])
      slug = publish(payload)
      {:ok, conn: conn, slug: slug}
    end

    defp query(href) do
      href |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()
    end

    test "each chip removes exactly its own parameter and keeps the others", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?category=A&fed=BEL&q=abc") |> doc()

      chip_hrefs =
        document |> LazyHTML.query(".filter-chip:not(.filter-chip-clear) a") |> attr("href")

      # One chip per active key: category, federation, name search.
      assert length(chip_hrefs) == 3

      for href <- chip_hrefs do
        params = query(href)
        # Exactly two of the three keys survive on each chip's link - the
        # one it removes is gone, the rest are untouched.
        assert map_size(params) == 2
      end

      # The category chip specifically drops `category` and keeps the rest.
      fed_and_q_only =
        Enum.find(chip_hrefs, fn href ->
          params = query(href)

          not Map.has_key?(params, "category") and Map.has_key?(params, "fed") and
            Map.has_key?(params, "q")
        end)

      assert fed_and_q_only

      # And the reverse: the federation chip drops only `fed`.
      category_and_q_only =
        Enum.find(chip_hrefs, fn href ->
          params = query(href)

          not Map.has_key?(params, "fed") and Map.has_key?(params, "category") and
            Map.has_key?(params, "q")
        end)

      assert category_and_q_only
    end

    test "Clear all goes back to the plain URL", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?category=A&fed=BEL") |> doc()

      [clear_href] = document |> LazyHTML.query(".filter-chip-clear a") |> attr("href")
      assert clear_href == ~p"/t/#{slug}"
    end

    test "no chips at all when nothing is active", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}") |> doc()
      assert LazyHTML.query(document, ".filter-chips") |> Enum.empty?()
    end

    test "a sort chip appears and removing it restores the default", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}?sort=rating") |> doc()

      [sort_href] =
        document
        |> LazyHTML.query(".filter-chip:not(.filter-chip-clear) a")
        |> attr("href")

      refute sort_href =~ "sort="
    end

    test "each chip carries an accessible name naming the filter it removes", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}?category=A") |> doc()

      [label] =
        document
        |> LazyHTML.query(".filter-chip:not(.filter-chip-clear) a")
        |> attr("aria-label")

      assert label =~ "category"
      assert label =~ "A"
    end
  end

  describe "the result count" do
    test "standings: unfiltered shows the total, filtered shows shown-of-total", %{conn: conn} do
      payload = SnapshotPayloads.swiss() |> with_categories(["A", "B"])
      slug = publish(payload)

      plain = conn |> get(~p"/t/#{slug}") |> doc()
      assert texts(plain, ".filter-count") == ["10 players"]

      filtered = build_conn() |> get(~p"/t/#{slug}?category=A") |> doc()
      assert texts(filtered, ".filter-count") == ["5 of 10 players"]
    end

    test "round pairings: counted in boards, not players", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      filtered = conn |> get(~p"/t/#{slug}/round/1?club=KGSRL") |> doc()
      assert texts(filtered, ".filter-count") == ["1 of 5 boards"]
    end

    test "cross-table: counted in players", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      filtered = conn |> get(~p"/t/#{slug}/crosstable?club=SF+Berlin") |> doc()
      assert texts(filtered, ".filter-count") == ["1 of 10 players"]
    end

    test "singular plural form when exactly one matches", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}?club=SF+Berlin") |> doc()
      assert texts(document, ".filter-count") == ["1 of 10 players"]
    end
  end

  describe "no-JS structure" do
    test "the Apply button is present in the markup", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}") |> doc()
      assert LazyHTML.query(document, ~s(button.filter-submit[type="submit"])) != []
    end

    test "the disclosure exists and holds the filter controls", %{conn: conn} do
      payload = SnapshotPayloads.swiss() |> with_categories(["A", "B"])
      slug = publish(payload)
      document = conn |> get(~p"/t/#{slug}") |> doc()

      details = LazyHTML.query(document, "details.filter-disclosure")
      assert details != []

      selects_inside =
        LazyHTML.query(document, "details.filter-disclosure select")

      assert selects_inside != []
    end

    test "the disclosure opens by default once a filter is active", %{conn: conn} do
      payload = SnapshotPayloads.swiss() |> with_categories(["A", "B"])
      slug = publish(payload)
      document = conn |> get(~p"/t/#{slug}?category=A") |> doc()

      assert LazyHTML.query(document, "details.filter-disclosure[open]") != []
    end

    test "the controls are always rendered open, so sorting is never hidden", %{conn: conn} do
      # A closed <details> hid the sort and filter controls on desktop too:
      # CSS cannot reliably reveal a closed disclosure. The server always
      # renders it open; only the script folds it, on a narrow screen, when
      # `data-keep-open` is "false".
      payload = SnapshotPayloads.swiss() |> with_categories(["A", "B"])
      slug = publish(payload)
      document = conn |> get(~p"/t/#{slug}") |> doc()

      refute LazyHTML.query(document, "details.filter-disclosure[open]") |> Enum.empty?()
      refute LazyHTML.query(document, ~s(details[data-keep-open="false"])) |> Enum.empty?()

      filtered = conn |> get(~p"/t/#{slug}?sort=rating") |> doc()
      refute LazyHTML.query(filtered, ~s(details[data-keep-open="true"])) |> Enum.empty?()
    end

    test "standings column headers sort, as plain links keeping the other filters", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}?fed=BEL") |> doc()

      hrefs =
        document
        |> LazyHTML.query("table.standings thead a.sort-link")
        |> LazyHTML.attribute("href")

      assert Enum.any?(hrefs, &(&1 =~ "sort=name" and &1 =~ "fed=BEL"))
      assert Enum.any?(hrefs, &(&1 =~ "sort=rating"))

      sorted = conn |> get(~p"/t/#{slug}?sort=name") |> doc()

      assert sorted
             |> LazyHTML.query(~s(table.standings thead th[aria-sort="ascending"]))
             |> Enum.count() == 1
    end
  end

  describe "name search highlighting" do
    test "the matching part is wrapped in <mark>, and the raw name is always escaped", %{
      conn: conn
    } do
      payload =
        SnapshotPayloads.swiss()
        |> update_in(["players", Access.at(0)], &Map.put(&1, "name", "<b>Xavier</b> Peeters"))

      slug = publish(payload)

      body = conn |> get(~p"/t/#{slug}?q=Xavier") |> html_response(200)

      refute body =~ "<b>Xavier</b>"
      assert body =~ "&lt;b&gt;"
      assert body =~ "<mark>Xavier</mark>"
    end
  end

  describe "the page cache" do
    alias OpenResultsWeb.Plugs.Revalidate.Page

    setup do
      Page.clear()
      on_exit(fn -> Page.clear() end)
      :ok
    end

    test "an unfiltered request is still cached (a hit on the second read)", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      first = get(conn, ~p"/t/#{slug}")
      second = get(build_conn(), ~p"/t/#{slug}")

      assert html_response(first, 200) == html_response(second, 200)
      # The `Page` table now holds this tournament's plain page.
      assert Page.get(
               slug,
               OpenResults.Snapshots.latest_id(slug),
               "en",
               List.first(Plug.Conn.get_resp_header(second, "etag"))
             )
    end

    test "a filtered request is never stored in the page cache", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      conn = get(conn, ~p"/t/#{slug}?fed=BEL")
      etag = List.first(Plug.Conn.get_resp_header(conn, "etag"))

      refute Page.get(slug, OpenResults.Snapshots.latest_id(slug), "en", etag)
    end

    test "filtered and unfiltered responses for the same tournament never mix", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      plain = conn |> get(~p"/t/#{slug}") |> html_response(200)
      filtered = build_conn() |> get(~p"/t/#{slug}?fed=BEL") |> html_response(200)

      refute plain == filtered
      # And a second read of the filtered link renders the same thing again
      # (correctness without caching it) rather than drifting.
      filtered_again = build_conn() |> get(~p"/t/#{slug}?fed=BEL") |> html_response(200)
      assert filtered == filtered_again
    end
  end
end
