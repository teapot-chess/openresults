defmodule OpenResultsWeb.TermsHTML do
  @moduledoc """
  The markup for `OpenResultsWeb.TermsController`.

  Every sentence is its own msgid, and a sentence that differs by whether the
  operator has a name, or a contact address, is two whole msgids rather than
  one sentence with a piece swapped in: a translator reorders a sentence, not
  a fragment.
  """

  use OpenResultsWeb, :html

  embed_templates "terms_html/*"

  @doc """
  The operator's contact address as a plain `mailto:` link, fenced for
  Cloudflare.

  Cloudflare's Email Address Obfuscation rewrites every address in an HTML
  response into a "[email protected]" link that its own script decodes. The
  public pages' CSP would let that script run, but the address would still be
  unreadable to anyone without JavaScript, and wrong after the first poll of
  the page refresher (`root.html.heex`), which swaps the region's HTML and
  never runs a script it inserts. `email_off` is Cloudflare's documented
  opt-out, as in the admin layout; the markers must reach the browser, so
  they are HTML comments, not HEEx ones.
  """
  attr :email, :string, required: true
  attr :id, :string, default: "terms-contact-email"

  def contact_link(assigns) do
    ~H"""
    <!--email_off-->
    <a href={"mailto:" <> @email} id={@id}>{@email}</a>
    <!--/email_off-->
    """
  end
end
