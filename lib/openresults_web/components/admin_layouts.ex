defmodule OpenResultsWeb.Admin.Layouts do
  @moduledoc """
  The admin panel's own root layout, and nothing borrowed from the public one.

  The public layout carries a theme picker, a language picker, a 20-second
  refresher and a player-card script. None of that belongs here, and all of
  it is JavaScript this panel promises not to need. What it keeps is the
  stylesheet and the mark, so it still looks like the same site - and an
  inverted bar with an ADMIN badge, so it is never mistaken for a public page.

  English only, on purpose: the panel has two users. Its text is not wrapped
  in gettext and should not be.
  """
  use OpenResultsWeb, :html

  embed_templates "admin_layouts/*"

  # Every section the panel is planned to have, in order. Only those with a
  # GET route in `OpenResultsWeb.Router` are rendered - see `nav_items/1` - so
  # a section appears in the navigation the moment its page is routed, and
  # never before. Paths are plain strings rather than `~p` for exactly that
  # reason: `~p` would refuse to compile a link to a page that does not exist
  # yet, which is the point of this list.
  @sections [
    {"Dashboard", "/admin"},
    {"Tournaments", "/admin/tournaments"},
    {"Installations", "/admin/installations"},
    {"Reports", "/admin/reports"},
    {"Address blocks", "/admin/address-blocks"},
    {"Players", "/admin/players"},
    {"Action log", "/admin/action-log"},
    {"Stats", "/admin/stats"},
    {"System", "/admin/system"},
    {"Settings", "/admin/settings"}
  ]

  @doc "The page's title, then the panel's."
  def title(assigns) do
    [assigns[:page_title], "OpenResults admin"] |> Enum.reject(&is_nil/1) |> Enum.join(" - ")
  end

  @doc """
  The navigation entries that lead somewhere: every planned section whose
  path has a GET route, marked current when the request is on that section.

  No dead links, by construction rather than by remembering.
  """
  @spec nav_items(Plug.Conn.t()) :: [%{label: String.t(), path: String.t(), current?: boolean()}]
  def nav_items(%Plug.Conn{} = conn) do
    here = String.trim_trailing(conn.request_path, "/")

    for {label, path} <- @sections, routed?(conn, path) do
      %{label: label, path: path, current?: current?(here, path)}
    end
  end

  @doc "Every planned section, routed or not. For the test that keeps the list honest."
  def sections, do: @sections

  defp routed?(conn, path) do
    case Phoenix.Router.route_info(OpenResultsWeb.Router, "GET", path, conn.host) do
      %{} -> true
      :error -> false
    end
  end

  # The dashboard is current only on itself; any other section also on the
  # pages beneath it (a tournament's own page lights up "Tournaments").
  defp current?(here, "/admin"), do: here == "/admin"
  defp current?(here, path), do: here == path or String.starts_with?(here, path <> "/")

  @doc "The flash messages worth showing, in a fixed order."
  def flash_messages(assigns) do
    flash = assigns[:flash] || %{}

    for kind <- ["info", "error"],
        message <- [Phoenix.Flash.get(flash, kind)],
        is_binary(message),
        do: {kind, message}
  end
end
