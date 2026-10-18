defmodule OpenResultsWeb.RegistrationWorkflowTest do
  @moduledoc """
  The entry form's own settings - the window, the size of the field and the
  public entry list - and the two guards added with them: the honeypot and
  the national ID. See `docs/snapshot-schema.md`, "The entry form's own
  settings".
  """
  use OpenResultsWeb.ConnCase

  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots
  alias OpenResultsWeb.Tournament

  @email "window.test@example.invalid"

  setup do
    RateLimit.reset()
    :ok
  end

  defp publish(payload) do
    {:ok, _} = Snapshots.ingest(payload)
    payload["tournament"]["slug"]
  end

  defp with_settings(payload, settings) do
    payload
    |> put_in(["tournament", "registration_open"], true)
    |> put_in(["tournament", "registration"], settings)
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp in_hours(n), do: DateTime.add(DateTime.utc_now(), n * 3600, :second)

  defp entry(overrides \\ %{}) do
    Map.merge(%{"name" => "Janssens, Lotte", "email" => @email}, overrides)
  end

  defp submit(conn, slug, attrs), do: post(conn, ~p"/t/#{slug}/register", registration: attrs)

  defp doc(conn, status), do: LazyHTML.from_document(html_response(conn, status))

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  describe "the window" do
    test "before it opens, the form says when and takes nothing", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss() |> with_settings(%{"opens_at" => iso(in_hours(24))}) |> publish()

      document = conn |> get(~p"/t/#{slug}/register") |> doc(403)
      assert count(document, "#entries-closed[data-reason=not_yet]") == 1
      assert count(document, "form#registration-form") == 0

      assert conn |> submit(slug, entry()) |> html_response(403)
      assert Registrations.list_for_tournament(slug) == []
    end

    test "once its closing time has passed, the form is shut", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"closes_at" => iso(in_hours(-1))})
        |> publish()

      document = conn |> get(~p"/t/#{slug}/register") |> doc(403)
      assert count(document, "#entries-closed[data-reason=ended]") == 1

      assert conn |> submit(slug, entry()) |> html_response(403)
      assert Registrations.list_for_tournament(slug) == []
    end

    test "inside it, the form takes entries and says when it closes", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"opens_at" => iso(in_hours(-1)), "closes_at" => iso(in_hours(24))})
        |> publish()

      document = conn |> get(~p"/t/#{slug}/register") |> doc(200)
      assert count(document, "#entry-facts") == 1

      assert conn |> submit(slug, entry()) |> html_response(200) =~ "Entry sent"
      assert [_one] = Registrations.list_for_tournament(slug)
    end

    test "the FIDE search is closed with the form", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss() |> with_settings(%{"opens_at" => iso(in_hours(24))}) |> publish()

      assert conn |> get(~p"/t/#{slug}/fide?q=carlsen") |> json_response(403) == %{
               "players" => []
             }
    end
  end

  describe "a capped field" do
    test "is full when the arbiter's count reaches the cap", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"max_players" => 10, "taken" => 10})
        |> publish()

      document = conn |> get(~p"/t/#{slug}/register") |> doc(403)
      assert count(document, "#entries-closed[data-reason=full]") == 1

      assert conn |> submit(slug, entry()) |> html_response(403)
      assert Registrations.list_for_tournament(slug) == []
    end

    test "counts entries that arrived after the snapshot, which its count cannot include",
         %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"max_players" => 10, "taken" => 9})
        |> publish()

      # One place left, and the page says so.
      document = conn |> get(~p"/t/#{slug}/register") |> doc(200)
      assert document |> LazyHTML.query("#entry-places") |> LazyHTML.text() =~ "9 of 10"

      # Somebody takes it. The arbiter's laptop is closed, so no snapshot
      # carries the new count - and the form must still see the field full.
      assert conn |> submit(slug, entry()) |> html_response(200) =~ "Entry sent"

      assert conn
             |> get(~p"/t/#{slug}/register")
             |> doc(403)
             |> count("#entries-closed[data-reason=full]") ==
               1
    end

    test "a malformed cap is no cap", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"max_players" => "10", "taken" => 99})
        |> publish()

      assert conn |> get(~p"/t/#{slug}/register") |> html_response(200) =~ "registration-form"
    end
  end

  describe "the honeypot" do
    setup do
      {:ok, slug: SnapshotPayloads.swiss() |> with_settings(%{}) |> publish()}
    end

    test "is on the form, hidden from people", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/register") |> doc(200)

      assert count(document, ".trap[aria-hidden=true] input#registration_trap[tabindex='-1']") ==
               1
    end

    test "filled in, stores nothing and gives everything back, saying why", %{
      conn: conn,
      slug: slug
    } do
      document =
        conn |> submit(slug, entry(%{"website" => "http://spam.example.invalid"})) |> doc(422)

      assert Registrations.list_for_tournament(slug) == []

      # Not silent: the reason is on the page, the trap is visible so a
      # person can clear it, and what they typed is still there.
      assert count(document, "p.alarm[role=alert]") >= 1
      assert count(document, ".trap") == 0
      assert count(document, "input#registration_trap") == 1
      assert count(document, ~s|input#registration_name[value="Janssens, Lotte"]|) == 1
    end

    test "a map where the trap should be is refused, not a crash", %{conn: conn, slug: slug} do
      assert conn |> submit(slug, entry(%{"website" => %{"x" => "1"}})) |> html_response(422)
      assert Registrations.list_for_tournament(slug) == []
    end

    test "left empty, the entry goes through", %{conn: conn, slug: slug} do
      assert conn |> submit(slug, entry(%{"website" => ""})) |> html_response(200) =~ "Entry sent"
      assert [_one] = Registrations.list_for_tournament(slug)
    end
  end

  describe "the national ID" do
    setup do
      {:ok, slug: SnapshotPayloads.swiss() |> with_settings(%{}) |> publish()}
    end

    test "travels to the arbiter as a string, a G licence's minus included", %{
      conn: conn,
      slug: slug
    } do
      assert conn |> submit(slug, entry(%{"national_id" => " -12345 "})) |> html_response(200)

      [registration] = Registrations.list_for_tournament(slug)
      assert registration.payload["player"]["national_id"] == "-12345"
    end

    test "that is not an identifier is refused with a reason", %{conn: conn, slug: slug} do
      document = conn |> submit(slug, entry(%{"national_id" => "12 34; drop"})) |> doc(422)

      assert count(document, "#registration_national_id_error") == 1
      assert Registrations.list_for_tournament(slug) == []
    end
  end

  describe "the public entry list" do
    test "is absent unless the arbiter allows it", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> with_settings(%{}) |> publish()

      assert conn |> get(~p"/t/#{slug}/register") |> doc(200) |> count("#entry-list") == 0
    end

    test "lists the published players, never an undecided entry and never an email", %{
      conn: conn
    } do
      payload = SnapshotPayloads.swiss() |> with_settings(%{"list_public" => true})
      slug = publish(payload)

      assert conn |> submit(slug, entry()) |> html_response(200)

      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)
      document = LazyHTML.from_document(html)

      rows = document |> LazyHTML.query("#entry-list tbody tr") |> Enum.count()
      assert rows == length(Tournament.players(payload))

      # The entry just submitted is waiting for the arbiter: not a name here.
      refute document |> LazyHTML.query("#entry-list") |> LazyHTML.text() =~ "Janssens"
      refute html =~ @email
    end

    test "lists the arbiter's pending names after the players, marked unconfirmed, escaped", %{
      conn: conn
    } do
      payload =
        SnapshotPayloads.swiss()
        |> with_settings(%{
          "list_public" => true,
          "pending" => [%{"name" => "Waiting, Wim"}, %{"name" => "<script>alert(1)</script>"}]
        })

      slug = publish(payload)
      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert count(document, "#entry-list tbody tr.pending") == 2
      assert count(document, "#entry-list tbody tr.pending .tag") == 2
      assert document |> LazyHTML.query("#entry-pending-count") |> LazyHTML.text() =~ "2"
      assert document |> LazyHTML.query("#entry-list") |> LazyHTML.text() =~ "Waiting, Wim"
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;"
      # The confirmed players are untouched, and come first.
      confirmed = length(Tournament.players(payload))
      assert count(document, "#entry-list tbody tr") == confirmed + 2
    end

    test "pending names are not shown when the list is not public, or when none are sent", %{
      conn: conn
    } do
      closed =
        SnapshotPayloads.swiss()
        |> with_settings(%{"pending" => [%{"name" => "Waiting, Wim"}]})
        |> publish()

      html = conn |> get(~p"/t/#{closed}/register") |> html_response(200)
      refute html =~ "Waiting, Wim"

      open = SnapshotPayloads.swiss() |> with_settings(%{"list_public" => true}) |> publish()
      assert conn |> get(~p"/t/#{open}/register") |> doc(200) |> count("tr.pending") == 0
    end

    test "malformed pending entries are dropped and the list is capped" do
      payload =
        SnapshotPayloads.swiss()
        |> with_settings(%{
          "list_public" => true,
          "pending" =>
            [%{"name" => "  "}, %{"name" => 5}, "x", %{"name" => "Fine\u0007  Name"}] ++
              for(n <- 1..300, do: %{"name" => "N#{n}"})
        })

      names = Tournament.pending_entrants(payload)
      assert hd(names) == "Fine Name"
      assert length(names) == 200
    end

    test "stays on the closed page, where people who missed out look", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"list_public" => true, "closes_at" => iso(in_hours(-1))})
        |> publish()

      assert conn |> get(~p"/t/#{slug}/register") |> doc(403) |> count("#entry-list") == 1
    end

    test "hides the columns the arbiter hid everywhere else", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"list_public" => true})
        |> put_in(["tournament", "display"], %{"club" => false, "rating" => false})
        |> publish()

      headers =
        conn
        |> get(~p"/t/#{slug}/register")
        |> doc(200)
        |> LazyHTML.query("#entry-list th")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      refute "Club" in headers
      refute "Rating" in headers
      assert "Name" in headers
    end
  end

  describe "the entry fee" do
    test "is stated on the form when the arbiter set one", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{
          "fee" => %{"amount" => "12.50", "currency" => "EUR", "note" => "Free for juniors"}
        })
        |> publish()

      text = conn |> get(~p"/t/#{slug}/register") |> doc(200) |> LazyHTML.query("#entry-fee")
      assert LazyHTML.text(text) =~ "12.50 EUR"
      assert LazyHTML.text(text) =~ "Free for juniors"
    end

    test "can be a note alone, and is absent when unset", %{conn: conn} do
      free =
        SnapshotPayloads.swiss()
        |> with_settings(%{"fee" => %{"note" => "Free for everyone"}})
        |> publish()

      document = conn |> get(~p"/t/#{free}/register") |> doc(200)
      assert document |> LazyHTML.query("#entry-fee") |> LazyHTML.text() =~ "Free for everyone"

      none = SnapshotPayloads.swiss() |> with_settings(%{}) |> publish()
      assert conn |> get(~p"/t/#{none}/register") |> doc(200) |> count("#entry-fee") == 0
    end

    test "reads nonsense as no fee, and escapes the note" do
      read = fn fee ->
        SnapshotPayloads.swiss() |> with_settings(%{"fee" => fee}) |> Tournament.entry_fee()
      end

      assert read.(%{"amount" => "lots", "currency" => "EUR"}) == nil
      assert read.("12") == nil

      assert read.(%{"amount" => "7", "currency" => "euro"}) ==
               %{amount: "7", currency: nil, note: nil}
    end

    test "escapes a hostile note", %{conn: conn} do
      slug =
        SnapshotPayloads.swiss()
        |> with_settings(%{"fee" => %{"note" => "<b>free</b>"}})
        |> publish()

      html = conn |> get(~p"/t/#{slug}/register") |> html_response(200)
      refute html =~ "<b>free</b>"
      assert html =~ "&lt;b&gt;free"
    end
  end

  describe "no confirmation e-mail" do
    test "the page that acknowledges an entry says so, and nothing is mailed", %{conn: conn} do
      slug = SnapshotPayloads.swiss() |> with_settings(%{}) |> publish()
      html = conn |> submit(slug, entry()) |> html_response(200)
      assert html =~ "No confirmation e-mail is sent"
    end
  end

  describe "Tournament.registration_state/3" do
    @now ~U[2026-03-01 10:00:00Z]

    defp payload(open, settings, players \\ []) do
      %{
        "tournament" => %{"registration_open" => open, "registration" => settings},
        "players" => players
      }
    end

    test "names the first reason in the order a person would want it" do
      assert Tournament.registration_state(
               payload(false, %{"max_players" => 1, "taken" => 5}),
               @now
             ) ==
               :closed

      assert Tournament.registration_state(
               payload(true, %{
                 "opens_at" => "2026-03-02T00:00:00Z",
                 "max_players" => 1,
                 "taken" => 5
               }),
               @now
             ) == :not_yet

      assert Tournament.registration_state(
               payload(true, %{"closes_at" => "2026-03-01T10:00:00Z"}),
               @now
             ) == :ended

      assert Tournament.registration_state(
               payload(true, %{"max_players" => 5, "taken" => 4}),
               @now,
               1
             ) ==
               :full

      assert Tournament.registration_state(
               payload(true, %{"max_players" => 5, "taken" => 4}),
               @now
             ) ==
               :open
    end

    test "opens at its opening instant, not a moment later" do
      assert Tournament.registration_state(
               payload(true, %{"opens_at" => "2026-03-01T10:00:00Z"}),
               @now
             ) == :open
    end

    test "falls back to the published players when there is no count" do
      players = [%{"no" => 1, "name" => "A"}, %{"no" => 2, "name" => "B"}]

      assert Tournament.registration_state(payload(true, %{"max_players" => 2}, players), @now) ==
               :full
    end

    test "an unparseable time is no restriction" do
      assert Tournament.registration_state(payload(true, %{"opens_at" => "tomorrow"}), @now) ==
               :open
    end
  end
end
