defmodule OpenResultsWeb.RegistrationControllerTest do
  use OpenResultsWeb.ConnCase

  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.Registrations.Registration
  alias OpenResults.Repo
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  # Distinctive enough that finding it anywhere it should not be is
  # unambiguous, and unroutable so a mistake cannot reach a person.
  @email "ilse.de.vos@example.invalid"

  setup do
    # Every test in this file arrives from 127.0.0.1, so they share one rate
    # limit window unless it is cleared between them.
    RateLimit.reset()

    swiss = SnapshotPayloads.swiss()
    {:ok, _snapshot} = Snapshots.ingest(swiss)

    {:ok, swiss: swiss, slug: swiss["tournament"]["slug"]}
  end

  defp doc(conn, status \\ 200), do: LazyHTML.from_document(html_response(conn, status))

  defp texts(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim() |> String.replace(~r/\s+/, " ")))
  end

  # A complete entry, as a browser would post it: everything a string, the
  # byes as a list, the federation in whatever case the person typed.
  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "De Vos, Ilse",
        "email" => @email,
        "rating" => "1804",
        "federation" => "bel",
        "fide_id" => "2503014",
        "club" => "KGSRL",
        "requested_byes" => ["3", "4"]
      },
      overrides
    )
  end

  defp submit(conn, slug, attrs \\ nil) do
    post(conn, ~p"/t/#{slug}/register", registration: attrs || entry())
  end

  # One person, arriving the way everybody arrives: through the tunnel, which
  # reaches this app over loopback and names them in the header. A fresh conn
  # per request because recycling a dispatched one carries only `accept`,
  # `accept-language` and `authorization` over, and this would quietly become
  # a test of the loopback fallback instead.
  defp visitor(address), do: build_conn() |> put_req_header("cf-connecting-ip", address)

  # A tournament's queue at its cap, without the thousand posts that would
  # take - and which the rate limit would stop at five anyway. Nothing reads
  # these rows; they only have to exist and belong to this tournament.
  defp fill_queue(slug, rows) do
    received_at = DateTime.utc_now()

    for n <- 1..rows do
      %{
        tournament_slug: slug,
        version: 1,
        received_at: received_at,
        payload: %{
          "schema" => Registrations.schema_id(),
          "version" => 1,
          "tournament_slug" => slug,
          "player" => %{"name" => "Filler, Number #{n}"}
        }
      }
    end
    |> Enum.chunk_every(100)
    |> Enum.each(&Repo.insert_all(Registration, &1))
  end

  describe "GET /t/:slug/register" do
    test "renders a form with the fields the contract allows and no others", %{
      conn: conn,
      slug: slug
    } do
      document = conn |> get(~p"/t/#{slug}/register") |> doc()

      assert LazyHTML.query(document, "form#registration-form") |> Enum.count() == 1

      # Every named control, not just the inputs. This looked only at
      # `input[name]` until a <select> was added for the title, at which point
      # a whole field became invisible to a test whose entire claim is "and no
      # others" - the one assertion that has to enumerate everything.
      named =
        document
        |> LazyHTML.query(
          "form#registration-form input[name], form#registration-form select[name]"
        )
        |> Enum.map(&(&1 |> LazyHTML.attribute("name") |> List.first()))
        |> Enum.uniq()

      assert named == [
               "registration[name]",
               "registration[email]",
               "registration[rating]",
               "registration[federation]",
               "registration[fide_id]",
               "registration[club]",
               "registration[title]",
               "registration[birth_year]",
               "registration[national_id]",
               "registration[requested_byes][]",
               # The honeypot - named, so a bot fills it, and never stored:
               # `Entry` does not cast it, and a filled one refuses the post.
               "registration[website]"
             ]
    end

    test "sits under the tournament it is for", %{conn: conn, slug: slug} do
      document = conn |> get(~p"/t/#{slug}/register") |> doc()

      assert texts(document, "h1") == ["Gent Spring Open 2026"]
      assert texts(document, "h2") == ["Enter this tournament starts 2026-03-01"]
    end

    test "says the arbiter decides, before anybody types anything", %{conn: conn, slug: slug} do
      # The design constraint, on the page rather than only in the docs. A form
      # that reads like a checkout is a form people think entered them.
      document = conn |> get(~p"/t/#{slug}/register") |> doc()

      assert [footnote] = texts(document, "section > p.footnote")
      assert footnote =~ "It does not enter you"
      assert footnote =~ "they decide who plays"
    end

    test "offers a box for every round the tournament has", %{conn: conn, slug: slug} do
      # rounds_count is 5 and round 4 is unpublished. A bye is requested for a
      # round that exists, not for a round that has been posted.
      document = conn |> get(~p"/t/#{slug}/register") |> doc()

      assert texts(document, "fieldset .check") == ~w(1 2 3 4 5)
    end

    test "asks nothing about byes when the payload does not say how long the event is", %{
      conn: conn,
      swiss: swiss
    } do
      # An older client, or a tournament whose length is not settled. A
      # free-text round list would be inviting an answer nothing could check,
      # so the question is simply not asked.
      lengthless =
        swiss
        |> update_in(["tournament"], &Map.delete(&1, "rounds_count"))
        |> Map.delete("rounds")

      {:ok, _snapshot} = Snapshots.ingest(lengthless)

      document = conn |> get(~p"/t/#{lengthless["tournament"]["slug"]}/register") |> doc()

      assert texts(document, "fieldset") == []
      assert LazyHTML.query(document, "form#registration-form") |> Enum.count() == 1
    end

    test "is linked from the tournament's own pages", %{conn: conn, slug: slug} do
      # The link came down on 2026-08-29 while the form was unfinished and
      # went back up on 2026-09-30 with the rest of the workflow. Every page
      # of the tournament carries it, because the masthead does.
      for path <- [~p"/t/#{slug}", ~p"/t/#{slug}/round/1", ~p"/t/#{slug}/player/1"] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s|href="/t/#{slug}/register"|, "#{path} does not link to the form"
      end

      assert conn |> get(~p"/t/#{slug}/register") |> html_response(200) =~ "registration-form"
    end

    test "a slug nobody has published is a 404", %{conn: conn} do
      html = conn |> get(~p"/t/no-such-tournament/register") |> html_response(404)

      assert html =~ "No tournament has published under no-such-tournament"
    end

    test "sets no cookie and carries no token nothing would check", %{conn: conn, slug: slug} do
      # A form is the one thing that could have dragged a session onto this
      # site. It did not: there is no authority here to forge, so there is no
      # token, and therefore no cookie to keep one in.
      conn = get(conn, ~p"/t/#{slug}/register")

      assert get_resp_header(conn, "set-cookie") == []
      refute html_response(conn, 200) =~ "_csrf_token"
    end
  end

  describe "POST /t/:slug/register - a good entry" do
    test "is stored as the payload the contract describes", %{conn: conn, slug: slug} do
      conn = submit(conn, slug)

      assert html_response(conn, 200)
      assert [registration] = Registrations.list_for_tournament(slug)

      assert registration.tournament_slug == slug
      assert registration.version == 1
      assert registration.payload["schema"] == Registrations.schema_id()
      assert registration.payload["tournament_slug"] == slug

      assert registration.payload["player"] == %{
               "name" => "De Vos, Ilse",
               "email" => @email,
               "rating" => 1804,
               # Typed in lower case, filed as FIDE writes it.
               "federation" => "BEL",
               "fide_id" => 2_503_014,
               "club" => "KGSRL",
               "requested_byes" => [3, 4]
             }
    end

    test "is stamped with the server's clock, in the row and in the document", %{
      conn: conn,
      slug: slug
    } do
      before = DateTime.utc_now()
      submit(conn, slug)

      assert [registration] = Registrations.list_for_tournament(slug)
      assert DateTime.compare(registration.received_at, before) in [:gt, :eq]

      # Here the server IS the submitter, so the claim in the envelope and the
      # column the arbiter sorts by are the same instant rather than one
      # trusting the other.
      assert {:ok, claimed, _offset} = DateTime.from_iso8601(registration.payload["received_at"])
      assert DateTime.diff(registration.received_at, claimed, :second) == 0
    end

    test "a name and an email alone are enough, because club chess is like that", %{
      conn: conn,
      slug: slug
    } do
      bare = %{"name" => "Nguyễn, Thị Hà", "email" => @email}

      assert conn |> submit(slug, bare) |> html_response(200)
      assert [registration] = Registrations.list_for_tournament(slug)

      # Absent rather than null: the contract says a missing key and a null
      # mean the same thing, and the shorter document is the honest one.
      assert registration.payload["player"] == %{"name" => "Nguyễn, Thị Hà", "email" => @email}
    end

    test "the confirmation never says the person is entered", %{conn: conn, slug: slug} do
      html = conn |> submit(slug) |> html_response(200)

      assert html =~ "Entry sent"
      assert html =~ "This is not a place in the tournament"
      assert html =~ "decide who plays"

      # And the tournament is unchanged, which is the same statement in data.
      assert conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "Gent Spring Open 2026"
      refute conn |> get(~p"/t/#{slug}") |> html_response(200) =~ "De Vos, Ilse"
    end

    test "does not touch the tournament it is for", %{conn: conn, slug: slug, swiss: swiss} do
      submit(conn, slug)

      # The whole architectural constraint in one assertion: an entry adds a
      # row to a queue and leaves the published document byte for byte alone.
      assert Snapshots.latest(slug).payload == swiss
    end
  end

  describe "POST /t/:slug/register - a bad entry" do
    test "is refused, and nothing at all is stored", %{conn: conn, slug: slug} do
      attrs = entry(%{"name" => "", "email" => "ilse.at.example"})

      assert conn |> submit(slug, attrs) |> html_response(422)
      assert Registrations.list_for_tournament(slug) == []
    end

    test "says what to fix, next to the box it is about", %{conn: conn, slug: slug} do
      attrs = entry(%{"name" => "", "email" => "ilse.at.example"})
      document = conn |> submit(slug, attrs) |> doc(422)

      assert texts(document, "#registration_name_error") ==
               ["please give the name you want on the pairing list"]

      assert texts(document, "#registration_email_error") ==
               ["that does not look like an email address - check for a missing @ or a typo"]

      assert texts(document, "p.alarm") ==
               ["Nothing has been sent. Fix what is marked below and send it again."]
    end

    test "hands back what was typed, so nobody fills the form twice", %{conn: conn, slug: slug} do
      attrs = entry(%{"email" => "ilse.at.example"})
      document = conn |> submit(slug, attrs) |> doc(422)

      assert document
             |> LazyHTML.query("#registration_name")
             |> LazyHTML.attribute("value") == ["De Vos, Ilse"]

      assert document
             |> LazyHTML.query("#registration_club")
             |> LazyHTML.attribute("value") == ["KGSRL"]

      assert texts(document, "fieldset .check input:checked ~ span") == ~w(3 4)
    end

    test "a rating with a letter in it is told so in words", %{conn: conn, slug: slug} do
      document = conn |> submit(slug, entry(%{"rating" => "eighteen hundred"})) |> doc(422)

      assert texts(document, "#registration_rating_error") ==
               ["a rating is a whole number, digits only"]

      assert Registrations.list_for_tournament(slug) == []
    end

    test "a federation that is not a three-letter code is refused", %{conn: conn, slug: slug} do
      document = conn |> submit(slug, entry(%{"federation" => "Belgium"})) |> doc(422)

      assert texts(document, "#registration_federation_error") ==
               ["a federation is a three-letter FIDE code, like BEL or NOR"]
    end

    test "a bye for a round the tournament does not have is refused", %{conn: conn, slug: slug} do
      # Five rounds. Round 9 is somebody remembering a different tournament,
      # and it is worth catching here rather than leaving for the arbiter.
      document = conn |> submit(slug, entry(%{"requested_byes" => ["3", "9"]})) |> doc(422)

      assert texts(document, "fieldset p.wrong") ==
               ["choose from the rounds this tournament has: 1, 2, 3, 4, 5"]

      assert Registrations.list_for_tournament(slug) == []
    end

    test "a body that is not the form's shape is an empty form, not a crash", %{
      conn: conn,
      slug: slug
    } do
      assert post(conn, ~p"/t/#{slug}/register", registration: "nonsense") |> html_response(422)
      assert post(conn, ~p"/t/#{slug}/register", %{}) |> html_response(422)
      assert Registrations.list_for_tournament(slug) == []
    end
  end

  describe "POST /t/:slug/register - a tournament that is not here" do
    test "is a 404 and invents nothing", %{conn: conn} do
      html = conn |> submit("no-such-tournament") |> html_response(404)

      assert html =~ "No tournament has published under no-such-tournament"

      # The queue would otherwise fill with entries no arbiter will ever pull,
      # for a tournament this server would have conjured out of a form post.
      assert Registrations.list_for_tournament("no-such-tournament") == []
      assert Snapshots.latest("no-such-tournament") == nil
    end
  end

  describe "the rate limit" do
    test "lets an ordinary number of entries through and stops a flood", %{
      conn: conn,
      slug: slug
    } do
      # Five is a family entering from one phone. The sixth in ten minutes is
      # not, and the door shuts before the database is touched.
      for n <- 1..5 do
        assert conn |> submit(slug, entry(%{"name" => "Entrant, Number #{n}"})) |> response(200)
      end

      blocked = submit(conn, slug, entry(%{"name" => "Entrant, Number 6"}))

      assert html_response(blocked, 429) =~ "nothing has been stored"
      assert [retry_after] = get_resp_header(blocked, "retry-after")
      assert String.to_integer(retry_after) > 0

      assert Registrations.list_for_tournament(slug) |> length() == 5
    end

    test "the refusal says what to do about it", %{conn: conn, slug: slug} do
      for _ <- 1..5, do: submit(conn, slug)

      html = conn |> submit(slug) |> html_response(429)

      assert html =~ "Try again in about"
      assert html =~ "A shared connection counts as one"
    end

    test "counts visitors behind the tunnel one by one, not all as one", %{slug: slug} do
      # The bug this replaces: the tunnel dials this app over loopback, so
      # every request in the world arrived as 127.0.0.1 and the limit was a
      # single bucket for the whole internet. One person could spend it, and
      # the sixth entry of the day - from anybody, anywhere - was refused.
      for n <- 1..5 do
        assert visitor("203.0.113.7")
               |> submit(slug, entry(%{"name" => "Flood, Number #{n}"}))
               |> response(200)
      end

      assert visitor("203.0.113.7") |> submit(slug) |> html_response(429)

      assert visitor("198.51.100.2")
             |> submit(slug, entry(%{"name" => "Elsewhere, Entirely"}))
             |> response(200)
    end

    test "does not let a caller that bypassed the tunnel pick its own bucket", %{slug: slug} do
      # A header is only worth reading when the request came through the
      # thing that sets it. From any other peer it is a stranger's sentence,
      # and believing it would hand a flooder an unlimited supply of buckets.
      direct = fn claimed ->
        %{build_conn() | remote_ip: {203, 0, 113, 9}}
        |> put_req_header("cf-connecting-ip", claimed)
      end

      for n <- 1..5 do
        assert direct.("198.51.100.#{n}")
               |> submit(slug, entry(%{"name" => "Spoof, Number #{n}"}))
               |> response(200)
      end

      assert direct.("198.51.100.6") |> submit(slug) |> html_response(429)
    end
  end

  describe "POST /t/:slug/register - a tournament whose queue is full" do
    test "refuses cleanly, and stores nothing on the way", %{conn: conn, slug: slug} do
      fill_queue(slug, 1000)

      document = conn |> submit(slug) |> doc(503)

      assert texts(document, "h1") == ["Too many entries are waiting"]
      assert Registrations.list_for_tournament(slug) |> length() == 1000
    end

    test "and tells a player what to do about it without blaming them", %{
      conn: conn,
      slug: slug
    } do
      fill_queue(slug, 1000)

      html = conn |> submit(slug) |> html_response(503)

      assert html =~ "nothing has been stored"
      assert html =~ "nobody here has decided the field is full"
      assert html =~ "Contact the organisers directly"
    end

    test "is one tournament's problem and not the next tournament's", %{
      conn: conn,
      slug: slug,
      swiss: swiss
    } do
      # The bound has to be per tournament for the reason the page cache's
      # did: several events run at once, and one of them being flooded must
      # not shut the others' entries off.
      next_door = put_in(swiss, ["tournament", "slug"], "leuven-autumn-open-2026")
      {:ok, _snapshot} = Snapshots.ingest(next_door)

      fill_queue(slug, 1000)

      assert conn |> submit(slug) |> html_response(503)

      assert conn
             |> submit("leuven-autumn-open-2026", entry(%{"name" => "Elsewhere, Entirely"}))
             |> response(200)

      assert Registrations.list_for_tournament("leuven-autumn-open-2026") |> length() == 1
    end
  end

  describe "the email" do
    test "is held for the arbiter and rendered nowhere", %{conn: conn, slug: slug} do
      confirmation = conn |> submit(slug) |> html_response(200)

      # Held: the whole reason this table exists.
      assert [registration] = Registrations.list_for_tournament(slug)
      assert registration.payload["player"]["email"] == @email

      # And not on the page that just received it.
      refute confirmation =~ @email

      pages = [
        ~p"/",
        ~p"/t/#{slug}",
        ~p"/t/#{slug}/round/1",
        ~p"/t/#{slug}/round/2",
        ~p"/t/#{slug}/round/3",
        ~p"/t/#{slug}/player/1",
        ~p"/t/#{slug}/register"
      ]

      for path <- pages do
        refute conn |> get(path) |> html_response(200) =~ @email, "#{path} rendered the email"
      end
    end

    test "is not in the public snapshot API either", %{conn: conn, slug: slug} do
      submit(conn, slug)

      body = conn |> get(~p"/api/tournaments/#{slug}") |> json_response(200)

      refute Jason.encode!(body) =~ @email
    end

    test "does not reach the snapshot a registration was made against", %{conn: conn, slug: slug} do
      submit(conn, slug)

      # Registrations and snapshots are separate tables on purpose. A snapshot
      # is what an arbiter published; nothing this form collects can join it.
      refute Jason.encode!(Snapshots.latest(slug).payload) =~ @email
    end
  end

  describe "GET /api/tournaments/:slug/registrations - the arbiter's pull" do
    @token "test-ingest-token"

    defp pull(conn, slug, token \\ @token) do
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/tournaments/#{slug}/registrations")
    end

    test "is refused without the token", %{conn: conn, slug: slug} do
      # This is the only route in the system that returns an email address,
      # so it sits behind the same gate as publishing rather than beside the
      # open read routes.
      assert conn |> get(~p"/api/tournaments/#{slug}/registrations") |> json_response(401)
    end

    test "is refused with the wrong token", %{conn: conn, slug: slug} do
      assert conn |> pull(slug, "not-the-token") |> json_response(401)
    end

    test "returns an empty list for a tournament nobody has entered", %{conn: conn, slug: slug} do
      body = conn |> pull(slug) |> json_response(200)

      assert body["registrations"] == []
      assert body["tournament_slug"] == slug
    end

    test "returns what the public form collected, with a stable id", %{conn: conn, slug: slug} do
      submit(conn, slug, %{"name" => "De Vos, Ilse", "email" => "ilse@example.com"})

      body = conn |> pull(slug) |> json_response(200)

      assert [entry] = body["registrations"]
      assert entry["payload"]["player"]["name"] == "De Vos, Ilse"
      assert entry["received_at"]

      # The id is what lets the arbiter's machine tell one entry from another
      # across repeated pulls. Without it a discarded entry would come back
      # every single time.
      assert is_integer(entry["id"])
    end

    test "the same pull twice gives the same ids", %{conn: conn, slug: slug} do
      submit(conn, slug, %{"name" => "One", "email" => "one@example.com"})
      submit(conn, slug, %{"name" => "Two", "email" => "two@example.com"})

      first = conn |> pull(slug) |> json_response(200)
      second = conn |> pull(slug) |> json_response(200)

      # This server has no notion of an entry being "handled" - that is a
      # fact about the arbiter's machine. So the pull is idempotent and
      # returns everything, every time.
      assert Enum.map(first["registrations"], & &1["id"]) ==
               Enum.map(second["registrations"], & &1["id"])
    end

    test "an entry for another tournament is not returned", %{conn: conn, slug: slug} do
      submit(conn, slug, %{"name" => "Ours", "email" => "ours@example.com"})

      other = conn |> pull("some-other-tournament") |> json_response(200)
      assert other["registrations"] == []
    end
  end
end
