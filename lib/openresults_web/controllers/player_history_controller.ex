defmodule OpenResultsWeb.PlayerHistoryController do
  @moduledoc """
  `GET /players/:fide_id` - one player, across every tournament published
  here.

  Unlike `OpenResultsWeb.TournamentController`, this page is not about one
  snapshot - it gathers every tournament that lists a FIDE id. A FIDE id
  that matches nothing is not a 404: any positive integer is a legitimate
  address for this route, the same way an empty front page is not a 404
  either. It reads as "nothing published here yet", not "this does not
  exist". A path segment that is not a FIDE id at all - letters, a negative
  number, punctuation - IS a 404: that address could never have meant
  anything.

  ## The header

  From this server's own copy of the FIDE rating list
  (`OpenResults.FideList`): name, title, federation and the CURRENT
  ratings, labelled as such - the tournaments below each carry the rating
  they were played at. Birth year is in that list too and is never printed.

  ## Search engines

  Indexable (the maintainer's call, 2026-10-31), with one exception that is
  not a setting: **a player who may be under 18 gets `noindex`, always.**
  "May be" is decided by `minor?/2`, from the FIDE list's birth year, and
  an unknown birth year - not on the list, no year on file, no list at all -
  counts as a minor. The page still exists for the parent looking for it; it
  is just not something a search engine is invited to show a stranger.

  ## Removal

  A player who wants this page gone writes to the operator (see `/terms`),
  who hides it from the admin panel (`OpenResults.Moderation.suppress_player/3`).
  A hidden page answers 404 and is out of player search and the sitemap; the
  tournaments, and the name on them, stay as their organisers published them.

  ## Caching

  Per player, through `OpenResultsWeb.HubCache`, under that FIDE id's
  generation (moved by any publish, takedown or status change of a
  tournament listing the id, and by a suppression), the FIDE list's (a new
  list changes the header) and the year (which can turn a minor into an
  adult).
  """

  use OpenResultsWeb, :controller

  alias OpenResults.ResultsIndex
  alias OpenResults.ResultsIndex.Generations
  alias OpenResultsWeb.HubCache
  alias OpenResultsWeb.Meta
  alias OpenResultsWeb.PlayerHistory

  def show(conn, %{"fide_id" => raw} = params) do
    case parse_fide_id(raw) do
      nil ->
        not_found(conn, gettext("%{value} is not a FIDE id.", value: raw))

      fide_id ->
        if ResultsIndex.suppressed?(fide_id) do
          not_found(conn, gettext("There is no player page for this FIDE id."))
        else
          today = Date.utc_today()

          generation =
            {Generations.get({:player, fide_id}), Generations.get(:fide_list), today.year}

          year =
            if is_binary(params["year"]) and params["year"] =~ ~r/\A\d{4}\z/, do: params["year"]

          canonical = if year, do: URI.encode_query(year: year), else: ""

          HubCache.serve(
            conn,
            {:player, fide_id},
            generation,
            conn.query_string == canonical,
            &render_player(&1, fide_id, year, today)
          )
        end
    end
  end

  defp render_player(conn, fide_id, year, today) do
    %{listed: listed, entries: all} = PlayerHistory.load(fide_id)

    years =
      all
      |> Enum.map(&year_of/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort(:desc)

    year = if year in years, do: year
    entries = if year, do: Enum.filter(all, &(year_of(&1) == year)), else: all
    noindex? = minor?(listed, today)

    conn =
      if noindex?, do: put_resp_header(conn, "x-robots-tag", "noindex"), else: conn

    render(conn, :show,
      page_title: page_title(fide_id, listed, all),
      page_description: Meta.player_history(fide_id, all),
      noindex: noindex?,
      fide_id: fide_id,
      listed: listed,
      entries: entries,
      years: if(length(years) > 1, do: years, else: []),
      year: year
    )
  end

  @doc """
  Whether the player may be under 18 on `today`, by the FIDE list's birth
  year - and `true` when that cannot be known.

  By year alone, somebody born in 2008 turns 18 at some point in 2026, so in
  2026 they may still be 17: only `today.year - birth_year >= 19` proves an
  adult. A year off in the safe direction for at most one year of a
  player's life.
  """
  @spec minor?(map() | nil, Date.t()) :: boolean()
  def minor?(%{birth_year: year}, %Date{year: now}) when is_integer(year) and year > 1900,
    do: now - year < 19

  def minor?(_unknown, _today), do: true

  defp year_of(%{start_date: <<year::binary-size(4), "-", _::binary>>}), do: year
  defp year_of(_no_date), do: nil

  defp page_title(fide_id, %{name: name}, _entries) when is_binary(name),
    do: "#{name} - FIDE #{fide_id}"

  defp page_title(fide_id, _listed, [entry | _newest_first]),
    do: "#{entry.player_name} - FIDE #{fide_id}"

  defp page_title(fide_id, _listed, []), do: "FIDE #{fide_id}"

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OpenResultsWeb.TournamentHTML)
    |> render(:not_found,
      page_title: gettext("Not found"),
      page_description: Meta.not_found(),
      message: message,
      back: ~p"/"
    )
  end

  # A whole, positive number and nothing else - `"1503014x"` is not a FIDE
  # id, and `String.to_integer/1` would raise on it where a 404 is the right
  # answer. Zero and negative numbers are rejected too: FIDE ids start at 1
  # and a payload can never carry one that does not, so no snapshot could
  # ever match and the honest answer is "not a FIDE id" rather than a
  # perpetually empty list.
  defp parse_fide_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _not_a_positive_integer -> nil
    end
  end
end
