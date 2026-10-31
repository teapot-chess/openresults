defmodule OpenResultsWeb.HubFeedController do
  @moduledoc """
  A federation's tournaments for other people's software:

    * `GET /f/:code/feed.xml` - Atom: a tournament arriving here, and a
      tournament finishing, one entry each;
    * `GET /f/:code/calendar.ics` - iCalendar: the upcoming tournaments and
      the ones being played, as all-day events. Dates only - this site has
      no round times and does not invent them.

  `/f/none/...` is the tournaments that name no federation, as on the
  listings.

  ## What travels

  Tournaments, never players: a name, the city and the dates where the
  arbiter shows them, and the link. All of it from the results index
  (`OpenResults.ResultsIndex`), which copied each field after the display
  rules, so a hidden city is not in the calendar and a tournament whose
  dates are hidden is not in it at all - an all-day event without a day is
  not an event.

  Approved tournaments only. A pending one is on the listings with an
  "unapproved" mark; a feed entry or a calendar event is copied into
  somebody else's reader, where the mark would not follow it.

  ## Entries are states

  As in `OpenResultsWeb.FeedController`: an entry's id names the state
  (`#published`, `#finished`), so a reader shows each once however often
  the tournament publishes. `published` is dated by the tournament's first
  publish here, `finished` by its newest.

  Cached like the federation's listing (`OpenResultsWeb.HubCache`), under the
  same generation and today's date.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.ResultsIndex
  alias OpenResults.ResultsIndex.Generations
  alias OpenResultsWeb.HubCache
  alias OpenResultsWeb.HubHTML

  def atom(conn, %{"code" => raw}) do
    with_code(conn, raw, fn code ->
      serve(conn, {:atom, code}, code, "application/atom+xml", fn conn ->
        conn
        |> put_resp_content_type("application/atom+xml")
        |> send_resp(200, atom_body(code, Date.utc_today()))
      end)
    end)
  end

  def calendar(conn, %{"code" => raw}) do
    with_code(conn, raw, fn code ->
      serve(conn, {:ics, code}, code, "text/calendar", fn conn ->
        conn
        |> put_resp_header("content-disposition", ~s(inline; filename="#{file(code)}.ics"))
        |> put_resp_content_type("text/calendar")
        |> send_resp(200, calendar_body(code, Date.utc_today()))
      end)
    end)
  end

  defp serve(conn, slot, code, type, render) do
    generation = {Generations.get({:federation, code}), Date.utc_today()}

    HubCache.serve(
      conn,
      {:federation_feed, slot},
      generation,
      conn.query_string == "",
      render,
      type
    )
  end

  # The listing's codes - `BEL`, `none` - in any case; anything else is not
  # an address this route could have meant.
  defp with_code(conn, raw, fun) do
    cond do
      raw == "none" -> fun.(:none)
      is_binary(raw) and raw =~ ~r/\A[A-Za-z]{2,4}\z/ -> fun.(String.upcase(raw))
      true -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found\n")
    end
  end

  defp file(:none), do: "none"
  defp file(code), do: code

  ## ---------- Atom ----------

  defp atom_body(code, today) do
    home = OpenResultsWeb.Endpoint.url() <> HubHTML.federation_path(code)
    label = HubHTML.federation_label(code)

    entries =
      code
      |> ResultsIndex.feed_entries(today)
      |> Enum.flat_map(&states(&1, today))
      |> Enum.sort_by(&elem(&1, 3), {:desc, DateTime})

    updated =
      case entries do
        [{_id, _title, _href, at, _summary} | _] -> at
        [] -> DateTime.utc_now()
      end

    [
      ~s(<?xml version="1.0" encoding="utf-8"?>\n),
      ~s(<feed xmlns="http://www.w3.org/2005/Atom">\n),
      "  <id>",
      esc(home),
      "</id>\n",
      "  <title>",
      esc(gettext("%{federation} - tournaments", federation: label)),
      "</title>\n",
      ~s(  <link rel="alternate" type="text/html" href="#{esc(home)}"/>\n),
      ~s(  <link rel="self" type="application/atom+xml" href="#{esc(home <> "/feed.xml")}"/>\n),
      "  <updated>",
      stamp(updated),
      "</updated>\n",
      "  <author><name>OpenResults</name></author>\n",
      "  <generator>OpenResults</generator>\n",
      Enum.map(entries, &atom_entry/1),
      "</feed>\n"
    ]
  end

  defp states(entry, today) do
    href = url(~p"/t/#{entry.slug}")
    summary = summary(entry)
    first = entry.first_seen || entry.last_published_at

    published =
      {href <> "#published", gettext("%{tournament} is on the site", tournament: entry.name),
       href, first, summary}

    if ResultsIndex.status(entry, today) == :finished do
      finished =
        {href <> "#finished", gettext("%{tournament} has finished", tournament: entry.name), href,
         entry.last_published_at, summary}

      [finished, published]
    else
      [published]
    end
  end

  defp atom_entry({id, title, href, at, summary}) do
    [
      "  <entry>\n",
      "    <id>",
      esc(id),
      "</id>\n",
      "    <title>",
      esc(title),
      "</title>\n",
      ~s(    <link rel="alternate" type="text/html" href="#{esc(href)}"/>\n),
      "    <updated>",
      stamp(at),
      "</updated>\n",
      "    <summary>",
      esc(summary),
      "</summary>\n",
      "  </entry>\n"
    ]
  end

  # What the tournament's own listing row says: where and when, each only
  # where shown.
  defp summary(entry) do
    [entry.city, HubHTML.dates(entry)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> entry.name
      parts -> Enum.join(parts, " · ")
    end
  end

  defp stamp(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp stamp(_unknown), do: stamp(DateTime.utc_now())

  defp esc(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  ## ---------- iCalendar ----------

  defp calendar_body(code, today) do
    host = OpenResultsWeb.Endpoint.host()

    events =
      for entry <- ResultsIndex.calendar_entries(code, today),
          {:ok, start} <- [Date.from_iso8601(entry.start_date)] do
        finish =
          case entry.end_date && Date.from_iso8601(entry.end_date) do
            {:ok, date} -> if Date.compare(date, start) == :lt, do: start, else: date
            _none -> start
          end

        [
          "BEGIN:VEVENT",
          "UID:" <> entry.slug <> "@" <> host,
          "DTSTAMP:" <> ics_stamp(entry.last_published_at),
          "DTSTART;VALUE=DATE:" <> ics_date(start),
          # Exclusive, as RFC 5545 has it for all-day events: the day after.
          "DTEND;VALUE=DATE:" <> ics_date(Date.add(finish, 1)),
          "SUMMARY:" <> ics_text(entry.name)
        ] ++
          if(entry.city, do: ["LOCATION:" <> ics_text(entry.city)], else: []) ++
          ["URL:" <> url(~p"/t/#{entry.slug}"), "TRANSP:TRANSPARENT", "END:VEVENT"]
      end

    lines =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//OpenResults//Results hub//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:" <>
          ics_text(
            gettext("%{federation} - tournaments", federation: HubHTML.federation_label(code))
          )
      ] ++ List.flatten(events) ++ ["END:VCALENDAR"]

    Enum.map(lines, &[fold(&1), "\r\n"])
  end

  defp ics_date(date), do: Calendar.strftime(date, "%Y%m%d")

  defp ics_stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y%m%dT%H%M%SZ")
  defp ics_stamp(_unknown), do: ics_stamp(DateTime.utc_now())

  defp ics_text(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r\n|\r|\n/, "\\n")
  end

  # RFC 5545 3.1: lines longer than 75 octets are folded, the continuation
  # starting with a space - and never inside a character.
  defp fold(line) when byte_size(line) <= 75, do: line

  defp fold(line) do
    {head, rest} = split_at_octets(line, 75)
    [head | fold_rest(rest)]
  end

  defp fold_rest(""), do: []

  defp fold_rest(rest) do
    {head, rest} = split_at_octets(rest, 74)
    ["\r\n ", head | fold_rest(rest)]
  end

  defp split_at_octets(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, size} ->
      if size + byte_size(g) > max,
        do: {:halt, {acc, size}},
        else: {:cont, {acc <> g, size + byte_size(g)}}
    end)
    |> then(fn {head, size} -> {head, binary_part(text, size, byte_size(text) - size)} end)
  end
end
