defmodule OpenResultsWeb.Admin.InstallationController do
  @moduledoc """
  Installations: the list, one installation, and suspend, unsuspend and
  revoke - each a confirmation page and the POST behind it.

  Revoking asks what happens to the installation's tournaments and has no
  default answer. Hiding a club's live event and leaving a spammer's pages up
  are both mistakes a pre-ticked box would make for somebody.

  ## Moving every tournament

  The restore case (`Moderation.transfer_all/3`): no OpenPairings backup
  carries the installation key, so a restored laptop registers as a new
  installation and its tournaments have to follow it. One path, as always:

    * `GET .../move-tournaments` - which tournaments would move, and a field
      for the installation to move them to;
    * `GET .../move-tournaments?to=in_...` - the confirmation page, which
      shows that installation's client, version and when and where it was
      last seen, so the operator can tell it is the right laptop before
      anything moves. A GET, because an installation id is nothing a URL
      should not carry;
    * `POST .../move-tournaments` - the move, confirmed.
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components,
    only: [render_not_found: 2, page_window: 1, page_rows: 1, client_label: 1]

  alias OpenResults.Moderation
  alias OpenResultsWeb.Admin.{Confirmation, Params}

  plug Confirmation
       when action in [:suspend, :unsuspend, :revoke, :move, :trust, :untrust, :limits, :label]

  @statuses ~w(active suspended revoked)

  def index(conn, params) do
    {page, window} = page_window(params)
    status = Params.one_of(params["status"], @statuses)
    search = Params.text(params["search"])

    {installations, more?} =
      %{status: status, search: search}
      |> Map.merge(window)
      |> Moderation.list_installations()
      |> page_rows()

    render(conn, :index,
      page_title: "Installations",
      installations: installations,
      page: page,
      more?: more?,
      filters: %{"status" => status, "search" => search}
    )
  end

  def show(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      render(conn, :show,
        page_title: installation.id,
        installation: installation,
        tournaments: Moderation.list_tournaments(%{installation_id: installation.id}),
        storage: Moderation.installation_storage(installation.id),
        limits: OpenResults.PublicPublishing.installation_limits(installation),
        actions:
          Moderation.list_actions(%{
            target_type: "installation",
            target: installation.id,
            limit: 20
          })
      )
    end)
  end

  # --- suspend, unsuspend -----------------------------------------------------

  def confirm_suspend(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      if installation.status == "active" do
        Confirmation.render_page(conn,
          title: "Suspend #{installation.id}?",
          action: ~p"/admin/installations/#{installation.id}/suspend",
          button: "Suspend installation",
          cancel: ~p"/admin/installations/#{installation.id}",
          consequences: [
            summary(installation),
            "Its key stops working for publishing, creating tournaments, and reading history " <>
              "and entries: OpenPairings tells the arbiter to contact the operator, and their " <>
              "updates wait on their machine.",
            "It can still delete its own tournaments. Its tournaments stay up as they are.",
            "Unsuspending restores it."
          ]
        )
      else
        refuse(conn, installation, "Only an active installation can be suspended")
      end
    end)
  end

  def confirm_unsuspend(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      if installation.status == "suspended" do
        Confirmation.render_page(conn,
          title: "Unsuspend #{installation.id}?",
          action: ~p"/admin/installations/#{installation.id}/unsuspend",
          button: "Unsuspend installation",
          cancel: ~p"/admin/installations/#{installation.id}",
          danger: false,
          consequences: [
            summary(installation),
            "Its key works again for publishing, creating tournaments, and reading history and " <>
              "entries. Updates that waited on the arbiter's machine are sent on its next retry."
          ]
        )
      else
        refuse(conn, installation, "Only a suspended installation can be unsuspended")
      end
    end)
  end

  def suspend(conn, %{"id" => id}),
    do: change_status(conn, id, &Moderation.suspend/2, "Suspended", "can be suspended")

  def unsuspend(conn, %{"id" => id}),
    do: change_status(conn, id, &Moderation.unsuspend/2, "Unsuspended", "can be unsuspended")

  defp change_status(conn, id, fun, done, verb) do
    case fun.(id, conn.assigns.admin) do
      {:ok, installation} ->
        conn
        |> put_flash(:info, "#{done} #{installation.id}.")
        |> redirect(to: ~p"/admin/installations/#{installation.id}")

      {:error, :invalid_status} ->
        # Somebody else changed it between the confirmation page and this.
        with_installation(conn, id, fn installation ->
          conn
          |> put_flash(
            :error,
            "Nothing changed: #{installation.id} is #{installation.status} now, so it no " <>
              "longer #{verb}."
          )
          |> redirect(to: ~p"/admin/installations/#{installation.id}")
        end)

      {:error, :not_found} ->
        gone(conn, id)
    end
  end

  # --- revoke ------------------------------------------------------------------

  def confirm_revoke(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      if installation.status in ["active", "suspended"] do
        render_revoke(conn, installation, nil, nil)
      else
        refuse(conn, installation, "It is already revoked, and revoking is final")
      end
    end)
  end

  def revoke(conn, %{"id" => id} = params) do
    with_installation(conn, id, fn installation ->
      case Params.one_of(params["hide_tournaments"], ["true", "false"]) do
        nil ->
          render_revoke(
            conn,
            installation,
            nil,
            "Choose what happens to its tournaments. Nothing was changed."
          )

        choice ->
          case Moderation.revoke(installation.id, conn.assigns.admin,
                 hide_tournaments: choice == "true"
               ) do
            {:ok, revoked} ->
              conn
              |> put_flash(:info, revoked_message(revoked.id, choice, installation))
              |> redirect(to: ~p"/admin/installations/#{revoked.id}")

            {:error, :invalid_status} ->
              conn
              |> put_flash(:error, "Nothing changed: #{installation.id} is already revoked.")
              |> redirect(to: ~p"/admin/installations/#{installation.id}")

            {:error, :not_found} ->
              gone(conn, id)
          end
      end
    end)
  end

  defp render_revoke(conn, installation, choice, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:revoke,
      page_title: "Revoke #{installation.id}",
      installation: installation,
      active_tournaments: active_tournaments(installation),
      choice: choice,
      error: error
    )
  end

  defp revoked_message(id, "true", installation) do
    case active_tournaments(installation) do
      1 -> "Revoked #{id}, and hid its 1 tournament."
      n -> "Revoked #{id}, and hid its #{n} tournaments."
    end
  end

  defp revoked_message(id, "false", _installation),
    do: "Revoked #{id}. Its tournaments were left as they are."

  # --- trust -------------------------------------------------------------------

  def confirm_trust(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      cond do
        installation.status == "revoked" ->
          refuse(conn, installation, "A revoked installation cannot be trusted")

        installation.trusted ->
          already(conn, installation, "is already trusted")

        true ->
          render(conn, :trust,
            page_title: "Trust #{installation.id}",
            installation: installation,
            pending: pending_tournaments(installation)
          )
      end
    end)
  end

  def trust(conn, %{"id" => id} = params) do
    list? = params["list_pending"] == "true"

    case Moderation.trust(id, conn.assigns.admin, list_pending: list?) do
      {:ok, installation} ->
        listed = if list?, do: " Its pending tournaments are on player pages now.", else: ""

        conn
        |> put_flash(
          :info,
          "Trusted #{installation.id}: its new tournaments start listed.#{listed}"
        )
        |> redirect(to: ~p"/admin/installations/#{installation.id}")

      {:error, :invalid_status} ->
        with_installation(conn, id, fn installation ->
          conn
          |> put_flash(
            :error,
            "Nothing changed: #{installation.id} is #{installation.status}" <>
              if(installation.trusted, do: " and already trusted.", else: ".")
          )
          |> redirect(to: ~p"/admin/installations/#{installation.id}")
        end)

      {:error, :not_found} ->
        gone(conn, id)
    end
  end

  def confirm_untrust(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      if installation.trusted do
        Confirmation.render_page(conn,
          title: "Stop trusting #{installation.id}?",
          action: ~p"/admin/installations/#{installation.id}/untrust",
          button: "Stop trusting",
          cancel: ~p"/admin/installations/#{installation.id}",
          danger: false,
          consequences: [
            summary(installation),
            "Tournaments it creates from now on start pending again: public at once, but not on " <>
              "players' history pages until you show them there.",
            "Its tournaments that are already listed stay listed. Its own limits are unchanged."
          ]
        )
      else
        already(conn, installation, "is not trusted")
      end
    end)
  end

  def untrust(conn, %{"id" => id}) do
    case Moderation.untrust(id, conn.assigns.admin) do
      {:ok, installation} ->
        conn
        |> put_flash(:info, "#{installation.id} is no longer trusted.")
        |> redirect(to: ~p"/admin/installations/#{installation.id}")

      {:error, :invalid_status} ->
        with_installation(conn, id, &already(conn, &1, "is not trusted"))

      {:error, :not_found} ->
        gone(conn, id)
    end
  end

  defp already(conn, installation, words) do
    conn
    |> put_flash(:error, "Nothing changed: #{installation.id} #{words}.")
    |> redirect(to: ~p"/admin/installations/#{installation.id}")
  end

  defp pending_tournaments(installation),
    do: Enum.filter(installation.tournaments, &(&1.status == "pending"))

  # --- the operator's label ---------------------------------------------------

  def edit_label(conn, %{"id" => id}) do
    with_installation(conn, id, fn installation ->
      render_label(conn, installation, installation.label, nil)
    end)
  end

  def label(conn, %{"id" => id} = params) do
    with_installation(conn, id, fn installation ->
      text = if is_binary(params["label"]), do: params["label"], else: ""

      case Moderation.put_installation_label(installation.id, text, conn.assigns.admin) do
        {:ok, updated} ->
          conn
          |> put_flash(:info, "Saved the name of #{updated.id}.")
          |> redirect(to: ~p"/admin/installations/#{updated.id}")

        {:error, %Ecto.Changeset{} = changeset} ->
          {message, _} = Keyword.fetch!(changeset.errors, :label)

          conn
          |> put_status(:unprocessable_entity)
          |> render_label(installation, text, "The name #{message}.")

        {:error, :not_found} ->
          gone(conn, id)
      end
    end)
  end

  defp render_label(conn, installation, value, error) do
    render(conn, :label,
      page_title: "Name for #{installation.id}",
      installation: installation,
      value: value,
      error: error
    )
  end

  # --- own limits --------------------------------------------------------------

  def confirm_limits(conn, %{"id" => id} = params) do
    with_installation(conn, id, fn installation ->
      values = limit_values(params["limits"], installation)

      if params["check"] do
        changeset = Moderation.change_installation_limits(installation, values)

        if changeset.valid? do
          render(conn, :limits_confirm,
            page_title: "Limits for #{installation.id}",
            installation: installation,
            before_limits: OpenResults.PublicPublishing.installation_limits(installation),
            after_limits:
              OpenResults.PublicPublishing.installation_limits(
                Ecto.Changeset.apply_changes(changeset)
              ),
            hidden: Map.new(values, fn {k, v} -> {"limits[#{k}]", v || ""} end)
          )
        else
          render_limits(conn, installation, values, limit_errors(changeset))
        end
      else
        render_limits(conn, installation, values, %{})
      end
    end)
  end

  def limits(conn, %{"id" => id} = params) do
    with_installation(conn, id, fn installation ->
      values = limit_values(params["limits"], nil)

      case Moderation.put_installation_limits(installation.id, values, conn.assigns.admin) do
        {:ok, updated} ->
          conn
          |> put_flash(:info, "Saved #{updated.id}'s limits.")
          |> redirect(to: ~p"/admin/installations/#{updated.id}")

        {:error, %Ecto.Changeset{} = changeset} ->
          render_limits(conn, installation, values, limit_errors(changeset))

        {:error, :not_found} ->
          gone(conn, id)
      end
    end)
  end

  defp render_limits(conn, installation, values, errors) do
    conn
    |> put_status(if errors == %{}, do: :ok, else: :unprocessable_entity)
    |> render(:limits,
      page_title: "Limits for #{installation.id}",
      installation: installation,
      limits: OpenResults.PublicPublishing.installation_limits(installation),
      values: values,
      errors: errors
    )
  end

  # The four fields as text, blank as nil. With no form sent yet, the
  # installation's own values fill it.
  defp limit_values(fields, installation) when is_map(fields) or is_nil(fields) do
    Map.new(OpenResults.Installations.Installation.limits(), fn field ->
      name = Atom.to_string(field)

      value =
        case fields do
          %{^name => text} when is_binary(text) -> Params.text(text)
          nil when installation != nil -> own_text(Map.get(installation, field))
          _ -> nil
        end

      {name, value}
    end)
  end

  defp limit_values(_not_a_map, installation), do: limit_values(%{}, installation)

  defp own_text(nil), do: nil
  defp own_text(n), do: Integer.to_string(n)

  defp limit_errors(changeset) do
    Map.new(changeset.errors, fn {field, {message, _}} ->
      {field, "#{limit_label(field)} #{message}, or empty for the server's value."}
    end)
  end

  @doc false
  def limit_label(:max_tournaments), do: "Pending and listed tournaments"
  def limit_label(:max_snapshot_bytes), do: "Largest snapshot (bytes)"
  def limit_label(:publishes_per_minute), do: "Publishes per minute"
  def limit_label(:max_versions), do: "Versions kept per tournament"

  # --- move every tournament ---------------------------------------------------

  def confirm_move(conn, %{"id" => id} = params) do
    with_movable(conn, id, fn installation, tournaments ->
      case params["to"] do
        nil ->
          render_move_form(conn, installation, tournaments, nil, nil)

        to ->
          case target(installation, Params.text(to)) do
            {:ok, target} ->
              render(conn, :move_confirm,
                page_title: "Move tournaments to #{target.id}",
                installation: installation,
                tournaments: tournaments,
                target: target
              )

            {:error, message} ->
              render_move_form(conn, installation, tournaments, to, message)
          end
      end
    end)
  end

  def move(conn, %{"id" => id} = params) do
    with_movable(conn, id, fn installation, tournaments ->
      to = Params.text(params["to"])

      result =
        if to,
          do: Moderation.transfer_all(installation.id, to, conn.assigns.admin),
          else: {:error, :no_target}

      case result do
        {:ok, %{to: to, slugs: slugs}} ->
          conn
          |> put_flash(
            :info,
            "Moved #{tournaments_word(length(slugs))} from #{installation.id} to #{to}. Their " <>
              "tournament keys are cleared: #{to}'s next publish of each claims it."
          )
          |> redirect(to: ~p"/admin/installations/#{to}")

        {:error, :no_tournaments} ->
          conn
          |> put_flash(:error, "Nothing moved: #{installation.id} owns no tournaments any more.")
          |> redirect(to: ~p"/admin/installations/#{installation.id}")

        {:error, reason} ->
          render_move_form(conn, installation, tournaments, to, refusal(reason, to))
      end
    end)
  end

  # The same checks `transfer_all/3` makes, made first here so the
  # confirmation page can refuse with a sentence instead of offering a button
  # that will not work. The POST is checked again by the context either way.
  defp target(_installation, nil), do: {:error, refusal(:no_target, nil)}
  defp target(%{id: same}, same), do: {:error, refusal(:same_installation, same)}

  defp target(_installation, to) do
    case Moderation.get_installation(to) do
      nil -> {:error, refusal(:not_found, to)}
      %{status: "revoked"} -> {:error, refusal(:installation_revoked, to)}
      %{status: "suspended"} -> {:error, refusal(:installation_suspended, to)}
      target -> {:ok, target}
    end
  end

  defp refusal(:no_target, _to), do: "Enter the id of the installation to move them to."

  defp refusal(:same_installation, _to),
    do: "That is this installation. Enter the id of the one to move its tournaments to."

  defp refusal(:not_found, to), do: "No installation has the id #{to}."

  defp refusal(:installation_revoked, to),
    do: "#{to} is revoked, and a revoked installation cannot receive tournaments."

  defp refusal(:installation_suspended, to),
    do:
      "#{to} is suspended, so its key cannot publish: every tournament moved to it would stop " <>
        "updating. If it is the right laptop, unsuspend it first."

  defp render_move_form(conn, installation, tournaments, to, error) do
    conn
    |> put_status(if error, do: :unprocessable_entity, else: :ok)
    |> render(:move,
      page_title: "Move #{installation.id}'s tournaments",
      installation: installation,
      tournaments: tournaments,
      to: if(is_binary(to), do: to),
      error: error
    )
  end

  # Every tournament the installation owns, whatever its status - what
  # `transfer_all/3` moves. With none, there is nothing to offer.
  defp with_movable(conn, id, fun) do
    with_installation(conn, id, fn installation ->
      case Moderation.list_tournaments(%{installation_id: installation.id}) do
        [] ->
          conn
          |> put_flash(
            :error,
            "#{installation.id} owns no tournaments, so there is nothing to move."
          )
          |> redirect(to: ~p"/admin/installations/#{installation.id}")

        tournaments ->
          fun.(installation, tournaments)
      end
    end)
  end

  defp tournaments_word(1), do: "1 tournament"
  defp tournaments_word(n), do: "#{n} tournaments"

  # --- shared ------------------------------------------------------------------

  # `get_installation/1` preloads its tournaments; pending and listed are the
  # ones a revoke can hide.
  defp active_tournaments(installation),
    do: Enum.count(installation.tournaments, &(&1.status in ["pending", "listed"]))

  defp with_installation(conn, id, fun) do
    case Moderation.get_installation(id) do
      nil -> gone(conn, id)
      installation -> fun.(installation)
    end
  end

  defp gone(conn, id), do: render_not_found(conn, "No installation has the id #{id}.")

  defp refuse(conn, installation, sentence) do
    conn
    |> put_flash(:error, "#{sentence}; #{installation.id} is #{installation.status}.")
    |> redirect(to: ~p"/admin/installations/#{installation.id}")
  end

  defp summary(installation) do
    "#{installation.id} (#{client_label(installation)}) is #{installation.status}, holding " <>
      case active_tournaments(installation) do
        1 -> "1 pending or listed tournament."
        n -> "#{n} pending or listed tournaments."
      end
  end
end
