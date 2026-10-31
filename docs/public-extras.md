# Printing, feeds, embeds, the sitemap and the hall display

None of these compute anything or read anything the pages do not already
show. Each honours the arbiter's display switches the same way the pages do.

## Printing

Print any page from the browser. The print stylesheet (the `@media print`
block at the end of `assets/css/app.css`) forces black on white, hides the
site's own furniture, keeps the tournament's name and the current round chip,
repeats table headers on each sheet and never splits a row.

## The feed - `/t/<slug>/feed.xml`

Atom. One entry per state the tournament has reached, with the state in the
entry id so a feed reader shows each one once:

| id suffix | when |
|---|---|
| `#round-N-pairings` | round N is published, and pairings are shown |
| `#round-N-results` | every board of round N has a result, and its results are public |
| `#standings-N` | the standings reflect round N, and standings are shown |

Every entry carries the current snapshot's time. A hidden tournament's feed is
the same 404 as one that never published.

## A player's board - `/t/<slug>/player/<no>/board`

A redirect to the latest published round, with `#board-B` when the player is
on a board there. 404 for a player not in the tournament; withheld when
pairings are not published.

## Embedding - `?embed=1`

```html
<iframe src="https://results.example.org/t/gent-spring-open-2026?embed=1"
        style="width:100%;height:40rem;border:0" title="Standings"></iframe>
```

Works on any tournament page: standings, a round, the cross-table, a card.
The site's header, the operator's notice, the filter bar and the footer are
left out; one link back to the full page stays. Links open in the whole tab
(`<base target="_top">`). Which sites may frame the page is still decided by
`PUBLIC_FRAME_ANCESTORS` - see `OpenResultsWeb.Framing`.

## The sitemap - `/sitemap.xml`

Every listed tournament (moderation-visible and listed by their arbiter):
standings, cross-table and each published round, as far as the arbiter
publishes each. Also `/federations`, each federation's listing, and the player
pages of players the FIDE list says are adults (see below). Player cards are
never listed. `robots.txt` is static and
cannot know this site's host, so submit the sitemap to search engines
directly, or add a `Sitemap:` line to `priv/static/robots.txt` on deploy.

## Listings and search - `/federations`, `/f/<code>`, `/search`

The front page shows only what is live, upcoming, or finished in the last 14
days. Everything else is under its federation: `/f/BEL` has live, upcoming
and the last 30 days, then the archive, 50 a page (`?page=2`), filterable by
year (`?year=2025`, offered when there is more than one). `/f/none` holds
tournaments that name no federation or hide it. A tournament that never
published a round and started more than 30 days ago is left out of the
listings (its own address still works). Unapproved tournaments are listed
and searchable, marked "unapproved".

`/search?q=` finds tournaments by name or city and players by name or FIDE
ID, at least three letters, 30 searches a minute per address, never indexed.
Players come from approved tournaments only.

All of these read the results index (`OpenResults.ResultsIndex`), filled at
ingest. After an upgrade, existing tournaments are indexed in the background
on the first boot; `mix openresults.reindex [--force]` does it by hand.

## Player pages - `/players/<FIDE ID>`

Every approved tournament published under that FIDE ID, newest first, with a
year filter, headed by the name, title, federation and current ratings from
this server's copy of the FIDE list. A result whose name plainly does not
match the FIDE list's name for that ID is dropped (see
`OpenResults.ResultsIndex.NameMatch` for the rule). Players who may be under
18 by the FIDE list's birth year, or whose birth year is unknown, get
`noindex` and stay out of the sitemap. A page the admin hid answers 404.

## The hall display - `/t/<slug>/hall`

A full-screen page for a television or a projector in the playing hall. No
login, one address per tournament, linked from a card near the top of the
standings, cross-table and round pages (one card for each of the two screens,
once per tournament, not per round). Open it in a browser on the screen's
computer and press the Full screen button (or F).

It cycles through, a page at a time:

1. **Pairings** of the current round - the newest published one - twelve
   boards a page, with results as they arrive (team matches for a team
   event paired by matches);
