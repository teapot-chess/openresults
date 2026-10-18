defmodule OpenResultsWeb.RegistrationController do
  @moduledoc """
  The public entry form.

  The only place a member of the public can write to this server, and what it
  writes to is a QUEUE. Nothing here touches a tournament. The arbiter's
  machine pulls the queue and the arbiter decides who plays, exactly as with a
  paper entry form left on a table at the club - which is why every word on
  these two pages is careful never to say "you are entered".

  A tournament has to have published here before anybody can enter it. That is
  not a convenience check: a registration for `gent-spring-opne-2026` would
  otherwise sit in a queue no arbiter will ever pull, and this app is not
  allowed to invent a tournament from an entry. The 404 is the same one the
  standings page gives, for the same reason.

  Both actions run on the read pipeline, so like every other page on this site
  they set no cookie. See the router for why a form here needs neither a
  session nor a CSRF token, and what protects it instead.
  """

  use OpenResultsWeb, :controller

  alias OpenResults.FideList
  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResults.Registrations.Entry
  alias OpenResults.TournamentKeys
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ClientAddress
  alias OpenResultsWeb.Meta
  alias OpenResultsWeb.Tournament

  # Five entries per ten minutes from one address. Chosen to be invisible to
  # the case that actually happens - a parent entering three children from one
  # phone - while making a script's thousandth POST cost ten minutes instead
  # of a millisecond.
  #
  # A honeypot was first rejected because the usual kind fails SILENTLY: a
  # password manager or an over-eager autofill filling the hidden box throws
  # away a real person's only attempt with no error. This one does not fail
  # silently - see `@trap` - so it is on.
  @rate_limit 5
  @rate_window_ms :timer.minutes(10)

  # The honeypot: a field the page hides from people and a naive bot fills
  # in. When it arrives filled, nothing is stored and the form comes back
  # WITH EVERYTHING THE PERSON TYPED, the trap now visible and labelled
  # "leave this empty", and a sentence saying so. A bot is stopped; a person
  # whose browser autofilled it clears one box and sends again. It never
  # loses an entry quietly, which was the objection to the usual kind.
  @trap "website"

  @doc """
  `GET /t/:slug/register` - the entry form for a tournament that exists here.
  """
  def new(conn, %{"slug" => slug}) do
    with_tournament(conn, slug, fn conn, payload ->
      render_form(conn, slug, payload, Entry.new())
    end)
  end

  @doc """
  `POST /t/:slug/register` - validates one entry and puts it in the queue.

  Renders the confirmation directly rather than redirecting to it. The usual
  post/redirect/get exists to stop a refresh re-posting, and it needs somewhere
  to keep "you just submitted" between the two requests - a flash, and behind
  it a session and a cookie on a site that has none. The trade is a browser
  warning on refresh against a cookie on every reader, and a duplicate entry
  is the one mistake this system is already built to absorb: `Registrations`
  deduplicates nothing on purpose, because two entries for the same player is
  an arbiter's decision and always was.
  """
  def create(conn, %{"slug" => slug} = params) do
    # Before the database is touched, so a flood costs a lookup in ETS rather
    # than a query per request.
    #
    # `ClientAddress` rather than `conn.remote_ip`: the tunnel dials this app
    # over loopback, so the peer address is 127.0.0.1 for every visitor on
    # earth and keying on it made this one bucket for the whole internet.
    case RateLimit.take({:registration, ClientAddress.of(conn)},
           limit: @rate_limit,
           window_ms: @rate_window_ms
         ) do
      :ok -> store(conn, slug, submitted(params))
      {:denied, retry_in_ms} -> too_many(conn, slug, retry_in_ms)
    end
  end

  @doc """
  `GET /t/:slug/fide?q=` - candidates from this server's copy of the FIDE
  list (`OpenResults.FideList`).

  Behind the same closed-form gate as the form itself: a tournament that is
  not taking entries has no reason to lend anybody a search, and leaving this
  open would make it reachable for every tournament on the site regardless.

  Before the first import has finished the answer is an empty list with
  `"available": false`, which the page turns into "not available yet"
  rather than "no match" - the second would tell somebody who IS on the list
  that they are not.
  """
  def fide(conn, %{"slug" => slug} = params) do
    case Tournaments.public_latest(slug) do
      nil ->
        conn |> put_status(:not_found) |> json(%{"players" => []})

      snapshot ->
        if registration_state(slug, snapshot) == :open do
          query = params |> Map.get("q", "") |> to_string()
          tempo = Tournament.info(snapshot.payload)["tempo"]

          case FideList.search(query, tempo) do
            {:ok, players} -> json(conn, %{"players" => players})
            :unavailable -> json(conn, %{"players" => [], "available" => false})
          end
        else
          conn |> put_status(:forbidden) |> json(%{"players" => []})
        end
    end
  end

  defp store(conn, slug, attrs) do
    with_tournament(conn, slug, fn conn, payload ->
      rounds = Tournament.round_slots(payload)

      if trap_tripped?(attrs) do
        # Nothing stored, everything kept, and said - see `@trap`.
        conn
        |> put_status(:unprocessable_entity)
        |> render_form(slug, payload, Entry.changeset(attrs, rounds),
          trap: trap_value(attrs),
          alarm:
            gettext(
              "Nothing has been sent. The box marked \"Leave this empty\" below has something in it - usually your browser filling it in by itself. Empty it and send the form again."
            )
        )
      else
        validate_and_store(conn, slug, payload, rounds, attrs)
      end
    end)
  end

  defp trap_tripped?(attrs) do
    case Map.get(attrs, @trap) do
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _something_else -> true
    end
  end

  # What the trap held, to show back. Only ever a string: a crafted post can
  # send a map here, and the page must still render.
  defp trap_value(attrs) do
    case Map.get(attrs, @trap) do
      value when is_binary(value) -> value
      _not_a_string -> ""
    end
  end

  defp validate_and_store(conn, slug, payload, rounds, attrs) do
    case attrs |> Entry.changeset(rounds) |> Ecto.Changeset.apply_action(:insert) do
      {:ok, entry} ->
        received_at = DateTime.utc_now()

        case Registrations.ingest(Entry.to_payload(entry, slug, received_at),
               received_at: received_at
             ) do
          {:ok, _registration} ->
            render(conn, :received,
              page_title:
                gettext("Entry sent - %{tournament}", tournament: Tournament.name(payload)),
              page_description: Meta.received(payload),
              payload: payload,
              slug: slug,
              # The name only. The email is the one thing this server holds
              # that a snapshot never carries, and a confirmation page is
              # still a rendered page.
              name: entry.name
            )

          {:error, :queue_full} ->
            queue_full(conn, slug)

          {:error, _unstorable} ->
            # Unreachable in practice - the payload was built from the
            # contract two lines ago - but a person who has just typed their
            # details deserves a page that says what happened rather than a
            # stack trace.
            conn
            |> put_status(:internal_server_error)
            |> render_form(slug, payload, Entry.changeset(attrs, rounds),
              alarm:
                gettext(
                  "Something went wrong at our end and your entry was not stored. Your answers are still below - please send it again."
                )
            )
        end

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_form(slug, payload, changeset)
    end
  end

  # The form's own params, or nothing. A caller who posts `?registration=x`
  # gets an empty form back rather than a 500, which is the same restraint
  # `OpenResults.Envelope` shows about payloads of the wrong shape.
  defp submitted(params) do
    case Map.get(params, "registration") do
      attrs when is_map(attrs) -> attrs
      _absent_or_wrong_shape -> %{}
    end
  end

  defp render_form(conn, slug, payload, changeset, opts \\ []) do
    render(conn, :new,
      page_title: gettext("Enter %{tournament}", tournament: Tournament.name(payload)),
      page_description: Meta.register(payload),
      payload: payload,
      slug: slug,
      rounds: Tournament.round_slots(payload),
      alarm: Keyword.get(opts, :alarm),
      # `nil` - the trap stays hidden - unless it came back filled, when it is
      # shown with what was in it so the person can see what to clear.
      trap: Keyword.get(opts, :trap),
      trap_name: @trap,
      # Offered where this server has a FIDE list or is fetching one. A
      # search box that cannot search is worse than none: it invites a click
      # and answers nothing - so while the first list is still on its way,
      # the panel says that instead of showing the box.
      fide_search?: FideList.offered?(),
      fide_available?: FideList.available?(),
      form: Phoenix.Component.to_form(changeset, as: :registration)
    )
  end

  # `public_latest/1`: a hidden tournament takes no entries, and says so with
  # the same 404 as a tournament that never published.
  defp with_tournament(conn, slug, render_fun) do
    case Tournaments.public_latest(slug) do
      nil ->
        not_found(
          conn,
          gettext("No tournament has published under %{slug}, so there is nothing to enter.",
            slug: slug
          ),
          back: ~p"/"
        )

      snapshot ->
        queued = queued_since(slug, snapshot)
        conn = assign(conn, :places, places(snapshot.payload, queued))

        case Tournament.registration_state(snapshot.payload, DateTime.utc_now(), queued) do
          :open -> render_fun.(conn, snapshot.payload)
          reason -> closed(conn, slug, snapshot.payload, reason)
        end
    end
  end

  # The arbiter's switch, the window and the cap, judged now - see
  # `Tournament.registration_state/3`.
  defp registration_state(slug, snapshot) do
    Tournament.registration_state(
      snapshot.payload,
      DateTime.utc_now(),
      queued_since(slug, snapshot)
    )
  end

  # Entries that arrived after the snapshot was stored, which its `taken`
  # cannot include yet. Counted only when there is a cap to count them
  # against, so an uncapped form costs no query.
  defp queued_since(slug, snapshot) do
    if Tournament.max_players(snapshot.payload),
      do: Registrations.count_since(slug, snapshot.received_at),
      else: 0
  end

  # "12 of 60 places taken", or nil when the field is not capped.
  defp places(payload, queued) do
    case Tournament.max_players(payload) do
      nil -> nil
      max -> %{taken: min(Tournament.places_taken(payload, queued), max), max: max}
    end
  end

  # The arbiter has shut the door. A 404 would be wrong - the tournament is
  # right there on this site, and telling a player it does not exist sends
  # them to look for a link they already have. This says what happened and
  # points them at the tournament they were trying to enter.
  #
  # `403` rather than `200`, so a crawler or a script does not record a
  # closed form as a working one.
  #
  # Four reasons, one page: the arbiter closed it, it has not opened yet, its
  # closing time has passed, or the field is full. Each says which, because
  # "closed" said to somebody who is merely early sends them away for good.
  defp closed(conn, slug, payload, reason) do
    conn
    |> put_status(:forbidden)
    |> render(:closed,
      page_title: closed_title(reason),
      page_description: Meta.entries_closed(),
      payload: payload,
      slug: slug,
      reason: reason,
      back: ~p"/t/#{slug}"
    )
  end

  defp closed_title(:not_yet), do: gettext("Entries are not open yet")
  defp closed_title(:full), do: gettext("The field is full")
  defp closed_title(_closed_or_ended), do: gettext("Entries are closed")

  # The tournament's queue is full - see `OpenResults.Registrations` for what
  # it is bounded at and why per tournament. Nothing to do with this person:
  # it is the first thing the page says, because a refusal that reads like an
  # accusation sends somebody looking for a mistake they did not make.
  #
  # `503` rather than `403`: the door is shut by pressure rather than by the
  # arbiter, and it opens again. No `retry-after` goes with it, unlike the
  # rate limit's - that one knows when its window ends, and this one would be
  # guessing at when an arbiter will next clear a queue.
  defp queue_full(conn, slug) do
    conn
    |> put_status(:service_unavailable)
    |> render(:queue_full,
      page_title: gettext("Too many entries are waiting"),
      page_description: Meta.queue_full(),
      back: ~p"/t/#{slug}"
    )
  end

  defp too_many(conn, slug, retry_in_ms) do
    conn
    |> put_status(:too_many_requests)
    |> put_resp_header("retry-after", Integer.to_string(ceil(retry_in_ms / 1000)))
    |> render(:too_many,
      page_title: gettext("Too many entries"),
      page_description: Meta.too_many(),
      minutes: max(1, ceil(retry_in_ms / 60_000)),
      back: ~p"/t/#{slug}"
    )
  end

  # One not-found page for the whole site, so a mistyped slug looks the same
  # whichever page it was mistyped on.
  defp not_found(conn, message, back: back) do
    conn
    |> put_status(:not_found)
    |> put_view(html: OpenResultsWeb.TournamentHTML)
    |> render(:not_found,
      page_title: gettext("Not found"),
      page_description: Meta.not_found(),
      message: message,
      back: back
    )
  end

  @doc """
  The arbiter's pull: every entry this server holds for `slug`.

  Token-gated, and sitting alongside `/history` rather than beside the open
  read routes, because this is the ONE thing in the system that carries an
  email address. Everything a spectator can reach was chosen for publication
  by an arbiter; this was typed by a member of the public who expected the
  organiser to read it, and nobody else.

  The shape is a 1:1 render of the stored row rather than a bare array of
  payloads: the arbiter's machine has to tell one entry from another across
  repeated pulls so a discarded entry does not come back every time, and `id`
  is the only stable handle for that. A bare array would leave the client
  hashing the document to invent one.

  This server still never decides anything. It has no notion of an entry
  being "handled" - that is a fact about the arbiter's machine, and it is
  kept there. So this returns everything, every time, and is safe to call
  repeatedly.
  """
  def index(conn, %{"slug" => slug}) do
    # Break-glass only for the operator token. An installation key reaching
    # here has already been checked as this tournament's owner by
    # `OpenResultsWeb.InstallationAccess`; the tournament key applies on top.
    case TournamentKeys.authorize_read(slug, tournament_key(conn),
           break_glass: conn.assigns[:credential] == :operator
         ) do
      :ok -> render_index(conn, slug)
      {:error, reason} -> forbid(conn, reason)
    end
  end

  defp tournament_key(conn) do
    case Plug.Conn.get_req_header(conn, "x-openresults-key") do
      [key | _rest] -> key
      [] -> nil
    end
  end

  # 403 rather than 401, the same split the publish path makes: 401 means "you
  # may not talk to this server", 403 means "you may, but not to this
  # tournament". By here the caller has already proved it holds the ingest
  # token.
  defp forbid(conn, reason) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: Atom.to_string(reason), detail: forbid_detail(reason)})
  end

  defp forbid_detail(:key_required),
    do: "this tournament is claimed; send its key in x-openresults-key"

  defp forbid_detail(:key_mismatch),
    do: "the tournament key does not match the one this tournament was claimed with"

  defp render_index(conn, slug) do
    registrations = Registrations.list_for_tournament(slug)

    json(conn, %{
      "schema" => "openresults/registration-list",
      "version" => 1,
      "tournament_slug" => slug,
      "registrations" =>
        Enum.map(registrations, fn registration ->
          %{
            "id" => registration.id,
            "received_at" => DateTime.to_iso8601(registration.received_at),
            "payload" => registration.payload
          }
        end)
    })
  end
end
