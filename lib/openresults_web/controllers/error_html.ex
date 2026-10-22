defmodule OpenResultsWeb.ErrorHTML do
  @moduledoc """
  The pages a reader gets when nothing else answered: an address no route
  knows (404) and a crash (500).

  These were the generator's two bare words, "Not Found", on an unstyled
  white page with no way back - which is what a reader got from a mistyped
  tournament link shared in a club's group chat. Now a sentence in the
  reader's language and a link to the front page.

  The language comes from `Accept-Language` alone, never a cookie: an
  unknown route runs no plug, so there is nothing fetched to read, and the
  admin gate (`OpenResultsWeb.Plugs.AdminAuth`) relies on its refusal being
  byte-for-byte this same page. Both are rendered from the same header by
  the same function, so they stay identical.

  The strings are computed before the template and the whole page is
  rendered to iodata inside `Gettext.with_locale/3`, because a HEEx
  template's dynamic parts are evaluated lazily and would otherwise be
  translated after the locale was put back.
  """
  use OpenResultsWeb, :html

  alias OpenResultsWeb.Locale

  def render("404.html", assigns), do: page(assigns, 404)
  def render("500.html", assigns), do: page(assigns, 500)

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  defp page(assigns, status) do
    locale = locale(assigns[:conn])

    Gettext.with_locale(OpenResultsWeb.Gettext, locale, fn ->
      %{
        locale: locale,
        heading: heading(status),
        message: message(status),
        home: gettext("Go to the front page")
      }
      |> error_page()
      |> Phoenix.HTML.Safe.to_iodata()
      |> safe()
    end)
  end

  # Already escaped: this is the HEEx engine's own output, rendered now
  # rather than later so the locale above still applies.
  defp safe(iodata), do: {:safe, iodata}

  defp locale(%Plug.Conn{} = conn) do
    header = conn |> Plug.Conn.get_req_header("accept-language") |> List.first()
    Locale.resolve(nil, nil, header)
  end

  defp locale(_no_conn), do: Locale.default()

  defp heading(404), do: gettext("Page not found")
  defp heading(500), do: gettext("Something went wrong")

  defp message(404),
    do:
      gettext(
        "Nothing is published at this address. The link may be mistyped, or the tournament may have been taken down."
      )

  defp message(500),
    do:
      gettext(
        "This page could not be shown because of a fault at our end. Try again in a minute; the results themselves are not affected."
      )

  defp error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={@locale}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@heading} - OpenResults</title>
        <link rel="icon" href={~p"/favicon.svg"} type="image/svg+xml" />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body>
        <main id="main">
          <header class="masthead">
            <h1 id="error-heading">{@heading}</h1>
          </header>
          <section>
            <p class="empty" id="error-message">{@message}</p>
            <p><a id="error-home" href={~p"/"}>{@home}</a></p>
          </section>
        </main>
      </body>
    </html>
    """
  end
end
