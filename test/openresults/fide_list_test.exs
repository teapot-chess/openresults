defmodule OpenResults.FideListTest do
  @moduledoc """
  The search the entry form asks, against the fixture list.
  """
  use OpenResults.FideListCase, async: true

  defp names({:ok, players}), do: Enum.map(players, & &1["name"])

  test "says so while there is no list, instead of finding nobody" do
    refute FideList.available?()
    assert FideList.search("de vos") == :unavailable
  end

  describe "with the list imported" do
    setup context do
      import_fixture!(context)
      :ok
    end

    test "a surname, strongest first" do
      assert names(FideList.search("de vos")) == ["De Vos, Jan", "De Vos, Ilse"]
    end

    test "with or without the comma, in either order, and the start of the last word" do
      for query <- ["De Vos, Ilse", "de vos ilse", "ilse de vos", "Ilse De Vos", "de vos il"] do
        assert names(FideList.search(query)) == ["De Vos, Ilse"], query
      end
    end

    test "without the accents FIDE's list has" do
      assert names(FideList.search("muller jurgen")) == ["Müller, Jürgen"]
      assert names(FideList.search("ostergaard")) == ["Østergaard, Søren"]
      assert names(FideList.search("elodie dubois")) == ["Dubois, Élodie"]
    end

    test "a FIDE id" do
      assert names(FideList.search("901007")) == ["Janssens, Lucas"]
      assert FideList.search("123") == {:ok, []}
      # Far past what SQLite's integer holds: no such player, not a crash.
      assert FideList.search("99999999999999999999999") == {:ok, []}
    end

    test "returns the form's own field names" do
      assert {:ok, [jan | _]} = FideList.search("de vos")

      assert jan == %{
               "fide_id" => 901_002,
               "name" => "De Vos, Jan",
               "title" => "FM",
               "federation" => "BEL",
               "birth_year" => 1980,
               "rating" => 2290
             }
    end

    test "the rating for the tournament's tempo, and the standard one where there is none" do
      rating = fn query, tempo ->
        {:ok, [player]} = FideList.search(query, tempo)
        player["rating"]
      end

      assert rating.("de vos jan", "rapid") == 2240
      assert rating.("de vos jan", "blitz") == 2201
      assert rating.("de vos jan", "standard") == 2290
      # Ilse has no blitz rating: her standard one, not nothing and not 0.
      assert rating.("de vos ilse", "blitz") == 2105
    end

    test "a blank stays a blank" do
      {:ok, [anna]} = FideList.search("peeters anna")
      assert anna["rating"] == nil
      assert anna["title"] == nil
    end

    test "too little to mean anything finds nothing" do
      assert FideList.search("d") == {:ok, []}
      assert FideList.search("   ") == {:ok, []}
      assert FideList.search(<<0xFF, 0xFE>>) == {:ok, []}
      assert FideList.search(nil) == {:ok, []}
    end

    test "a first name alone is not a search for everybody called that" do
      assert FideList.search("lucas") == {:ok, []}
    end

    test "punctuation cannot reach the query" do
      assert FideList.search("de vos%") |> names() == ["De Vos, Jan", "De Vos, Ilse"]
      assert FideList.search("'; DROP TABLE fide_players; --") == {:ok, []}
      assert FideList.available?()
    end
  end

  describe "status/0, for the admin page" do
    test "before anything was imported" do
      status = FideList.status()

      refute status.available?
      assert status.player_count == nil
      assert status.last_check_at == nil
    end

    test "after an import", context do
      import_fixture!(context)
      status = FideList.status()

      assert status.available?
      assert status.player_count == 8
      assert status.list_date == ~U[2026-11-01 06:00:00Z]
      assert %DateTime{} = status.imported_at
      assert status.last_check_result == "imported"
    end
  end
end
