defmodule OpenResultsWeb.Framing do
  @moduledoc """
  Lets a club site put these pages in an iframe.

  Phoenix's `put_secure_browser_headers/2` sets
  `content-security-policy: base-uri 'self'; frame-ancestors 'self'`, which is
  the right default for an application with a login. Since the 2026-10-19
  sweep `OpenResultsWeb.Plugs.ContentSecurityPolicy` replaces that with the
  full policy, keeping `frame-ancestors 'self'` for this plug to rewrite. This site has neither a
  login nor a session, and being embeddable is one of the things it is for -
  a club front page showing its own tournament's standings is the ordinary
  case, not an edge one.

  The arbiter's app used to serve three embeddable public pages behind a
  careful argument about which routes qualified. Those pages moved here on
  2026-08-29 and the argument moved with them, but the header did not: the
  framework default silently blocked every embed, and nothing tested it - so
  the feature was reported as surviving the move when it had not.

  ## Why this is safe here and was not there

  Clickjacking steals authority the victim already holds: an invisible frame,
  a stray click, and something happens as them. Every page on this site holds
  none. There is no session, no cookie, nothing a visitor is signed in to,
  and the two things that write - the entry form and the FIDE search it
  borrows - take no authority from the visitor either. A framing page gains
  nothing it could not get by fetching the same URL itself.

  That argument covers the whole site rather than a list of routes, which is
  why this is a plug on the browser pipeline and not an opt-in a new route
  has to remember to ask for. The list was the fragile part last time.

  ## Configuring it

  `PUBLIC_FRAME_ANCESTORS`, default `*`. Set it to a space-separated origin
  list to restrict embedding to particular sites, or to `'none'` to switch it
  off entirely without touching the router.

  Every other directive is left exactly as the policy plug set it. Only the
  one changes, so this cannot loosen anything else by accident.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    # Phoenix does not set this, but a reverse proxy or a custom header map
    # might, and the older header has no syntax for "these origins" - a stray
    # SAMEORIGIN would silently override the CSP in browsers that prefer it.
    |> delete_resp_header("x-frame-options")
    |> rewrite()
  end

  defp rewrite(conn) do
    case get_resp_header(conn, "content-security-policy") do
      [policy | _] ->
        put_resp_header(
          conn,
          "content-security-policy",
          String.replace(policy, "frame-ancestors 'self'", "frame-ancestors #{ancestors()}")
        )

      [] ->
        conn
    end
  end

  defp ancestors do
    :openresults
    |> Application.get_env(:public_frame_ancestors, "*")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "'none'"
      value -> value
    end
  end
end
