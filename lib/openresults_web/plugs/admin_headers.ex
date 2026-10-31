defmodule OpenResultsWeb.Plugs.AdminHeaders do
  @moduledoc """
  The response headers every admin page leaves with, and the reverse of the
  public site's on two counts.

  ## Never stored

  `Cache-Control: no-store`. The public pages are `private, no-cache`
  ("always ask first") because a stale standings page is the worst thing a
  results site can show. An admin page is worse to keep than to miss: it
  names installations, addresses and reporters, and a browser's back-forward
  cache or a shared machine's disk is no place for that.

  The admin scope also never passes through `OpenResultsWeb.Plugs.Revalidate`,
  so no ETag is made and nothing reaches the rendered-page cache, which is
  safe only for pages that are byte-identical for every reader.

  ## Never framed

  The public site is embeddable on purpose, and `OpenResultsWeb.Framing`
  argues why: nothing there acts with a visitor's authority. The admin panel
  is the one place where a click does act with somebody's authority, so it is
  the one place clickjacking would work. `frame-ancestors 'none'` for browsers
  that read CSP, `X-Frame-Options: DENY` for the ones that still prefer it.

  ## And the rest

  - `script-src 'none'`: the panel works without JavaScript by design, and
    it will display text strangers typed (report details, tournament names).
    Output is escaped anyway; this makes a slip in that escaping inert.
  - No `form-action`: when an Access session expires, Cloudflare answers the
    next form post with a redirect to its login page, and Chrome applies
    `form-action` to that redirect. The directive would turn "sign in again"
    into a blocked navigation.
  - `X-Robots-Tag: noindex, nofollow`. Access keeps crawlers out; this is
    for the day it does not.

  ## Except the dashboard

  LiveDashboard (`/admin/dashboard`) is a LiveView and cannot run without
  scripts. Its requests carry a per-request nonce
  (`OpenResultsWeb.AdminAccess.LiveDashboard`), and only then is the policy
  `script-src 'nonce-...'`: the dashboard's own tags, nothing inline that
  lacks the nonce, nothing from anywhere else. Style attributes are allowed
  there because its templates use them; everything else is as above.

  Set when the plug runs, so a page rendered from an error keeps them, and
  set again just before sending, so nothing later in the request can loosen
  them by accident.
  """

  import Plug.Conn

  @policy "default-src 'self'; script-src 'none'; object-src 'none'; " <>
            "base-uri 'none'; frame-ancestors 'none'"

  @headers [
    {"cache-control", "no-store"},
    {"x-frame-options", "DENY"},
    {"x-robots-tag", "noindex, nofollow"},
    {"referrer-policy", "same-origin"},
    {"x-content-type-options", "nosniff"},
    {"x-permitted-cross-domain-policies", "none"}
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put()
    |> register_before_send(&put/1)
  end

  @doc "Puts the admin headers on `conn`, replacing whatever was there."
  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    merge_resp_headers(conn, [{"content-security-policy", policy(conn)} | @headers])
  end

  defp policy(%Plug.Conn{private: %{admin_csp_nonce: nonce}}) when is_binary(nonce) do
    "default-src 'self'; script-src 'nonce-#{nonce}'; style-src 'self' 'nonce-#{nonce}'; " <>
      "style-src-attr 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; " <>
      "object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
  end

  defp policy(_conn), do: @policy
end
