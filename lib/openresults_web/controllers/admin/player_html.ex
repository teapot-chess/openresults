defmodule OpenResultsWeb.Admin.PlayerHTML do
  @moduledoc """
  The players page of the admin panel. English only, not wrapped in gettext -
  see `OpenResultsWeb.Admin.Layouts`.
  """
  use OpenResultsWeb, :html

  import OpenResultsWeb.Admin.Components

  def index(assigns) do
    ~H"""
    <h1>Players</h1>

    <p>
      A player who asks for their cross-tournament page to be removed gets it removed: the page
      answers 404 and their FIDE id leaves player search and the sitemap. Their name stays on the
      tournaments themselves, which are the organisers' publication.
    </p>

    <form method="get" action={~p"/admin/players/hide"} class="admin-filters" id="hide-player-form">
      <label>
        FIDE id <input type="text" name="fide_id" inputmode="numeric" autocomplete="off" />
      </label>
      <button type="submit" id="hide-player-go">Hide a player page…</button>
    </form>

    <h2>Hidden player pages</h2>
    <p :if={@suppressions == []} class="empty" id="suppressions-empty">No player page is hidden.</p>

    <div :if={@suppressions != []} class="scroller">
      <table class="admin-table" id="suppressions">
        <caption class="visually-hidden">Hidden player pages</caption>
        <thead>
          <tr>
            <th scope="col">FIDE id</th>
            <th scope="col">Hidden by</th>
            <th scope="col"><span class="visually-hidden">Restore</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={s <- @suppressions} id={"suppression-#{s.fide_id}"}>
            <td><code>{s.fide_id}</code></td>
            <td>{s.created_by} <span class="quiet">{at(s.inserted_at)}</span></td>
            <td><a href={~p"/admin/players/#{s.fide_id}/restore"}>Restore</a></td>
          </tr>
        </tbody>
      </table>
    </div>

    <h2>Names that do not match their FIDE id</h2>
    <p>
      Published beside a FIDE id whose name on the FIDE list is clearly someone else's - usually
      a mistyped id. Kept off that player's page automatically, and shown here so the arbiter can
      be told. Checked when each tournament was last published.
    </p>
    <p :if={@mismatches == []} class="empty" id="mismatches-empty">None.</p>

    <div :if={@mismatches != []} class="scroller">
      <table class="admin-table" id="mismatches">
        <caption class="visually-hidden">Names that do not match their FIDE id</caption>
        <thead>
          <tr>
            <th scope="col">Published name</th>
            <th scope="col">FIDE id</th>
            <th scope="col">Tournament</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={a <- @mismatches} id={"mismatch-#{a.id}"}>
            <td>{a.name}</td>
            <td><a href={~p"/players/#{a.fide_id}"}>{a.fide_id}</a></td>
            <td><a href={~p"/admin/tournaments/#{a.slug}"}>{a.tournament_name}</a></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
