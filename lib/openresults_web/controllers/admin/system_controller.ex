defmodule OpenResultsWeb.Admin.SystemController do
  @moduledoc """
  The System page: is it up, is the off-site copy current, and what has
  crashed - the three questions an operator asks before any other, on one
  page. Read from this server's own tables (`OpenResults.Ops`), and nothing
  on it is a secret: the bucket's host and name, never its keys; how many
  public keys a backup is encrypted to, never which.

  Three actions, each a confirmed pair like everything else in the panel:
  send the newest backup off-site now, forget one crash, forget them all.
  None of them is in the action log, which is the record of moderation and
  of what the cross-repo contract names; a forgotten crash report or an
  extra copy in a bucket changes nothing anybody published.

  Sending happens inside the POST, so the page answers when the bucket has.
  That is a few seconds for a database this size, and it means the flash
  says what actually happened rather than "queued".
  """
  use OpenResultsWeb, :controller

  import OpenResultsWeb.Admin.Components, only: [render_not_found: 2]

  alias OpenResults.Ops.{ErrorReports, Health, OffsiteBackup}
  alias OpenResultsWeb.Admin.Confirmation

  plug Confirmation when action in [:send_now, :clear, :forget]

  def show(conn, _params) do
    config = OffsiteBackup.config()

    render(conn, :show,
      page_title: "System",
      health: Health.report(),
      offsite_enabled?: OffsiteBackup.enabled?(config),
      offsite: offsite_summary(config),
      runs: OffsiteBackup.runs(10),
      errors: ErrorReports.list()
    )
  end

  defp offsite_summary(config) do
    s3 = config[:s3] || []

    %{
      host: s3[:endpoint] && URI.parse(s3[:endpoint]).host,
      bucket: s3[:bucket],
      prefix: s3[:prefix],
      recipients: length(config[:recipients] || []),
      stale_hours: OffsiteBackup.stale_hours(config)
    }
  end

  def confirm_send(conn, _params) do
    if OffsiteBackup.enabled?() do
      Confirmation.render_page(conn,
        title: "Send the newest backup off-site now?",
        consequences: [
          "The newest local backup is encrypted to the configured public keys and uploaded, " <>
            "even if it was already sent. Nothing on this server changes.",
          "This page waits for the upload to finish."
        ],
        action: ~p"/admin/system/offsite-backup",
        button: "Send it now",
        cancel: ~p"/admin/system",
        danger: false
      )
    else
      not_configured(conn)
    end
  end

  def send_now(conn, _params) do
    {kind, message} =
      case OffsiteBackup.push(force: true) do
        {:ok, key} -> {:info, "Sent off-site as #{key}."}
        :disabled -> {:error, "Off-site backups are not configured. Nothing was sent."}
        _error -> {:error, "The off-site backup failed; the latest run below says why."}
      end

    conn |> put_flash(kind, message) |> redirect(to: ~p"/admin/system")
  end

  def confirm_clear(conn, _params) do
    Confirmation.render_page(conn,
      title: "Forget every error report?",
      consequences: [
        "Every row on the System page's error list is deleted. A crash that happens again " <>
          "comes back as a new row, counted from one."
      ],
      action: ~p"/admin/system/errors/clear",
      button: "Forget them all",
      cancel: ~p"/admin/system"
    )
  end

  def clear(conn, _params) do
    {count, _} = ErrorReports.clear()

    conn
    |> put_flash(:info, "Forgot #{count} error report(s).")
    |> redirect(to: ~p"/admin/system")
  end

  def confirm_forget(conn, %{"id" => id}) do
    with_report(conn, id, fn report ->
      Confirmation.render_page(conn,
        title: "Forget this error report?",
        consequences: [
          "#{report.kind}, seen #{report.count} time(s), is deleted from the list. " <>
            "If it happens again it comes back as a new row."
        ],
        action: ~p"/admin/system/errors/#{report.id}/forget",
        button: "Forget it",
        cancel: ~p"/admin/system"
      )
    end)
  end

  def forget(conn, %{"id" => id}) do
    with_report(conn, id, fn report ->
      ErrorReports.delete(report.id)

      conn
      |> put_flash(:info, "Forgot the #{report.kind} report.")
      |> redirect(to: ~p"/admin/system")
    end)
  end

  defp with_report(conn, id, fun) do
    case ErrorReports.get(id) do
      nil -> render_not_found(conn, "There is no error report #{id}.")
      report -> fun.(report)
    end
  end

  defp not_configured(conn) do
    conn
    |> put_flash(:error, "Off-site backups are not configured on this server.")
    |> redirect(to: ~p"/admin/system")
  end
end
