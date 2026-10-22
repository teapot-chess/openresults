defmodule OpenResultsWeb.Router do
  use OpenResultsWeb, :router

  # The read path, stripped to what a public results page actually needs.
  #
  # Gone from the scaffold's version: `fetch_session`, `fetch_live_flash` and
  # `protect_from_forgery`. This app has no accounts, so a session would exist
  # only to be created. Their absence is the feature: every response leaves
  # without a Set-Cookie, which is why these pages need no consent banner and
  # can be cached by anything in front of them. Add either one back only
  # alongside the thing that needs it.
  #
  # There are now two forms on this pipeline - the entry form and the report
  # form below - and they still need neither, for the reason set out where the
  # entry form is routed: they act on nobody's behalf, so there is no ambient
  # authority for a forged request to borrow. That reasoning is about THESE
  # forms. A form that ever acts for a visitor brings both plugs back with it.
  #
  # The language picker did not bring a session back either, and the argument
  # above is why: an explicit choice travels in the URL, and only a request
  # that carries one leaves a cookie behind. See `OpenResultsWeb.Locale`.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, html: {OpenResultsWeb.Layouts, :root}
    # Ahead of everything that renders, and - because this pipeline runs
    # before the scope's own plugs - ahead of `Revalidate`, which cannot
    # build an ETag or find a cached page without knowing the language.
    plug OpenResultsWeb.Plugs.Locale
    # The operator's notice, decided once, in this language - before
    # `Revalidate`, which keys the ETag and the page cache on its version.
    plug OpenResultsWeb.Plugs.PublicNotice
    plug :put_secure_browser_headers
    # The whole Content-Security-Policy: scripts allowed by hash only.
    plug OpenResultsWeb.Plugs.ContentSecurityPolicy
    # Runs AFTER, because it rewrites the header the line above just set.
    # See `OpenResultsWeb.Framing` for why every page here is safe to embed
    # and why that is a property of the site rather than a list of routes.
    plug OpenResultsWeb.Framing
  end

  # The admin panel - the thing the comments above were waiting for: the
  # first page on this site that acts on somebody's behalf. So it gets the
  # session and CSRF protection the public pipeline argues it does not need,
  # and it gets them on its own pipeline, so none of it can leak onto a
  # public response. Nothing from `:browser` is shared: no locale (English
  # only), no framing permission (the opposite), no revalidation or page
  # cache (see `OpenResultsWeb.Plugs.AdminHeaders`).
  #
  # The order is load-bearing:
  #
  #   1. `AdminAuth` first, before anything has touched the response, so a
  #      request without a valid Cloudflare Access token leaves as the
  #      router's own unknown-route 404 - same status, body and headers.
  #   2. `AdminHeaders` next, so every admin response from here on, error
  #      pages included, is no-store and unframeable.
  #   3. The session and the CSRF check only after the gate, so a stranger
  #      is never handed a session cookie, not even a refused one.
  pipeline :admin do
    plug OpenResultsWeb.Plugs.AdminAuth
    plug OpenResultsWeb.Plugs.AdminHeaders
    # Always HTML, whatever `Accept` says - negotiating would only add a 406
    # nobody needs.
    plug :put_format, "html"
    plug OpenResultsWeb.Plugs.AdminSession
    plug :put_root_layout, html: {OpenResultsWeb.Admin.Layouts, :root}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :ingest do
    plug OpenResultsWeb.Plugs.IngestAuth
  end

  # The routes that exist only when `OPENRESULTS_PUBLIC_PUBLISHING=enabled` -
  # see `OpenResultsWeb.Plugs.PublicPublishingGate`. Put FIRST in a scope's
  # `pipe_through`, so a gated route answers exactly like an unrouted one.
  pipeline :public_publishing do
    plug OpenResultsWeb.Plugs.PublicPublishingGate
  end

  # The public pages. A tournament is addressed by its slug and a player by
  # `no`, the tournament pairing number - the same two handles the payload
  # uses, so no database id appears in a URL either.
  # The read pages get their own scope so they can carry the
  # revalidation plug, which the entry form below deliberately must not: a
  # form is not a document, and a browser deciding it already has the answer
  # is exactly wrong there.
  #
  # `Visibility` runs before `Revalidate` on every route that has a slug, in
  # both scopes: a hidden tournament must not get a 304 or a cached page, and
  # the ETag is keyed on the status. See `OpenResults.Tournaments` for what
  # each status shows to whom.
  scope "/", OpenResultsWeb do
    pipe_through [:browser, OpenResultsWeb.Plugs.Visibility, OpenResultsWeb.Plugs.Revalidate]

    get "/t/:slug", TournamentController, :standings
    # The grid. In this scope and not the one below, because it is the
    # heaviest document this app renders - a row per player, a column per
    # round - and it is exactly the kind of page a hall full of phones asks
    # for repeatedly between two publishes. A read page that misses this plug
    # is not cached and nothing says so.
    get "/t/:slug/crosstable", TournamentController, :crosstable
    get "/t/:slug/round/:n", TournamentController, :round
    get "/t/:slug/player/:no", TournamentController, :player
    get "/t/:slug/team/:no", TournamentController, :team
    get "/t/:slug/teams", TournamentController, :teams
    get "/t/:slug/board-prizes", TournamentController, :board_prizes
  end

  # The event stream every open page of a tournament listens on, so a
  # publish reaches it within a second instead of at its next poll - see
  # `OpenResultsWeb.EventsController`. Outside `:browser`, which accepts only
  # HTML and would answer `EventSource`'s `text/event-stream` with a 406, and
  # outside `Revalidate`: a stream has no version to revalidate. Visibility is
  # decided in the controller, the same way and with the same 404 for a
  # hidden slug as for an unknown one.
  scope "/", OpenResultsWeb do
    get "/t/:slug/events", EventsController, :stream
  end

  # The hall display - the one public page that keeps a connection open, for
  # the reasons in `OpenResultsWeb.HallLive`. Its own scope and its own
  # `live_session`, and deliberately not behind `Revalidate`: the socket
  # re-reads the snapshot on every publish, so an ETag or a cached render
  # would only ever be a stale copy of what the socket is about to replace.
  #
  # Still no session and no CSRF token, for the router's reason at the top:
  # nothing here acts for anyone. The locale travels in the page's signed
  # LiveView session (`HallLive.session/1`), not a cookie. `HallGate` answers
  # a hidden or unknown slug with the standings page's own 404 before the
  # LiveView renders.
  scope "/", OpenResultsWeb do
    pipe_through [:browser, OpenResultsWeb.Plugs.Visibility, OpenResultsWeb.Plugs.HallGate]

    live_session :hall,
      root_layout: {OpenResultsWeb.Layouts, :hall_root},
      session: {OpenResultsWeb.HallLive, :session, []} do
      live "/t/:slug/hall", HallLive, :hall
      # The same LiveView, pairings only: the projector view, which follows
      # the newest round. Not the `?display=1` page of one round.
      live "/t/:slug/projector", HallLive, :projector
    end

    # Live boards - the games of a round as they are played. The same reasons
    # as the hall display for being outside `Revalidate`: the page is a
    # socket that re-reads the live games itself, so a cached render could
    # only ever be a stale copy of what the socket is about to replace. A
    # second `live_session` because its root layout is the site's own, not
    # the hall's full-screen one.
    # The whole round as one PGN, for a poller. A plain GET, but ahead of
    # the `live_session` all the same: `/live/:round/:board` would take
    # "pgn" for a board.
    get "/t/:slug/live/:round/pgn", LivePgnController, :round_pgn

    live_session :live_boards,
      root_layout: {OpenResultsWeb.Layouts, :live_root},
      session: {OpenResultsWeb.HallLive, :session, []} do
      # The broadcast: one game large, the round's games listed beside it.
      # `/live` goes to the newest round; `/live/:round` features its first
      # game in progress, `/live/:round/:board` that board. `/all` is the
      # grid of every board, and comes first so it is not read as a board.
      live "/t/:slug/live", BroadcastLive, :index
      live "/t/:slug/live/:round/all", BoardsLive, :round
      # The chosen games of a round, nothing else, for a projector: the
      # selection travels in the query (`?boards=1,3&auto=1`) so a hall PC
      # can bookmark it. Before `/:board` for the same reason as `/all`.
      live "/t/:slug/live/:round/projector", ProjectorLive, :show
      live "/t/:slug/live/:round", BroadcastLive, :round
      live "/t/:slug/live/:round/:board", BroadcastLive, :game
    end

    # A game as a PGN file. Not behind `Revalidate` either: it is built from
    # the live game on every request, at the broadcast delay.
    get "/t/:slug/live/:round/:board/pgn", LivePgnController, :show
  end

  scope "/", OpenResultsWeb do
    # `Visibility` does nothing on the three routes here without a slug.
    pipe_through [:browser, OpenResultsWeb.Plugs.Visibility]

    get "/", TournamentController, :index

    # One player, across every tournament published here - see
    # `OpenResultsWeb.PlayerHistory` for why this is keyed by FIDE id and not
    # by name. Not in the scope above: there is no single tournament, and so
    # no slug, for `Revalidate` to key an ETag against.
    get "/players/:fide_id", PlayerHistoryController, :show

    # An event: the tournaments that are sections of it, as cards. `:id` is
    # the random id the arbiter's app minted for the group, not a slug - so
    # `Visibility` and `Revalidate` have nothing to key on, and the page is
    # rendered per request from the members' own current snapshots. See
    # `OpenResultsWeb.EventController`.
    get "/e/:id", EventController, :show

    # What changed here, release by release - see
    # `OpenResultsWeb.ChangelogController` for why this sits beside
    # `players/:fide_id` rather than in the scope above: there is no
    # tournament and no slug behind it either, and nothing it shows can
    # change between two requests against the same running build.
    get "/changelog", ChangelogController, :show

    # Terms, acceptable use and privacy - what OpenPairings' consent dialog
    # links when no `terms_url` is set, and where a player who wants their
    # name removed is sent. Here and not behind `Revalidate` for the
    # changelog's reason, and one of its own: it shows server settings (the
    # operator's name and contact address), so it is rendered on every
    # request and a change in the panel is on the next one. See
    # `OpenResultsWeb.TermsController`.
    get "/terms", TermsController, :show

    # Follows a player from round to round - a redirect, so not in the
    # revalidated scope above. See `TournamentController.board/2`.
    get "/t/:slug/player/:no/board", TournamentController, :board

    # Entry. Under the tournament, beside `round` and `player`, because an
    # entry is for one event and the slug is the only handle there is - and
    # because a tournament that has not published here then 404s from the same
    # lookup as everywhere else, rather than needing its own rule.
    #
    # Still on `:browser`, which means still no session and still no CSRF
    # token, and that is a decision rather than an oversight. CSRF exists to
    # stop another site making a VISITOR'S browser act with the visitor's
    # ambient authority. There is no authority here: no account, no session,
    # nothing this form can do that a stranger with `curl` cannot do more
    # easily. A token would therefore protect nothing, while the session it
    # has to be checked against would put a Set-Cookie on a site whose whole
    # read path is deliberately cookie-free. Revisit both the moment this form
    # can do something on somebody's behalf.
    #
    # What actually guards it: an entry is only accepted for a slug that has
    # already published, and the controller rate-limits by address.
    get "/t/:slug/register", RegistrationController, :new
    post "/t/:slug/register", RegistrationController, :create

    # The entry form's FIDE search, against this server's own copy of the
    # list - see `OpenResults.FideList`. Returns an empty list rather than an
    # error whenever it cannot answer, because the form works without it.
    get "/t/:slug/fide", RegistrationController, :fide

    # Reporting a page to the operator - fake results, personal data, spam.
    # The same reasoning as the entry form above for having neither a session
    # nor a CSRF token: it acts on nobody's behalf, and a stranger with `curl`
    # can already do anything a forged request could. Guarded the same way,
    # too: only for a tournament the public can see, and rate-limited by
    # address. See `OpenResultsWeb.ReportController`.
    get "/t/:slug/report", ReportController, :new
    post "/t/:slug/report", ReportController, :create

    # Where a report stands, by the reference it was given on sending. Not
    # under a tournament: the reporter holds a number, not a slug. Read-only,
    # rate-limited by address, and it answers with the status and the
    # reporter's own text, never the operator's notes or anybody else's report.
    get "/report/status", ReportController, :status
  end

  # The two public documents that are XML, not HTML: a tournament's Atom feed
  # and the sitemap. Off `:browser` because a feed reader asks for
  # `application/atom+xml` and `accepts ["html"]` would turn it away with a
  # 406. The locale is still read, so a feed's titles are in the language
  # its reader's client asks for, and `Visibility` still runs, so a hidden
  # tournament's feed is the same 404 as a slug that never published.
  scope "/", OpenResultsWeb do
    pipe_through [OpenResultsWeb.Plugs.Locale, OpenResultsWeb.Plugs.Visibility]

    get "/t/:slug/feed.xml", FeedController, :show
    get "/sitemap.xml", SitemapController, :show
  end

  # Public publishing, the open half: an OpenPairings installation asking for
  # its own key. No token - the key is what it is asking for - so it is
  # guarded instead by the environment gate, the `registration_open` switch,
  # address blocks and two registration budgets. See
  # `OpenResultsWeb.InstallationController` and `docs/public-publishing.md`.
  scope "/api", OpenResultsWeb do
    pipe_through [:public_publishing, :api]

    post "/installations", InstallationController, :create
  end

  # Writes. Everything behind this pipeline can create a tournament page, so
  # the token gate is on the pipeline rather than on the action - a route added
  # here later is authenticated by default rather than by remembering.
  #
  # That now has two halves. The OPERATOR token is accepted on every route
  # here, as it always was. An INSTALLATION key is accepted on none of them
  # unless the route names what it does in `installation_access`, and naming
  # it is what makes `OpenResultsWeb.InstallationAccess` run that action's
  # checks - ownership included - before the controller. A route added here
  # without it refuses installation keys with the anonymous 401, which
  # `test/openresults_web/default_deny_test.exs` walks this router to prove.
  scope "/api", OpenResultsWeb do
    pipe_through [:public_publishing, :api, :ingest]

    # Minting a slug for the installation asking. Gated like the route above;
    # the operator token is refused in the controller with
    # `installation_key_required`, since there is no installation to bind to.
    post "/tournaments", MintController, :create, private: %{installation_access: :mint}
  end

  scope "/api", OpenResultsWeb do
    pipe_through [:api, :ingest]

    post "/snapshots", SnapshotController, :create, private: %{installation_access: :publish}

    # A hall relay's moves, clocks and results, board by board - see
    # `OpenResultsWeb.LiveBoardController` and docs/live-boards-api.md. A write
    # like a publish, so behind the same gate; its own budget for an
    # installation key, because it is called every few seconds.
    #
    # The one route a relay key (`OpenResults.RelayKeys`) is accepted on.
    post "/tournaments/:slug/live", LiveBoardController, :create,
      private: %{installation_access: :live, relay_access: true}

    # The tournament's publisher asking for a relay key for its own hall box,
    # and withdrawing the ones it made - `OpenResultsWeb.RelayKeyController`.
    # The credentials of a publish, the ownership check of a publish, and the
    # tournament's key in the header as for a publish. A relay key is NOT
    # accepted here: a box must not be able to mint itself a successor.
    post "/tournaments/:slug/relay-keys", RelayKeyController, :create,
      private: %{installation_access: :relay_key}

    delete "/tournaments/:slug/relay-keys", RelayKeyController, :delete,
      private: %{installation_access: :relay_key_revoke}

    # History is a WRITE-side privilege, not a read-side one. An earlier
    # snapshot can hold a round or board the arbiter has since retracted, so
    # walking back through the append-only table is exactly as sensitive as
    # publishing into it.
    get "/tournaments/:slug/history", SnapshotController, :history,
      private: %{installation_access: :history}

    # Whether the slug is claimed with the key in `x-openresults-key` - what a
    # hosted OpenPairings asks before adopting a key from a backup file
    # (docs/public-publishing.md, "Checking a tournament key"). Operator
    # token only: no `installation_access`, so an installation key is the
    # anonymous 401. A read; it never claims.
    get "/tournaments/:slug/claim", ClaimController, :show

    # Takedown. On the write pipeline because it is a write - the most
    # destructive one here - and gated a second time by the tournament key,
    # like publishing.
    #
    # It removes every snapshot, the whole history, and the registration queue
    # with the email addresses in it. Until this route existed the only way to
    # remove a published tournament was to SSH in and edit SQLite, which meant
    # that in practice a tournament published by accident stayed published.
    delete "/tournaments/:slug", SnapshotController, :delete,
      private: %{installation_access: :delete}

    # The arbiter pulling what the public form collected. Token-gated for the
    # same reason as history and for one of its own: this is the only route
    # in the system that returns an email address.
    get "/tournaments/:slug/registrations", RegistrationController, :index,
      private: %{installation_access: :registrations}
  end

  # Reads. Open, because the CURRENT snapshot only ever contains what an
  # arbiter chose to publish: an unpublished round and a hidden board were
  # withheld when the document was built and were never sent here.
  #
  # That guarantee is about the current document only. Earlier ones can hold
  # what has since been retracted, which is why history is above, behind the
  # token, and why `show` refuses `?at=` rather than ignoring it.
  scope "/api", OpenResultsWeb do
    pipe_through :api

    # What this server is and whether it takes installations - the first thing
    # an OpenPairings copy in public mode asks. Open, and never cached: see
    # `OpenResultsWeb.ServerController`.
    get "/server", ServerController, :show

    # Reachable for a pending tournament and not for a hidden one, which gets
    # the same 404 as a slug that never published - see
    # `SnapshotController.show/2`.
    get "/tournaments/:slug", SnapshotController, :show
  end

  # The admin panel. Behind Cloudflare Access at the edge and checked again
  # by `:admin` - see `OpenResultsWeb.Plugs.AdminAuth` and docs/admin.md.
  #
  # Only routes that exist are linked from the panel's navigation
  # (`OpenResultsWeb.Admin.Layouts.nav_items/1`), so a section appears there
  # the moment its route is added here. An `/admin/...` path with no route
  # is the router's ordinary 404, for admins and strangers alike.
  #
  # Every action is a pair on ONE path: GET is its confirmation page, POST
  # carries it out, and the controller plugs `OpenResultsWeb.Admin.Confirmation`
  # on the POST so it acts only when sent from that page. The one POST that
  # changes nothing is `address-blocks/new`, which checks a block and shows
  # its confirmation. `test/openresults_web/admin_actions_test.exs` walks
  # these routes to hold every other POST to that rule.
  scope "/admin", OpenResultsWeb.Admin do
    pipe_through :admin

    get "/", DashboardController, :show

    get "/switches/:key", SwitchController, :confirm
    post "/switches/:key", SwitchController, :update

    get "/tournaments", TournamentController, :index
    get "/tournaments/:slug", TournamentController, :show
    get "/tournaments/:slug/approve", TournamentController, :confirm_approve
    post "/tournaments/:slug/approve", TournamentController, :approve
    get "/tournaments/:slug/hide", TournamentController, :confirm_hide
    post "/tournaments/:slug/hide", TournamentController, :hide
    get "/tournaments/:slug/unhide", TournamentController, :confirm_unhide
    post "/tournaments/:slug/unhide", TournamentController, :unhide
    get "/tournaments/:slug/delete", TournamentController, :confirm_delete
    post "/tournaments/:slug/delete", TournamentController, :delete
    get "/tournaments/:slug/transfer", TournamentController, :confirm_transfer
    post "/tournaments/:slug/transfer", TournamentController, :transfer

    # How far behind the game spectators see the live boards - see
    # `OpenResults.LiveBoards`. Its own pair, like every change here.
    get "/tournaments/:slug/live-delay", TournamentController, :confirm_live_delay
    post "/tournaments/:slug/live-delay", TournamentController, :live_delay

    # A tournament's relay keys: the list, and the confirmed pairs that make
    # and revoke one. `new` comes before `:id` so it is not read as an id.
    get "/tournaments/:slug/relay-keys", RelayKeyController, :index
    get "/tournaments/:slug/relay-keys/new", RelayKeyController, :confirm_create
    post "/tournaments/:slug/relay-keys/new", RelayKeyController, :create
    get "/tournaments/:slug/relay-keys/:id/revoke", RelayKeyController, :confirm_revoke
    post "/tournaments/:slug/relay-keys/:id/revoke", RelayKeyController, :revoke

    get "/installations", InstallationController, :index
    get "/installations/:id", InstallationController, :show
    get "/installations/:id/suspend", InstallationController, :confirm_suspend
    post "/installations/:id/suspend", InstallationController, :suspend
    get "/installations/:id/unsuspend", InstallationController, :confirm_unsuspend
    post "/installations/:id/unsuspend", InstallationController, :unsuspend
    get "/installations/:id/revoke", InstallationController, :confirm_revoke
    post "/installations/:id/revoke", InstallationController, :revoke
    get "/installations/:id/move-tournaments", InstallationController, :confirm_move
    post "/installations/:id/move-tournaments", InstallationController, :move
    get "/installations/:id/trust", InstallationController, :confirm_trust
    post "/installations/:id/trust", InstallationController, :trust
    get "/installations/:id/untrust", InstallationController, :confirm_untrust
    post "/installations/:id/untrust", InstallationController, :untrust
    # GET the form; GET with `check=1` the confirmation; POST the change.
    # A private name: its own form is the page that posts, carrying the marker.
    get "/installations/:id/label", InstallationController, :edit_label
    post "/installations/:id/label", InstallationController, :label
    get "/installations/:id/limits", InstallationController, :confirm_limits
    post "/installations/:id/limits", InstallationController, :limits

    get "/reports", ReportController, :index
    get "/reports/:id", ReportController, :show
    get "/reports/:id/resolve", ReportController, :confirm_resolve
    post "/reports/:id/resolve", ReportController, :resolve

    get "/address-blocks", AddressBlockController, :index
    get "/address-blocks/new", AddressBlockController, :new
    post "/address-blocks/new", AddressBlockController, :preview
    post "/address-blocks", AddressBlockController, :create
    get "/address-blocks/:id/unblock", AddressBlockController, :confirm_unblock
    post "/address-blocks/:id/unblock", AddressBlockController, :unblock

    get "/action-log", ActionLogController, :index

    # Read-only, and cheap to open: see `OpenResults.Stats`.
    get "/stats", StatsController, :show

    # Server settings and the public notice. A setting's and the notice's
    # confirmation is a GET carrying the value (nothing here is personal), so
    # every POST is a confirmed action like the rest.
    get "/settings", SettingsController, :index
    get "/settings/notice", SettingsController, :confirm_notice
    post "/settings/notice", SettingsController, :notice
    get "/settings/notice/clear", SettingsController, :confirm_clear_notice
    post "/settings/notice/clear", SettingsController, :clear_notice
    get "/settings/:key", SettingsController, :confirm_setting
    post "/settings/:key", SettingsController, :setting
    get "/settings/:key/reset", SettingsController, :confirm_reset
    post "/settings/:key/reset", SettingsController, :reset

    # Test-only: a harmless confirmation page and the POST behind it, so the
    # confirmation pattern and the CSRF check are proven through this exact
    # pipeline. Compiled in only where config/test.exs asks for it; no
    # production route table has it.
    if Application.compile_env(:openresults, :admin_confirmation_probe, false) do
      get "/confirmation-probe", ConfirmationProbeController, :new
      post "/confirmation-probe", ConfirmationProbeController, :create
    end
  end
end
