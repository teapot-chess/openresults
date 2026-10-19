defmodule OpenResultsWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  The public pages' Content-Security-Policy.

  Phoenix's `put_secure_browser_headers/2` sets only `base-uri 'self';
  frame-ancestors 'self'`, which said nothing about scripts: an escaping slip
  in a player's name, a club's name or an arbiter's notice - all of them text
  a stranger can now publish - would have run as this site. This replaces it
  with a policy that lets a page run only `app.js` and the inline scripts the
  site ships, each allowed by its hash (`OpenResultsWeb.InlineScripts`, which
  says why hashes and not a nonce: the page cache).

      default-src 'self'; script-src 'self' 'sha256-...'...;
      style-src 'self' 'unsafe-inline'; img-src 'self' data:;
      font-src 'self' data:; connect-src 'self'; object-src 'none';
      base-uri 'self'; form-action 'self'; frame-ancestors 'self'

  - `style-src 'unsafe-inline'`: the pages put `style` attributes in their
    markup (bar widths, a tie-break tip's position) and LiveView sets them
    too. A style cannot run code; the scripts are what this is about.
  - `img-src data:` and `font-src data:`: the stylesheet draws a few small
    icons as `data:` SVG.
  - `connect-src 'self'`: the refresher, its event stream, the player card,
    the FIDE search and LiveView's socket all talk to this host only.
  - `frame-ancestors 'self'` is the placeholder `OpenResultsWeb.Framing`
    rewrites next, to `PUBLIC_FRAME_ANCESTORS` (default `*`): being
    embeddable is a feature here. This plug must run before it.

  The admin panel has its own, stricter policy (`OpenResultsWeb.Plugs.AdminHeaders`,
  `script-src 'none'`) and does not come through here.
  """

  import Plug.Conn

  @policy Enum.join(
            [
              "default-src 'self'",
              Enum.join(["script-src 'self'" | OpenResultsWeb.InlineScripts.hashes()], " "),
              "style-src 'self' 'unsafe-inline'",
              "img-src 'self' data:",
              "font-src 'self' data:",
              "connect-src 'self'",
              "object-src 'none'",
              "base-uri 'self'",
              "form-action 'self'",
              "frame-ancestors 'self'"
            ],
            "; "
          )

  @doc "The policy, before `OpenResultsWeb.Framing` fills in `frame-ancestors`."
  def policy, do: @policy

  def init(opts), do: opts

  def call(conn, _opts), do: put_resp_header(conn, "content-security-policy", @policy)
end
