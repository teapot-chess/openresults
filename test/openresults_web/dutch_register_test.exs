defmodule OpenResultsWeb.DutchRegisterTest do
  @moduledoc """
  The Dutch catalogue says "je", like every other app in the family. Half of
  it said "u" - the entry form and the terms page mostly, written on a more
  formal day - so a player was tutoyed on the standings and addressed like a
  tax office one click later.
  """
  use ExUnit.Case, async: true

  @catalogues Path.wildcard("priv/gettext/nl/LC_MESSAGES/*.po")

  test "the Dutch catalogues exist" do
    assert @catalogues != []
  end

  test "no Dutch translation uses the formal u/uw" do
    offenders =
      for path <- @catalogues,
          {line, no} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          String.starts_with?(line, "msgstr"),
          Regex.match?(~r/\b(u|U|uw|Uw)\b/u, line),
          do: "#{Path.basename(path)}:#{no}: #{line}"

    assert offenders == []
  end
end
