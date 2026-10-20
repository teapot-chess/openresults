defmodule OpenResults.FideList.ParserTest do
  use ExUnit.Case, async: true

  alias OpenResults.FideList.Parser

  @fixture Path.expand("../../fixtures/fide/players_list_foa.txt", __DIR__)

  setup do
    [header | lines] = @fixture |> File.read!() |> :binary.split("\r\n", [:global])
    {:ok, offsets} = Parser.offsets(header)
    %{offsets: offsets, lines: lines}
  end

  defp parsed(%{lines: lines, offsets: offsets}) do
    lines |> Enum.map(&Parser.parse_line(&1, offsets)) |> Enum.reject(&is_nil/1)
  end

  test "reads every player and nothing else", context do
    rows = parsed(context)

    assert length(rows) == 10
    assert Enum.map(rows, & &1.fide_id) == Enum.to_list(901_001..901_010)
  end

  test "keeps the columns after an accented name where they belong", context do
    # Latin-1 "Ø" and "ø" are one byte each and two in UTF-8. Converted before
    # slicing, every column after the name would move left by two.
    soren = context |> parsed() |> Enum.find(&(&1.fide_id == 901_003))

    assert soren.name == "Østergaard, Søren"
    assert soren.federation == "DEN"
    assert soren.standard_rating == 1950
    assert soren.birth_year == 1971
  end

  test "an empty rating or a 0 birth year is nothing, not zero", context do
    rows = context |> parsed() |> Map.new(&{&1.fide_id, &1})

    assert rows[901_001].blitz_rating == nil
    assert rows[901_005].standard_rating == nil
    assert rows[901_006].birth_year == nil
    assert rows[901_002].title == "FM"
    assert rows[901_003].title == ""
  end

  test "keeps only the columns the form has a field for", context do
    row = context |> parsed() |> hd()

    assert Map.keys(row) |> Enum.sort() ==
             Enum.sort(
               ~w(fide_id name search_key surname_terms given_terms federation title birth_year
                          standard_rating rapid_rating blitz_rating)a
             )
  end

  test "a header without a column is refused, not guessed around" do
    assert {:error, message} = Parser.offsets("ID Number      Name        Fed Sex")
    assert message =~ "Tit"
  end

  describe "search_key/1" do
    test "drops case, accents and punctuation" do
      assert Parser.search_key("De Vos, Ilse") == "de vos ilse"
      assert Parser.search_key("Dubois, Élodie") == "dubois elodie"
      assert Parser.search_key("Müller, Jürgen") == "muller jurgen"
      assert Parser.search_key("O'Neill-Smith,  Pat") == "o neill smith pat"
    end

    test "folds the letters Unicode will not decompose" do
      assert Parser.search_key("Østergaard, Søren") == "ostergaard soren"
      assert Parser.search_key("Weiß") == "weiss"
      assert Parser.search_key("Łukasz") == "lukasz"
    end
  end
end
