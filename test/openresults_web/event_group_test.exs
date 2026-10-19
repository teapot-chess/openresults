defmodule OpenResultsWeb.EventGroupTest do
  @moduledoc """
  An event of several tournaments: the tab strip, the event page and the
  front page's gathering - and, mostly, what this server refuses to take a
  snapshot's word for. See `OpenResults.TournamentGroups`.
  """

  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures,
    only: [installation!: 0, installation!: 1, mint!: 1]

  alias OpenResults.Moderation
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResults.Takedown
  alias OpenResults.TournamentGroups
  alias OpenResultsWeb.EventGroup

  @event "5c1f0e9a7b3d2c4e6f"

  setup do
    TournamentGroups.Epochs.clear()
    :ok
  end

  # One section of the festival: the swiss fixture under `slug`, labelled
  # `label` at `position`, naming `siblings` (`{slug, label}`).
  defp section(slug, label, position, siblings, opts \\ []) do
    SnapshotPayloads.swiss()
    |> put_in(["tournament", "slug"], slug)
    |> put_in(["tournament", "name"], "Gent Spring #{label} 2026")
    |> put_in(["tournament", "listed"], Keyword.get(opts, :listed, true))
    |> put_in(["tournament", "group"], %{
      "id" => Keyword.get(opts, :event, @event),
      "name" => Keyword.get(opts, :event_name, "Gent Spring Festival 2026"),
      "label" => label,
      "position" => position,
      "siblings" =>
        for {sibling, sibling_label} <- siblings do
          %{
            "slug" => sibling,
            "label" => sibling_label,
            "name" => "Gent Spring #{sibling_label} 2026"
          }
        end
    })
  end

  defp publish!(payload, opts \\ []) do
    {:ok, _} = Snapshots.ingest(payload, opts)
    payload["tournament"]["slug"]
  end

  # Open | U20 | U12, each naming the other two.
  defp festival! do
    publish!(section("fest-open", "Open", 1, [{"fest-u20", "U20"}, {"fest-u12", "U12"}]))
    publish!(section("fest-u20", "U20", 2, [{"fest-open", "Open"}, {"fest-u12", "U12"}]))
    publish!(section("fest-u12", "U12", 3, [{"fest-open", "Open"}, {"fest-u20", "U20"}]))
    :ok
  end

  defp doc(conn, path, status \\ 200),
    do: conn |> get(path) |> html_response(status) |> LazyHTML.from_document()

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp tabs(document) do
    document
    |> LazyHTML.query("#event-tabs .event-tab")
    |> Enum.map(fn tab ->
      {tab |> LazyHTML.text() |> String.trim(), tab |> LazyHTML.attribute("href") |> List.first()}
    end)
  end

  describe "the contract fixture" do
    test "carries the block, and reads as the U20 of an event with one sibling" do
      payload = SnapshotPayloads.swiss_grouped()

      assert %{
               id: @event,
               name: "Gent Spring Festival 2026",
               label: "U20",
               position: 2,
               siblings: [
                 %{slug: "gent-spring-open-2026", label: "Open", name: "Gent Spring Open 2026"}
               ]
             } = EventGroup.block(payload)
    end

    test "alone on the server it is an ordinary tournament: no strip, no event page", %{
      conn: conn
    } do
      slug = publish!(SnapshotPayloads.swiss_grouped())

      document = doc(conn, ~p"/t/#{slug}")
      assert count(document, "#event-tabs") == 0
      refute LazyHTML.text(document) =~ "Gent Spring Festival"

      assert conn |> get(~p"/e/#{@event}") |> html_response(404)
    end

    test "beside the sibling it names, both get the strip", %{conn: conn} do
      open =
        SnapshotPayloads.swiss()
        |> put_in(["tournament", "group"], %{
          "id" => @event,
          "name" => "Gent Spring Festival 2026",
          "label" => "Open",
          "position" => 1,
          "siblings" => [
            %{
              "slug" => "gent-spring-u20-2026",
              "label" => "U20",
              "name" => "Gent Spring U20 2026"
            }
          ]
        })
        |> publish!()

      u20 = publish!(SnapshotPayloads.swiss_grouped())

      assert conn |> doc(~p"/t/#{open}") |> tabs() == [{"Open", nil}, {"U20", "/t/#{u20}"}]
      assert conn |> doc(~p"/t/#{u20}") |> tabs() == [{"Open", "/t/#{open}"}, {"U20", nil}]
    end
  end

  describe "the tab strip" do
    test "lists the event's tournaments in order, the open one marked and not a link", %{
      conn: conn
    } do
      festival!()
      document = doc(conn, ~p"/t/fest-u20")

      assert tabs(document) == [{"Open", "/t/fest-open"}, {"U20", nil}, {"U12", "/t/fest-u12"}]
      assert count(document, "#event-tabs span.event-tab.current[aria-current]") == 1
      assert count(document, ~s(#event-link[href="/e/#{@event}"])) == 1

      assert document |> LazyHTML.query("#event-link") |> LazyHTML.text() =~
               "Gent Spring Festival 2026"
    end

    test "opens the same page of the sibling where it has one, its overview where not", %{
      conn: conn
    } do
      festival!()

      # The U12 has no round 5 and no cross-table.
      "fest-u12"
      |> section("U12", 3, [{"fest-open", "Open"}, {"fest-u20", "U20"}])
      |> update_in(["rounds"], fn rounds -> Enum.reject(rounds, &(&1["number"] == 5)) end)
      |> put_in(["tournament", "display", "crosstable"], false)
      |> publish!()

      assert conn |> doc(~p"/t/fest-open/round/5") |> tabs() == [
               {"Open", nil},
               {"U20", "/t/fest-u20/round/5"},
               {"U12", "/t/fest-u12"}
             ]

      assert conn |> doc(~p"/t/fest-open/round/1") |> tabs() |> List.last() ==
               {"U12", "/t/fest-u12/round/1"}

      assert conn |> doc(~p"/t/fest-open/crosstable") |> tabs() == [
               {"Open", nil},
               {"U20", "/t/fest-u20/crosstable"},
               {"U12", "/t/fest-u12"}
             ]

      # A page that belongs to one tournament - a player's card - has no twin.
      assert conn |> doc(~p"/t/fest-open/player/1") |> tabs() |> Enum.map(&elem(&1, 1)) ==
               [nil, "/t/fest-u20", "/t/fest-u12"]
    end

    test "a snapshot without the block renders exactly as before", %{conn: conn} do
      slug = publish!(SnapshotPayloads.swiss())
      document = doc(conn, ~p"/t/#{slug}")

      assert count(document, "#event-tabs") == 0
      assert count(document, ".event-tab") == 0
    end

    test "is not on the full-screen views", %{conn: conn} do
      festival!()

      for path <- [
            "/t/fest-open/hall",
            "/t/fest-open/live/5/all",
            "/t/fest-open/live/5/projector"
          ] do
        html = conn |> get(path) |> html_response(200)
        refute html =~ "event-tabs", path
      end
    end
  end

  describe "what a snapshot may not decide" do
    test "a sibling that is not on this server is not shown - not even its label", %{conn: conn} do
      publish!(section("fest-open", "Open", 1, [{"fest-u20", "U20"}, {"fest-ghost", "Ghost-U8"}]))
      publish!(section("fest-u20", "U20", 2, [{"fest-open", "Open"}]))

      document = doc(conn, ~p"/t/fest-open")
      assert tabs(document) == [{"Open", nil}, {"U20", "/t/fest-u20"}]
      refute LazyHTML.text(document) =~ "Ghost"
    end

    test "a sibling whose own snapshot does not claim the event is not shown", %{conn: conn} do
      publish!(section("fest-open", "Open", 1, [{"fest-victim", "U20"}]))
      # Published, public, same publisher - and it never said it was part of this.
      SnapshotPayloads.swiss() |> put_in(["tournament", "slug"], "fest-victim") |> publish!()

      assert conn |> doc(~p"/t/fest-open") |> count("#event-tabs") == 0
      assert conn |> doc(~p"/t/fest-victim") |> count("#event-tabs") == 0
      assert conn |> get(~p"/e/#{@event}") |> html_response(404)
    end

    test "a sibling left behind by a newer snapshot is dropped at once", %{conn: conn} do
      festival!()
      # The U12 leaves the event: its next snapshot carries no block.
      SnapshotPayloads.swiss() |> put_in(["tournament", "slug"], "fest-u12") |> publish!()

      # The Open's own snapshot still names it, and the strip does not.
      assert conn |> doc(~p"/t/fest-open") |> tabs() == [{"Open", nil}, {"U20", "/t/fest-u20"}]
    end

    test "another publisher cannot join an event by naming it", %{conn: conn} do
      festival!()

      {squatter, _key} = installation!()
      fake = mint!(squatter)

      fake
      |> section("Fake", 1, [{"fest-open", "Open"}, {"fest-u20", "U20"}])
      |> publish!(installation: squatter)

      # Not on the real sections' strips, not on the event page ...
      assert conn |> doc(~p"/t/fest-open") |> tabs() |> Enum.map(&elem(&1, 0)) == [
               "Open",
               "U20",
               "U12"
             ]

      event = doc(conn, ~p"/e/#{@event}")
      assert count(event, ".event-card") == 3
      assert count(event, "#event-card-#{fake}") == 0

      # ... and the real sections are not on the squatter's page either.
      assert conn |> doc(~p"/t/#{fake}") |> count("#event-tabs") == 0
    end

    test "two tournaments of another publisher claiming a taken id get no event page of their own",
         %{conn: conn} do
      festival!()
      {squatter, _key} = installation!({198, 51, 100, 21})
      a = mint!(squatter)
      b = mint!(squatter)
      a |> section("Fake A", 1, [{b, "Fake B"}]) |> publish!(installation: squatter)
      b |> section("Fake B", 2, [{a, "Fake A"}]) |> publish!(installation: squatter)

      event = doc(conn, ~p"/e/#{@event}")
      assert count(event, ".event-card") == 3
      refute LazyHTML.text(event) =~ "Fake"
    end

    test "the event stays its first publisher's when that publisher's sections are gone", %{
      conn: conn
    } do
      # The 2026-10-19 sweep: the first claim used to be worked out from the
      # tournaments still claiming the id, so hiding the real sections handed
      # the event page to whoever had copied the id since.
      festival!()
      {squatter, _key} = installation!({198, 51, 100, 22})
      a = mint!(squatter)
      b = mint!(squatter)
      a |> section("Fake A", 1, [{b, "Fake B"}]) |> publish!(installation: squatter)
      b |> section("Fake B", 2, [{a, "Fake A"}]) |> publish!(installation: squatter)

      admin = %{email: "admin@example.invalid"}
      for slug <- ~w(fest-open fest-u20 fest-u12), do: {:ok, _} = Moderation.hide(slug, admin)

      assert TournamentGroups.owners([@event]) == %{@event => nil}
      assert TournamentGroups.member_slugs(@event) == []
      assert conn |> get(~p"/e/#{@event}") |> html_response(404)

      # Deleted rather than hidden: the same.
      for slug <- ~w(fest-open fest-u20 fest-u12), do: {:ok, _} = Moderation.delete(slug, admin)
      assert TournamentGroups.member_slugs(@event) == []
    end

    test "an operator's transfer takes the event along, once the last section has moved" do
      festival!()
      {organiser, _key} = installation!({198, 51, 100, 23})
      admin = %{email: "admin@example.invalid"}

      {:ok, _} = Moderation.transfer("fest-open", organiser.id, admin)
      # The operator token still publishes two of its sections.
      assert TournamentGroups.owners([@event]) == %{@event => nil}

      {:ok, _} = Moderation.transfer("fest-u20", organiser.id, admin)
      {:ok, _} = Moderation.transfer("fest-u12", organiser.id, admin)
      assert TournamentGroups.owners([@event]) == %{@event => organiser.id}
      assert TournamentGroups.member_slugs(@event) == ~w(fest-open fest-u20 fest-u12)
    end

    test "a tournament moderation hid leaves its siblings' strips and the event page", %{
      conn: conn
    } do
      festival!()
      assert conn |> doc(~p"/t/fest-open") |> tabs() |> length() == 3

      {:ok, _} = Moderation.hide("fest-u12", %{email: "admin@example.invalid"})

      document = doc(conn, ~p"/t/fest-open")
      assert tabs(document) == [{"Open", nil}, {"U20", "/t/fest-u20"}]
      refute LazyHTML.text(document) =~ "U12"

      event = doc(conn, ~p"/e/#{@event}")
      assert count(event, ".event-card") == 2
      refute LazyHTML.text(event) =~ "U12"
    end

    test "a link-only section is not linked from a listed one", %{conn: conn} do
      publish!(section("fest-open", "Open", 1, [{"fest-u20", "U20"}], listed: true))
      publish!(section("fest-u20", "U20", 2, [{"fest-open", "Open"}], listed: false))

      assert conn |> doc(~p"/t/fest-open") |> count("#event-tabs") == 0
      # The link-only one may point at the listed one.
      assert conn |> doc(~p"/t/fest-u20") |> tabs() == [{"Open", "/t/fest-open"}, {"U20", nil}]
      # And the event page, which the listed one would link, shows no link-only section.
      assert conn |> get(~p"/e/#{@event}") |> html_response(404)
    end

    test "a malformed block is no block", %{conn: conn} do
      for group <- [
            "Open",
            %{"id" => "x", "name" => "Too short an id", "siblings" => []},
            %{"id" => "../../etc/passwd", "name" => "Not an id"},
            %{"id" => @event, "siblings" => [%{"slug" => "fest-u20"}]},
            %{"id" => @event, "name" => "", "siblings" => [%{"slug" => "fest-u20"}]}
          ] do
        payload = SnapshotPayloads.swiss() |> put_in(["tournament", "group"], group)
        assert EventGroup.block(payload) == nil
      end

      slug = SnapshotPayloads.swiss() |> put_in(["tournament", "group"], "Open") |> publish!()
      assert conn |> doc(~p"/t/#{slug}") |> count("#event-tabs") == 0
    end
  end

  describe "a cached page" do
    test "is not served again once a sibling changed", %{conn: conn} do
      festival!()

      first = get(conn, ~p"/t/fest-open")
      [etag] = get_resp_header(first, "etag")
      assert html_response(first, 200) =~ "U12"

      # Unchanged: the reader's copy is still good.
      assert conn
             |> put_req_header("if-none-match", etag)
             |> get(~p"/t/fest-open")
             |> response(304)

      # The U12 is taken down. Nothing was published for the Open.
      Takedown.purge("fest-u12")

      again = conn |> put_req_header("if-none-match", etag) |> get(~p"/t/fest-open")
      assert [new_etag] = get_resp_header(again, "etag")
      assert new_etag != etag
      refute html_response(again, 200) =~ "U12"
    end

    test "moves when a sibling publishes a round this page links to", %{conn: conn} do
      festival!()
      [etag] = conn |> get(~p"/t/fest-open/round/5") |> get_resp_header("etag")

      "fest-u12"
      |> section("U12", 3, [{"fest-open", "Open"}, {"fest-u20", "U20"}])
      |> update_in(["rounds"], fn rounds -> Enum.reject(rounds, &(&1["number"] == 5)) end)
      |> publish!()

      again = conn |> put_req_header("if-none-match", etag) |> get(~p"/t/fest-open/round/5")

      assert again |> html_response(200) |> LazyHTML.from_document() |> tabs() |> List.last() ==
               {"U12", "/t/fest-u12"}
    end

    test "an unchanged re-send of a section moves nothing", %{conn: conn} do
      festival!()
      [etag] = conn |> get(~p"/t/fest-open") |> get_resp_header("etag")

      publish!(section("fest-u12", "U12", 3, [{"fest-open", "Open"}, {"fest-u20", "U20"}]))

      assert conn
             |> put_req_header("if-none-match", etag)
             |> get(~p"/t/fest-open")
             |> response(304)
    end

    test "a tournament in no event has no epoch to move" do
      slug = publish!(SnapshotPayloads.swiss())
      assert TournamentGroups.epoch(slug) == 0
      assert TournamentGroups.sibling_slugs(slug) == []
    end
  end

  describe "the event page" do
    test "lists the tournaments as cards, in the event's order", %{conn: conn} do
      festival!()
      document = doc(conn, ~p"/e/#{@event}")

      assert document |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Gent Spring Festival 2026"

      assert document
             |> LazyHTML.query(".event-card-link")
             |> LazyHTML.attribute("href") == ["/t/fest-open", "/t/fest-u20", "/t/fest-u12"]

      assert document
             |> LazyHTML.query(".event-card-label")
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == ["Open", "U20", "U12"]

      players = length(SnapshotPayloads.swiss()["players"])

      assert document
             |> LazyHTML.query("#event-card-fest-open .event-card-players")
             |> LazyHTML.text()
             |> String.trim() == to_string(players)

      assert count(document, "#event-card-fest-open .event-card-round") == 1
      assert count(document, "#event-card-fest-open .event-badge") == 1
    end

    test "an unknown id, and junk, are the same 404", %{conn: conn} do
      assert conn |> get(~p"/e/nobody-claims-this") |> html_response(404) =~ "no event"
      assert conn |> get("/e/%2e%2e") |> html_response(404)
    end

    test "goes when only one tournament is left", %{conn: conn} do
      publish!(section("fest-open", "Open", 1, [{"fest-u20", "U20"}]))
      publish!(section("fest-u20", "U20", 2, [{"fest-open", "Open"}]))
      assert conn |> get(~p"/e/#{@event}") |> html_response(200)

      Takedown.purge("fest-u20")
      assert conn |> get(~p"/e/#{@event}") |> html_response(404)
    end
  end

  describe "the front page" do
    test "gathers an event's tournaments under its name", %{conn: conn} do
      festival!()
      alone = SnapshotPayloads.swiss() |> put_in(["tournament", "slug"], "alone") |> publish!()

      document = doc(conn, ~p"/")

      assert count(document, ~s(li.event-entry[data-event="#{@event}"])) == 1
      assert count(document, ~s(li.event-entry > a[href="/e/#{@event}"])) == 1

      assert document
             |> LazyHTML.query("li.event-entry .event-sections a")
             |> LazyHTML.attribute("href") == ["/t/fest-open", "/t/fest-u20", "/t/fest-u12"]

      # Each section is found by its own name in the search, through the event's row.
      [names] = document |> LazyHTML.query("li.event-entry") |> LazyHTML.attribute("data-name")
      assert names =~ "Gent Spring Festival 2026"
      assert names =~ "Gent Spring U12 2026"

      # The tournament in no event is a row of its own, as before.
      assert count(document, ~s{.tournaments > li:not(.event-entry) > a[href="/t/#{alone}"]}) == 1
    end

    test "an event with one listed tournament is just that tournament", %{conn: conn} do
      publish!(section("fest-open", "Open", 1, [{"fest-u20", "U20"}], listed: true))
      publish!(section("fest-u20", "U20", 2, [{"fest-open", "Open"}], listed: false))

      document = doc(conn, ~p"/")
      assert count(document, "li.event-entry") == 0
      assert count(document, ~s(.tournaments > li > a[href="/t/fest-open"])) == 1
      refute LazyHTML.text(document) =~ "U20"
      refute LazyHTML.text(document) =~ "Festival"
    end

    test "without events the page is what it was", %{conn: conn} do
      slug = publish!(SnapshotPayloads.swiss())
      document = doc(conn, ~p"/")

      assert count(document, "li.event-entry") == 0
      assert count(document, ~s(.tournaments > li > a[href="/t/#{slug}"])) == 1
    end
  end
end
