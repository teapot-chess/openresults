defmodule OpenResultsWeb.Plugs.AdminSession do
  @moduledoc """
  A session and CSRF protection, for `/admin` and nowhere else.

  ## Why here and not in the endpoint

  The router explains why the public site has neither: no accounts, nothing
  a forged request could borrow, and every response cookie-free. The admin
  panel is the first thing here that acts on somebody's behalf, so it brings
  both back - but only for itself.

  Until this plug existed `Plug.Session` sat in the endpoint, so every
  request carried a session that nothing fetched. That was cookie-free only
  because nobody had yet called `fetch_session`; one `put_flash` on a public
  page would have put a site-wide cookie on it. The session now lives only
  in this plug, and on a public route `fetch_session` raises instead of
  quietly succeeding.

  ## The cookie

  Its own name, so it can never be confused with anything the public side
  sets. `Path=/admin`, so the browser does not even send it anywhere else.
  `Secure` always - production is HTTPS at Cloudflare's edge even though the
  tunnel speaks HTTP to this app, and browsers accept a `Secure` cookie from
  `localhost` for development. `HttpOnly`. `SameSite=Strict`, which a link
  from another site into the panel would only cost a second click. No
  `max_age`: it ends with the browser session, and Cloudflare Access decides
  how long a sign-in lasts anyway. Signed and encrypted.

  It holds the CSRF token and flash messages, and - after a LiveDashboard
  page - a stamp of who loaded it and when. Who is signed in is never read
  from it for an HTTP request: that is re-established from the Access token
  on every request, by `OpenResultsWeb.Plugs.AdminAuth`. The stamp is only
  for the dashboard's socket, which never sees that token; see
  `OpenResultsWeb.AdminAccess.LiveDashboard`.

  ## A refused token keeps the admin headers

  An exception raised by a pipeline plug reaches the endpoint's error
  renderer with the connection as it was when the request came in, which
  would send the CSRF refusal out without `Cache-Control: no-store` and
  without the framing headers. Re-raised here wrapped around the connection
  as it entered this plug, the error page keeps what
  `OpenResultsWeb.Plugs.AdminHeaders` already put on it.
  """

  use Plug.Builder

  import Phoenix.Controller, only: [fetch_flash: 2, protect_from_forgery: 2]

  @session_options [
    store: :cookie,
    key: "_openresults_admin",
    signing_salt: "or-admin-sign",
    encryption_salt: "or-admin-encrypt",
    path: "/admin",
    secure: true,
    http_only: true,
    same_site: "Strict"
  ]

  plug Plug.Session, @session_options
  plug :fetch_session
  plug :fetch_flash
  plug :protect_from_forgery

  @impl Plug
  def call(conn, opts) do
    super(conn, opts)
  catch
    kind, reason -> Plug.Conn.WrapperError.reraise(conn, kind, reason, __STACKTRACE__)
  end

  @doc "The session cookie's options. Exposed for the tests that check its attributes."
  def session_options, do: @session_options
end
