defmodule OpenResultsWeb.ReportController do
  @moduledoc """
  The public report form: telling the operator something is wrong with a
  tournament page.

  Anybody can publish here once public publishing is on, so anybody has to be
  able to object - the player who finds invented results under their FIDE id,
  or their email address on a page, most of all. A report writes to a queue
  in the admin panel (`OpenResults.Reports`) and changes nothing on the page.

  Guarded like the entry form, and for the same reasons (the router has them):
  no session, no CSRF token, only for a tournament the public can see - a
  hidden or unknown slug gets the site's one not-found page - and
  rate-limited by client address through `OpenResults.RateLimit`, in a bucket
  of its own so an entry and a report do not spend each other's allowance.

  Pages carry `noindex` whatever the tournament's status: a form is not
  something a search result should lead to.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.RateLimit
  alias OpenResults.Reports
  alias OpenResults.Reports.Report
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ClientAddress
  alias OpenResultsWeb.Meta
  alias OpenResultsWeb.Tournament

  # The entry form's numbers: five per ten minutes from one address. A
  # person reporting a page sends one; a script sending hundreds is exactly
  # what this is for.
  @rate_limit 5
  @rate_window_ms :timer.minutes(10)
  # Looking a number up is cheaper than sending a report, but a script
  # guessing references is the one thing this limit is for: twenty guesses a
  # ten-minute window against 2^40 numbers.
  @lookup_limit 20

  @doc "`GET /t/:slug/report`"
  def new(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn payload ->
      render_form(conn, slug, payload, Report.submission_changeset(%{}) |> Map.put(:action, nil))
    end)
  end

  @doc "`POST /t/:slug/report`"
  def create(conn, %{"slug" => slug} = params) do
    case RateLimit.take({:report, ClientAddress.of(conn)},
           limit: @rate_limit,
           window_ms: @rate_window_ms
         ) do
      :ok -> store(conn, slug, submitted(params))
      {:denied, retry_in_ms} -> too_many(conn, slug, retry_in_ms)
    end
  end

  @doc """
  `GET /report/status` - with `?ref=` the status of that report, without it
  the box to type the number into. A reference that matches nothing and one
  that is not shaped like a reference get the same sentence.
  """
  def status(conn, params) do
    case params do
      %{"ref" => ref} when is_binary(ref) and ref != "" ->
        case RateLimit.take({:report_lookup, ClientAddress.of(conn)},
               limit: @lookup_limit,
               window_ms: @rate_window_ms
             ) do
          :ok -> render_status(conn, ref, Reports.get_by_reference(ref))
          {:denied, retry_in_ms} -> too_many_lookups(conn, retry_in_ms)
        end

      _no_reference ->
        render_status(conn, "", :none)
    end
  end

  defp render_status(conn, ref, report) do
    conn
    |> put_noindex()
    |> put_resp_header("cache-control", "no-store")
    |> render(:status,
      page_title: gettext("Look up a report"),
      page_description: nil,
      ref: ref,
      report: if(report == :none, do: nil, else: report),
      searched?: report != :none
    )
  end

  defp too_many_lookups(conn, retry_in_ms) do
    conn
    |> put_status(:too_many_requests)
    |> put_resp_header("retry-after", Integer.to_string(ceil(retry_in_ms / 1000)))
    |> put_noindex()
    |> render(:too_many,
      page_title: gettext("Too many reports"),
      page_description: nil,
      minutes: max(1, ceil(retry_in_ms / 60_000)),
      back: ~p"/report/status",
      lookup?: true
    )
  end

  defp store(conn, slug, attrs) do
    with_tournament(conn, slug, fn payload ->
      case Reports.create(slug, attrs, ClientAddress.of(conn)) do
        {:ok, report} ->
          conn
          |> put_noindex()
          |> render(:received,
            page_title:
              gettext("Report sent - %{tournament}", tournament: Tournament.name(payload)),
            page_description: Meta.withheld(payload),
            payload: payload,
            slug: slug,
            reference: Reports.format_reference(report.reference)
          )

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> render_form(slug, payload, changeset)
      end
    end)
  end

  defp submitted(params) do
    case Map.get(params, "report") do
      attrs when is_map(attrs) -> attrs
      _absent_or_wrong_shape -> %{}
    end
  end

  defp render_form(conn, slug, payload, changeset) do
    conn
    |> put_noindex()
    |> render(:new,
      page_title: gettext("Report %{tournament}", tournament: Tournament.name(payload)),
      page_description: Meta.withheld(payload),
      payload: payload,
      slug: slug,
      form: Phoenix.Component.to_form(changeset, as: :report)
    )
  end

  defp with_tournament(conn, slug, render_fun) do
    case Tournaments.public_latest(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: OpenResultsWeb.TournamentHTML)
        |> render(:not_found,
          page_title: gettext("Not found"),
          page_description: Meta.not_found(),
          message: gettext("No tournament has published under %{slug}.", slug: slug),
          back: ~p"/"
        )

      snapshot ->
        render_fun.(snapshot.payload)
    end
  end

  defp too_many(conn, slug, retry_in_ms) do
    conn
    |> put_status(:too_many_requests)
    |> put_resp_header("retry-after", Integer.to_string(ceil(retry_in_ms / 1000)))
    |> put_noindex()
    |> render(:too_many,
      page_title: gettext("Too many reports"),
      page_description: nil,
      minutes: max(1, ceil(retry_in_ms / 60_000)),
      back: ~p"/t/#{slug}",
      lookup?: false
    )
  end

  defp put_noindex(conn) do
    conn
    |> assign(:noindex, true)
    |> put_resp_header("x-robots-tag", "noindex")
  end
end
