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

    test "the first name first, while the surname is still half typed" do
      for query <- ["ilse de", "ilse de v", "ilse d", "lucas jans"] do
        assert [_ | _] = found = names(FideList.search(query)), query
        assert hd(found) in ["De Vos, Ilse", "Janssens, Lucas"], query
      end

      assert names(FideList.search("ilse de v")) == ["De Vos, Ilse"]
    end

    test "a surname from its middle, and run together" do
      assert names(FideList.search("berghe")) == ["Van den Berghe, Pieter-Jan"]
      assert "Van den Berghe, Pieter-Jan" in names(FideList.search("vandenberghe"))
      assert "Vandenberghe, Koen" in names(FideList.search("vandenberghe"))
      assert names(FideList.search("pieterjan vandenb")) == ["Van den Berghe, Pieter-Jan"]
      assert names(FideList.search("pieter-jan van den berghe")) == ["Van den Berghe, Pieter-Jan"]
    end

    test "whole words outrank halves, and rating breaks the tie" do
      # Both start with "vandenberghe"; Koen's surname IS that word.
      assert hd(names(FideList.search("vandenberghe"))) == "Vandenberghe, Koen"
      assert names(FideList.search("peeters")) == ["Peeters, Marc", "Peeters, Anna"]
    end

    test "one misspelt word of three still finds the other two" do
      assert hd(names(FideList.search("ilze de vos"))) == "De Vos, Ilse"
      # Two words with one wrong is too little left to go on.
      assert FideList.search("ilze vos") == {:ok, []}
    end

    test "each typed word needs a word of its own" do
      assert FideList.search("vos vos") == {:ok, []}
    end

    test "a list from before the word index still answers by key" do
      OpenResults.FideList.Repo.query!("DROP TABLE fide_names")
      refute OpenResults.FideList.Store.words_available?()
      assert names(FideList.search("ilse de vos")) == ["De Vos, Ilse"]
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
      assert status.player_count == 10
      assert status.list_date == ~U[2026-11-01 06:00:00Z]
      assert %DateTime{} = status.imported_at
      assert status.last_check_result == "imported"
    end
  end
end
