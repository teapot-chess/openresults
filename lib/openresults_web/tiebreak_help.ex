defmodule OpenResultsWeb.TiebreakHelp do
  @moduledoc """
  The small "?" beside a tie-break's name, and the one or two sentences behind
  it.

  Spectators see "Buchholz Cut-1" and are expected to know. They mostly do
  not, and the arbiter's app already sends a human label with every code, so
  the missing half is only what the label means. The sentences follow FIDE
  C.07 (Tie-Break Regulations) and are deliberately short: where C.07 has a
  detail that does not fit in a tooltip (the virtual opponent for unplayed
  games), the text names it and moves on rather than half-explaining it.

  A code this module has no sentence for renders **nothing**: a "?" that
  opens an empty box, or a guess dressed as a definition, is worse than the
  bare name. The codes are the app's (`BHC1`) or C.07's own spelling
  (`BH/C1`); both are accepted.

  Mechanics: a `<button>` with `aria-expanded` and a sibling `role="tooltip"`
  text. The stylesheet shows the text on hover and on keyboard focus, so it
  works with the scripts off; the small handler in the root layout adds
  tap-to-open for phones, Escape and tap-outside to close, and keeps the
  text inside the viewport. The text is `position: fixed` so the scrolling
  wrapper around a standings table cannot clip it.
  """
  use Phoenix.Component
  use Gettext, backend: OpenResultsWeb.Gettext

  @doc """
  The explanation for a tie-break code, or nil when there is none.
  """
  def explain(code) when is_binary(code) do
    code |> String.trim() |> String.upcase() |> String.replace("/", "") |> text()
  end

  def explain(_other), do: nil

  # Each clause is a literal gettext call so `mix gettext.extract` sees it.
  defp text("BH"),
    do:
      gettext(
        "The sum of the final scores of all your opponents. Games you did not play count against a virtual opponent, as FIDE C.07 describes."
      )

  defp text("BHC1"),
    do: gettext("Buchholz with the score of your lowest-scoring opponent left out.")

  defp text("BHC2"),
    do: gettext("Buchholz with the scores of your two lowest-scoring opponents left out.")

  defp text("MBH"),
    do:
      gettext(
        "Buchholz with the scores of your highest-scoring and your lowest-scoring opponent left out."
      )

  defp text("BHM1"), do: text("MBH")

  defp text("BHM2"),
    do:
      gettext(
        "Buchholz with the two highest-scoring and the two lowest-scoring opponents left out."
      )

  defp text("SB"),
    do:
      gettext(
        "For every opponent you beat, add their score; for every opponent you drew with, add half of it. Beating strong opponents counts for more."
      )

  defp text("SBC1"),
    do: gettext("Sonneborn-Berger with the smallest single contribution left out.")

  defp text("SBC2"),
    do: gettext("Sonneborn-Berger with the two smallest contributions left out.")

  defp text("DE"),
    do:
      gettext(
        "Only looked at between players who are tied on everything before it: the result of the games they played against each other."
      )

  defp text("WIN"), do: gettext("The number of games you won, forfeit wins included.")

  defp text("WON"),
    do: gettext("The number of games you won over the board. Forfeit wins and byes do not count.")

  defp text("BPG"), do: gettext("The number of games you played with the black pieces.")
  defp text("BWG"), do: gettext("The number of games you won with the black pieces.")

  defp text("PS"),
    do:
      gettext(
        "Your running score after round 1, plus after round 2, and so on, added up. A fast start is worth more than a fast finish."
      )

  defp text("PSC1"),
    do: gettext("Progressive score with the lowest of those running scores left out.")

  defp text("PSC2"),
    do: gettext("Progressive score with the two lowest of those running scores left out.")

  defp text("KS"),
    do:
      gettext(
        "The points you scored against opponents who finished on 50% or more of the maximum score."
      )

  defp text("ARO"), do: gettext("The average rating of your opponents.")

  defp text("AROC1"),
    do: gettext("The average rating of your opponents, with the lowest-rated one left out.")

  defp text("AROC2"),
    do: gettext("The average rating of your opponents, with the two lowest-rated ones left out.")

  defp text("AROM1"),
    do:
      gettext(
        "The average rating of your opponents, with the highest-rated and the lowest-rated one left out."
      )

  defp text("AROM2"),
    do:
      gettext(
        "The average rating of your opponents, with the two highest-rated and the two lowest-rated ones left out."
      )

  defp text("REP"), do: gettext("The number of rounds you actually played at the board.")

  defp text("MP"),
    do: gettext("Match points: what a team scores for winning, drawing or losing a match.")

  defp text("GP"), do: gettext("Game points: the total of the board points a team scored.")
  defp text(_unknown), do: nil

  attr :code, :any, default: nil, doc: "the tie-break's code, as the snapshot declares it"
  attr :name, :string, default: nil, doc: "its label, for the button's accessible name"

  @doc """
  The "?" and its text, or nothing when the code has no explanation.
  """
  def help(assigns) do
    text = explain(assigns.code)

    assigns = assign(assigns, :text, text)

    ~H"""
    <span :if={@text} class="tb-help-wrap">
      <button
        type="button"
        class="tb-help"
        aria-expanded="false"
        aria-label={gettext("What is %{name}?", name: @name || @code)}
        data-tb-help
      >
        ?
      </button>
       <span class="tb-help-text" role="tooltip">{@text}</span>
    </span>
    """
  end
end
