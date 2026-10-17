defmodule OpenResultsWeb.StatsTelemetry do
  @moduledoc """
  The two telemetry handlers that feed `OpenResults.Stats`, attached once at
  boot by `OpenResults.Application`.

  ## `[:bandit, :request, :stop]`, not Phoenix's endpoint event

  Bandit's event fires for every response it sends, including the static
  assets `Plug.Static` answers before `Plug.Telemetry` in the endpoint ever
  runs, and the 400s for requests too malformed to reach a plug. It runs in
  the connection's own process after the response has gone, so it adds no
  latency to the request it counts - only CPU, which is what
  `OpenResults.Stats` keeps to one counter increment (two on a tournament
  page). The page cache's decision arrives in `conn.private`, put there by
  `OpenResultsWeb.Plugs.Revalidate`, and rides in the same increment.

  ## What is looked at

  The method, the path's first segment, the status, the duration and - for a
  tournament page - its slug and the visibility `OpenResultsWeb.Plugs.Visibility`
  assigned. Never the address or the query string.

  A tournament page is counted in "busiest tournaments" only when that
  visibility says something has published under the slug (`:pending` or
  `:listed`) and the page answered 2xx or 304, so a scan of made-up slugs -
  `:none`, and a 404 - adds nothing.

  ## Views against refreshes

  A public tournament page polls its own URL every 20 seconds so a reader
  watching it sees updates without reloading (`root.html.heex`, and the
  projector board in `tournament_html.ex`) - one reader with a tab open for a
  couple of hours can throw hundreds of these at a slug that never had
  hundreds of visitors. Only a genuine navigation is counted as a view; a
  poll is counted separately, as a refresh (`OpenResults.Stats.record_refresh/3`).

  The distinction reads at most two request headers, only on a tournament
  page that already reached the visibility check below - never on a request
  that would not be counted at all:

    * the refresher's own `fetch()` calls send `x-openresults-refresh: 1`.
      Same-origin, so no CORS preflight. Whatever `Sec-Fetch-Mode` says, its
      presence alone means a poll.
    * otherwise, `Sec-Fetch-Mode: navigate` (a browser loading the page,
      including inside another site's `<iframe>`) means a view; any other
      value (`cors`, `same-origin`, `no-cors` - a script's own `fetch`,
      an on-page peek like the player-card popup) means a poll.
    * a request with no `Sec-Fetch-Mode` at all - older browsers, most
      non-browser clients, some bots - is counted as a view. That
      slightly over-counts a scripted client working through the API-less
      HTML pages, which this cannot tell from a real reader without the
      header; it is the same trade `Sec-Fetch` support itself makes.

  ## Readers

  The public pages' requests also go to `OpenResults.Stats.Viewers`, which
  tells real readers from bots and refreshes and counts distinct readers per
  day from a salted hash of address and user agent. That is the one place an
  address is read, and it is hashed on the spot: see that module.

  Publishes, mints and registrations are recognised here from their route and
  success status, so the controllers that do them are not touched; refusals
  are counted where the refusal body is built, `OpenResultsWeb.ApiError`.

  ## `[:open_results, :repo, :query]`

  Ecto's per-query event, for query time and the time spent waiting for a
  pool connection - the queue that emptied in the 2026-09-12 incident.

  ## Never raises

  `:telemetry` detaches a handler that raises, for good. Everything a handler
  here reads is matched with a fallback, and `OpenResults.Stats` swallows a
  missing table.
  """

  alias OpenResults.Stats
  alias OpenResults.Stats.Viewers

  @static OpenResultsWeb.static_paths()
  @table Stats.table()

  @doc "Attaches both handlers, replacing earlier copies."
  def attach do
    :telemetry.detach({__MODULE__, :request})
    :telemetry.detach({__MODULE__, :query})

    :ok =
      :telemetry.attach(
        {__MODULE__, :request},
        [:bandit, :request, :stop],
        &__MODULE__.handle_request/4,
        nil
      )

    :ok =
      :telemetry.attach(
        {__MODULE__, :query},
        query_event(),
        &__MODULE__.handle_query/4,
        nil
      )
  end

  @doc """
  The Repo's query event. Ecto derives its prefix from the module name when
  none is configured - `[:open_results, :repo]`, not the `openresults.repo`
  the scaffold's `OpenResultsWeb.Telemetry` metrics name.
  """
  def query_event do
    prefix =
      Application.get_env(:openresults, OpenResults.Repo, [])[:telemetry_prefix] ||
        [:open_results, :repo]

    prefix ++ [:query]
  end

  @doc false
  def handle_request(_event, measurements, metadata, _config) do
    minute = Stats.minute_now()
    us = microseconds(measurements[:duration])

    case metadata do
      # A tournament's event stream (`OpenResultsWeb.EventsController`) is
      # one request held open for up to half an hour. Counted, it would be a
      # half-hour "request" in the public pages' duration histogram for every
      # reader with a tab open - and it is not a page anyone viewed.
      %{conn: %Plug.Conn{path_info: ["t", _slug, "events"]}} ->
        :ok

      %{conn: %Plug.Conn{} = conn} ->
        group = group(conn)
        cache = conn.private[:openresults_page_cache]
        Stats.record_request(@table, minute, group, conn.status, us, cache)
        after_request(group, conn, minute)
        if group == :public, do: Viewers.observe(conn)

      _no_conn ->
        # Bandit could not build a request out of what arrived.
        Stats.record_request(@table, minute, :public, 400, us)
    end
  end

  @doc false
  def handle_query(_event, measurements, _metadata, _config) do
    Stats.record_query(microseconds(measurements[:query_time]), queue(measurements[:queue_time]))
  end

  defp queue(nil), do: nil
  defp queue(native), do: microseconds(native)

  defp microseconds(native) when is_integer(native),
    do: :erlang.convert_time_unit(native, :native, :microsecond)

  defp microseconds(_missing), do: 0

  @doc "The route group a request is counted under."
  @spec group(Plug.Conn.t()) :: atom()
  def group(%Plug.Conn{path_info: path_info, method: method}) do
    case path_info do
      ["admin" | _] -> :admin
      ["api" | _] when method in ["GET", "HEAD"] -> :api_read
      ["api" | _] -> :api_write
      [first | _] when first in @static -> :static
      _ -> :public
    end
  end

  defp after_request(:public, %Plug.Conn{status: status} = conn, minute)
       when status in 200..299 or status == 304 do
    with %{tournament_visibility: visibility} when visibility in [:pending, :listed] <-
           conn.assigns,
         %{"slug" => slug} when is_binary(slug) <- conn.path_params do
      case poll?(conn) do
        true -> Stats.record_refresh(@table, minute, slug)
        false -> Stats.record_view(@table, minute, slug)
      end
    end

    :ok
  end

  defp after_request(:api_write, %Plug.Conn{method: "POST", status: status} = conn, _minute) do
    case {conn.path_info, status} do
      {["api", "snapshots"], 200} -> Stats.count({:publish, credential(conn)})
      {["api", "tournaments"], 201} -> Stats.count(:mint)
      {["api", "installations"], 201} -> Stats.count(:registration)
      _other -> :ok
    end
  end

  defp after_request(_group, _conn, _minute), do: :ok

  # `true` for one of the refresher's own polls, `false` for a real page
  # load - see the moduledoc. At most two headers read, and only reached
  # once a tournament page has already matched the `with` above.
  defp poll?(conn) do
    case Plug.Conn.get_req_header(conn, "x-openresults-refresh") do
      [_ | _] -> true
      [] -> not navigate?(conn)
    end
  end

  defp navigate?(conn) do
    case Plug.Conn.get_req_header(conn, "sec-fetch-mode") do
      [] -> true
      ["navigate" | _] -> true
      [_other | _] -> false
    end
  end

  defp credential(%Plug.Conn{assigns: %{credential: {:installation, _}}}), do: :installation
  defp credential(_operator), do: :operator

  @doc """
  Open HTTP connections on the endpoint, from Thousand Island's own
  connection supervisors: `{:ok, n}`, or `:error` when the endpoint is not
  serving (tests, or `PHX_SERVER` unset). Walks one supervisor per acceptor,
  so it is sampled on the collector's timer, never per request.
  """
  def open_connections(endpoint \\ OpenResultsWeb.Endpoint) do
    with {:ok, pid} when is_pid(pid) <- Bandit.PhoenixAdapter.bandit_pid(endpoint),
         {:ok, pids} <- ThousandIsland.connection_pids(pid) do
      {:ok, length(pids)}
    else
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end
end
