defmodule OpenResultsWeb.PlayerHistory do
  @moduledoc """
  One player's appearances across every tournament this server has published,
  matched by FIDE id.

  Read from the results index (`OpenResults.ResultsIndex`): one indexed
  query on `player_appearances`, rather than walking the current snapshot of
  every tournament on the server, which is what this did until the server
  held enough tournaments for that to hurt. The index holds copies of the
  same fields, after the same display rules this module used to apply
  itself - so everything below still holds, it is merely decided once at
  publish time instead of on every request. There is still no identity
  table and no cross-tournament player record: the FIDE id IS the join key.

  ## Why FIDE id and never a name

  Names collide. Two "Jan Janssens" in two different clubs are two different
  people, and matching on the string would silently merge their histories -
  wrongly, and invisibly to whoever was reading it. A FIDE id is the one
  handle the contract carries that actually identifies a *person* rather
  than a *seat in one event* (`no` is the latter, and is meaningless outside
  the tournament that assigned it). A player with no FIDE id gets no history
  page and no link to one - see `OpenResultsWeb.TournamentHTML.player_link/1`
  and the player template, which only ever link here when `fide_id` is
  present.

  ## What is deliberately filtered out

  **Unlisted tournaments.** `listed?` controls the front page, and this is
  another listing - a search surface, not a single tournament's own address.
  A tournament an arbiter chose to hand out only as a direct link should not
  become findable by searching a player's FIDE id instead. This is a
  judgement call: the tournament's OWN page (`/t/:slug`) stays reachable
  either way, exactly as unlisting already promises: see `Tournament.listed?/1`.

  **Pending and hidden tournaments.** Moderation's filter, beside the
  arbiter's. A hidden one is simply not there. A PENDING one is reachable at
  its own address but kept off these pages until it is approved, and this is
  the row public publishing rests on: otherwise anybody could register an
  installation, publish a tournament full of real FIDE ids and invented
  results, and have those results appear on real players' histories before a
  person had looked at it. See `OpenResults.Tournaments`.

  **A withheld placing.** When `display.standings` is off, the entry still
  appears - the tournament happened and this player played in it - but
  carries no rank, no points and no field size, the same withholding the
  standings page itself and the player card already apply.

  **A withheld card.** When `display.player_cards` is off, the entry is
  still listed but is not a link - the courtesy `player_link/1` already
  extends everywhere else on the site.

  **A taken-down tournament.** Not filtered here at all: `Takedown.purge/1`
  deletes its index rows with everything else, so it never reaches this
  module.

  **A name that is not this player's.** An appearance whose published name
  does not match the FIDE list's name for the id - a mistyped id - stays off
  the page. See `OpenResults.ResultsIndex.NameMatch` for the rule, which errs
  towards keeping a result.

  **A suppressed id.** The player asked for this page to go; it has none.

  Nothing is computed that was not already sent. A placing and a points total
  are read straight off `standings.rows`, the same fields the standings page
  itself renders - never re-derived, for the reason the schema doc gives
  everywhere else: the arbiter's screen and this site must never be able to
  disagree.
  """

  alias OpenResults.ResultsIndex

  @type entry :: %{
          slug: String.t(),
          name: String.t(),
          city: String.t() | nil,
          start_date: String.t() | nil,
          end_date: String.t() | nil,
          player_no: integer(),
          player_name: String.t() | nil,
          rating: integer() | nil,
          rank: integer() | nil,
          points: number() | nil,
          total: non_neg_integer() | nil,
          performance: integer() | nil,
          linkable?: boolean()
        }

  @doc """
  The FIDE list's row for `fide_id` (or `nil`) and every published, listed,
  approved tournament whose player list carries it under a matching name,
  newest first by start date.

  `fide_id` is expected to already be a positive integer - see
  `OpenResultsWeb.PlayerHistoryController` for where a path parameter is
  parsed and rejected before it reaches here.
  """
  @spec load(integer()) :: %{listed: map() | nil, entries: [entry()]}
  def load(fide_id) when is_integer(fide_id) do
    %{listed: listed, appearances: appearances} = ResultsIndex.player(fide_id)
    %{listed: listed, entries: Enum.map(appearances, &entry/1)}
  end

  @doc "`load/1`'s entries alone."
  @spec for_fide_id(integer()) :: [entry()]
  def for_fide_id(fide_id) when is_integer(fide_id), do: load(fide_id).entries
  def for_fide_id(_not_a_fide_id), do: []

  defp entry(appearance) do
    %{
      slug: appearance.slug,
      name: appearance.tournament_name,
      city: appearance.city,
      start_date: if(appearance.dates_shown, do: appearance.start_date),
      end_date: if(appearance.dates_shown, do: appearance.end_date),
      player_no: appearance.no,
      player_name: appearance.name,
      rating: appearance.rating,
      rank: appearance.rank,
      points: appearance.points && normalise(appearance.points),
      total: appearance.ranked_total,
      performance: appearance.performance,
      linkable?: appearance.card_linkable
    }
  end

  # Points are stored as a float; 2.0 reads back as 2, as it was sent.
  defp normalise(points) when points == trunc(points), do: trunc(points)
  defp normalise(points), do: points
end
