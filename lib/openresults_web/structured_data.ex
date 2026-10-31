defmodule OpenResultsWeb.StructuredData do
  @moduledoc """
  The schema.org `SportsEvent` a tournament's pages carry as JSON-LD, so a
  search engine can tell a chess tournament from a page that mentions one.

  What it says is what the page's own share card says (`OpenResultsWeb.Meta`):
  the name, the dates and the city - each only where the arbiter shows it -
  and the address. No players, no organiser, no arbiter, no results: a
  machine-readable copy of a person's name is still a person's name, and
  the point of this block is the event.

  A `data` block, not a script: `application/ld+json` is never executed, so
  the page's Content-Security-Policy does not apply to it and it needs no
  hash in `OpenResultsWeb.InlineScripts`. It is encoded with
  `escape: :html_safe`, which writes `<`, `>`, `&` and `/` as `\\u` escapes,
  so a tournament named `</script>` cannot close the element early.
  """

  alias OpenResultsWeb.Tournament

  @doc "The JSON-LD object for a tournament's pages, as a map."
  @spec sports_event(map(), String.t()) :: map()
  def sports_event(payload, url) do
    info = Tournament.info(payload)
    dates? = Tournament.show?(payload, "dates")
    city = Tournament.show?(payload, "city") && text(info["city"])

    %{
      "@context" => "https://schema.org",
      "@type" => "SportsEvent",
      "name" => Tournament.name(payload),
      "sport" => "Chess",
      "url" => url,
      "eventAttendanceMode" => "https://schema.org/OfflineEventAttendanceMode",
      "eventStatus" => "https://schema.org/EventScheduled"
    }
    |> put("startDate", dates? && date(info["start_date"]))
    |> put("endDate", dates? && date(info["end_date"]))
    |> put(
      "location",
      city &&
        %{
          "@type" => "Place",
          "name" => city,
          "address" => %{"@type" => "PostalAddress", "addressLocality" => city}
        }
    )
  end

  @doc """
  `sports_event/2` encoded for the page's `<script type="application/ld+json">`,
  marked safe: the escaping above is what makes it so.
  """
  @spec encode(map()) :: Phoenix.HTML.safe()
  def encode(object), do: {:safe, Jason.encode!(object, escape: :html_safe)}

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> nil
    end
  end

  defp date(_absent), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_absent), do: nil
end
