defmodule OpenResultsWeb.AdminAccess.LiveDashboard do
  @moduledoc """
  What lets Phoenix LiveDashboard live inside the admin panel: a plug for the
  HTTP request, an `on_mount` hook for the socket, and the reason both exist.

  ## The problem

  Every other admin page is one HTTP request, and `OpenResultsWeb.Plugs.AdminAuth`
  checks the Cloudflare Access token on each. LiveDashboard is a LiveView: the
  first render is an HTTP request through the same `:admin` pipeline, and
  everything after that is a WebSocket the router never sees. A socket does
  not get the token - Phoenix hands a socket a fixed set of request details,
  and `Cf-Access-Jwt-Assertion` is not one of them.

  ## What holds the socket

    1. **Its path.** The dashboard's socket is `/admin/live`, not the public
       `/live` the hall display uses, so the WebSocket upgrade goes through
       the same Cloudflare Access application as every other `/admin` path.
       Nobody without an Access session reaches it at all.
    2. **The admin session cookie and its CSRF token.** The socket is
       declared with `OpenResultsWeb.Plugs.AdminSession`'s cookie as its
       session, so LiveView refuses a connection whose CSRF token does not
       match that cookie - and the cookie is `Path=/admin`, `SameSite=Strict`,
       and only ever issued behind `AdminAuth`.
    3. **A stamp in that session, checked on every mount.** `call/2` writes
       the admitted email and the time into the session on each dashboard
       request that passed `AdminAuth`; `on_mount/4` refuses a mount without
       one, with one older than #{12} hours, or with an email that is no
       longer on `OPENRESULTS_ADMIN_EMAILS`. Removing an address therefore
       closes the dashboard at the next mount, as it closes every other page
       at the next request.

  The stamp is the one place the admin session carries an identity. It is
  never used to admit an HTTP request - `AdminAuth` still decides those from
  the token, every time - only to let a socket follow a page that was.

  ## Its scripts

  The panel's CSP is `script-src 'none'`. The dashboard cannot work without
  scripts, so its pages - and only its pages - get a per-request nonce
  (`:csp_nonce`, which LiveDashboard puts on its own script and style tags)
  and a policy that allows that nonce and nothing else. See
  `OpenResultsWeb.Plugs.AdminHeaders.put/1`.
  """

  @behaviour Plug

  import Plug.Conn

  alias OpenResultsWeb.AdminAccess.Config

  @session_key "admin_dashboard"
  @max_age_seconds 12 * 3600

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_private(:admin_csp_nonce, nonce)
    |> put_session(@session_key, %{
      "email" => conn.assigns.admin.email,
      "at" => System.system_time(:second)
    })
  end

  @doc false
  # The `on_mount` hook named in the router's `live_dashboard` call.
  def on_mount(:admin, _params, session, socket) do
    if admitted?(session[@session_key]) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/admin")}
    end
  end

  @doc false
  # Public for the tests.
  def admitted?(stamp, now \\ System.system_time(:second))

  def admitted?(%{"email" => email, "at" => at}, now)
      when is_binary(email) and is_integer(at) do
    now - at < @max_age_seconds and at <= now + 60 and still_allowed?(email)
  end

  def admitted?(_stamp, _now), do: false

  defp still_allowed?(email) do
    case Config.dev_bypass() do
      {:ok, bypass_email} ->
        email == bypass_email

      :off ->
        case Config.fetch() do
          {:ok, config} -> Config.allowed?(config, email)
          :unconfigured -> false
        end
    end
  end
end
