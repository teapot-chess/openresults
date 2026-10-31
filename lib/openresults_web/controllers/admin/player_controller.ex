defmodule OpenResultsWeb.Admin.PlayerController do
  @moduledoc """
  Cross-tournament player pages, from the operator's side.

    * `GET /admin/players` - the pages hidden at a player's request, and the
      appearances whose published name does not match the FIDE list's name
      for their id (probable mistyped ids, kept off that player's page
      automatically - see `OpenResults.ResultsIndex.NameMatch`).
    * `GET|POST /admin/players/hide?fide_id=` - hide one page. A player who
      writes to the operator asking for their page to go gets it gone, on
      identity alone and with no reasons required (the right to object).
    * `GET|POST /admin/players/:fide_id/restore` - put it back, when the
      player withdraws the request.

  Hiding removes the page, the id's place in player search and in the
  sitemap. It never touches a tournament: the name stays on the
  tournaments, which are their organisers' publication.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [render_not_found: 2]

  alias OpenResults.Moderation
  alias OpenResults.ResultsIndex
  alias OpenResultsWeb.Admin.Confirmation

  plug Confirmation when action in [:hide, :restore]

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Players",
      suppressions: ResultsIndex.list_suppressions(),
      mismatches: ResultsIndex.name_mismatches()
    )
  end

  def confirm_hide(conn, params) do
    case fide_id(params["fide_id"]) do
      nil ->
        conn
        |> put_flash(:error, "That is not a FIDE id.")
        |> redirect(to: ~p"/admin/players")

      fide_id ->
        Confirmation.render_page(conn,
          title: "Hide the player page of FIDE #{fide_id}?",
          action: ~p"/admin/players/hide",
          button: "Hide player page",
          cancel: ~p"/admin/players",
          hidden: %{"fide_id" => Integer.to_string(fide_id)},
          consequences: [
            "/players/#{fide_id} answers 404 and the id leaves player search and the sitemap.",
            "Tournament pages are untouched: the name stays on every tournament that published it.",
            "Kept until the player withdraws the request; restoring is one click on the players page."
          ]
        )
    end
  end

  def hide(conn, params) do
    with fide_id when is_integer(fide_id) <- fide_id(params["fide_id"]),
         {:ok, _suppression} <- Moderation.suppress_player(fide_id, nil, conn.assigns.admin) do
      conn
      |> put_flash(:info, "The player page of FIDE #{fide_id} is hidden.")
      |> redirect(to: ~p"/admin/players")
    else
      nil ->
        render_not_found(conn, "That is not a FIDE id.")

      {:error, :already_hidden} ->
        conn
        |> put_flash(:error, "Nothing changed: that player page was already hidden.")
        |> redirect(to: ~p"/admin/players")
    end
  end

  def confirm_restore(conn, %{"fide_id" => raw}) do
    case fide_id(raw) do
      nil ->
        render_not_found(conn, "That is not a FIDE id.")

      fide_id ->
        Confirmation.render_page(conn,
          title: "Restore the player page of FIDE #{fide_id}?",
          action: ~p"/admin/players/#{fide_id}/restore",
          button: "Restore player page",
          cancel: ~p"/admin/players",
          danger: false,
          consequences: [
            "Only when the player has withdrawn the request.",
            "/players/#{fide_id} is back, and the id is in player search and the sitemap again."
          ]
        )
    end
  end

  def restore(conn, %{"fide_id" => raw}) do
    with fide_id when is_integer(fide_id) <- fide_id(raw),
         {:ok, _} <- Moderation.restore_player(fide_id, conn.assigns.admin) do
      conn
      |> put_flash(:info, "The player page of FIDE #{fide_id} is back.")
      |> redirect(to: ~p"/admin/players")
    else
      nil ->
        render_not_found(conn, "That is not a FIDE id.")

      {:error, :not_hidden} ->
        conn
        |> put_flash(:error, "Nothing changed: that player page was not hidden.")
        |> redirect(to: ~p"/admin/players")
    end
  end

  defp fide_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 and id < 10_000_000_000 -> id
      _ -> nil
    end
  end

  defp fide_id(_absent), do: nil
end
