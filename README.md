# OpenResults

The public half of [OpenPairings](https://github.com/teapot-chess/openpairings):
published pairings, standings and player registration for a chess tournament.

It renders what an arbiter sends it. **It computes nothing.**

## Why it is a separate thing

An arbiter's tool and a spectator's page want opposite things.

| | the arbiter | the public |
|---|---|---|
| writers | exactly one person | none |
| readers | one | hundreds, in bursts |
| latency | instant, and offline-tolerant | seconds are fine |
| when it matters | during the round | after it |
| cost of failure | the round cannot be paired | somebody refreshes |

They used to be one process, which meant a chess venue's wifi - school gyms,
hotel basements - could block an arbiter from pairing round 5, and a popular
open's standings page was served by the same machine trying to run the
tournament.

Splitting them lets the arbiter's side run entirely on a laptop with no
network at all, and lets this side be cached hard and fall over without
stopping anybody's chess.

## What it does

1. **Publish.** Accepts a snapshot of a tournament and serves it: standings
   with the arbiter's chosen tiebreaks (a starting rank of every entered
   player, in place of the table, before round one), a page per round shown
   live as results come in, and a cross-table and a card per player that
   stop at the round the published standings reflect rather than racing
   ahead of them. A published round is immutable, so it caches for a long
   time.
2. **Registration.** Takes entries from a public form and holds them in a
   queue. It never writes to a tournament - the arbiter's machine pulls the
   queue, and the arbiter decides who is in.

The arbiter chooses how much of it is shown. Ratings, titles, federations,
clubs, categories, tiebreak columns and the player cards can each be switched
off per tournament, and a tournament can be published without appearing on the
front page at all. See
[OpenPairings' public-pages doc](https://github.com/teapot-chess/openpairings/blob/main/docs/public-pages.md).

## What it deliberately does not do

- **It does not calculate.** Standings arrive already computed, tiebreaks
  applied, in the arbiter's chosen order - hand-set, if that is what they
  did, and the page says so. The arbiter's screen is the document of record
  and this page must never contradict the hall.
- **It does not hold tournament state.** It has snapshots and a registration
  queue. The source of truth is the arbiter's machine.
- **It does not know who anybody is.** No accounts, no sessions, no cookies
  on the reading path. The stats page counts unique readers per day from a
  hash under a salt that is thrown away each day; what is kept is in
  [docs/privacy-retention.md](docs/privacy-retention.md).
- **It cannot leak what it was not sent.** An unpublished round and a hidden
  board are absent from the payload, not filtered on render.

## The contract

One document, described in
[`docs/snapshot-schema.md`](docs/snapshot-schema.md). It is deliberately
boring and deliberately hard to change: a laptop running an old OpenPairings
will be publishing to a new server for months, the same way SwissManager has
always worked. Additive only, never rename, the reader ignores what it does
not recognise.

The rule that makes that work is that **an absent field always means what the
server did before the field existed**. A payload with no `registration_open`
is taking entries, because that is what every payload published before that
field was added meant. A payload with no `display` map shows everything. Read
either the other way and a change here would silently alter tournaments
nobody touched.

## The JavaScript

There is no bundle, no socket and no request on load. Two inline scripts,
both of which only ever act after the page is already readable:

- a theme preference reader that runs before first paint;
- a right-click player card, a 20-second refresher for the standings (a finished
  tournament stops it), and the
  FIDE search on the entry form.

Every page renders completely with all of it switched off. A player's name is
a real link to a real page; the refresher swaps one region rather than
reloading; the theme falls back to light. That is the condition under which
adding any of it was worth it - hundreds of phones load this over a playing
hall's wifi, and a result should be readable the moment the HTML lands.

## Embedding

Every page may be put in an iframe, so a club can show its own tournament's
standings on its front page. Safe because there is nothing here to clickjack:
no session, no login, and the two things that write take no authority from
the visitor either.

`PUBLIC_FRAME_ANCESTORS` restricts it to an origin list, or `'none'` to switch
it off.

## Running it

```
mix setup
mix phx.server
```

### Configuration

| variable | what it does |
|---|---|
| `OPENRESULTS_INGEST_TOKEN` | the shared secret an arbiter's machine publishes with. Unset, every publish is refused. |
| `PUBLIC_FRAME_ANCESTORS` | who may embed these pages. Default `*`. |
| `OPENRESULTS_FIDE_LIST_SYNC` | `off` stops this server fetching the FIDE rating list. Default on. |
| `OPENRESULTS_FIDE_LIST_HOUR` | the hour (UTC, 0-23) of the daily look for a new list. Default 3. |
| `FIDE_LIST_URL` | where to fetch the list from, for a host FIDE refuses. Default FIDE's own. |
| `FIDE_LIST_DATABASE_PATH` | the list's own SQLite file. Default `fide_list.db` beside `DATABASE_PATH`. |

The entry form's FIDE search reads this server's own copy of FIDE's rating
list, so it works however the arbiter's machine is connected - a laptop
behind a club's router included, which the old arrangement (asking the
arbiter's machine over `localhost`) never reached. The copy is checked once a
day and downloaded only when FIDE has published a new one, which is about
once a month. A fresh install fetches it a minute after its first boot; until
then the form says the search is not available yet.

## Status

In production. Publishing, registration, tournament keys, takedown, themes,
per-tournament display rules and the FIDE search are all live and covered by
the test suite.

A player's history across every tournament this server holds, found by FIDE
id, is also live: linked from a player's card when they have one, honouring
the same display rules, takedown and unlisting as everywhere else. See
`OpenResultsWeb.PlayerHistory`.

Before round one, the standings page shows the field in starting-number
order instead of an empty table. See `Tournament.starting_rank?/1`.

The standings table can be sorted by any column and filtered by club,
federation or category, entirely in the browser - the server renders one
table regardless of how it is later sorted or filtered, so the page cache
stays exactly as valid as it always was. A club or federation filter is
reflected in the URL and can be copied and shared. See
`OpenResultsWeb.TournamentHTML.standings_table/1`.

Every tiebreak value on that table opens, by tap or by keyboard, to the
per-round working behind it - the same figures the player page already
shows in full, reached with `<details>`/`<summary>` rather than a script.
See `OpenResultsWeb.TournamentHTML.tiebreak_cell/1`.

The front page groups its tournaments into live, upcoming and finished, and
can be searched, again in the browser. A tournament's group is derived from
fields the snapshot already carries - rounds published against the declared
total, and its own dates - never computed or stored. See
`OpenResultsWeb.Tournament.status/2`.

## Licence

OpenResults is source-available under the **Elastic License 2.0** (see
[LICENSE](LICENSE)), (c) 2026 Jorian Burssens - the same licence
[OpenPairings](https://github.com/teapot-chess/openpairings) uses.
Self-hosting and modifying the software are both permitted; the one thing
the licence withholds is offering it to someone else as a hosted or managed
service - selling access to a copy of this app, rather than running it for
your own tournaments.

A federation, league, association or club publishing its own members' and
affiliated clubs' tournaments is exactly what this app exists for, and the
licence says so explicitly: [LICENSE](LICENSE) carries an additional
permission stating that this kind of hosting is not the "hosted or managed
service" the base licence restricts.

GitHub labels the repository's licence "Other" in its sidebar, because the
Elastic License 2.0 is not an OSI-approved open-source licence - expected,
not a bug, so nobody needs to file an issue about it.
