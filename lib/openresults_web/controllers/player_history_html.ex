defmodule OpenResultsWeb.PlayerHistoryHTML do
  @moduledoc """
  The markup for `OpenResultsWeb.PlayerHistoryController`.

  Thin on purpose: every fact here was already decided by
  `OpenResultsWeb.PlayerHistory`, which is where the display-rule and
  takedown logic lives. This module only prints what it was handed.
  """

  use OpenResultsWeb, :html

  alias OpenResultsWeb.TournamentHTML

  embed_templates "player_history_html/*"

  @doc """
  The heading name: the FIDE list's, then the player's own name as the most
  recent tournament recorded it, or the FIDE id alone when neither has it.

  Never a name manufactured from the id - if nothing published it, this page
  has nothing to call the player but the number in its own address.
  """
  def heading(_fide_id, %{name: name}, _entries) when is_binary(name), do: name
  def heading(fide_id, _listed, []), do: "FIDE #{fide_id}"
  def heading(_fide_id, _listed, [entry | _newest_first]), do: entry.player_name

  @doc "The current ratings line, from the FIDE list's row: `[{label, value}]`, rated lists only."
  def ratings(nil), do: []

  def ratings(listed) do
    [
      {gettext("Standard"), listed[:standard_rating]},
      {gettext("Rapid"), listed[:rapid_rating]},
      {gettext("Blitz"), listed[:blitz_rating]}
    ]
    |> Enum.filter(fn {_label, value} -> is_integer(value) end)
  end

  @doc "One entry's dates, reusing the same rendering the masthead uses."
  def dates(entry) do
    TournamentHTML.dates(%{"start_date" => entry.start_date, "end_date" => entry.end_date})
  end

  @doc "One entry's placing, or `nil` when the tournament withheld it."
  def placing(%{rank: rank, points: points, total: total})
      when is_integer(rank) and not is_nil(total) do
    gettext("rank %{rank} of %{total}, on %{points}",
      rank: rank,
      total: total,
      points: TournamentHTML.number(points)
    )
  end

  def placing(_no_rank), do: nil

  @doc "A link to the page narrowed to one year, or to every year."
  def year_path(fide_id, nil), do: ~p"/players/#{fide_id}"
  def year_path(fide_id, year), do: ~p"/players/#{fide_id}?#{[year: year]}"
end
