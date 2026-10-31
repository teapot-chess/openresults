defmodule OpenResultsWeb.HubHTML do
  @moduledoc """
  The markup for `OpenResultsWeb.HubController`: the federation listings and
  search. Thin, like `OpenResultsWeb.PlayerHistoryHTML`: what to show was
  decided by `OpenResults.ResultsIndex`, which already applied the display
  rules when it copied each field.
  """

  use OpenResultsWeb, :html

  alias OpenResults.ResultsIndex.Entry
  alias OpenResultsWeb.TournamentHTML

  embed_templates "hub_html/*"

  @doc """
  The search box every hub page carries: a plain GET form to `/search`, so it
  works with no script at all.
  """
  attr :q, :string, default: ""
  attr :id, :string, default: "hub-search"

  def search_form(assigns) do
    ~H"""
    <form id={@id} class="hub-search" action={~p"/search"} method="get" role="search">
      <.input
        type="search"
        name="q"
        id={@id <> "-q"}
        value={@q}
        label={gettext("Search tournaments and players")}
        class="index-search-input"
        placeholder={gettext("Tournament, city or player name")}
        autocomplete="off"
        minlength="3"
      />
      <button type="submit" class="hub-search-button" id={@id <> "-go"}>
        {gettext("Search")}
      </button>
    </form>
    """
  end

  @doc "The links between the hub's pages."
  attr :current, :atom, default: nil

  def hub_nav(assigns) do
    ~H"""
    <nav class="hub-nav" aria-label={gettext("Results")} id="hub-nav">
      <a href={~p"/"} aria-current={@current == :front && "page"}>{gettext("Now")}</a>
      <a href={~p"/federations"} aria-current={@current == :federations && "page"}>
        {gettext("All tournaments by federation")}
      </a>
    </nav>
    """
  end

  @doc "One tournament in a listing, from its index row."
  attr :entry, Entry, required: true
  attr :show_federation, :boolean, default: false

  def entry_row(assigns) do
    ~H"""
    <li id={"t-" <> @entry.slug} class="hub-entry">
      <a href={~p"/t/#{@entry.slug}"}>{@entry.name}</a>
      <.unapproved :if={@entry.status == "pending"} />
      <span class="details">
        <span :if={@show_federation && @entry.federation}>
          <Flags.flag code={@entry.federation} />{@entry.federation}
        </span>
        <span :if={@entry.city}>{@entry.city}</span>
        <span :if={dates(@entry)}>{dates(@entry)}</span>
        <span :if={@entry.team}>{gettext("Teams")}</span>
      </span>
    </li>
    """
  end

  @doc """
  The mark on a tournament moderation has not approved yet: public, but not
  on the player pages, and the reader deserves to know that nobody has
  looked at it.
  """
  def unapproved(assigns) do
    ~H"""
    <span class="badge-unapproved" title={gettext("Not yet checked by this site's operator")}>
      {gettext("unapproved")}
    </span>
    """
  end

  @doc "An index row's dates, only where the arbiter shows them."
  def dates(%{dates_shown: false}), do: nil

  def dates(%{start_date: start, end_date: finish}),
    do: TournamentHTML.dates(%{"start_date" => start, "end_date" => finish})

  @doc "A federation's name in a heading: the code, or the no-federation bucket."
  def federation_label(:none), do: gettext("No federation")
  def federation_label(nil), do: gettext("No federation")
  def federation_label(code), do: code

  @doc "The path of a federation's listing."
  def federation_path(nil), do: ~p"/f/none"
  def federation_path(:none), do: ~p"/f/none"
  def federation_path(code), do: ~p"/f/#{code}"

  @doc "The heading of a life-cycle section on a listing."
  def section_title(:live), do: TournamentHTML.group_title(:live)
  def section_title(:upcoming), do: TournamentHTML.group_title(:upcoming)

  def section_title(:finished),
    do:
      gettext("Finished in the last %{days} days",
        days: OpenResults.ResultsIndex.federation_recent_days()
      )

  @doc "A link to one page of the archive, keeping the year."
  def archive_path(code, year, page) do
    query = Enum.reject([year: year, page: if(page > 1, do: page)], fn {_k, v} -> is_nil(v) end)

    case query do
      [] -> federation_path(code)
      query -> federation_path(code) <> "?" <> URI.encode_query(query)
    end
  end
end
