# Design: OpenResults as a replacement for chess-results.com

Status: proposal, 2026-10-31. **Phase 1 is built** (branch
`results-hub-phase1`); where it departs from the text below:

- Removal is by email to the operator, not a report-form reason (the
  maintainer's answer to section 6), so there is no `scope` beyond hiding
  the whole page.
- Player pages and player search use approved tournaments only; pending ones
  are in the tournament listings and search, marked unapproved.
- The name check runs at ingest (stored, for the admin list) and again when
  the page is drawn, against the FIDE list in force then, so a new list
  never leaves a stale verdict on a page.
- The front page still decodes the snapshots of the tournaments it shows,
  for the event grouping; the listings read only the index.
- The sitemap's tournament URLs still come from the tournaments table, not
  the index.
- A stale shell is a tournament with no published round whose start date is
  more than 30 days ago.

**Phase 2 is built** (branch `results-hub-phase2`, with OpenPairings'
`results-series`), **without national ids**: the maintainer's decision is
that only the FIDE id is public, so there is no `players[].national_id`,
no national-id page and no alias table (gap #4 and section 2's rule 3 are
dropped, not postponed). Built, and where it departs from the text below:

- CSV exports at `/t/:slug/{standings,crosstable,pairings,players}.csv`,
  each behind its page's switch and holding only that page's columns
  (`OpenResultsWeb.Export`); cached like the pages (ETag on the snapshot id,
  body in the page cache), `noindex`. The FIDE id is in the player list
  only where the player cards are published.
- Series: additive `tournament.series_id` (publish-v1, both copies). The
  "other editions" block lists same-id, same-publisher, visible, listed
  editions; their pages are touched like event siblings on any change.
- `/f/:code/feed.xml` and `/f/:code/calendar.ics`: approved tournaments
  only (a pending one's "unapproved" mark would not travel into somebody's
  calendar), tournaments never players, no event for hidden dates.
- JSON-LD `SportsEvent` on every tournament page: name, dates, city, url.
- The sitemap is always an index (not only past 50,000 URLs), built from
  the results index; the tournament URLs no longer come from the
  tournaments table and decoded snapshots.
- `/tournaments` (A-Z, by the folded name) and `/statistics` (tournaments
  and player entries per federation and month; tournaments that hide
  their dates are not counted by month). Counts by title were not built.

The original proposal follows unchanged. Guesses are marked
**(guess)**; everything else was read from this repo, OpenPairings, or
chess-results.com itself (read-only).

The idea as saved: *OpenResults grows player pages that follow a player
across tournaments*. That page already exists in a minimal form
(`/players/:fide_id`, `OpenResultsWeb.PlayerHistory`). This document is about
the rest: what it takes for a player, an organiser or a spectator to stop
opening chess-results.com.

Fixed product decisions this design respects: live results are not live
boards (boards come from Alnasl); no norm indicators; no round times; a
category filter (built); and the README's rule that **the server computes
nothing** - anything that is a calculation is sent by OpenPairings.

## 1. What chess-results offers, what we have, what is missing

### chess-results.com, by audience

- **Spectators / players:** a tournament database filterable by federation
  (~200 codes, Austria split by region), by state (running, starting in the
  next 7 days, finished in the last 7 days, "with games in the last 10
  weeks"), sorted by last upload; per tournament: starting rank, alphabetical
  list, pairings per round, board pairings, ranking after any round,
  crosstable, statistics (federations/titles), team views (team pairings,
  team ranking, board-by-board), a player card with per-game rating change
  (Elo calculation with K) and performance; a **player search** across all
  tournaments by last/first name, club, national "Ident-Number", FIDE id,
  federation, end-date range, birth year, minimum rating; a game search with
  PGN; ~40 languages; print and Excel export of every list.
- **Organisers:** zero-effort publishing *from Swiss-Manager* (the real moat:
  it is the default upload target), tournament series ("tournament
  selection" links between editions), online registration, a calendar,
  federations linking it as their official results page.
- **Mobile:** works, but is a 2005-era table site; heavy pages, ads.

### Where OpenResults already is

Standings with tiebreak working, starting rank before round 1, round pages
live as results arrive, crosstable, player card, team pages and board prizes,
club/federation/category filter and column sort, event grouping of sections
(`/e/:id`), year filter and client-side search on the front page, Atom feed
per tournament, sitemap, embeds, print CSS, hall/projector, live boards via
Alnasl, entry form with FIDE search, reports, takedown, moderation, a
cookie-free cached read path, EN/NL/FR, and the FIDE-id player history
(listed tournaments only, honours display rules).

### What is missing, ranked by what makes people switch

Ranking rationale **(guess, but a confident one)**: players go where their
results are findable; organisers go where players already look. Discovery and
the player page carry the switch; per-tournament features are already at
parity or better.

| # | Gap | Who it moves | Computes? | Phase |
|---|---|---|---|---|
| 1 | **Federation/country listings** (`/f/BEL`), running/upcoming/recent, paged archive. Today the front page is one flat list of everything. | everyone | no | 1 |
| 2 | **Server-side search**: tournaments by name/city, players by name. Today search is in-browser over whatever the front page loaded. | players | no | 1 |
| 3 | **A real player page**: header (name, title, fed, current FIDE rating from our list copy), every tournament with score, place, rating at the time, performance when published; reachable from search. | players | no | 1 |
| 4 | **Players without a FIDE id** - most Belgian club and youth play. Needs a national id in the snapshot. | players, federation | no | 2 |
| 5 | **Rating change per game / per tournament** ("what did I gain"). The single most-used chess-results card feature **(guess)**. Must be sent by OpenPairings. | players | yes - OpenPairings | 3 |
| 6 | **Export** (CSV of standings, crosstable, pairings, player list). Renders what was sent. | organisers, journalists | no | 2 |
| 7 | **Standings after round N**. The snapshot carries only the current standings; older versions are behind the token for a reason (retractions). Needs a contract addition. | spectators | yes - OpenPairings | 3 |
| 8 | **Tournament series** (last year's edition). `event_id` groups sections, not editions. | organisers | no | 2 |
| 9 | Alphabetical list, statistics page (counts by federation/title) | spectators | counting only | 2 |
| 10 | Federation-wide feeds: Atom and iCal (all-day events, dates only - no round times) per federation | organisers, clubs | no | 2 |
| 11 | Tournaments not run in OpenPairings (Swiss-Manager, SWAR, Vega). Without this coverage is capped at OpenPairings' share. | everyone | - | open question |

Out of scope on purpose: game search/PGN database (Alnasl's domain, and a
different product), norms, round times, ads, 40 languages.

## 2. Player identity across tournaments

### What the snapshot already carries

`players[]`: `no`, `name`, `title`, `rating`, `federation`, `fide_id`,
`club`, `category`/`categories` (gated), `sex` (gated, default off).
`standings.rows[]`: `rank`, `points`, `performance` (gated). OpenPairings'
`player_row/2` is an allowlist; birth date/year, national id, email, phone
and `norm_data` never travel. `fide_id` is not behind a display key.

This server also holds FIDE's own list (`fide_list.db`: id, name, federation,
title, **birth year**, three ratings), refreshed daily.

### Matching rules

1. **FIDE id is the key**, as today. Never merge on a name, ever - the
   existing moduledoc's reasoning stands.
2. **Guard against a mistyped FIDE id.** At index time, compare the
   snapshot's name with the FIDE list's name for that id (normalised: case,
   diacritics, "Last, First" order). Mismatch: the appearance is indexed but
   *not attached* to that player's page, and the admin panel lists it. A typo
   by one arbiter must not put a stranger's result on a real player's page.
   FIDE id absent from the list (new, inactive-removed): attach, with no list
   header.
3. **National id (phase 2).** Additive contract field
   `players[].national_id: {"federation": "BEL", "id": "12345"}`. Key on the
   pair. Only for federations whose id list is itself public (KBSB's monthly
   `players_YYYYMM.zip` is) **(guess for other federations)**. Anything in
   the snapshot is public through `GET /api/tournaments/:slug`, so there is
   no "send it but don't show it"; a hashed id is pseudonymous personal data
   and brute-forceable over a 5-digit space, so it buys nothing. If it is
   sent, it is behind a display key like `sex`.
   A player with both ids: the FIDE id wins; the national id links the
   pre-FIDE junior history to the same page (an alias row, see section 4).
4. **No id at all:** no player page. Name search still finds the
   *appearance* and links to that tournament's own card - one hit per
   tournament, never grouped. Honest, and no false merges.
5. **Duplicates.** FIDE ids are stable; FIDE merges duplicate ids rarely and
   we have no feed of merges **(guess)**. An operator-only alias table
   (`player_aliases`: from-key -> to-key) handles the handful that happen,
   and the national-id link above uses the same table.

### Privacy (GDPR; Belgian operator, EU) - design position, not legal advice

- **Two controllers, two purposes.** The organiser publishes a tournament
  (sports results, legitimate interest, Art. 6(1)(f)) - unchanged. The
  *operator* building a cross-tournament profile is a **new purpose** with
  its own balancing test, and it is the operator's. It is closer to
  profiling, so it has to be modest: only what tournaments already
  publish, only listed + approved tournaments, nothing the arbiter hid.
- **Right to object (Art. 21) without a fight.** A player may ask for their
  player page to be removed; we comply on identity alone, no reasons
  required. New table `player_suppressions` (key, scope, created_at, note):
  - scope `history`: no `/players/...` page, absent from player search and
    from the sitemap. The tournaments themselves are untouched (the
    organiser's publication, their call).
  - scope `name` (escalation, operator decides): the name is rendered as
    "withheld" on every page and stripped from the open JSON, at render time
    - snapshots stay as sent, so the arbiter's record is intact and a
    later publish cannot undo it.
  The request path is the existing report form plus a "remove my player
  page" reason, and `/terms` says so. Reports keep their 90-day contact
  retention.
- **Minors.** The FIDE list gives a birth year for many juniors. Proposal:
  a player under 18 by that year gets `noindex` on their player page and is
  left out of the sitemap, whatever the global setting; the page itself
  still exists for the parent looking for it. Without a birth year we cannot
  know, so the default for *all* player pages is the open question 1.
- **Nothing new is stored about people.** The index tables in section 4 are
  derived copies of public snapshot fields, deleted with the tournament on
  takedown, rebuilt from snapshots. `docs/privacy-retention.md` gains one
  row (suppressions: kept until the player withdraws the request).
- Birth year, sex and national id are never shown on a player page in
  phase 1, even though the FIDE list has birth year.

## 3. Discovery

### Listings and search

- `/f/:code` per federation (from `tournament.federation`; absent = "no
  federation" bucket), and `/federations` with counts. Sections: live,
  upcoming, finished in the last 30 days, then a paged archive by month.
  Filter by year, city, team/individual, FIDE-rated. All plain links and
  query strings, no script.
- Front page becomes: live + upcoming + last 14 days, plus the federation
  picker. Today it renders every listed tournament in one response; that
  does not survive 5,000 tournaments.
- `/search?q=`: tournaments (name, city) and players (name -> FIDE-id pages,
  national-id pages, then id-less appearances), via SQLite FTS5 with
  diacritics removed (FTS5 is already used by `FideList.Store`).

### SEO and feeds

- Already: indexable tournament pages, sitemap. Add listings and (subject to
  question 1) player pages to the sitemap, a sitemap index once it passes
  50,000 URLs, `schema.org/SportsEvent` JSON-LD on standings pages, canonical
  URLs. Googling one's own name is how a lot of players reach
  chess-results **(guess)** - player-page indexing is the biggest SEO lever,
  and the biggest privacy one.
- `/f/:code/feed.xml` (Atom: new tournaments and finished ones) and
  `/f/:code/calendar.ics` (upcoming, all-day, dates only). Cheap, cacheable.

### How tournaments get here

Already: desktop OpenPairings in public mode registers an installation and
publishes (consent once per installation); hosted OpenPairings publishes with
the operator token; a federation can run its own OpenResults (the licence
says so). Nothing changes on that path for phase 1 - everything in phase 1 is
derived from snapshots that already arrive, from every OpenPairings version
already in the field.

Not covered: other OpenResults servers (question 10) and other pairing
programs (question 6).

### Trust and spam

The existing model holds and extends naturally:

- *pending* is public at its URL, on listings and in tournament search
  (consistent with the 2026-09-13 decision) but is **not** in player pages
  or player search - that row is what stops invented results on real
  players' pages, and it now also covers the national-id pages.
- *trusted* installations skip pending. A federation's own machines are the
  obvious candidates; a small "published by a trusted organiser" marker on
  listings is cheap (question 5).
- New: listings leave out stale shells - no round published and the start
  date more than 30 days ago (question 9). Test tournaments are
  chess-results' worst clutter.
- A tournament claiming `federation: BEL` is a claim, not a fact. Listings
  show it; nothing in this design treats federation as authority.

## 4. Data model and architecture

### Today

One append-only `snapshots` table (JSON payload), `tournaments` (status,
owner, event), ETS caches: `LatestIdCache`, `BodyCache` (decoded payloads),
`StatusCache`, and the rendered-page cache keyed by snapshot id / locale /
notice / status epoch. The tournament pages are fast. **The two
cross-tournament reads are not**: the front page and `PlayerHistory` both
call `Snapshots.list_current/1`, which loads and decodes the newest payload
of *every* tournament on every request. Fine at 50 tournaments, a problem at
1,000, broken at 10,000 (each payload up to a few MB).

### Proposal: derived index tables, written at ingest

Rule: **an index is not a calculation and not a source of truth**. It is a
copy of fields the snapshot carries, after the same display rules the pages
apply, rebuildable at any time from `snapshots`.

```
tournament_index        -- one row per slug, replaced on every accepted publish
  slug PK, name, city, federation, start_date, end_date, rounds_count,
  rounds_published, players_count, system, team?, fide_rated?,
  arbiter_listed?,          -- tournament.listed (the arbiter's choice)
  event_id, last_published_at, index_version

player_appearances      -- one row per (slug, no), replaced with its tournament
  slug, no, name, name_key, federation, title, rating, club,
  fide_id NULL, national_fed NULL, national_id NULL,
  rank NULL, points NULL, ranked_total NULL, performance NULL,
  card_linkable?, fide_name_mismatch?, start_date
  INDEX (fide_id, start_date), INDEX (national_fed, national_id)

search_fts              -- FTS5: tournament names/cities, appearance names
player_aliases          -- operator-made merges (from_key -> to_key)
player_suppressions     -- section 2
```

- Written in the ingest transaction that stores the snapshot, so the index
  can never be ahead of or behind the page. Moderation status is **joined at
  query time** from `tournaments`, never copied - one less thing to keep in
  sync, and `StatusCache` already exists for hot paths.
- Withheld values are stored as NULL at index time (standings off -> no
  rank/points; same logic `PlayerHistory.build/2` already applies), so a
  query cannot leak what the page would not show.
- Takedown: `Takedown.purge/1` deletes the slug's index rows in the same
  transaction. Retention and version pruning do not touch the index (it
  follows the newest snapshot only).
- Backfill: `mix openresults.reindex` plus a boot check on `index_version`
  that reindexes in the background in batches, so a deploy that changes the
  indexer rebuilds itself.
- Size **(guess)**: Belgium-scale traffic, ~1,000 tournaments/year x ~60
  players = 60k appearance rows/year. Even chess-results' global scale
  (tens of thousands of tournaments/year) is a few million rows - ordinary
  for SQLite with these indexes. Snapshot storage, bounded by the version
  cap, stays the dominant cost.

### Caching on a small VPS

- Tournament pages: unchanged.
- Listings and player pages: rendered-page cache keyed on a **generation**
  instead of a snapshot id. One counter per federation (bumped when a
  tournament of that federation is indexed or changes status) for `/f/:code`;
  for a player page, `max(last_published_at)` + row count over that player's
  appearances (one indexed query) plus the status epoch and suppression
  epoch. A busy Saturday in BEL then invalidates BEL's listing and the
  players actually playing, not everything.
- Search: not page-cached; FTS5 queries are cheap, rate-limited per address
  like the other open endpoints, minimum 3 characters, capped result count.
- Load test to repeat with a seeded 10,000-tournament database before
  phase 1 ships (the 2026-09-12 method, one pinned core).

## 5. Phased plan

Effort in focused dev-days **(guess)**, agent-assisted as usual.

### Phase 1 - "find a tournament, find a player" (~12 days)

No contract change, so it works for every tournament already published and
every OpenPairings version in the field.

1. Index tables, ingest hook, purge hook, reindex task + boot backfill (3).
2. `/f/:code`, `/federations`, front page on the index, stale-shell rule (3).
3. `/search` over FTS5: tournaments and players (2).
4. Player page v2: FIDE-list header, table with score/place/rating/
   performance, year filter, name-mismatch guard, admin list of mismatches (2).
5. `player_suppressions` (scope `history`), report-form reason, admin action,
   `/terms` and privacy-retention rows, minors `noindex` (1).
6. Caching generations, load test at 10k tournaments, EN/NL/FR, changelog (1).

### Phase 2 - Belgian club play and organiser polish (~10 days)

- `players[].national_id` (OpenPairings + contract + schema in
  `priv/contracts/publish-v1`, gated display key), national-id pages,
  aliases (4).
- CSV export of standings, crosstable, pairings, player list (2).
- Tournament series: additive `tournament.series_id` from OpenPairings,
  "other editions" block (2).
- Federation Atom + iCal, JSON-LD, sitemap index, alphabetical list and
  statistics page (2).

### Phase 3 - the calculated things, sent by OpenPairings (~10-15 days, mostly OpenPairings)

- Rating change: per game and per tournament, FIDE (and national via the
  KBSB plug-in?) computed by OpenPairings, sent as additive fields, shown on
  card and player page.
- Standings after round N: an additive `standings_by_round` (compact rows),
  so the round picker on the standings page needs no history access.
- `name` scope suppression (render-time masking incl. JSON).

### Later / only if decided

Cross-server index between OpenResults installations; ingest for other
pairing programs (via an OpenPairings TRF import that publishes, never a
server-side calculation).

## 6. Questions for the maintainer

1. Player pages in search engines: indexable (the SEO win, "google my name")
   or `noindex` by default? Either way, `noindex` for under-18s by FIDE-list
   birth year - yes?
2. National ids: may `players[].national_id` travel publicly for BEL (the
   KBSB list is public)? Which other federations, if any - or BEL only?
3. A "remove my player page" request: is the player's own email (or a
   parent's for a minor) to the operator enough, or do you want a check
   against the FIDE list/KBSB data first? And should the operator ever mask
   a name inside tournament pages (scope `name`), or only remove the
   cross-tournament page and send the player to the organiser?
4. Pending tournaments on federation listings and in tournament search:
   visible, as on today's front page? (Proposed: yes; still off player pages.)
5. Should trusted installations get a public "trusted organiser" marker, and
   should the KBSB's machines be trusted by default?
6. Do we want tournaments from Swiss-Manager/SWAR/Vega at all (through an
   OpenPairings TRF import that publishes)? Without it, coverage is
   OpenPairings' share of the market, which decides how "replacement" this
   can be.
7. Rating change: FIDE only, or Belgian national rating too (plug-in)? OK
   that OpenPairings computes it and OpenResults only shows it?
8. Players with no id: name search shows each appearance separately, never
   grouped - acceptable, or do you want no name search for id-less players
   at all?
9. Leave stale shells (no round published, start date 30+ days ago) off the
   listings - and is 30 days right?
10. Is openresults.cloud the only hub, or should a federation's own
    OpenResults feed its index into it (and vice versa)?
11. Front page: switch to live + upcoming + last 14 days with the archive
    under federation listings? Yes / different window?
12. Phase 1 player page: show the current FIDE rating from our list copy in
    the header, or only what tournaments published?
