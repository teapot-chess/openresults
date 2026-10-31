defmodule OpenResultsWeb.Plugs.Revalidate do
  @moduledoc """
  Answers "has this tournament changed since you last asked" without reading
  the tournament.

  ## The cost this removes

  Every page here is a plain request that loads the published snapshot and
  decodes it. On a 300-player, 11-round event that document is ~580 KB of
  JSON and the decode is about 17 ms of CPU - and the page refreshes itself
  every 20 seconds, per spectator, so a hall full of phones pays that
  repeatedly for a document that only changes when the arbiter publishes.

  The snapshot table appends one row per changed publish and collapses a
  byte-identical re-send, so **the newest row's id IS the version**. Asking
  for the id alone is a primary-key lookup; if the reader already has that
  id, the answer is `304 Not Modified` and the payload is never touched.

  ## Why not let the CDN hold it

  Cloudflare sits in front of this site and currently caches nothing
  (`cf-cache-status: DYNAMIC`), which is a real cost - but making the page
  publicly cacheable would mean a spectator could be handed a standings page
  that was correct thirty seconds ago, and there is no worse failure for a
  results site than a stuck page somebody trusts. Deliberately rejected by
  the maintainer on those grounds.

  So the header is `private, no-cache`: not "do not store", but "always ask
  first". The reader revalidates on every poll and gets the new page the
  instant it exists, while an unchanged one costs a primary-key lookup
  instead of half a megabyte of JSON.

  ## Why the tag is keyed

  The ETag is also the page cache's key, so two URLs that produce the same
  tag are one page as far as this site is concerned. It used to be a bare
  `phash2` of the path and query string - public, deterministic, unkeyed and
  27 bits wide - which meant a query string colliding with a target page's
  tag could be worked out offline in seconds, and the collision would then
  serve one page's body under the URL a legitimate reader asks for.

  It is now an HMAC under a value drawn once per boot, so there is nothing
  to compute against: the input nobody outside this node holds is the secret.
  Bounded even when it did collide - the tournament, the snapshot id and the
  locale are separate parts of the cache key, so a collision could never
  cross tournaments, outlive a publish or surface a 404 or a withheld page.
  Defacement inside one tournament, not disclosure.

  ## The filter bar and the page cache

  `?category=U1800`, `?sort=rating` and the rest of
  `OpenResultsWeb.FilterParams`'s query keys change what a page RENDERS -
  see `OpenResultsWeb.Tournament.Filter` - which `Page`'s own contract
  ("every reader of one URL gets byte-identical HTML") was never written to
  allow. The ETag digest already includes the raw query string (see
  `etag_for/3` below, unchanged by this), so a filtered request and the
  plain one could never collide or shadow each other even before this - the
  problem is not correctness, it is the KEY SPACE: `Page.put/5` bounds each
  tournament to 512 entries and wipes the lot when a busier one is
  published, `?category=U1800`, `?category=u1800` and `?category=U1800&x=1`
  each earning their own entry for what a reader would call one filter.
  That is real capacity a stranger typing query junk can burn through,
  repeatedly evicting a tournament's warm cache for every OTHER reader.

  Two ways to close that were on the table: key `Page` on a NORMALISED
  filter (fold every filtered request to one canonical query string first,
  so the key space is bounded by real filter combinations rather than by
  what a client can type), or never let a filtered request touch `Page` at
  all. This plug takes the second: `filtered?` in `revalidate/2` below is
  the whole decision, one guard clause rather than a second key shape for
  `Page` to learn. A filtered response still renders correctly and still
  answers a matching `If-None-Match` with a real 304 (see the `cond` below
  for why that half costs nothing to keep) - it is simply never read from
  or written to the ETS table, so `Page`'s key space stays exactly what it
  always was: bounded by how many distinct PAGES a tournament actually has,
  not by how many query strings a stranger can invent. An unfiltered
  request to the same path is untouched either way.

  ## What is not covered

  Only the read routes for a published tournament. The entry form is a form,
  the registration and snapshot APIs are authenticated, and none of them
  wants a browser deciding it already knows the answer.

  ## Compression

  Bandit will gzip a response on its own (`compress: true` is the library
  default) - except that it deliberately refuses to on any response carrying
  a *strong* ETag (see `Bandit.Compression.new/5`: a strong validator claims
  byte-for-byte identity, which a freshly gzipped stream cannot promise). This
  plug always sends a strong tag, so Bandit's own compression is silently
  off for every page this plug touches - confirmed with `curl -H
  "Accept-Encoding: gzip"` against a running server before this comment was
  written, not assumed.

  So compression is done here instead, once per publish rather than once per
  request: the moment a page is stored in `Page` (a cache miss), the gzip
  bytes are computed and stored alongside the identity ones under a second
  key. A cache HIT - the common case under load - then costs a lookup and a
  send either way, gzip or not; nothing is compressed on the request path
  itself. A reader whose `Accept-Encoding` does not mention gzip (or who asks
  before anybody has, i.e. the miss itself) gets the identity bytes exactly
  as before this change - this is additive, not a replacement of the default.

  `Vary: Accept-Encoding` is added (merged with `OpenResultsWeb.Plugs.Locale`'s
  own `Vary`, never overwriting it) because the response now genuinely
  depends on a second request header.
  """

  import Plug.Conn

  alias OpenResults.Snapshots
  alias OpenResultsWeb.FilterParams
  alias OpenResultsWeb.Plugs.Revalidate.Page

  @secret {__MODULE__, :etag_secret}

  # Below this, gzip's own framing overhead is not worth paying for - nothing
  # real this app serves is this small (the smallest measured page is a
  # 33 KB player card), so this only ever matters for a test fixture.
  @gzip_min_bytes 512

  def init(opts), do: opts

  @doc """
  Draws this node's ETag secret. Called once, at boot, by
  `OpenResults.Application`.

  Once per boot and not once per request, because the tag is an HTTP
  validator as well as a cache key: a value that moved under a reader would
  answer 200 to every revalidation and switch this plug off. Stable for the
  life of a snapshot is the property that matters, and a restart changing it
  costs one fetch per reader - the page cache does not survive a restart
  either.
  """
  @spec new_secret() :: :ok
  def new_secret, do: :persistent_term.put(@secret, :crypto.strong_rand_bytes(32))

  def call(conn, _opts) do
    case conn.params["slug"] do
      slug when is_binary(slug) -> revalidate(conn, slug)
      _no_slug -> conn
    end
  end

  defp revalidate(conn, slug) do
    visibility = visibility(conn, slug)

    case visibility in [:none, :hidden] || Snapshots.latest_id(slug) do
      # Nothing published under this slug - or something is, and moderation
      # hid it, which must look exactly the same from here: no ETag, no 304,
      # no cached page. The 404 that follows is not a thing to cache, and
      # there is no version to name.
      absent when absent in [true, nil] ->
        conn

      id ->
        locale = locale(conn)
        etag = etag_for(conn, id, locale, visibility)
        # Whether this request carries the filter bar's own query keys with
        # a real value - `?category=U1800`, `?sort=rating`, and so on. See
        # "The filter bar and the page cache" below for what this decides.
        filtered? = FilterParams.any_present?(conn.params)

        # Computed ahead of the `cond` rather than inside one of its clauses:
        # `&&`/`and` each open their own scope for the value they short
        # circuit to, so a `body = ...` bound on their right-hand side is not
        # visible in the clause's own body afterward. Never even asked for a
        # filtered request - see below.
        gzip_body =
          (not filtered? and gzip_acceptable?(conn)) && Page.get(slug, id, locale, gzip_key(etag))

        body = not filtered? and Page.get(slug, id, locale, etag)

        conn =
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, no-cache")
          |> add_vary_accept_encoding()

        cond do
          # A 304 costs nothing this plug needs to guard: it is a header
          # comparison, never a `Page` read, and it only fires when the
          # reader already holds the tag for THIS EXACT query string (the
          # digest covers it - see `etag_for/3`), filtered or not. Kept for
          # every request, filtered included, so a filtered link a reader
          # revalidates still gets the cheap answer.
          etag in request_etags(conn) ->
            conn |> stats(:not_modified) |> send_resp(304, "") |> halt()

          gzip_body ->
            conn
            |> stats(:hit)
            |> put_resp_header("content-encoding", "gzip")
            |> put_served_type(served_type(conn))
            |> send_resp(200, gzip_body)
            |> halt()

          # See "The filter bar and the page cache": a filtered request is
          # never looked up in `Page` at all, filtered or not - falls
          # straight through to the render-and-do-not-store branch below.
          body ->
            conn
            |> stats(:hit)
            |> put_served_type(served_type(conn))
            |> send_resp(200, body)
            |> halt()

          filtered? ->
            # Rendered normally, ETag and all - a filtered link still
            # revalidates correctly, it is just never the thing that gets
            # stored or read back from `Page`. No `stats/2` call: this is
            # not a page-cache decision, it is "the page cache was not
            # asked", which is exactly what `Stats.cache_index(nil)` already
            # means for every request this plug never reaches at all.
            conn

          true ->
            conn
            |> stats(:miss)
            |> register_before_send(&keep(&1, slug, id, locale, etag))
        end
    end
  end

  # The decision, for the admin stats page: read off the finished conn by
  # `OpenResultsWeb.StatsTelemetry` and counted in the same single increment
  # as the response itself, rather than costing one of its own here.
  defp stats(conn, outcome), do: put_private(conn, :openresults_page_cache, outcome)

  # A cache miss always answers with the identity bytes, whatever this
  # particular reader's own Accept-Encoding says - see the moduledoc's
  # "Compression" section for why: this is the rare event (once per
  # tournament version, not once per request), so simplicity here costs
  # nothing worth measuring. The gzip variant is computed once, right here,
  # for every reader *after* this one to find in `Page`.
  defp add_vary_accept_encoding(conn) do
    case get_resp_header(conn, "vary") do
      [] -> put_resp_header(conn, "vary", "accept-encoding")
      [existing | _] -> put_resp_header(conn, "vary", existing <> ", accept-encoding")
    end
  end

  # Deliberately simple: real browsers never list `gzip` in `Accept-Encoding`
  # while refusing it via `;q=0` - that combination only shows up in
  # hand-built test requests - so this does not parse q-values. Getting that
  # corner wrong would mean gzipping for a reader who asked not to receive
  # it, which is not a correctness bug for an HTML document every browser can
  # already decode; it is a missed preference, not a wrong answer.
  defp gzip_acceptable?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(String.downcase(&1), "gzip"))
  end

  # Same key `Page` already uses, just for a second body under one tag - no
  # change needed to that module, which does not care what the bytes mean.
  defp gzip_key(etag), do: etag <> "|gzip"

  # Set by `OpenResultsWeb.Plugs.Locale`, which the browser pipeline runs
  # before this one. The fallback is not decoration: this plug must not be
  # the thing that breaks if it is ever mounted somewhere that one is not.
  defp locale(conn), do: conn.assigns[:locale] || OpenResultsWeb.Locale.default()

  # Set by `OpenResultsWeb.Plugs.Visibility`, mounted ahead of this one. Looked
  # up here when it is not, for the same reason as the locale above - and
  # looked up rather than assumed `listed`, because assuming would serve a
  # hidden tournament's cached page from any scope that forgot the plug.
  defp visibility(conn, slug),
    do: conn.assigns[:tournament_visibility] || OpenResultsWeb.Plugs.Visibility.visibility(slug)

  # Only a plain 200 of the type this route serves (HTML, or the CSV a
  # `CsvDownload` route serves). A redirect, a 404 or an error page is not
  # this document and must never be served in its place.
  defp keep(%{status: 200} = conn, slug, id, locale, etag) do
    if served?(conn) do
      body = IO.iodata_to_binary(conn.resp_body)
      Page.put(slug, id, locale, etag, body)

      # Paid once here, per tournament version and language, not per request -
      # see the moduledoc's "Compression" section.
      if byte_size(body) >= @gzip_min_bytes do
        Page.put(slug, id, locale, gzip_key(etag), :zlib.gzip(body))
      end
    end

    conn
  end

  defp keep(conn, _slug, _id, _locale, _etag), do: conn

  # What this route serves: HTML, unless a plug ahead of this one said
  # otherwise (`OpenResultsWeb.Plugs.CsvDownload` for the exports). Read on a
  # hit to label the stored bytes, and on a miss to decide whether the
  # response is the document this route is for - an error page is HTML
  # whatever the route, and must never be stored as a CSV.
  @doc false
  # The content type of a stored body, from the short list of what this site
  # stores - one literal per clause, so no request can name a type.
  @spec put_served_type(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_served_type(conn, "text/csv"), do: put_resp_content_type(conn, "text/csv")
  def put_served_type(conn, "application/xml"), do: put_resp_content_type(conn, "application/xml")

  def put_served_type(conn, "application/atom+xml"),
    do: put_resp_content_type(conn, "application/atom+xml")

  def put_served_type(conn, "text/calendar"), do: put_resp_content_type(conn, "text/calendar")
  def put_served_type(conn, _html), do: put_resp_content_type(conn, "text/html")

  defp served_type(conn), do: conn.private[:revalidate_content_type] || "text/html"

  defp served?(conn) do
    type = served_type(conn)

    conn
    |> get_resp_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, type))
  end

  # The PATH is part of the identity, not just the snapshot - one document
  # renders as standings, as a round, and as a card per player, so a reader
  # moving from the standings to a player page must not be told that the page
  # they have not seen is unchanged. The QUERY STRING is now part of it too:
  # a round's own URL renders differently under `?display=1` (the projector
  # view), and without this a reader's `?display=1` request and somebody
  # else's plain one would share one ETag and shadow each other's page in
  # `Page` - whichever variant rendered first would be served to both.
  #
  # And the LOCALE, which is the one of the three that does not appear in the
  # URL at all: a reader whose browser asks for Dutch and a reader whose
  # browser asks for French request the same address and must not be handed
  # the same document. That matters here beyond the page cache - this string
  # goes to the browser as an HTTP validator, and a browser holding the Dutch
  # page must get a 200 rather than a 304 when it next asks in French.
  #
  # The path and the query string are the two an outsider chooses, so they go
  # through the MAC rather than a plain hash - see "Why the tag is keyed". The
  # id and the locale stay readable in front of it: they are already separate
  # parts of the cache key, and a tag one can read at a glance is worth
  # keeping for the afternoon somebody is reading a header dump.
  #
  # And the VISIBILITY, inside the MAC. A status change can change a page
  # without changing its snapshot id (it did while pending carried `noindex`,
  # until 2026-09-13), so a reader holding the page from before the change must
  # not be answered 304. `Page.forget/1` drops the stored bodies on the same
  # change; this is the half that reaches the reader's own cache.
  #
  # And the PUBLIC NOTICE's version, inside the MAC (the admin upgrade,
  # 2026-09-13). The operator's notice is on every page and belongs to no
  # snapshot, so setting, changing, clearing or expiring it changes every
  # page at once. Its version in the tag means a browser holding a page from
  # under another notice gets a 200, and - the tag being part of `Page`'s key -
  # no body rendered under another notice is ever served. `nil` when no notice
  # shows, which is how an expired notice stops matching with no admin action:
  # `OpenResultsWeb.Plugs.PublicNotice` compares the expiry with the clock on
  # every request. The bodies stored under an old notice's tags are not swept;
  # they are unreachable, bounded by `Page`'s per-tournament cap, and go at
  # the tournament's next publish.
  defp etag_for(conn, id, locale, visibility),
    do: ~s("#{id}-#{locale}-#{digest(conn, visibility)}")

  # `term_to_binary` rather than joining with a separator, because a separator
  # has to be a character that can appear in neither half, and this settles
  # that by construction. 16 bytes of a SHA-256 MAC: 128 bits is beyond any
  # collision search, and the rest would only make a header longer.
  defp digest(conn, visibility) do
    notice = OpenResultsWeb.Plugs.PublicNotice.version(conn)

    # A tournament shown as one section of an event prints its siblings' tabs,
    # which move when THEY publish or are hidden, not when this one does. The
    # epoch is what moves this tag then; 0, from one ETS miss, for a
    # tournament beside nothing. See `OpenResults.TournamentGroups`.
    epoch = OpenResults.TournamentGroups.epoch(conn.params["slug"])

    :hmac
    |> :crypto.mac(
      :sha256,
      secret(),
      :erlang.term_to_binary({conn.request_path, conn.query_string, visibility, notice, epoch})
    )
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  @doc false
  # The same keyed digest, for `OpenResultsWeb.HubCache`: one secret per boot
  # for every ETag this site sends.
  @spec sign(term()) :: String.t()
  def sign(term) do
    :hmac
    |> :crypto.mac(:sha256, secret(), :erlang.term_to_binary(term))
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  defp secret do
    case :persistent_term.get(@secret, nil) do
      nil ->
        # Only reachable if this plug runs without the application having
        # started - a unit test, in practice. Drawing one here keeps that
        # case working; the boot path is what makes it one value per node.
        new_secret()
        :persistent_term.get(@secret)

      secret ->
        secret
    end
  end

  # `If-None-Match` may carry several, comma separated, and a cache is
  # allowed to return a weak validator (`W/"..."`) for one we sent strong.
  # Compared after stripping that prefix rather than by exact string, or a
  # revalidation through any intermediary would silently always miss.
  defp request_etags(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end
end
