defmodule OpenResults.ResultsIndex.NameMatch do
  @moduledoc """
  Whether the name a tournament published beside a FIDE id plausibly belongs
  to the player FIDE lists under that id.

  The guard against a mistyped id. An arbiter who types 1503041 for 1503014
  puts somebody's result on a stranger's player page, and the stranger is
  the one person who will never know to complain. So an appearance whose
  name clearly is not the listed player's is kept off that player's page
  (and out of player search under that id) - it stays on the tournament's own
  pages, where the arbiter put it.

  ## The rule, and why it errs towards "same person"

  Dropping a real result from a real player's page is the worse mistake of
  the two: it is silent, and the player has no way to fix it. So this only
  says "different person" when there is no reasonable reading under which
  the two names are one. Both names are folded first
  (`OpenResults.FideList.Parser.search_key/1`: lower case, accents and
  punctuation gone, `ø` as `o` and so on), and then the names MATCH when any
  of these holds:

    1. **The surname is there.** FIDE writes "Surname, Given names". Every
       word of FIDE's surname appears among the tournament name's words -
       in any order, so "Jan De Vos" and "De Vos, Jan" agree.
    2. **The surname is there, run together or split.** FIDE's surname with
       its spaces removed occurs inside the tournament name with ITS spaces
       removed - "Dewinne" and "De Winne", "Van den Berghe" and
       "Vandenberghe".
    3. **Part of a compound surname is there.** Any one surname word of four
       letters or more appears on its own - a double surname shortened to
       one half, a married name added or dropped.
    4. **A typo.** Some surname word of four letters or more and some word
       of the tournament name are within Jaro distance 0.9 of each other -
       "Mueller" for "Muller", "Peters" for "Peeters".
    5. **Nothing to judge by.** Either name folds to nothing (blank, or only
       punctuation). No evidence of a mismatch is not evidence.

  A given name on its own never counts as a match ("Jan" is half of
  Flanders), and a FIDE name without a comma is all surname, as the FIDE
  list itself treats it.

  What this cannot catch, and does not try to: a typo that lands on another
  player with the same surname. Those pages stay wrong until the arbiter
  republishes - which is the same as on every other results site, and the
  reason the operator can still hide a player page by hand.
  """

  alias OpenResults.FideList.Parser

  @typo_threshold 0.9
  @min_word 4

  @doc """
  `true` when `published` (the tournament's name for the player) can be the
  player FIDE lists as `fide_name`. See the moduledoc for the rule.
  """
  @spec match?(String.t() | nil, String.t() | nil) :: boolean()
  def match?(published, fide_name) when is_binary(published) and is_binary(fide_name) do
    words = published |> Parser.search_key() |> String.split(" ", trim: true)
    surname = fide_name |> surname_part() |> Parser.search_key() |> String.split(" ", trim: true)

    cond do
      words == [] or surname == [] -> true
      Enum.all?(surname, &(&1 in words)) -> true
      String.contains?(Enum.join(words), Enum.join(surname)) -> true
      Enum.any?(surname, &(String.length(&1) >= @min_word and &1 in words)) -> true
      typo?(surname, words) -> true
      true -> false
    end
  end

  def match?(_published, _fide_name), do: true

  defp surname_part(name) do
    case String.split(name, ",", parts: 2) do
      [surname, _given] -> surname
      [whole] -> whole
    end
  end

  defp typo?(surname, words) do
    Enum.any?(surname, fn part ->
      String.length(part) >= @min_word and
        Enum.any?(words, &(String.jaro_distance(part, &1) >= @typo_threshold))
    end)
  end
end
