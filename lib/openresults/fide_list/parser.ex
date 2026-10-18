defmodule OpenResults.FideList.Parser do
  @moduledoc """
  Reading FIDE's combined rating list (`players_list_foa.txt`) one line at a
  time.

  The file is fixed-width Latin-1 with a header line. The column positions are
  taken from that header every time rather than written down here, so a month
  in which FIDE widens a column produces the right fields instead of quietly
  shifted ones. The same approach OpenPairings has used since it first
  imported the list, and for the same reason: FIDE has changed the layout
  before and did not announce it.

  Bytes are sliced first and converted to UTF-8 after. Converting the line
  first would move every column after an accented name one byte to the left,
  which is how a list ends up with ratings in the birth-year column.
  """

  # The header's labels in file order - "ID Number" is one column despite the
  # space. Every label is needed, not only the ones kept: a column ends where
  # the next one starts.
  @header_labels [
    "ID Number",
    "Name",
    "Fed",
    "Sex",
    "Tit",
    "WTit",
    "OTit",
    "FOA",
    "SRtng",
    "SGm",
    "SK",
    "RRtng",
    "RGm",
    "Rk",
    "BRtng",
    "BGm",
    "BK",
    "B-day",
    "Flag"
  ]

  # What the entry form can use, and nothing else. Sex, the K-factors, game
  # counts and the inactivity flag are in the file and are not anybody's
  # business on a results site.
  @field_labels %{
    fide_id: "ID Number",
    name: "Name",
    federation: "Fed",
    title: "Tit",
    standard_rating: "SRtng",
    rapid_rating: "RRtng",
    blitz_rating: "BRtng",
    birth_year: "B-day"
  }

  @numeric ~w(fide_id standard_rating rapid_rating blitz_rating birth_year)a

  # The largest id SQLite's INTEGER holds is 2^63 - 1, and exqlite raises on
  # anything bigger. No real FIDE id is within nine orders of magnitude of it.
  @max_fide_id 999_999_999_999

  @type offsets :: %{atom() => {non_neg_integer(), non_neg_integer() | :eol}}

  @doc """
  Column offsets from the header line, or `{:error, reason}` when a column is
  missing - which means this is not the file it claims to be.
  """
  @spec offsets(binary()) :: {:ok, offsets()} | {:error, String.t()}
  def offsets(header) when is_binary(header) do
    starts =
      Enum.reduce_while(@header_labels, {%{}, 0}, fn label, {acc, from} ->
        case :binary.match(header, label, scope: {from, byte_size(header) - from}) do
          {idx, len} -> {:cont, {Map.put(acc, label, idx), idx + len}}
          :nomatch -> {:halt, {:missing, label}}
        end
      end)

    case starts do
      {:missing, label} ->
        {:error, "the FIDE list's header has no \"#{label}\" column"}

      {starts, _end} ->
        {:ok,
         Map.new(@field_labels, fn {field, label} ->
           stop =
             case next_label(label) do
               nil -> :eol
               next -> Map.fetch!(starts, next)
             end

           {field, {Map.fetch!(starts, label), stop}}
         end)}
    end
  end

  defp next_label(label) do
    idx = Enum.find_index(@header_labels, &(&1 == label))
    Enum.at(@header_labels, idx + 1)
  end

  @doc """
  One player line as a row for the store, or `nil` for a line that has no
  usable id or name (blank lines, a truncated last line).
  """
  @spec parse_line(binary(), offsets()) :: map() | nil
  def parse_line(line, offsets) do
    row =
      Map.new(offsets, fn {field, {start, stop}} ->
        {field, value(field, slice(line, start, stop))}
      end)

    cond do
      not is_integer(row.fide_id) -> nil
      row.fide_id < 1 or row.fide_id > @max_fide_id -> nil
      row.name == "" -> nil
      true -> Map.put(row, :search_key, search_key(row.name))
    end
  end

  defp slice(line, start, stop) do
    size = byte_size(line)
    len = if stop == :eol, do: size - start, else: stop - start

    if len > 0 and start < size do
      line
      |> binary_part(start, min(len, size - start))
      |> :unicode.characters_to_binary(:latin1, :utf8)
      |> String.trim()
    else
      ""
    end
  end

  defp value(field, raw) when field in @numeric do
    case Integer.parse(raw) do
      # FIDE writes 0 for "no rating in this list" and for "birth year not
      # recorded". Neither is a number anybody should see in a form.
      {0, _} when field != :fide_id -> nil
      {n, _} -> n
      :error -> nil
    end
  end

  defp value(_field, raw), do: raw

  # Letters that Unicode does not decompose, so stripping accents leaves them
  # alone: a player typing "ostergaard" for "Østergaard" would otherwise find
  # nobody.
  @folds %{
    "ø" => "o",
    "æ" => "ae",
    "ß" => "ss",
    "ð" => "d",
    "þ" => "th",
    "œ" => "oe",
    "ł" => "l",
    "đ" => "d"
  }
  @fold_pattern ~r/[øæßðþœłđ]/u

  @doc """
  The form a name is matched in: lower case, accents gone, everything that is
  not a letter or a digit turned into one space. `"De Vos, Ilse"` and
  `"de vos ilse"` both become `"de vos ilse"`, which is what lets a prefix
  index answer a person who never types the comma.
  """
  @spec search_key(String.t()) :: String.t()
  def search_key(text) when is_binary(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(@fold_pattern, &Map.fetch!(@folds, &1))
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end
end