2. **Find your board** - every player in the round alphabetically (accents
   ignored), with board and colour, 28 names a page and the letters each page
   covers ("Names A to De");
3. **Results** - how many are in, and the latest twelve, newest first; a
   result that arrived while the screen was on is marked for five minutes;
4. **Standings** - the top N, twelve a page;
5. **Announcement** - the arbiter's text, when there is one.

A view with nothing to show is skipped. The header carries the tournament's
name, the round and its date, a "Final round" badge on the last round, and a
clock (the screen's own time). A tap or the space bar pauses on the page
showing; the arrow keys step.

**Holding on a new round.** While the newest round is paired and none of its
results is in, the cycle shows only the pairings, the name list and the
announcement - what everyone in the hall is looking for at that moment. A
newly published round jumps the screen straight to its pairings. The first
result ends the hold.

**Settings** travel from OpenPairings in the snapshot (`tournament.hall`, see
`docs/snapshot-schema.md`), set on its Results-site settings page: each view
on or off, seconds per page (default 15), how many standings rows (default
10), the hold, and the announcement. Two more are for whoever sets up the
screen, in the URL:

| parameter | effect |
|---|---|
| `?theme=black\|white\|ultra` | the colours: black (the default), white (pure white, black text), or ultra contrast (pure black and white, a yellow accent, bold, thick rules, every text pairing above 7:1). `light` still works and means white |
| `?views=names,pairings` | only these views on this screen - for a hall with two screens. It can only narrow what the arbiter chose |
| `?lang=nl` | the language, as on every page |

**Never more than the public pages.** No pairings, names or results when the
arbiter withholds round pages; no standings when they withhold standings;
no rating, title or federation beside a name when that tick is off; no byes
in the name list when byes are hidden; no result from a round whose results
are not public. A hidden or unknown tournament is the standings page's own
404, and a tournament hidden while a screen shows it leaves the screen.

**How it stays current.** Unlike every other page here, it keeps a
connection open: it is a LiveView on a PubSub topic per tournament
(`OpenResults.TournamentEvents`), told about every publish and every status
change, so a result appears within a second of the arbiter publishing it.
It is not behind the page cache or the ETag revalidation - the socket
re-reads the snapshot itself - and each page turn also checks the snapshot id
(one ETS lookup), so a message lost to a reconnect costs one page, not the
round. No session and no cookie: the socket is declared without session
connect-info (see `OpenResultsWeb.Endpoint`), and the language travels in the
page's signed LiveView session. The reverse proxy must pass WebSockets
through (Cloudflare's tunnel does); LiveView falls back to long polling
where it cannot.

## The projector view - `/t/<slug>/projector`

The same screen machinery as the hall display, with the pairings only, in
large type, and always the **newest round**: it follows a newly published
round and the results as they arrive, by itself, over the same connection
(LiveView on `OpenResults.TournamentEvents`, never the page cache). It
respects the same display rules: no boards when the arbiter withholds the
pairings, no result from a round whose results are not public, a hidden or
unknown tournament is the standings page's own 404 and a screen left open on
a tournament that is then hidden empties. `?views=` is ignored; the hall's
per-view settings are not needed (the projector shows the pairings whenever
the public round pages exist), but the seconds per page are used.

**On-screen controls**, on both screens, in the top corner: Full screen
(also the F key; uses the browser's Fullscreen API with the WebKit prefix, and
the button is hidden where the browser has none, e.g. iPhone Safari) and the
colours Black / White / Ultra contrast. The controls fade out after four
seconds without a mouse move, tap or key and return on any. A colour chosen
on the screen is remembered in that browser (localStorage); `?theme=` in
the URL wins over what was remembered. `tournament.hall` in the snapshot
carries no colour option today, so a per-tournament default is not offered;
adding one would be a snapshot change on the OpenPairings side. The hall
clock shows seconds (HH:MM:SS) and ticks in the browser, with no server
round-trips.

The older per-round page (`/t/<slug>/round/<n>?display=1`) is unchanged and
still works for bookmarks: it shows that one round, a plain document that
polls; it is no longer linked from the site, and has no on-screen controls.
