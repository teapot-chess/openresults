defmodule OpenResultsWeb.Admin.TournamentController do
  @moduledoc """
  Tournaments: the list, one tournament, and the five things moderation does
  to one - approve, hide, unhide, delete, transfer. Each of those is a
  confirmation page (GET) and the action behind it (POST, same path); see
  `OpenResultsWeb.Admin.Confirmation`.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components,
    only: [render_not_found: 2, page_window: 1, page_rows: 1]

  alias OpenResults.Moderation
  alias OpenResultsWeb.Admin.{Confirmation, Params}

  plug Confirmation when action in [:approve, :hide, :unhide, :delete, :transfer, :live_delay]

  @statuses ~w(pending listed hidden)

  def index(conn, params) do
    {page, window} = page_window(params)
    status = Params.one_of(params["status"], @statuses)
    reported? = params["reported"] == "true"
    search = Params.text(params["search"])

    {tournaments, more?} =
      %{status: status, search: search}
      |> Map.merge(if reported?, do: %{reported?: true}, else: %{})
      |> Map.merge(window)
      |> Moderation.list_tournaments()
      |> page_rows()

    render(conn, :index,
      page_title: "Tournaments",
      tournaments: tournaments,
      labels: tournaments |> Enum.map(& &1.installation_id) |> Moderation.installation_labels(),
      page: page,
      more?: more?,
      filters: %{"status" => status, "reported" => if(reported?, do: "true"), "search" => search}
    )
  end

  def show(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn tournament ->
      render(conn, :show,
        page_title: label(tournament),
        tournament: tournament,
        stats: Moderation.tournament_stats(slug),
        live_delay: OpenResults.LiveBoards.delay_minutes(slug),
        reports: Moderation.list_reports(%{slug: slug}),
        actions: Moderation.list_actions(%{target_type: "tournament", target: slug, limit: 20})
      )
    end)
  end

  # --- approve, hide, unhide ---------------------------------------------------

  def confirm_approve(conn, %{"slug" => slug}), do: confirm_status(conn, slug, :approve)
  def confirm_hide(conn, %{"slug" => slug}), do: confirm_status(conn, slug, :hide)
  def confirm_unhide(conn, %{"slug" => slug}), do: confirm_status(conn, slug, :unhide)

  def approve(conn, %{"slug" => slug}),
    do: change_status(conn, slug, :approve, &Moderation.approve/2)

  def hide(conn, %{"slug" => slug}), do: change_status(conn, slug, :hide, &Moderation.hide/2)

  def unhide(conn, %{"slug" => slug}),
    do: change_status(conn, slug, :unhide, &Moderation.unhide/2)

  defp confirm_status(conn, slug, op) do
    with_tournament(conn, slug, fn tournament ->
      if allowed?(op, tournament.status) do
        Confirmation.render_page(conn, status_page(op, tournament))
      else
        conn
        |> put_flash(:error, not_allowed(op, tournament))
        |> redirect(to: ~p"/admin/tournaments/#{slug}")
      end
    end)
  end

  defp change_status(conn, slug, op, fun) do
    case fun.(slug, conn.assigns.admin) do
      {:ok, tournament} ->
        conn
        |> put_flash(:info, done(op, Moderation.get_tournament(slug) || tournament))
        |> redirect(to: ~p"/admin/tournaments/#{slug}")

      {:error, :invalid_status} ->
        # Somebody else changed it between the confirmation page and this.
        with_tournament(conn, slug, fn tournament ->
          conn
          |> put_flash(:error, "Nothing changed. " <> not_allowed(op, tournament))
          |> redirect(to: ~p"/admin/tournaments/#{slug}")
        end)

      {:error, :not_found} ->
        gone(conn, slug)
    end
  end

  defp allowed?(:approve, status), do: status == "pending"
  defp allowed?(:hide, status), do: status in ["pending", "listed"]
  defp allowed?(:unhide, status), do: status == "hidden"

  defp not_allowed(:approve, t),
    do: "Only a pending tournament can be shown on player pages, and #{label(t)} is #{t.status}."

  defp not_allowed(:hide, t), do: "#{label(t)} is already hidden."

  defp not_allowed(:unhide, t),
    do: "Only a hidden tournament can be unhidden, and #{label(t)} is #{t.status}."

  defp done(:approve, t), do: "Approved: #{label(t)} is listed, and on player pages."
  defp done(:hide, t), do: "Hidden: #{label(t)} now answers \"not found\" to the public."
  defp done(:unhide, t), do: "Unhidden: #{label(t)} is listed again."

  defp status_page(:approve, t) do
    [
      title: "Show #{label(t)} on player pages?",
      action: ~p"/admin/tournaments/#{t.slug}/approve",
      button: "Show on player pages",
      cancel: ~p"/admin/tournaments/#{t.slug}",
      danger: false,
      consequences: [
        summary(t),
        "It is already public: at its address, on the front page and in its search. Approving " <>
          "it lists it, and its results appear on players' cross-tournament history pages - " <>
          "check they are not invented results against real FIDE ids first."
      ]
    ]
  end

  defp status_page(:hide, t) do
    [
      title: "Hide #{label(t)}?",
      action: ~p"/admin/tournaments/#{t.slug}/hide",
      button: "Hide tournament",
      cancel: ~p"/admin/tournaments/#{t.slug}",
      consequences:
        [
          summary(t),
          "Every public page for it answers \"not found\", exactly as if it had never been " <>
            "published: the standings, rounds and player cards, and its entry and report forms.",
          "Nothing is deleted. Unhiding brings it back as listed."
        ] ++
          if(t.installation_id,
            do: [
              "Its installation can no longer publish to it - the arbiter is told the results " <>
                "site has hidden this tournament - but can still delete it and read its entries."
            ],
            else: []
          )
    ]
  end

  defp status_page(:unhide, t) do
    [
      title: "Unhide #{label(t)}?",
      action: ~p"/admin/tournaments/#{t.slug}/unhide",
      button: "Unhide and list",
      cancel: ~p"/admin/tournaments/#{t.slug}",
      danger: false,
      consequences:
        [
          summary(t),
          "It becomes listed, not pending: it is on the front page and in search again, and " <>
            "its results appear on players' history pages."
        ] ++
          if(t.installation_id, do: ["Its installation can publish to it again."], else: [])
    ]
  end

  # --- delete ------------------------------------------------------------------

  def confirm_delete(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn tournament ->
      stats = Moderation.tournament_stats(slug)

      Confirmation.render_page(conn,
        title: "Delete #{label(tournament)} for good?",
        action: ~p"/admin/tournaments/#{slug}/delete",
        button: "Delete tournament",
        cancel: ~p"/admin/tournaments/#{slug}",
        consequences: [
          summary(tournament),
          "This removes every snapshot this server holds for it: #{versions(stats.snapshots)}, " <>
            "the whole publish history and not only the current page.",
          "It also removes its entry list - #{entries(stats.registrations)} - with the email " <>
            "addresses people gave the entry form.",
          "Its tournament key and its slug are released. This cannot be undone. Reports about " <>
            "it and the action log are kept."
        ]
      )
    end)
  end

  def delete(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn tournament ->
      {:ok, counts} = Moderation.delete(slug, conn.assigns.admin)

      conn
      |> put_flash(
        :info,
        "Deleted #{label(tournament)}: #{versions(counts.snapshots)}, " <>
          "#{entries(counts.registrations)} and its tournament key."
      )
      |> redirect(to: ~p"/admin/tournaments")
    end)
  end

  # --- transfer ----------------------------------------------------------------

  def confirm_transfer(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, &render_transfer(conn, &1, nil, nil))
  end

  def transfer(conn, %{"slug" => slug} = params) do
    with_tournament(conn, slug, fn tournament ->
      case Params.text(params["installation_id"]) do
        nil ->
          render_transfer(
            conn,
            tournament,
            params["installation_id"],
            "Enter the id of the installation to transfer it to."
          )

        target ->
          case Moderation.transfer(slug, target, conn.assigns.admin) do
            {:ok, _tournament} ->
              conn
              |> put_flash(
                :info,
                "Transferred #{label(tournament)} to #{target}. Its tournament key is cleared: " <>
                  "#{target}'s next publish claims it."
              )
              |> redirect(to: ~p"/admin/tournaments/#{slug}")

            {:error, :not_found} ->
              render_transfer(conn, tournament, target, "No installation has the id #{target}.")

            {:error, :installation_revoked} ->
              render_transfer(
                conn,
                tournament,
                target,
                "#{target} is revoked, and a revoked installation cannot receive a tournament."
              )

            {:error, :installation_suspended} ->
              render_transfer(
                conn,
                tournament,
                target,
                "#{target} is suspended, so its key cannot publish: the tournament would " <>
                  "stop updating there. Unsuspend it first."
              )
          end
      end
    end)
  end

  defp render_transfer(conn, tournament, installation_id, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:transfer,
      page_title: "Transfer #{label(tournament)}",
      tournament: tournament,
      # Only text goes back into the field: `installation_id[x]=1` arrives
      # as a map, and a map is not something an input can show.
      installation_id: if(is_binary(installation_id), do: installation_id),
      error: error
    )
  end

  # --- live board delay --------------------------------------------------------

  def confirm_live_delay(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, &render_live_delay(conn, &1, nil, nil))
  end

  def live_delay(conn, %{"slug" => slug} = params) do
    with_tournament(conn, slug, fn tournament ->
      case Integer.parse(Params.text(params["minutes"]) || "") do
        {minutes, ""} ->
          case Moderation.set_live_delay(slug, minutes, conn.assigns.admin) do
            {:ok, 0} ->
              conn
              |> put_flash(:info, "Live boards are shown without a delay.")
              |> redirect(to: ~p"/admin/tournaments/#{slug}")

            {:ok, minutes} ->
              conn
              |> put_flash(:info, "Live boards are shown #{minutes} minutes behind the game.")
              |> redirect(to: ~p"/admin/tournaments/#{slug}")

            {:error, :invalid} ->
              render_live_delay(conn, tournament, params["minutes"], invalid_delay())

            {:error, :not_found} ->
              gone(conn, slug)
          end

        _not_a_number ->
          render_live_delay(conn, tournament, params["minutes"], invalid_delay())
      end
    end)
  end

  defp invalid_delay,
    do: "Enter a whole number of minutes from 0 to #{OpenResults.LiveBoards.max_delay_minutes()}."

  defp render_live_delay(conn, tournament, minutes, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:live_delay,
      page_title: "Live board delay for #{label(tournament)}",
      tournament: tournament,
      current: OpenResults.LiveBoards.delay_minutes(tournament.slug),
      minutes: if(is_binary(minutes), do: minutes),
      error: error
    )
  end

  # --- shared ------------------------------------------------------------------

  defp with_tournament(conn, slug, fun) do
    case Moderation.get_tournament(slug) do
      nil -> gone(conn, slug)
      tournament -> fun.(tournament)
    end
  end

  defp gone(conn, slug) do
    render_not_found(conn, "No tournament has the slug #{slug}. It may have been deleted.")
  end

  @doc false
  def label(%{name: name}) when is_binary(name) and name != "", do: name
  def label(%{slug: slug}), do: slug

  defp summary(t) do
    owner =
      if t.installation_id,
        do: "owned by #{t.installation_id}",
        else: "published with the operator token"

    "#{label(t)} (#{t.slug}) is #{t.status}, #{owner}."
  end

  defp versions(1), do: "1 stored version"
  defp versions(n), do: "#{n} stored versions"

  defp entries(1), do: "1 entry"
  defp entries(n), do: "#{n} entries"
end
