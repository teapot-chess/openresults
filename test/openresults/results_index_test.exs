defmodule OpenResults.ResultsIndexTest do
  @moduledoc """
  The results hub's index: what a publish writes into it, what a takedown
  takes out, what the rebuild finds to do, and the two rules that decide what
  a player page and the search may show - the name check and the hidden
  pages.
  """
  use OpenResults.DataCase, async: false

  import OpenResults.FideListCase, only: [setup_fide_list: 1, import_fixture!: 1]

  alias OpenResults.Repo
  alias OpenResults.ResultsIndex
  alias OpenResults.ResultsIndex.{Appearance, Entry, Generations, NameMatch}
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.Takedown

  setup :setup_fide_list

  defp publish!(payload) do
    {:ok, _} = Snapshots.ingest(payload, [])
    payload["tournament"]["slug"]
  end

  defp swiss(slug), do: put_in(SnapshotPayloads.swiss(), ["tournament", "slug"], slug)

  defp entry(slug), do: Repo.get_by(Entry, slug: slug)

  defp appearances(slug),
    do: Repo.all(from a in Appearance, where: a.slug == ^slug, order_by: a.no)

  defp fts_count(table),
    do: Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

  describe "a publish" do
    test "writes the tournament, one row per player, and both search tables" do
      payload = swiss("idx-one")
      publish!(payload)

      entry = entry("idx-one")
      assert entry.name == "Gent Spring Open 2026"
      assert entry.federation == "BEL"
      assert entry.start_date == "2026-03-01"
      assert entry.index_version == ResultsIndex.version()
      assert entry.players_count == length(payload["players"])

      rows = appearances("idx-one")
      assert length(rows) == length(payload["players"])
      assert %{name: "Müller, Jörg", fide_id: 1_503_014, rank: 3, ranked_total: 10} = hd(rows)

      assert fts_count("tournament_search") == 1
      assert fts_count("player_search") == length(rows)
    end

    test "again with the same snapshot is a no-op; a new one replaces the rows" do
      payload = swiss("idx-two")
      publish!(payload)
      %{id: first_id} = entry("idx-two")

      publish!(payload)
      assert entry("idx-two").id == first_id

      payload |> SnapshotPayloads.republished() |> publish!()
      refute entry("idx-two").id == first_id
      assert Repo.aggregate(Entry, :count) == 1
      assert fts_count("tournament_search") == 1
      assert fts_count("player_search") == length(appearances("idx-two"))
    end

    test "copies nothing the arbiter withheld" do
      "idx-hidden"
      |> swiss()
      |> put_in(["tournament", "display"], %{
        "club" => false,
        "rating" => false,
        "city" => false,
        "standings" => false
      })
      |> publish!()

      assert entry("idx-hidden").city == nil

      for row <- appearances("idx-hidden") do
        assert row.club == nil
        assert row.rating == nil
        assert row.rank == nil
        assert row.points == nil
      end
    end

    test "moves the generations of everything it touched, after the commit" do
      before = {Generations.get(:all), Generations.get({:federation, "BEL"})}
      publish!(swiss("idx-gen"))
      after_ = {Generations.get(:all), Generations.get({:federation, "BEL"})}

      assert elem(after_, 0) > elem(before, 0)
      assert elem(after_, 1) > elem(before, 1)
      assert Generations.get({:player, 1_503_014}) > 0
    end
  end

  describe "a takedown" do
    test "removes the tournament from the index, its players and both search tables" do
      publish!(swiss("idx-gone"))
      publish!(swiss("idx-stays"))
      player_gen = Generations.get({:player, 1_503_014})

      Takedown.purge("idx-gone")

      assert entry("idx-gone") == nil
      assert appearances("idx-gone") == []
      assert entry("idx-stays")
      assert fts_count("tournament_search") == 1
      assert fts_count("player_search") == length(appearances("idx-stays"))
      assert Generations.get({:player, 1_503_014}) > player_gen

      assert {:ok, %{tournaments: [%{slug: "idx-stays"}]}} = ResultsIndex.search("gent spring")
    end
  end

  describe "the rebuild" do
    test "finds what is missing, outdated or orphaned, and fixes exactly that" do
      publish!(swiss("idx-a"))
      publish!(swiss("idx-b"))

      Repo.delete_all(from e in Entry, where: e.slug == "idx-a")
      Repo.update_all(from(e in Entry, where: e.slug == "idx-b"), set: [index_version: 0])

      Repo.insert!(%Entry{
        slug: "idx-orphan",
        snapshot_id: 1,
        index_version: 1,
        name: "Gone",
        last_published_at: DateTime.utc_now()
      })

      assert %{reindex: ["idx-a", "idx-b"], orphaned: ["idx-orphan"]} = ResultsIndex.stale()

      assert ResultsIndex.reindex() == 2
      assert %{reindex: [], orphaned: []} = ResultsIndex.stale()
      assert entry("idx-a").index_version == ResultsIndex.version()
      assert entry("idx-orphan") == nil

      assert ResultsIndex.reindex() == 0
      assert ResultsIndex.reindex(force: true) == 2
    end
  end

  describe "the name check" do
    test "a surname that matches is a match, in any order and spelling" do
      assert NameMatch.match?("De Vos, Ilse", "De Vos, Ilse")
      assert NameMatch.match?("Ilse De Vos", "De Vos, Ilse")
      assert NameMatch.match?("DEVOS Ilse", "De Vos, Ilse")
      assert NameMatch.match?("Muller, Jorg", "Müller, Jörg")
      assert NameMatch.match?("Van den Berghe, P.", "Van den Berghe, Pieter-Jan")
      # One letter out on a long surname is a typo, not another person.
      assert NameMatch.match?("Muler, Jorg", "Müller, Jörg")
    end

    test "a different surname is not, even with the same given name" do
      refute NameMatch.match?("Janssens, Ilse", "De Vos, Ilse")
      refute NameMatch.match?("Dubois, Anna", "Peeters, Anna")
    end

    test "nothing to compare is never a mismatch" do
      assert NameMatch.match?("", "De Vos, Ilse")
      assert NameMatch.match?("De Vos, Ilse", "")
      assert NameMatch.match?(nil, "De Vos, Ilse")
    end
  end

  describe "a player" do
    setup context do
      import_fixture!(context)

      payload =
        swiss("idx-player")
        |> update_in(["players"], fn [first, second | rest] ->
          [
            first |> Map.put("fide_id", 901_001) |> Map.put("name", "De Vos, Ilse"),
            # The id of somebody else: mistyped.
            second |> Map.put("fide_id", 901_001) |> Map.put("name", "Janssens, Lucas")
            | rest
          ]
        end)

      publish!(payload)
      :ok
    end

    test "keeps the appearance under the right name and drops the mistyped one" do
      %{listed: listed, appearances: [kept]} = ResultsIndex.player(901_001)
      assert listed.name == "De Vos, Ilse"
      assert kept.name == "De Vos, Ilse"

      assert [%{name: "Janssens, Lucas"}] = ResultsIndex.name_mismatches()
    end

    test "is found by name and by id, once, and the mistyped row stays a loose hit" do
      assert {:ok, %{players: [%{fide_id: 901_001, tournaments: 1}]}} =
               ResultsIndex.search("de vos")

      assert {:ok, %{players: [%{fide_id: 901_001}]}} = ResultsIndex.search("901001")

      assert {:ok, %{players: [], appearances: [%{name: "Janssens, Lucas"}]}} =
               ResultsIndex.search("janssens")
    end

    test "hidden at their request: no page, not in search, tournaments untouched" do
      ResultsIndex.insert_suppression!(901_001, nil, "test")

      assert %{appearances: []} = ResultsIndex.player(901_001)
      assert {:ok, %{players: []}} = ResultsIndex.search("de vos")
      refute 901_001 in ResultsIndex.indexable_fide_ids()
      assert Enum.any?(appearances("idx-player"), &(&1.name == "De Vos, Ilse"))
    end
  end

  describe "search" do
    test "is refused for fewer than three letters" do
      assert {:error, :too_short} = ResultsIndex.search("ab")
      assert {:error, :too_short} = ResultsIndex.search("  ")
    end

    test "finds a tournament by a word of its name or its city, by prefix" do
      publish!(swiss("idx-search"))

      for q <- ["gent", "Spring Op", "ghent", "GENT SPRING"] do
        assert {:ok, %{tournaments: [%{slug: "idx-search"}]}} = ResultsIndex.search(q), q
      end

      assert {:ok, %{tournaments: []}} = ResultsIndex.search("antwerp")
    end

    test "keeps a tournament the arbiter unlisted out" do
      "idx-unlisted" |> swiss() |> put_in(["tournament", "listed"], false) |> publish!()
      assert {:ok, %{tournaments: []}} = ResultsIndex.search("gent")
    end
  end
end
