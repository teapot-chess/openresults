defmodule OpenResultsWeb.PageScriptsTest do
  @moduledoc """
  The server half of the browser-side script audit of 2026-09-15 - see
  `docs/js-audit-2026-09-15.md`. What the inline scripts compare and match
  against is decided here, in the HTML, so it is tested here.
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.{SnapshotPayloads, Snapshots}

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp doc(conn), do: LazyHTML.from_document(html_response(conn, 200))

  defp version(document) do
    document |> LazyHTML.query("#live-region") |> LazyHTML.attribute("data-version") |> hd()
  end

  defp standings_names(document) do
    document
    |> LazyHTML.query("table.standings > tbody > tr > th.row-head span.name")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "the pause control (WCAG 2.2.2)" do
    test "the page carries a labelled pause button and its words, hidden until the script runs",
         %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())
      document = conn |> get(~p"/t/#{slug}") |> doc()

      button = document |> LazyHTML.query("button#live-pause") |> Enum.to_list() |> hd()
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "hidden") != []
      assert button |> LazyHTML.attribute("data-pause") |> hd() == "Pause live updates"
      assert button |> LazyHTML.attribute("data-resume") |> hd() == "Resume live updates"
      assert LazyHTML.text(button) =~ "Pause live updates"

      status = document |> LazyHTML.query("#live-pause-status") |> Enum.to_list() |> hd()
      assert status |> LazyHTML.attribute("data-many") |> hd() =~ "{n}"
      assert status |> LazyHTML.attribute("data-one") |> hd() =~ "1 update waiting"
    end

    test "the script keeps the choice per visitor, guarded, and holds updates back" do
      script = File.read!("lib/openresults_web/inline_scripts/page.js")

      assert script =~ "openresults:paused"
      assert script =~ "localStorage.setItem(PAUSE_KEY"
      assert script =~ "holdBack(html)"
    end

    test "the Dutch words are in je-form", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      document =
        conn |> put_req_header("accept-language", "nl") |> get(~p"/t/#{slug}") |> doc()

      button = document |> LazyHTML.query("button#live-pause") |> Enum.to_list() |> hd()
      assert button |> LazyHTML.attribute("data-pause") |> hd() == "Live updates pauzeren"
      assert button |> LazyHTML.attribute("data-resume") |> hd() == "Live updates hervatten"
    end
  end

  describe "the refresher's change fingerprint (F1)" do
    test "the same page twice carries the same data-version", %{conn: conn} do
      slug = publish(SnapshotPayloads.swiss())

      first = conn |> get(~p"/t/#{slug}") |> doc() |> version()
      # A filtered request is never served from the page cache, so this one
      # is a fresh render rather than the stored bytes read back.
      again = build_conn() |> get(~p"/t/#{slug}?fed=BEL") |> doc() |> version()
      plain_again = build_conn() |> get(~p"/t/#{slug}?fed=BEL") |> doc() |> version()

      assert is_binary(first) and first != ""
      assert again == plain_again
      refute first == again
    end

    test "a new publish changes it", %{conn: conn} do
      payload = SnapshotPayloads.swiss()
      slug = publish(payload)
      before = conn |> get(~p"/t/#{slug}") |> doc() |> version()

      {:ok, _} = Snapshots.ingest(SnapshotPayloads.republished(payload))
      later = build_conn() |> get(~p"/t/#{slug}") |> doc() |> version()

      refute before == later
    end

    test "the index page has one too", %{conn: conn} do
      publish(SnapshotPayloads.swiss())
      assert conn |> get(~p"/") |> doc() |> version() =~ ~r/^[A-Za-z0-9_-]{16}$/
    end
  end

  describe "the name search agrees with the live row filter (F3)" do
    setup do
      {:ok, slug: publish(SnapshotPayloads.swiss())}
    end

    test "accents are ignored on both sides", %{conn: conn, slug: slug} do
      assert conn |> get(~p"/t/#{slug}?q=muller") |> doc() |> standings_names() == [
               "Müller, Jörg"
             ]

      assert build_conn() |> get(~p"/t/#{slug}?q=angstrom") |> doc() |> standings_names() ==
               ["Ångström, Åsa"]
    end

    test "a name typed first-name-first finds the arbiter's \"Last, First\"", %{
      conn: conn,
      slug: slug
    } do
      assert conn |> get(~p"/t/#{slug}?q=Jean-Baptiste+De+Smet") |> doc() |> standings_names() ==
               ["De Smet, Jean-Baptiste"]
    end

    test "every word must match, so an unrelated second word narrows to nothing", %{
      conn: conn,
      slug: slug
    } do
      assert conn |> get(~p"/t/#{slug}?q=muller+nguyen") |> doc() |> standings_names() == []
    end

    test "on a round, words split between White and Black do not make a match", %{
      conn: conn,
      slug: slug
    } do
      payload = SnapshotPayloads.swiss()
      players = Map.new(payload["players"], &{&1["no"], &1["name"]})
      board = payload["rounds"] |> hd() |> Map.fetch!("boards") |> hd()
      round = payload["rounds"] |> hd() |> Map.fetch!("number")

      white_first = players[board["white"]] |> String.split([",", " "], trim: true) |> hd()
      black_first = players[board["black"]] |> String.split([",", " "], trim: true) |> hd()

      body =
        conn
        |> get(~p"/t/#{slug}/round/#{round}?q=#{white_first <> " " <> black_first}")
        |> html_response(200)

      assert body =~ "No players match these filters."
    end
  end

  test "the filter form carries the live count sentence with its placeholders (F4)", %{
    conn: conn
  } do
    slug = publish(SnapshotPayloads.swiss())

    [sentence] =
      conn
      |> get(~p"/t/#{slug}")
      |> doc()
      |> LazyHTML.query("form[data-filter-form]")
      |> LazyHTML.attribute("data-live-count")

    assert sentence =~ "{shown}"
    assert sentence =~ "{total}"
  end
end
