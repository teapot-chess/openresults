defmodule OpenResultsWeb.InlineScripts do
  @moduledoc """
  The public pages' inline scripts, and the hashes the Content-Security-Policy
  allows them by (`OpenResultsWeb.Plugs.ContentSecurityPolicy`).

  Each script lives in `inline_scripts/<name>.js` beside this file and is
  read at compile time. `tag/1` writes it into the page between `<script>`
  and `</script>` byte for byte, and `hashes/0` is the SHA-256 of exactly
  those bytes - one source for both, so a page and its header cannot drift
  apart. Editing a script changes its hash on the next compile, and nothing
  else has to be remembered.

  Why hashes and not a nonce: the page cache (`OpenResultsWeb.Plugs.Revalidate`)
  serves one rendered body to every reader of a snapshot, and a nonce has to
  be new on every response. A hash is the same for everyone, so the cache
  keeps working and the policy still refuses any script it did not ship -
  including one that slipped through the escaping inside a player's name.

  The scripts are inline rather than files for the reason the root layout
  gives: the pages must work, and paint the right theme, before any second
  request returns, and every page renders completely with all of them off.
  """

  @dir Path.join(__DIR__, "inline_scripts")

  @names ~w(theme page phone tiebreak_help filter_bar index_search projector)

  for name <- @names, do: @external_resource(Path.join(@dir, name <> ".js"))

  @scripts Map.new(@names, fn name -> {name, File.read!(Path.join(@dir, name <> ".js"))} end)

  @hashes @scripts
          |> Map.values()
          |> Enum.map(&("'sha256-" <> Base.encode64(:crypto.hash(:sha256, &1)) <> "'"))
          |> Enum.sort()

  @doc "The `<script>` element for the script `name`, ready to put in a template."
  @spec tag(String.t()) :: Phoenix.HTML.safe()
  def tag(name) when is_map_key(@scripts, name),
    do: Phoenix.HTML.raw("<script>" <> Map.fetch!(@scripts, name) <> "</script>")

  @doc "Every script's CSP source expression, `'sha256-...'`, sorted."
  @spec hashes() :: [String.t()]
  def hashes, do: @hashes

  @doc "The script names, for tests."
  @spec names() :: [String.t()]
  def names, do: @names
end
