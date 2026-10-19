defmodule OpenResultsWeb.Plugs.CanonicalHost do
  @moduledoc """
  Moves requests that arrive on an old hostname to the canonical one.

  Off unless `PHX_REDIRECT_HOSTS` names at least one host (see
  `config/runtime.exs`), so deploying this changes nothing until somebody
  decides it should: a request on any other host - loopback, a health check -
  passes straight through.

  Only `GET` and `HEAD` are redirected. A `301` makes a client re-send as a
  `GET`, which would turn an OpenPairings publish (`POST`/`PUT` to `/api`)
  into a page view and lose its body. Those keep being answered on the old
  host, so a desktop copy that still publishes to it keeps working.

  Nothing under `/api` is redirected, whatever the method (the 2026-10-19
  sweep): OpenPairings no longer follows redirects - a followed one carries
  its bearer token and tournament key to wherever `Location` says - so a
  redirected `GET /api/server` would turn every desktop copy pointed at the
  old name into "the results site moved". The API answers on any host.

  The policy is read from `config :openresults, :host_policy` on every request
  (a keyword list: `:canonical`, `:redirect_hosts`).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts), do: conn

  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    policy = Application.get_env(:openresults, :host_policy, [])
    canonical = policy[:canonical]
    host = String.downcase(conn.host || "")

    if is_binary(canonical) and canonical != host and host in List.wrap(policy[:redirect_hosts]) do
      query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

      conn
      |> put_resp_header("location", "https://" <> canonical <> conn.request_path <> query)
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
