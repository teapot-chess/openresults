defmodule OpenResultsWeb.Format do
  @moduledoc """
  Locale-aware rendering for the two things a translated audit found were
  not translated at all: the decimal separator and the calendar.

  ## What this does not touch

  `en` is untouched, byte for byte - every function here falls straight
  back to today's behaviour (`Float.to_string/1`'s own `.`, the ISO date
  string verbatim) the moment the locale is not `nl` or `fr`. That is the
  scope the 2026-09-12 translations audit's findings 2 and 3 were approved
  for, not a limitation of the approach: nothing stops a later change from
  widening `@comma_locales` and giving `en` a month name of its own, but
  that is a separate decision.

  Nothing that is read back by a script or another program goes through
  this module. A `datetime` attribute, JSON, CSV or any other
  machine-readable surface is the same: this module is for what a reader
  sees, never for what a program parses back. (The standings table used to
  carry `data-points`/`data-value`/`data-rating` for a client-side sort
  script that read them with `parseFloat` - removed when sorting became a
  real `?sort=` request, per `OpenResultsWeb.Tournament.Filter`.)

  ## Why a comma and not a different notation

  The audit's own recommendation, and the one thing this module is
  deliberately narrow about: `5,5`, never `5½`. Chess federations in both
  languages write the fractional point with a comma and nothing else about
  how a score is expressed.

  ## Why gettext carries the month names

  `pgettext/2` under the `"month"` context, so a French or Dutch reviewer
  of the catalogues finds "augustus" and "août" sitting next to every other
  string this site ships rather than in a table only this module knows
  about, and the context keeps a msgid as ordinary as "May" from colliding
  with some unrelated one-word message that already exists.
  """

  use Gettext, backend: OpenResultsWeb.Gettext

  @comma_locales ~w(nl fr)

  @doc """
  A number as `OpenResultsWeb.TournamentHTML.number/1` already renders it,
  with the fractional point swapped for a comma in `nl` and `fr`.

  Takes a string - the module that shapes the value (dropping a trailing
  `.0`, deciding what is not a number at all) is `TournamentHTML.number/1`;
  this only ever touches the separator. Reads the process's own Gettext
  locale when none is given, which is set for the whole render by
  `OpenResultsWeb.Plugs.Locale` before any template runs.

  An integer string has no `.` to find, so this is a no-op for a rating, a
  round number, a pairing number or any other count - exactly the values
  the audit said must never gain a comma.
  """
  def number(string, locale \\ current_locale())

  def number(string, locale) when is_binary(string) and locale in @comma_locales,
    do: String.replace(string, ".", ",")

  def number(string, _locale), do: string

  @doc """
  One date - `"2026-08-29"` - the way this locale writes it: day, month
  name, year. `en` returns the ISO string exactly as it arrived, which is
  what every caller already did before this module existed.

  A date this function cannot parse renders as it arrived rather than
  raising: the snapshot schema is additive-only and old payloads exist, so
  a value in some other shape must not take a public page down. Absent
  (`nil`) passes straight through for the same reason - callers that only
  want to render a date when there is one still do their own `&&` check,
  the same as they did for the raw ISO string before.
  """
  def date(iso, locale \\ current_locale())

  def date(iso, locale) when is_binary(iso) and locale in @comma_locales do
    case Date.from_iso8601(iso) do
      {:ok, date} -> long(date, locale)
      {:error, _reason} -> iso
    end
  end

  def date(iso, _locale), do: iso

  @doc """
  A start and end date as one idiomatic range, the way a tournament
  announcement would write it rather than two full dates joined by a
  word: `"29-31 augustus 2026"` within a month, `"30 augustus - 2
  september 2026"` across months, and the full form on both ends across
  years.

  `en` keeps rendering exactly the sentence it always has -
  `gettext("%{start} to %{finish}", ...)`, whose English catalogue entry is
  blank, so gettext answers with the msgid itself and the two ISO strings
  land in it unchanged. The same sentence is the fallback for `nl` and
  `fr` too, when either date fails to parse - already translated
  (`"%{start} tot %{finish}"`, `"%{start} au %{finish}"`), and exactly what
  a malformed pair rendered as before this module existed.
  """
  def date_range(start_iso, finish_iso, locale \\ current_locale())

  def date_range(start_iso, finish_iso, locale)
      when is_binary(start_iso) and is_binary(finish_iso) and locale in @comma_locales do
    with {:ok, start_date} <- Date.from_iso8601(start_iso),
         {:ok, finish_date} <- Date.from_iso8601(finish_iso) do
      idiomatic_range(start_date, finish_date, locale)
    else
      {:error, _reason} -> fallback_range(start_iso, finish_iso, locale)
    end
  end

  def date_range(start_iso, finish_iso, locale), do: fallback_range(start_iso, finish_iso, locale)

  # `with_locale/3` here too, and not only in `month_name/2` below: this is
  # still a gettext lookup keyed by locale, and a caller that named one
  # explicitly must get that locale's sentence regardless of what the
  # process it is running in happens to be rendering. A no-op the moment
  # `locale` already IS the process's own, which is every request on this
  # site - the plug sets it before anything renders.
  defp fallback_range(start_iso, finish_iso, locale) do
    Gettext.with_locale(OpenResultsWeb.Gettext, locale, fn ->
      gettext("%{start} to %{finish}", start: start_iso, finish: finish_iso)
    end)
  end

  # Same month (and therefore same year, since a Date orders that way): the
  # month name and the year are said once, not twice.
  defp idiomatic_range(
         %Date{year: year, month: month, day: start_day},
         %Date{year: year, month: month, day: finish_day},
         locale
       ) do
    "#{day(start_day, locale)}-#{day(finish_day, locale)} #{month_name(month, locale)} #{year}"
  end

  # Same year, different month: the year still said once, at the end.
  defp idiomatic_range(%Date{year: year} = start_date, %Date{year: year} = finish_date, locale) do
    "#{day(start_date.day, locale)} #{month_name(start_date.month, locale)} - " <>
      "#{day(finish_date.day, locale)} #{month_name(finish_date.month, locale)} #{year}"
  end

  # Different years: nothing left to share, so both ends are the full form.
  defp idiomatic_range(start_date, finish_date, locale) do
    "#{long(start_date, locale)} - #{long(finish_date, locale)}"
  end

  defp long(%Date{} = date, locale),
    do: "#{day(date.day, locale)} #{month_name(date.month, locale)} #{date.year}"

  # French writes the first of the month as an ordinal - "1er septembre" - and
  # every other day as a plain number. Dutch has no such form.
  defp day(1, "fr"), do: "1er"
  defp day(day, _locale), do: Integer.to_string(day)

  # `with_locale/3` rather than trusting the process's own locale to already
  # be `locale`: it very often is (nothing here changes it), but a caller
  # that names a locale explicitly - which the second argument of every
  # function above exists to allow - gets that locale's month name even
  # from a process rendering some other page, and its own locale back
  # afterwards.
  @doc "A month's name, 1-12, in the current language - the statistics page's headings."
  def month_name(month) when month in 1..12, do: month_name(month, current_locale())

  defp month_name(month, locale) do
    Gettext.with_locale(OpenResultsWeb.Gettext, locale, fn -> month(month) end)
  end

  defp month(1), do: pgettext("month", "January")
  defp month(2), do: pgettext("month", "February")
  defp month(3), do: pgettext("month", "March")
  defp month(4), do: pgettext("month", "April")
  defp month(5), do: pgettext("month", "May")
  defp month(6), do: pgettext("month", "June")
  defp month(7), do: pgettext("month", "July")
  defp month(8), do: pgettext("month", "August")
  defp month(9), do: pgettext("month", "September")
  defp month(10), do: pgettext("month", "October")
  defp month(11), do: pgettext("month", "November")
  defp month(12), do: pgettext("month", "December")

  defp current_locale, do: Gettext.get_locale(OpenResultsWeb.Gettext)
end
