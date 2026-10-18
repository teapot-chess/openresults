# Changelog

All notable changes to OpenResults are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

OpenResults split off from OpenPairings into its own application on
2026-08-29; from that point the two have separate histories; this file is
only this site's. This file itself, and the version number below, did not
exist until 2026-09-12 - `mix.exs` had said `0.1.0` since the day the
repository was created, through fifty-odd commits and several real
production deploys, because nothing had ever bumped it. Every version below
**0.13.0** is reconstructed after the fact from the repository's own commit
history rather than written at the time it shipped, so the version
boundaries are a judgement call made during that reconstruction, not
something the commits themselves recorded.

Each entry is tagged so a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a vulnerability closed, or judged not to apply |
| [Verified] | checked against a reference, no code change |

## [Unreleased]

- [Feature] **Tie-breaks explain themselves.** "Buchholz Cut-1" has been printed on this site since the first release, in the quiet confidence that everyone reading it knows what it is. They mostly do not. Every tie-break name on a player's page now has a small "?" beside it that says in a sentence or two how the number is worked out, following FIDE C.07: Buchholz and its cuts and medians, Sonneborn-Berger and its cuts, direct encounter, wins, wins over the board, games with Black, progressive score, Koya, and the average-rating family. It opens on hover, on a tap and from the keyboard, and closes on Escape or a tap elsewhere. A tie-break the site has no sentence for gets no "?" rather than a guess. Texts in English, Dutch and French. The standings themselves stay free of question marks: the "?" turns up once you open a player, which is when you are actually asking.
- [Feature] **The player page shows the flag.** The standings have shown a federation flag before every name for a while; the page you land on when you click that name did not. It does now: the same flag, the same empty box where the federation is unknown, and only where the arbiter asked for flags.
- [Change] **The two links beside a player's name are smaller, and beside the name.** "All tournaments of ..." and "Follow this player" were full-width blocks under the heading, which is a lot of furniture for two optional errands. They are now compact pills on the heading row, wrapping under the name on a phone. Same routes, same ids; the right-click peek still leaves them out. The follow switch's explanation moved into its tooltip.
- [Feature] **An installation can be given a name.** `in_QBbAqjK8_A` told the operator nothing, which is the nature of identifiers and the reason people invented names. The installation's page now has a "Name it" link (Rename once it has one), taking a label of up to 80 characters such as "Club X laptop". The label appears above the id on the installations list and the tournament lists, as the heading of the installation's page and beside the owner of a tournament, and the list's search finds it. It is for the operator alone: no public page, API answer, snapshot or notice carries it, and the installation is never told. Saving it is logged like any other change, so the name's history is at least as well kept as its owner's memory.

## [0.26.0] - 2026-10-18

- [Feature] **The entry form states its fee.** When the arbiter sets one, the form says what taking part costs: an amount, a currency and a note such as "free for juniors". It is a sentence and not a till; this site takes no payment, and the page that acknowledges an entry now says in plain words that no confirmation e-mail follows, because none will.
- [Feature] **Entries waiting for the arbiter can be listed by name.** On the public entry list, when the arbiter allows both, the entries not yet decided on appear after the players by name only, each marked "unconfirmed". The list is the arbiter's own: discard an entry there and it is gone from here with the next copy. Names are cleaned, capped and escaped on the way in and on the way out, since a stranger chose them.
- [Feature] **The FIDE search works wherever the arbiter is.** The entry form's "find yourself on the FIDE list" used to ask the arbiter's own machine, over `localhost`, which was a fine plan for the one server where both programs live and no plan at all for a laptop behind a club's router - which is to say, most arbiters. This site now keeps its own copy of FIDE's rating list, in a database file of its own, and searches that. Surname first or last, with or without the comma or the accents, or a FIDE id; the rating offered is the one for the tournament's tempo.
- [Feature] **Downloaded only when there is something to download.** Once a day, at 03:17 UTC (the hour is `OPENRESULTS_FIDE_LIST_HOUR`), one `HEAD` request asks FIDE whether its file changed since the last import. When it has not, that is the end of it: a few hundred bytes instead of 45 MB. A new list streams to disk, is read a thousand players at a time at low priority, and replaces the old one in a single swap, so a search never meets half of each. A list that is suspiciously short, not a zip, or not in FIDE's layout is refused and last month's stays, which beats replacing 1.9 million players with an error page.
- [Feature] **A fresh install fetches the list by itself**, a minute after its first boot, in the background. Until it arrives the form says the search is not available yet, rather than telling people who are on the list that they are not.
- [Feature] The admin dashboard shows which FIDE list is live, how many players it holds, when it was last looked for and what came of it. `OPENRESULTS_FIDE_LIST_SYNC=off` stops the looking; `FIDE_LIST_URL` fetches from somewhere other than FIDE, for hosts FIDE has decided it does not like.
- [Removed] `FIDE_LOOKUP_ENDPOINT` and `FIDE_LOOKUP_TOKEN`, and the proxy behind them. Still set, they are ignored. With them went the national (KBSB) half of the answer the arbiter's machine used to add, so a Belgian club player without a FIDE id is now back to typing their own details.
- [Change] **New address.** The repository moved to github.com/teapot-chess; old links still redirect, out of politeness rather than obligation.

## [0.25.0] - 2026-10-18

- [Change] **A player's card now has a button to their other tournaments.** The link to a player's history across tournaments used to be a line of small text that the page's own stylesheet hid, which made it admirably discreet and entirely useless. It is now a pill at the top of the card, "All tournaments of" the player, full width on a phone, and still absent when there is no FIDE id to follow. The history page already linked every entry back to that tournament's card.
- [Change] **Finished tournaments stop polling.** A tournament whose rounds are all in and whose results are all reported is, as far as its readers go, a document, and its pages no longer ask the server every twenty seconds whether that has changed. The server marks them and the page reads the mark; a tournament that finishes while a page is open stops the page by itself on the next poll, and one that is reopened by a correction starts it again. Live tournaments, and every page that is not a tournament's, poll at exactly the old pace: no back-off, by request.
- [Feature] **Real numbers on the stats page.** A "Readers" section counts unique readers per day, real page views, auto-refreshes and bot hits, for today so far and the last 30 days, plus the top tournaments by unique readers today, over 7 days and over 30. A reader is a keyed hash of address and user agent under a salt that is replaced every day and thrown away: no cookie, no stored address, and the same person is an unrelated code tomorrow. Programs (bots, crawlers, link previews, curl and friends) are counted separately so the gap shows; so are polls. Daily totals, and only totals, are kept in the database for 400 days and survive a restart; counting itself stays in memory, so the request path pays a few ETS operations and no query.
- [Fix] The search box on the front page no longer sits glued to the year chips above it. They were never that close.
- [Change] The terms page says what is now counted and how, instead of claiming that nothing about visitors is looked at. English, Dutch and French.
## [0.24.1] - 2026-10-17

- [Change] **Phone leftovers.** The line of facts under a tournament's name (city, dates, arbiter, tempo) stays on one line on a phone and trails off with an ellipsis instead of taking three; a screen reader still gets all of it. The player you follow is now marked on the cross-table too, in the same tint as on the standings, since it seemed unfair that only two of three pages noticed.
- [Change] **Standings on a phone, second opinion.** Tie-break columns are headed by their abbreviation (BH-C1, BH, SB) instead of "Buchholz Cut-1" spelled out at the width of a player's name; the full name is still there for a screen reader and on a wider screen. Tapping a tie-break opens its working as a sheet from the bottom of the screen, with whose number it is and a Close button, instead of inside the cell, where it made one row a quarter of a screen tall. The site's name and its language and theme buttons share one line again, and the byes table and a player's round-by-round card no longer run a few pixels past the edge.
- [Feature] The site can now answer on a second address: pages opened on the old address keep working while the new one is switched on, and the old address can be set to forward visitors to the new one. Off until it is turned on.
- [Feature] A short-link address forwards a tournament link such as `/t/<name>` (and the home page) to the same page on the main address.

## [0.24.0] - 2026-10-17

- [Feature] **Follow a player.** A player's page now has "Follow this player". After that, their row sits pinned above the standings and their board above each round, and is marked where it sits in the table as well. The choice lives in this browser only, per tournament; the server never hears about it, which also means the page cache never has to. "Stop following" undoes it, for the parent whose child has asked them to stop.
- [Change] **Pairings on a phone.** Each board is two lines: White over Black, a square for each colour, the board number on the left and the result on the right. The old row of four columns came to a few pixels more than a 375px screen, so every board scrolled sideways by exactly enough to be irritating. Desktops and the projector view are unchanged.
- [Change] **Rounds on a phone** are one line that swipes, with the round you are on - or the newest one - already in view, under the Standings and Cross-table links. Before, nine rounds wrapped into three rows of chips and the first board started somewhere below the fold.
- [Fix] **Standings on a phone with Sex or Performance switched on.** Those two columns pushed the points off the right edge. On a phone they now join rating, category and rounds present in one quiet line under the name, so nothing is lost and the points are back where people look for them.
- [Change] On a phone, a player's round-by-round table drops the pairing number, federation, title and opponent's total and draws the colour as a square, and the list before round 1 keeps number and name in place while the rest scrolls, long club names wrapping instead of widening the table. A team round's match list wraps team names too, which in club chess are less names than sentences.

## [0.23.0] - 2026-10-17

- [Feature] **Performance column.** When the arbiter ticks "Performance" in OpenPairings, the Swiss and round-robin standings gain a Perf. column with each player's performance rating as of that round. A player with no finished game gets a dash. The tick starts off, and a snapshot whose rows do not carry the number gets no column, which is every snapshot published until now, none of which needed a word of warning.
- [Feature] **Sex column.** When the arbiter ticks "Sex" in OpenPairings, the standings and the starting list gain an M/F column. The tick starts off, so nothing changes until somebody asks. A snapshot that does not carry the field gets no column, which is also what every snapshot published before today gets, and none of them needed to be told.
- [Fix] **Categories before round 1.** The list a tournament shows before its first round had a column for rating, federation and club, and none for category, so an arbiter ticking "Categories" saw nothing happen and reasonably assumed the tick was broken. It was the list. It now gets a Category column whenever the players have one and the tick is on, the same rule the standings already followed.

- [Security] Bandit 1.12.5 → 1.13.1 (EEF-CVE-2026-105660, EEF-CVE-2026-105659) and decimal 3.1.1 → 3.2.0 (EEF-CVE-2026-97853). Same three advisories OpenPairings closed in 0.88.1; this site was running the same web server and the same gullible arithmetic. No behaviour changes.

- [Feature] **Pending games.** A round-robin board nobody has entered, in a round the tournament has since moved past, now arrives as `boards[].pending` with the points OpenPairings counts it for, and the standings bring a `pending_games` count. The round page says "Result not yet in" where the hyphen was, the cross-table gives it the hourglass a postponed game gets, and the line above the standings says "2 games have no result yet" instead of calling every one of them postponed, which would have been a confident claim about games nobody postponed. Running totals count it, and a round is not "live" for its sake. A snapshot without the new keys reads exactly as before.
- [Feature] An arbiter can hide the projector-view and hall-display cards at the foot of the standings, pairings and crosstable (the `screen_links` display tick, new in the snapshot). Only the cards go; `/t/<slug>/projector` and `/t/<slug>/hall` keep answering, so a screen already running in a hall carries on. Absent or true shows them, as before.

- [Feature] **A tournament's publisher can get the relay key for its own hall box by asking**: `POST /api/tournaments/<slug>/relay-keys`, with exactly the credentials a publish takes (the bearer token or an installation key that owns the tournament, plus the tournament's own key), answers with a fresh `orrk_` key, once. OpenPairings does this by itself, so nobody copies a key from the admin panel into anything and no administrator has to be found on a Saturday morning. The server still keeps only a fingerprint, which means it cannot hand the same key out twice; asking again under the same label therefore revokes the previous one and returns a new one, so a retry after a lost reply leaves one live key instead of a drawer full. `DELETE` on the same path withdraws the publisher's own keys. Six requests per ten minutes per tournament; a relay key itself is refused on the route, so a box cannot mint its successor. Every key made this way is in the action log and on the panel's Relay keys page, marked as the publisher's with which publisher and when, and revocable there like any other. Documented in `docs/live-boards-api.md`.
- [Change] Revoking an installation now revokes the relay keys of all its tournaments: a publisher that may no longer publish does not keep a box that may. (A takedown already deleted them and a transfer already revoked them.)
- [Change] The admin panel's "Make a relay key" stays, for a box that has no OpenPairings behind it, and its page now says that this is the exception.
- [Feature] `/t/<slug>/live/<round>/pgn` serves the whole round as one PGN, for a broadcast tool that would rather follow one URL than forty: boards in order, the same games at the same broadcast delay as the per-game file, boards nobody played as header-only games, an ETag of what was actually served so a poller that asks every few seconds mostly gets a 304. Linked as "PGN of the round" from the broadcast and the all-boards pages.
- [Feature] Both PGN files - the game's and the round's - now say what the clocks said: `{[%clk 1:29:50]}` after every move that was reported with one, which is the comment Lichess and chess.com read, so a broadcast that pulls the round's URL has clocks at last. The clocks were stored per move all along (each ply keeps the report that brought it); the builder had simply never been asked. The figure is the mover's clock once it stands still - from the next move's report where that shows it standing, increment and all, otherwise from the move's own - and a move that arrived in a batch, or without clocks, gets no comment rather than an invented one. Under a broadcast delay a clock is hidden for exactly as long as its move is. No migration, old games included.
- [Fix] The line of facts under a tournament's name wraps one fact at a time: "Tempo:" no longer ends a line with its time control starting the next.

- [Feature] **The flag is beside the player's name, on the pages people
  read.** Flags were drawn next to a federation code, which was tidy and
  meant the standings, the pairings and the cross-table - none of which
  print a federation code - had none. Where the arbiter's app asks for
  flags and shows federations, a small flag now sits before every name on
  the standings, a round's pairings (both players, and the same round on
  the hall's screen), the cross-table, the list of teams and a team's own
  page. The federation code is the picture's text, since those pages print
  it nowhere else. A player with no flag to draw (`FID`, a code that names
  no country, none at all) gets an empty space of the same width, so the
  names still line up. The starting list, a player's card and the entry
  list keep theirs in the federation column and do not get a second one.
  Same files, same month's cache, loaded lazily: a standings page of two
  hundred players is two hundred `img` tags and a request per country.
  Nothing in the snapshot changed.

- [Feature] **A round-robin row that is not counted says so.** A player who
  leaves a round robin with fewer than half the games played keeps the
  games in the table and counts for nobody (FIDE C.05 6.6). OpenPairings
  now marks that row (`standings.rows[].uncounted`), and this site stops
  printing it as a last place with more points than the row above: no place
  number, muted, "results not counted (withdrawn)" beside the name and the
  rule in a footnote - on the standings, the cross-table and the player's
  page, in English, Dutch and French. The other players' running scores
  leave those games out, marked "not counted" on their cards, so a card
  ends on the total the standings show. The hall display lists ranked rows
  only. A payload without the key renders as before.
- [Feature] **"not paired" has a name.** A player with no board and no bye
  in a round - withdrawn, or taken off a board by hand - arrives from
  OpenPairings as the bye kind `not-paired`, worth 0. It is printed as "not
  paired" ("niet gepaard", "non apparié") instead of the raw word, and the
  running score counts the round as the zero it is rather than giving up at
  the gap.
- [Change] **The "Live boards" link now has something to ask for it.**
  The public pages have linked to the live boards on
  `tournament.live_boards: true` since the live pages shipped; OpenPairings
  only now has the tick that sends it. Nothing changed here but the
  documentation, which no longer says "will".

- [Feature] **An event of several tournaments.** When an arbiter's app says
  a tournament is one section of an event (`tournament.group` in the
  snapshot - OpenPairings' tournament groups), its pages start with a row
  of tabs, "Open | U20 | U12", the open one marked. A tab opens the same
  page of the other section when it has one - standings to standings, round
  3 to round 3, the cross-table to the cross-table - and its overview when
  it does not. The event's name leads to a new page, `/e/<id>`, that lists
  the sections as cards: label and name, how many players, the round it is
  in, how many rounds are played, and whether it is live, upcoming or
  finished. The front page gathers an event's tournaments under its name.
  A snapshot without the block renders exactly as before, and the hall
  display, the projector and the live boards - full-screen views - carry no
  tabs.
- [Security] **A snapshot's word about another tournament is not taken.**
  With public publishing anybody can send a snapshot, so "I am part of
  event X, and so are these slugs" proves nothing. A sibling is shown only
  when it is public on this server, its own newest snapshot names the same
  event, and it has the same publisher - the same installation, or both the
  operator's. The event page belongs to the publisher that claimed the id
  first. A tournament moderation hid, one taken down, and one that left the
  event disappear from the others' tabs at once, without waiting for their
  arbiter's app to send again: each tournament page's ETag now carries an
  epoch that moves when a sibling changes, so neither the page cache nor a
  reader's browser keeps a strip that names something no longer there. A
  section not listed on the front page is never linked from one that is.
  Migration `add_event_to_tournaments` (two nullable columns and an index;
  runs at boot).
- [Feature] **Federation flags.** Where the arbiter's app asks for them
  (`display.flags` in the snapshot - OpenPairings' "Federation flags" tick,
  on unless unticked), a small flag is drawn beside a player's federation
  code: the starting list, the "Nat" column of a player's card, the entry
  list, the hall display, and on the live boards the broadcast's player
  bars, the All boards tiles and the projector tiles (flag only on the last
  two - a tile has no room for the code). A snapshot that does not mention
  flags gets none, so nothing already published changes until its arbiter's
  app is updated. A player under the FIDE flag, or with a code that names
  no country, keeps the code and gets no picture: a wrong flag is worse
  than none. The flags are flag-icons' (MIT), 215 static SVG files of 1.4 MB
  together, served from `/flags/` with a month's cache and loaded lazily, so
  a list of two hundred players fetches each country once and only the ones
  on screen. FIDE's codes are mapped to them by a table of this site's own
  (`GER`, `NED`, `SUI`, and `ENG`/`SCO`/`WLS`, which ISO has never heard
  of).
- [Fix] **A capped entry form counts the entry that arrived in the same
  instant as the snapshot.** The form adds the entries received "after" the
  last snapshot to the arbiter's count; "after" was strict, and a server
  clock ticks coarsely enough (a millisecond on some hosts) for an entry and
  a snapshot to carry the same stamp. That entry was then in neither count
  and a full field took one more. It is "at or after" now - which is also
  why one test failed now and then on a fast machine.
- [Feature] **A projector view of the games you pick.** "Projector" on the
  broadcast and the All boards pages opens a list of the round's boards to
  tick (all of them, none, or a few), an option to remove finished games
  automatically (on), and a link that opens
  `/t/:slug/live/:round/projector?boards=1,3,5&auto=1&pieces=chessnut` in a
  new tab - an address the hall PC can bookmark; no list means every board,
  and `&theme=night` (or any site theme) pins the colours for that screen.
  The page is the games and nothing else: no header, no moves, no buttons
  to step through anything. Each tile is Black's bar, the position with the
  last move lit, White's bar; a bar is the name, title, Elo, the points the
  player brought into the round and the clock, highlighted while it runs.
  The tiles fill the window - the page works out how many columns give the
  largest boards for this window and this many games, again on every
  resize, on full screen (`f`, or the button that disappears once you are
  in it) and whenever a tile goes, and the type grows with the board. In the
  automatic mode forfeits are never shown, a game that ends shows its result
  across the board for half a minute before its tile makes room for the
  others, and when the last one has gone the screen says so and lists the
  results. Without it, finished games stay put with their result. The old
  `/t/:slug/projector` pairings screen is unchanged. A phone gets one board
  per row and scrolls; a projector never has to.
- [Change] **The live pages are a broadcast now.** `/t/:slug/live/:round`
  is three columns: on the left the round pills, a search box and every
  game of the round (board, both players, the result as `1-0` or `½-½`,
  live games marked; a team round's boards under their match, "1 Team A
  2½-1½ Team B"); in the middle one game large, a bar above and below the
  board with the player's name, title, federation and rating, the clock in a
  box and what that side scored once there is a result, coordinates on the
  board's edge, the last move lit and a full-screen button; on the right the
  event (name, dates, place, round) and the moves as a table in figurine
  notation drawn with the chosen piece set, the current move highlighted and
  kept in view, with a "Game info" tab beside it. The page opens on the
  first game in progress; `/t/:slug/live/:round/:board` opens on that board,
  so every link to one game still works, and picking a game from the list
  swaps the middle without reloading anything. `/t/:slug/live` goes to the
  newest round. There is no evaluation bar, because there is no engine, and
  a bar that pretends otherwise would be lying in a large font.
- [Change] **"All boards" is the grid of every board of a round**, at
  `/t/:slug/live/:round/all`, one click from the broadcast and back. Tiles,
  clocks, badges and the hall display's live view got the same treatment:
  a boxed clock that fills when it runs, a live badge with a beating dot
  (still, for anyone who asked their system for less motion).
- [Change] On a phone the columns stack: rounds, the game list folded
  behind a button, the board the full width, the moves under it. Nothing
  scrolls sideways at 375px.
- [Fix] **A forfeited board no longer waits for a game that is never
  coming.** A board the arbiter published as `1-0FF`, `0-1FF` or `0-0FF`
  has nobody sitting at it, so the relay sends nothing, and the page used to
  read that as "Not started" with the starting position until the end of
  time. The published result now wins: the board says "Forfeit" (or "Double
  forfeit"), shows `1-0 FF`, and draws a faded empty board with "Not played -
  forfeit" instead of pieces that were never moved. A board with a published
  result and no relay game is "Game over", not "Not started". In a round
  whose results are withheld a forfeit is only "Game over", like everything
  else there.
- [Feature] **Two real piece sets, chosen by the viewer.** The live boards
  are drawn with Cburnett (the default; Colin M.L. Burnett, BSD 3-clause)
  or Chessnut (Alexis Luengas, Apache 2.0), replacing the homemade
  silhouettes. A "Pieces" picker on the live pages remembers the choice in
  the browser, as the colour theme does (still no new cookie);
  `?pieces=chessnut` in a URL wins, which is how a hall screen with no
  picker gets one, and a name that is not one of the two draws the default.
  Each set is one cached static SVG sprite
  under `priv/static/pieces/` next to its licence, never compiled into the
  code; the notices are in `NOTICE`.
- [Fix] A round a late entrant played before joining now has a name: "not yet joined", worth nothing. OpenPairings 0.81.0 sends it, so "points before this round" keeps counting for those players instead of showing a dash.

## [0.22.0] - 2026-10-08

- [Feature] Relay keys. A hall relay is a box in a room full of strangers, and until now it carried the operator token or an installation key, either of which can rewrite the whole tournament. An admin can now make a key per tournament (Tournaments, the tournament, Relay keys): it is shown once, kept as a fingerprint, listed with its last use and revocable. It opens `POST /api/tournaments/:slug/live` for that one tournament and nothing else - another slug is a 403, and publishing, history, deleting and the admin panel get the refusal a stranger gets. It replaces the tournament key on that route, has a budget of 1200 requests a minute of its own, and creating and revoking are in the action log without the secret. A takedown removes the tournament's keys. The older credentials still work on the live endpoint; `docs/live-boards-api.md` now recommends this one.
  A transfer to another installation revokes the tournament's relay keys: the
  new owner starts without the old owner's boxes in the hall.

## [0.21.0] - 2026-10-07

- [Feature] **Live boards.** A hall relay can report the games on the boards
  move by move, and spectators watch them as they are played. A new ingest
  route, `POST /api/tournaments/:slug/live`, takes a board's moves, clocks and
  status with the same credentials as a publish (the ingest token or an
  installation key that owns the slug, plus the tournament's key once it is
  claimed). Every move is checked for legality by a checker written for this
  site and proved against the standard perft counts; an illegal move refuses
  the update and names the ply. Updates are idempotent and order-tolerant,
  keyed by round, board and ply: an older update never undoes a newer one, and
  `replace: true` is the full-game resend. The contract is
  `docs/live-boards-api.md`.
- [Feature] **Live pages.** `/t/:slug/live` shows a round's boards as a grid
  of small boards with names, clocks, the last move and the result;
  `/t/:slug/live/:round/:board` is one game with a large board, a move list
  to step through (click a move, or use the arrow keys), clocks that count
  down, flip board and a PGN download, built from the games' players and
  ratings in the published snapshot. They are sockets that re-read the game
  themselves, outside the page cache, so a move shows within a second and
  nothing here is served stale. The boards are drawn as SVG with the project's
  own pieces; no script is loaded from elsewhere.
- [Feature] **The hall display shows the games in progress**, four a page,
  with their clocks, as one more view of its cycle. It has no pages (and is
  skipped) until a game is reported; `tournament.hall.live: false` switches it
  off, and `?views=live` gives one screen only the live boards.
- [Feature] **Broadcast delay.** A tournament can be shown a number of
  minutes behind the game, set in the admin panel (Tournaments, a tournament,
  Live board delay), for organisers who need it under anti-cheating rules. The
  relay's reports are stored in real time and every page, the hall display and
  the PGN show the game as it stood that long ago; nothing later is sent to a
  browser.
- [Feature] `mix openresults.live_sim` replays PGN files into the API with
  clocks at a configurable speed, for development and demonstrations. Three
  short public-domain games ship with it.
- [Change] A snapshot may say `tournament.live_boards: true`; the static pages
  then link to the live boards. They link on that word alone, not on whether a
  game has been reported, because they are cached per snapshot.
- [Change] Taking a tournament down also removes its live games and its delay
  setting.

## [0.20.2] - 2026-10-03

- [Feature] The team list shows each team's **rating** in a *Rating*
  column, when OpenPairings sends one (`teams[].rating`, since its
  2026-10-03 snapshot): by default the Olympiad's average of a team's
  highest-rated players, or a rating the arbiter typed in.
- [Verified] A team event OpenPairings pairs **without players** (its
  optional line-ups) publishes and renders: teams with no players, matches
  with no board on the page, scored only in their match points and game
  points and the team standings. A contract fixture from OpenPairings,
  `snapshot_team_lineups_optional.json`, now covers it; the team round
  robin fixture gains `teams[].rating`.

## [0.20.1] - 2026-10-03

- [Fix] **A change the arbiter publishes now shows on open pages within
  about three seconds**, not up to twenty. Traced end to end on 2026-10-03:
  OpenPairings sends about two seconds after the click and this site stores
  and announces it within milliseconds, but the standings, round, team and
  cross-table pages only looked again on their 20-second poll (10 while
  results come in), and the projector page (`?display=1`) every 60 seconds -
  an "unpublish results" took 15 seconds to show. Every tournament page now
  also listens on a small event stream (`/t/<slug>/events`) that says
  "changed" the moment a publish lands, and the page polls at once. The polls
  stay as the fallback; the stream carries no data, closes while the tab is
  in the background, and is capped server-wide.
- [Fix] **A page asked for while an installation's publish was being saved
  could stay on the old document until the next publish.** The new version
  was announced to readers before its row was committed, so a page rendered
  in that window was the old one under the new version's ETag - cached here
  and in the reader's browser as current. The version is now announced after
  the commit.

## [0.20.0] - 2026-10-03

- [Fix] **The hall and projector screens' controls no longer sit on the
  clock, and the full-screen button works.** The Black / White / Ultra
  colours and the full-screen button are now in the bottom-right corner
  (they still fade out after a few seconds), and the hall's footer keeps
  clear of them on a wide screen. The full-screen button never did anything:
  the controls' root element carried `data-choice`, so a click on the button
  was matched by `closest("[data-choice]")` as a colour pick and returned
  before the full-screen call. Only the three colour buttons are colour
  choices now, and the root's own value is `data-initial-choice`.
- [Change] **The projector and hall link cards are at the foot of the
  standings, round and cross-table pages**, after the table, not above it.
- [Fix] **Teams are shown by their full name everywhere** - team pages,
  matches, standings, cross-tables, the hall display and the projector
  view. The short name used to win and is now only the fallback for a team
  with no name.
- [Verified] **Publishing the first round of a team event reaches the
  readers**: a new snapshot gives every static page a new ETag and page-cache
  key (an old ETag is answered 200, not 304), the pages' 20-second refresher
  swaps the region, and the hall and projector LiveViews are pushed the
  change over PubSub. Tests added for each.

- [Fix] **A team round no longer lists every board twice.** The round page
  showed each match's boards behind a "Boards" disclosure and again in the
  flat pairing list. The boards are now listed once, in the pairing list,
  grouped under a header line per match (match number, the two teams, the
  score); the matches table above stays as the overview and its match numbers
  link to the groups. The Bd column is the board within the match (1, 2, 3 ...),
  not the round-wide number.
- [Fix] **A team's page showed the wrong board and the wrong points.** The Bd
  column was the position in the roster list, so a reserve was "board 4" of a
  three-board match, and Points was the player's whole-event score. It is now
  the board the player sat at most often, with games and points for the team.
  A match's score is also read from the team's own side now (its game points
  first), not always from team A's.
- [Feature] **Team pages for a team Swiss with matches.** The team page lists
  every round's line-up - who sat on each board, and what they scored - next to
  the opponent, the score and the forfeit decision, behind the pairings
  switch like the round pages. The old "phase 1: a team Swiss still pairs its
  players individually" wording is gone: OpenPairings has paired team against
  team since 0.62.0.
- [Feature] **A team list.** `/t/<slug>/teams`: every team with its place,
  match and game points, captain and roster in board order, and a
  teams-by-board grid (who played which board, with their points out of
  games). Linked as "Teams" in the round strip of a team event; behind the
  standings switch.
- [Feature] **A team cross-table for a team Swiss.** On the cross-table page,
  above the player cross-table: a row per team, a column per round, each cell
  the opponent, the colour on board 1, the game score and the match and game
  points so far. Same gate as the player cross-table (the pairings and
  cross-table switches, rounds the standings reach, results public).
- [Change] **The hall display and projector for a team event.** Matches show
  the colour each team has on board 1; "find your board" and the results view
  say "match 3, board 2" instead of the round-wide board number; a Swiss bye
  is marked as scored as a drawn match.
- [Verified] The team round page, team page, team list, team cross-table and
  the hall display are tested against a team Swiss with matches (new
  `snapshot_team_swiss.json`: a reserve, a board nobody sat at, a bye every
  round), including the switches that withhold them and the Dutch and French
  pages.

## [0.19.2] - 2026-10-02

- [Feature] **The projector view follows the newest round.** New
  `/t/<slug>/projector`: large boards for the latest round, updating by
  itself when a round is published or a result comes in (the hall display's
  live connection, never the page cache), with the same visibility rules as
  the other pages. A round's old `?display=1` link keeps working and keeps
  showing that round, but is no longer linked.
- [Change] **The two hall screens are linked once, near the top.** Two cards
  (icon, title, one line) under the round strip on the standings, cross-table
  and round pages, instead of a dotted line under each round's boards.
- [Feature] **Full screen and three colours on both screens.** A button in
  the corner (also F) toggles full screen; Black (still the default), White
  and Ultra contrast (pure black and white, bold, thick rules, above 7:1) can
  be picked on the screen, with `?theme=black|white|ultra` (`light` still
  means white) and are remembered per browser. The controls fade after a few
  seconds. The hall clock now shows seconds.

## [0.19.1] - 2026-10-02

- [Fix] **A thousand-player standings page is 16 times lighter on a
  phone.** Every tie-break value carried its own per-round working table,
  every opponent named, so a 1,000-player, nine-round open with four
  tie-breaks sent 11 MB of HTML (346 KB gzipped) and 221,000 elements - and
  the refresher fetched and swapped it again on every result. The working now
  stays inline only while the table shows at most a hundred rows (an ordinary
  club tournament, a category, or a search for one name); above that a line
  says it is on each player's own page. The same page is now 0.82 MB (50 KB
  gzipped) and 16,500 elements. A test holds the budget.
- [Feature] **The player search is on every standings, round and
  cross-table page, and stays at the top of a phone's screen.** A round
  whose tournament publishes no club, federation or category had no search
  box at all, so "find my board" meant scrolling five hundred boards. On a
  phone or small tablet the search bar now sticks to the top while the table
  scrolls under it, folded to one line, and a link to a board ("their board in
  the latest round") lands below it with the board marked.
- [Change] **Phone layouts for the tables.** On a phone held upright the
  pairing list is board, White, result, Black (ratings and points going in
  are on each player's page) with names wrapping instead of pushing Black off
  the screen; the standings show rank, name and points first, with the rank
  and name pinned while the tie-breaks scroll sideways; the cross-table's
  pinned name column is narrower so more rounds fit. Wider screens are
  unchanged.
- [Fix] **No more sideways page scroll on a phone** from a standings table
  with tie-break working (its hidden captions were placed against the page,
  outside the table's own scroller), from the changelog's tag table, or from
  the projector view opened on a phone.
- [Fix] **Typing in a search or form field no longer zooms the page on an
  iPhone.** Text boxes and dropdowns are 16px on touch screens and narrow
  ones; iOS zoomed in on anything smaller and left the page zoomed.
- [Change] **Touch targets of at least 44px on touch screens**: the round
  strip, the language and theme pickers, the filter controls and chips, the
  tournament list, table rows, the entry form's checkboxes, footer links and
  the player card's Close button. A desktop with a mouse is unchanged.
- [Fix] **The hall display is readable on a phone held upright.** Its type
  was sized to a 16:9 screen's height, which on a 390px-wide phone made it
  about 7px; portrait screens now size it to the width. It also uses the
  visible height, so a phone's browser bar no longer hides its footer.
- [Change] **Notches and rounded corners**: pages, the player card and the
  hall display keep their content inside the screen's safe area
  (`viewport-fit=cover`). Zoom is never disabled.
- [Change] **No `phx-r` attribute on every component's root tag.** It
  exists for colocated CSS, which this site does not use, and was stamped on
  every player link and cross-table cell.

- [Fix] **A running score is now exactly OpenPairings' own, under any point
  system and with postponed games.** The "points before this round" column
  on a round's pairing list counted every postponed game as a half point, and
  every played game as 1, a half or 0 read off the result token. OpenPairings
  now publishes the tournament's point system (`tournament.scoring`) and what
  each seat scored on each board (`boards[].points`, with `postponed_as` for a
  postponed game), and the pairing list, a player's card and the cross-table
  all read those instead of interpreting the token. A snapshot from an older
  OpenPairings still reads the token as 1, a half and 0, starts the pairing
  list from the standings' own totals where they cover the round, and shows
  "-" for a player whose total depends on a postponed game it cannot price.
- [Fix] The standings page's provisional line no longer always says postponed
  games "count as draws": it states how the snapshot's `postponed_as` says they
  are counted (a loss or a win for both players, a win for one and a loss or
  draw for the other, or "as they were valued when postponed" when the games
  differ), in Dutch and French too. A snapshot that does not say keeps the
  draw wording.
- [Fix] That "-" no longer says "an earlier round is not public" when the
  reason is a postponed game: it says a postponed game has not been played
  yet (Dutch and French included).

## [0.19.0] - 2026-10-01

- [Feature] **Hall display: a full-screen page for the television in the
  playing hall.** `/t/<slug>/hall`, linked from every round page, no login.
  It cycles through the current round's pairings in big type, an
  alphabetical "find your board" list split over pages, the results as they
  come in (the newest first, marked when they arrived while the screen was
  on), the top of the standings and the arbiter's announcement. A result the
  arbiter publishes appears within a second: this page, alone on the site,
  keeps a connection open and is told about every publish. While a new round
  has no result in yet it holds on the pairings and the name list, and a
  newly published round jumps straight to its pairings. Round, date,
  "Final round" and a clock in the header; a tap or the space bar pauses.
  Dark by default, `?theme=light` for a high-contrast light screen,
  `?views=names` to give a second screen only some views. The views, the
  seconds per page, the number of standings rows, the hold and the
  announcement are set in OpenPairings and travel in the snapshot
  (`tournament.hall`); a tournament published by an older OpenPairings gets
  the defaults. Everything the arbiter hides from spectators stays hidden
  here, and a tournament hidden by moderation leaves the screen.
- [Feature] **The entry form is back on the tournament's pages.** "Enter
  this tournament" shows in the header of every page of a tournament whose
  arbiter has opened entries. It came down on 2026-08-29 while the workflow
  was unfinished; the arbiter's side now has a review queue on the Players
  page to match.
- [Feature] **Entries can open and close on time, and a field can be
  capped.** When the arbiter sets an opening time, a closing time or a
  maximum number of players, the form says so: when entries close and how
  many places are taken, or - once shut - that entries are not open yet,
  closed on a given date, or that the field is full. The window is judged
  by this site's clock, so it opens and closes on time even while the
  arbiter's computer is off. A full field counts entries that arrived after
  the arbiter last published, so it cannot be oversubscribed while their
  laptop is closed.
- [Feature] **Who has entered so far**, on the entry form and the closed
  page, when the arbiter allows it: the players already on the entry list,
  with the columns the arbiter shows everywhere else. Entries still waiting
  for a decision are never listed by name, and no email address is ever
  shown.
- [Feature] **National ID on the entry form** - the member number at the
  player's own federation (in Belgium the KBSB/FRBE number), which the
  arbiter's app looks up in its national list when it accepts the entry.
  Picking yourself in the FIDE search now also fills it in, with the club,
  where the arbiter's computer knows them.
- [Security] **A honeypot on the entry form, and one that cannot lose an
  entry quietly.** A hidden field that bots fill in; when it arrives
  filled, nothing is stored and the form comes back with everything that
  was typed, the field visible and a sentence saying to empty it - so a
  person whose browser filled it by itself can still send their entry. The
  per-address rate limit is unchanged.

## [0.18.1] - 2026-09-28

- [Security] **Mint 1.11.0**, fixing three advisories in the HTTP client
  (EEF-CVE-2026-91043, -92103, -94194).

- [Fix] **The result column no longer disappears.** A round's pairings
  table, a team match's own table and its per-board list, and the projector
  view used to drop the Result/Score column entirely whenever no result was
  in yet, or the arbiter had withheld the round's results - leaving a table
  that looked lopsided until the first result arrived. The column now
  always stays, with the same "not yet reported" hyphen an ordinary pending
  game already showed, and a postponed game's own hourglass still where it
  was. A withheld round still gets its column, and only its placeholders -
  the real result never reaches the page.

## [0.18.0] - 2026-09-27

- [Feature] **Postponed games say so.** A game the arbiter has postponed now
  reads "Postponed" where its result would go, or "Postponed, to be played"
  and the date when the players have agreed one, written the way the site
  writes every other date (the date is left out when the arbiter hides
  dates). This shows on the round page, the projector
  view, a team match's board list and the player's round-by-round card. When
  the game is played, its result simply takes the label's place.
- [Feature] **Provisional scores are marked.** A team match with a postponed
  board shows its score with "1 board pending" beside it, on the round page
  and the team page, so it does not read as final. While a postponed game is
  still to be played, the standings page says the standings are provisional,
  how many games are postponed, and that those count as draws until they are
  played.
- [Change] **A round waiting only on postponed games is no longer "Live".**
  It used to stay live, and keep the page refreshing quickly, until the
  postponed game was played, which could be weeks later.
- [Feature] **The cross-table marks a postponed game too.** A cell that used
  to read as a plain "not yet reported" hyphen now shows an hourglass, with
  the same "Postponed" or "Postponed, to be played <date>" behind it a
  round's own page already says - explained in the grid's own legend beneath
  it. A team match with a postponed board carries the same mark in its own
  cross-table cell, beside the score it belongs to, rather than only in the
  page-level "board(s) pending" line.
- [Fix] **A pairing list's "points before this round" no longer goes dark
  forever over a postponed game.** It used to stop at the first postponed
  board it crossed and stay stopped for every later round, the same way an
  unresolved game does - but a postponed game is priced everywhere else on
  the site as its provisional draw, so this column now counts it the same
  way and keeps moving. A player's own card is unaffected: its round-by-round
  score still stops at a postponed game, on purpose, since that page already
  says why beside it.

## [0.17.1] - 2026-09-26

- [Security] **Two dependency advisories closed.** mint 1.10.0 -> 1.10.1
  fixes EEF-CVE-2026-82672 (MEDIUM): its HTTP/1 client did not validate the
  tail of a chunk-size line, allowing response smuggling on pooled
  connections. lazy_html 0.1.12 -> 0.1.13 (test-only) fixes
  EEF-CVE-2026-92106 (LOW): SVG and MathML style/script text serialised
  unescaped. websock 0.5.3 and websock_adapter 0.6.0
  were checked too: `mix hex.audit` and osv.dev list no advisory for them.

## [0.17.0] - 2026-09-25

- [Feature] **Print a page and get a sheet for the noticeboard.** Standings,
  rounds and the cross-table print black on white whatever theme is chosen,
  without the site bar, pickers, filters or footer links, with each table's
  header repeated on every sheet and no board split across two.
- [Feature] **Follow a tournament with a feed reader.** Every tournament has
  an Atom feed at `/t/<slug>/feed.xml`, linked from the footer and from the
  page head. A new item appears when a round's pairings are out, when every
  board of a round has a result, and when the standings move to a new round -
  and never for anything the arbiter does not publish.
- [Feature] **A link to a player's current board.** `/t/<slug>/player/<no>/board`
  always leads to the latest published round, scrolled to that player's
  board, so it can be bookmarked once for the whole tournament. The player's
  card links to it.
- [Feature] **Round links say who is on board 1.** A shared round link's
  preview now names the board 1 players and, once it is public, the result.
- [Feature] **An embed view.** Add `?embed=1` to any tournament page for a
  version without the site's own header, notice, filter bar or footer, for a
  club's iframe. Links followed inside it open in the whole tab, and one link
  at the bottom leads to the full page.
- [Feature] **A sitemap and a year filter.** `/sitemap.xml` lists the
  standings, cross-table and rounds of every tournament on the front page
  (never player cards). The front page offers a year filter once
  tournaments span more than one year.

## [0.16.10] - 2026-09-19

- [Change] **The rounds-present column is opt-in again** on the arbiter's
  side, so it arrives only for tournaments that asked to publish it. Nothing
  changed here either way: the column and its sort appear whenever the field
  is sent, and 0.16.9's note that it would arrive for everyone was true for a
  few hours only.

## [0.16.9] - 2026-09-19

- [Change] **The rounds-present column now arrives for ordinary tournaments**,
  because the arbiter's app sends it unless the arbiter turns it off. Nothing
  changed here: the column and its sort already appeared whenever the field
  was sent. (Reversed a few hours later - see 0.16.10.)

## [0.16.8] - 2026-09-19

- [Feature] **Sort the standings by rounds present.** Where a tournament
  publishes the "Rds" count, the column header sorts on it and the filter bar
  offers "Sort: Rounds present" - fullest card first, and players whose count
  was not published last rather than as a nought. Tournaments without the
  column are offered neither.

## [0.16.7] - 2026-09-19

- [Feature] **An attendance column on the standings.** A tournament whose
  arbiter turned on OpenPairings' new "Rds" column now sends a per-player
  count of the rounds that player was there for, and it shows beside the
  rating - on a Swiss and on a Keizer ladder. Tournaments that do not send it
  render exactly as before.

## [0.16.6] - 2026-09-16

- [Fix] **The page no longer "updates" every 10 to 20 seconds when nothing
  changed.** The refresher compared the page's own markup, which the filter
  bar's script had already altered, so every poll replaced the table, said
  "updated just now" to a screen reader again, and closed the phone filter
  panel. It now compares a fingerprint the server sends, and keeps open or
  closed panels as the reader left them.
- [Fix] **Typing in the search box filters the right rows.** It no longer
  matches a player through the opponents listed in their tie-break working,
  leaves the team matches table alone on a team round, and keeps filtering
  after the page refreshes instead of showing every row under a filled box.
- [Change] **The name search ignores accents and word order.** "muller" finds
  "Müller" and "Ilse De Vos" finds "De Vos, Ilse", both while typing and after
  pressing Enter, so the two can no longer disagree. The tournament list's
  search ignores accents too.
- [Fix] **Typing in the search box says how many rows match**, in
  the count under the bar and to a screen reader once you pause.
- [Fix] The projector view no longer rewrites its boards every minute when
  nothing changed.

## [0.16.5] - 2026-09-15

- [Change] **On a wide screen a chosen filter no longer shows twice.** The
  dropdown already shows "BEL"; the removable chip repeating it underneath is
  now only shown on a phone, where the dropdowns are folded away. "Clear all"
  stays on every screen.

## [0.16.4] - 2026-09-15

- [Fix] **The filter toolbar looks like one set of controls.** The site's
  general form styles were overriding it: square dropdowns without their
  arrows, a larger font, and a search icon stuck to the top of its box. The
  search, the filters and the sort are now matching rounded pills the height
  of the navigation tabs, in that order with sort on the right, and the player
  count sits right-aligned in small capitals. The cramped "Fed" link in the
  Player column header is gone; sort by federation from the Sort control.

## [0.16.3] - 2026-09-15

- [Fix] **Sorting and filtering on the standings are visible again.** The new
  toolbar folded its sort and filter controls into a "Filters" dropdown that
  stayed closed on desktop too, so there was no visible way to sort by
  federation, rating or name. The controls are now always shown on wide
  screens (a phone still folds them away), and the standings' column headers
  sort again: click "Player", "Fed" or "Rating", click again for rank order.
- [Fix] **The player search no longer reloads the page while you type.** It
  used to submit half a second after every pause, jumping the page mid-name.
  Rows now filter instantly as you type, and Enter applies the search as a
  link you can share.

## [0.16.2] - 2026-09-14

- [Change] **The filter/sort bar on standings, round pairings and the
  cross-table is now one compact toolbar instead of a wrapping row of plain
  `<select>`s.** A search box with an inline icon on the left, pill-styled
  filter controls in the middle (only the ones that apply, as before), and
  sort on the right; active filters and the current sort show as removable
  chips underneath, each a plain link built from the same `FilterParams` the
  rest of the site already uses, plus a result count ("12 of 86 players", or
  just the total when nothing is filtered). On a narrow screen the middle
  controls collapse behind a `<summary>`/`<details>` "Filters (N)"
  disclosure - real markup, no script required - open by default only when
  a filter or a non-default sort is already active. A name search now
  highlights the matching part of each player's name in the table
  (`<mark>`, HTML-escaped). Every control is still a real form element
  submitted by a visible GET button; the button only hides once the page's
  own script proves it is running (`.js-auto`), and every existing filter
  URL still works unchanged. Both themes, `prefers-reduced-motion`
  respected, no new colours outside the existing tokens.
- [Fix] **The cross-table no longer shows a sideways scrollbar under a table
  that fits the screen.** A long player name widened the whole table past the
  page, because the name column's width cap was ignored; names now shorten
  with an ellipsis at the intended width. When a cross-table really is wider
  than the screen, its scrollbar is slim.
- [Feature] **The admin panel shows which hosted account published a
  tournament**, instead of just "operator" for every tournament a hosted
  OpenPairings publishes. A hosted publish now carries a new, additive
  `publisher` field (owner email and instance host); stored on the
  tournament row (`owner_email`, `owner_host`) and shown in the tournaments
  list and on a tournament's own page - admin panel only. `GET
  /api/tournaments/:slug` strips `publisher` before serving the stored
  payload, so it never reaches a public page, public JSON, or a feed.
  Documented in `docs/snapshot-schema.md` and `docs/privacy-retention.md`,
  and listed on the terms page. An older client, a desktop/local publish, or
  a publish whose owner could not be resolved keeps showing "operator", as
  before.

## [0.16.1] - 2026-09-14

- [Change] **The admin panel no longer says "listed" for a tournament that is
  not on the front page.** The moderation status only ever decided the
  cross-tournament player pages, but "listed" read as "on the front page",
  which is the arbiter's own switch in OpenPairings. The statuses now read
  "pending: not on player pages yet" and "listed: on player pages", and the
  tournament list and each tournament's page gain a **Front page** column:
  "yes", "no: unlisted by the arbiter", "no: hidden", or "nothing published
  yet".

## [0.16.0] - 2026-09-14

- [Feature] **A match the arbiter forfeited by decision says so.** On a
  round page's match line and in a team page's match history, such a match
  reads "Awarded to Team A by the arbiter" under its score, and its boards
  stay listed as they are. It is shown only when OpenPairings sends the
  decision (`matches[].forfeit_decision`, withheld with the match points) -
  a match whose boards merely all show forfeits is not labelled. In Dutch
  and French too.
- [Feature] **Team tournaments have public pages.** A team event's tournament
  page now shows the team standings - rank, match points, game points and
  the configured team tie-breaks, each with the same expandable "working" a
  player's own tie-break cell offers - instead of an individual table, and,
  for a team round robin, a team-vs-team cross-table. A round page lists that
  round's matches ("Team A 2½-1½ Team B"), each expandable to its board
  lines, and carries the same withheld-results and live behaviour an
  individual round already has. Each team gets its own page: roster in board
  order, and its match history. A new board prizes page lists `board_stats`,
  one table per board. The filter bar's Team control narrows a round's board
  lines to one team; category, federation and name keep working alongside
  it. A team Swiss paired by teams gets the same pages except the
  cross-table; an older team Swiss that was paired player by player is sent
  as an individual event and keeps its individual pages. Every field this reads is
  additive - see `docs/snapshot-schema.md`'s new "Team tournaments" section -
  and an individual tournament's pages are unchanged.

## [0.15.0] - 2026-09-13

- [Feature] **A round's results can be held back while its pairings are public,
  and a round whose results are coming in says so.** OpenPairings now keeps a
  new round's results private until the arbiter switches them on; rounds that
  were already public keep their results. When a round's results are held
  back, its round page, the cross-table and a player's card say "Results for
  round N are not published yet." once, and the round page shows the boards
  without a result column rather than a column of unreported games. A round
  whose results are public but not all in carries a small "Live" label and
  "7 of 12 results" on its page and on the tournament's standings page, and
  the standings heading reads "after round 2, round 3 in progress" so the
  table does not look stuck. While a round is live, open tournament pages
  refresh every 10 seconds instead of 20; those refreshes still do not count
  as views. A round with held-back results is never treated as finished. A
  snapshot from an older OpenPairings, which does not say, is read as results
  public, exactly as before. English, Dutch and French.
- [Feature] **A filter and sort bar, on the standings, round pairings and
  cross-table pages.** Category (when the arbiter shows one), federation,
  club and a name search - narrow the standings to "Best U1800" or "my club"
  with a real link you can share or bookmark, no JavaScript required. Round
  pairings keeps a board when either player matches and marks which seat(s)
  do; the cross-table narrows which players get a row without touching the
  opponent numbers inside it. Sort by rank (the default), rating, name or
  federation on the standings - the rank column always shows the arbiter's
  own placing, whatever the sort. Filtering by category also shows each
  row's place within that category, e.g. "3 · 1 in U1800". Moving between
  the three pages keeps the filter and sort. Reads the category names
  OpenPairings now sends (see below); an older OpenPairings, or an arbiter
  who has category display turned off, simply gets no category control.
- [Change] **The standings table's club/federation/category filter and its
  sort-by-column buttons are gone**, replaced by the shared filter bar
  above - the old ones worked only with JavaScript and only on the standings
  page.
- [Change] **Dutch says "FIDE-rated", not "FIDE-gerateerd".** The FIDE badge on
  tournament pages uses the term Dutch-speaking arbiters actually say.
- [Change] **A player's chart waits for a third round, and a short event gets a
  narrow one.** After two rounds the chart was two bars and a stub of a line
  stretched across the full width; the round-by-round card already shows the
  same thing, so the chart now appears once the running score has three
  points. Each round gets at most 80 units of width, so a five-round event is
  no longer spread across the whole page.

## [0.14.1] - 2026-09-13

- [Fix] **A restore no longer drops a removal that shared its timestamp with
  another one.** Ending an installation's trust and lowering its limits in the
  same instant wrote two journal lines with one time; when a restore replayed
  them, the first line's replay made the second look already applied, so the
  limit stayed high. A replay now only covers a line of the same kind at the
  same time, and a second boot still changes nothing.
- [Feature] **A terms and privacy page, at `/terms`.** Who runs the site, who
  may publish what, what is not allowed, when a tournament shows where, how the
  operator moderates, how to have a tournament or your name removed or
  corrected, what the site keeps about people and for how long (the periods the
  server is really running with, backups included), and that results are the
  arbiter's. In English, Dutch and French, linked from the footer of every
  public page (not the projector view) and under the send button of the entry
  and report forms.
- [Feature] **A contact email setting.** Optional, blank by default, set on the
  admin Settings page or with `OPENRESULTS_CONTACT_EMAIL`, checked as one email
  address and written to the action log like the other settings. When set, the
  terms page shows it as a direct way to reach the operator, as a plain
  `mailto:` link that Cloudflare's email obfuscation leaves alone; when not,
  the page offers only the report form.
- [Change] **`GET /api/server` reports this server's own terms page when no
  terms link is set**, as `https://<host>/terms`, so OpenPairings' consent
  dialog links a real page with no configuration. A terms link set in the
  panel or the environment still wins.
- [Fix] **The stats page's "views" no longer count a tournament page's own
  auto-refresh.** A public tournament page polls its own URL every 20 seconds
  to stay live, and every poll used to count as a view - a single reader with
  a tab open for a couple of hours could look like hundreds of visitors (an
  operator saw 450 "hits" on one page embedded elsewhere, from what was really
  one person). A request now counts as a view only when it looks like a
  browser navigating to the page (`Sec-Fetch-Mode: navigate`, or no
  `Sec-Fetch-Mode` at all, for older clients); the refresher's own `fetch()`
  calls also carry an explicit `x-openresults-refresh` header so they are
  never mistaken for one either way. Polls are still counted, just apart from
  views, as "refreshes" on `/admin/stats`, next to a rough **"live followers"**
  estimate (refreshes per minute ÷ 3, since one open page polls about that
  often) - labelled as an estimate of open pages, not of visitors. (Both
  refreshers already paused their polling while their tab was hidden and
  caught up once when it became visible again - checked while fixing this,
  unchanged here.)

## [0.14.0] - 2026-09-13

- [Change] **A pending tournament is public straight away, except on player
  pages.** A tournament published with an installation key is now on the front
  page and in its search from its first publish, and its pages no longer carry
  `noindex`. What it still waits for is the cross-tournament player pages, so a
  fake tournament cannot put invented results on real players' histories. In
  the admin panel, approving is now **Show on player pages**, and a pending
  tournament reads "pending: not on player pages yet".
- [Feature] **Server settings in the admin panel.** The operator name, the terms
  link and the public-publishing limits (versions kept, the free-disk floor, the
  registration budgets, publishes per minute, tournaments per installation, the
  snapshot size cap) can be changed on a new **Settings** page, with no deploy.
  A value saved there wins over `.env`; each setting shows whether its value
  comes from the panel, the environment or the default, and **Reset to
  default** removes the panel's value. `GET /api/server` reports the panel's
  operator name and terms link. The public-publishing gate, the admin
  variables, tokens, passphrases, backups, database and host stay in `.env`
  only, listed read-only without their values.
- [Change] **The limits are checked for range at boot.** The five registration
  and installation limits in `.env` now stop the boot when out of range, as the
  panel refuses them (publishes per minute at least 1, snapshot cap 1 to
  8,000,000 bytes, the others at least 0), `OPENRESULTS_TERMS_URL` must be an
  `https://` address, and `OPENRESULTS_OPERATOR_NAME` one line of at most 100
  characters.
- [Feature] **Trusted installations.** An installation can be marked trusted
  from its page in the admin panel; tournaments it creates start listed, on
  player pages at once, and trusting can also list the ones it has pending.
  Revoking ends trust. Any installation can also be given its own tournament
  limit, snapshot size cap, publishes per minute and version cap, with an empty
  field meaning the server's value.
  Ending trust and lowering an installation's limits are kept in the
  moderation journal, so restoring an older backup does not bring back trust
  or a looser limit that was taken away; granting trust and raising a limit
  are not kept, like approving.
- [Feature] **A public notice.** The operator can put a short message on every
  public page ("Maintenance tonight 22:00-22:30") from the settings page: in
  English, with optional Dutch and French, as information or a warning, with
  an optional expiry after which it disappears by itself. It is not shown on
  the projector view. Setting, changing, clearing or expiring it changes every
  page's ETag and cached copy, so nobody keeps being served the old page.

- [Feature] **A stats page in the admin panel, `/admin/stats`.** Traffic for
  the last hour (per minute) and the last 24 hours (per hour): requests by
  route group, status classes, page-cache hit rate and 304 share, response
  time p50/p95/p99, and the busiest tournaments. Server health: CPU and load
  from `/proc` (or "not measured"), system and BEAM memory, schedulers online
  against logical CPUs (to confirm `+S 2:2` took effect), run queue, open HTTP
  connections, uptime and versions. Publishing in the last 24 hours:
  publishes by operator token and installation key, mints, registrations and
  refusals by code. The database: file and WAL size, row counts (once a
  minute), query and pool-queue p95, and free disk. Counted in memory by
  telemetry handlers doing one ETS increment per request, reset by a restart,
  with no addresses, user agents or query strings. Server-rendered SVG charts,
  no JavaScript, reloads every 30 seconds. Measured cost on one pinned core:
  about 1-2% of throughput, within the run-to-run noise
  (`docs/stats-overhead-2026-09-13.md`).
- [Fix] **The admin panel showed every email address as "[email protected]"
  behind Cloudflare.** Cloudflare's Email Address Obfuscation rewrites addresses
  in HTML and decodes them with a script, and the panel allows no scripts, so
  "Signed in as", the action log and report contacts all stayed mangled. The
  panel's pages are now wrapped in Cloudflare's `email_off` markers; public
  pages are unchanged.
- [Feature] **An arbiter's own delete shows in the action log.** Deleting a
  tournament through `DELETE /api/tournaments/:slug` was journalled but never
  reached the admin panel's action log, which only recorded the panel's own
  deletes. It now writes a `delete` row with the purge counts, and the actor
  says which credential did it: `installation:<id>`, `tournament-key` (the
  tournament's own key), or `operator-token` (a tournament never claimed).
  Break-glass is still logged once, as `break-glass`, and not a second time.
- [Change] **The action log's "Who" filter matches part of the actor.**
  Typing `installation:` or the start of an email now finds those rows; the
  other filters still match exactly.
- [Feature] **Entry queues are deleted once the tournament is over.** Thirty
  days after a tournament's `end_date` - or, with none, after its last publish,
  and never while its `start_date` is still ahead - its registrations, email
  addresses included, are deleted by the daily retention job.
  `OPENRESULTS_REGISTRATION_RETENTION_DAYS`, default 30.
- [Feature] **Report contact emails are forgotten after resolution.** Ninety
  days after a report is resolved its contact email is cleared; an open report
  keeps it. `OPENRESULTS_REPORT_CONTACT_RETENTION_DAYS`, default 90.
- [Feature] **The action log forgets blocked ranges.** Thirty days after an
  address block ended, its `block_address` and `unblock` rows lose the range
  and keep everything else. `OPENRESULTS_BLOCK_ADDRESS_RETENTION_DAYS`,
  default 30. All three variables refuse to boot on anything but a whole number
  of at least 1. `docs/privacy-retention.md` sets out every piece of personal
  data the server keeps and the longest it can survive, backups included.

- [Feature] **Public publishing can no longer fill the disk.** Every changed
  version of a tournament used to be kept, so one installation could store
  about 90 MiB a minute on a disk this server shares. Two bounds, decided
  before public publishing goes live (`docs/public-publishing.md`, "Storage
  bounds"): a tournament owned by an installation keeps its newest **20**
  versions (`OPENRESULTS_INSTALLATION_MAX_VERSIONS`), the oldest pruned in the
  same transaction as each publish - never the current one, and a tournament
  already over the cap is pruned on its next publish; operator-published
  tournaments keep every version. And when free space on the database's
  volume is below **10%** (`OPENRESULTS_MIN_FREE_DISK_PERCENT`), installation
  keys get 503 `storage_low` with `Retry-After: 300` when publishing or
  creating a tournament; deleting, reading, registering and the operator
  token are unaffected. Free space is measured with `df` every minute; where
  it cannot be (Windows, no `df`) nothing is refused and a warning is logged.
  The admin dashboard shows free space against the floor and the cap, with a
  warning while below it, and a pruned tournament's page says "Oldest kept
  version" instead of "First publish". Both values must be whole numbers in
  range or the app does not start.
- [Fix] **A restore no longer undoes moderation.** The restore drill restored a
  backup after the operator had kept working, and the restored site had
  undone all of it: a revoked installation minted a slug again, closed
  registration issued a key, a blocked range registered, a tournament deleted
  for personal data was back with its history, and a tournament its arbiter
  withdrew from OpenPairings was online again with its entry form open. Every
  action that makes the site safer - deleting a tournament (the admin panel's,
  and an owner's or the operator's `DELETE /api/tournaments/:slug`), hiding,
  revoking, suspending, blocking an address, closing registration, pausing
  publishing - now also appends a line, once it has committed, to a journal
  kept beside the database and outside it (`openresults-moderation.jsonl` next
  to `openresults.db`), which no backup contains and no restore touches. At
  every start, before the site serves anything, each journalled action the
  database does not know about is applied again, with an action log row from
  `restore-replay`. **Only in that direction**: approving, unhiding,
  unsuspending, unblocking, opening registration and unpausing are never
  journalled, so after a restore they stay as the backup had them and are
  redone deliberately. A tournament published again under a deleted address
  after the delete, and anything the operator reverses after the restore, are
  left alone. The journal is trimmed to what a remaining backup could still
  bring back. It holds slugs, installation ids, switches, and for a block the
  range and its expiry - not the block's reason.
- [Fix] **A server run refuses to start on a database that is behind the code,
  instead of answering some pages and 500ing the rest.** The drill's backup
  from before 2026-09-12 booted under `mix phx.server`, which does not
  migrate, and failed every tournament page, `GET /api/server` and every
  publish. A production run that does not migrate now checks first and, with
  migrations pending, says how many, which, and to run `mix ecto.migrate`, and
  stops - as OpenPairings does. A release still migrates at boot.
- [Security] **Backups no longer hold client addresses.** Where each
  installation registered from and was last seen from, and where each report
  came from, are nulled in the copy before it is written - the rows stay,
  only the addresses go - and the copy is vacuumed so the old values are gone
  from the file, not left in its free space (nulling alone left 43 of 400 test
  addresses readable). Retention forgets addresses after 30 days in the live
  database, but the restore drill measured backups holding them for about two
  months, and a restore bringing back addresses retention had already
  forgotten. They exist only for judging an address block, so losing them on
  a restore is harmless: the next request records a current one. Still in a
  backup, and left as a policy question in the drill document: a report's
  optional contact email, the entry form's email addresses, and the address
  or range recorded in the action log's block entries.
- [Change] **`BACKUP_RETENTION` is now a number of DAYS, not a number of
  files - and a restart no longer spends a backup.** It was a count, and every
  boot wrote a backup five minutes in and every manual run another, so the
  default "30" was a month only on a box nobody restarted: the restore drill's
  instance had four backups inside twenty minutes. Now a backup is kept while
  it is younger than that many days (by the time in its own header), **the
  newest is always kept** whatever its age, and the scheduler skips the
  boot-time backup when the newest on disk is less than a day old, scheduling
  the next one for when that one comes due. **If you set `BACKUP_RETENTION`,
  read it again as days**; a value that is not a whole number of at least 1
  still stops the boot. Listing backups reads each file's header instead of
  the whole file.
- [Fix] **Restoring a backup is now a written, rehearsed procedure - and the
  commands this site used to print for it could restore nothing.**
  `mix openresults.backup --restore` said to move the database file aside and
  the recovered one in. It never mentioned the database's `-wal` and `-shm`
  files: after a service that crashed or was killed rather than stopped,
  those hold the newest writes, and left beside the recovered file SQLite
  reads them into it. The 2026-09-13 drill got a database that never existed -
  the old action log, the backup's tournaments - with the integrity check
  saying "ok". The task now prints a swap that moves all three files together,
  restores ownership and runs `mix ecto.migrate` before the start (a backup
  older than the code otherwise boots and answers 500 on every page); the
  whole procedure, and what a restore undoes, is in `docs/deployment.md`.
- [Change] **What a restore undoes is now written down, with a way to find
  it.** As the drill found it, a restore rolled moderation back with the data:
  a revoked installation key worked again, closed registration was open,
  blocks were gone, and a tournament its arbiter withdrew was back online with
  its entry form open. The removals are now put back by the moderation journal
  (above); the deployment guide's read-only script compares the restored and
  the replaced database and lists what is still left by hand - the approvals,
  unhides and openings made after the backup. Details in
  `docs/restore-drill-2026-09-13.md`.
- [Fix] **`--verify` reads every page.** It checked that three tables existed,
  so a backup of a database with one damaged table verified and restored.
  It now runs SQLite's integrity check and refuses, before anything is written.
- [Security] **An encrypted backup can no longer ask for an absurd key-stretching
  count.** The iteration count is read from the file before its tag can be
  checked; a header asking for billions of iterations wedged `--verify` and
  `--restore` for hours (twenty million took 7.6 s). The same bound
  OpenPairings has applied since its 2026-09-01 sweep.
- [Fix] **Verifying a backup no longer leaves a decrypted copy of the database
  in the temp directory.** On Windows every verify did; on any system a refused
  one did. The copy is now removed on every path.
- [Fix] **`BACKUP_RETENTION` of 0 or less no longer deletes the newest
  backups.** 0 deleted every backup, the one just written included, and a
  negative count kept the oldest and deleted the rest. Retention never keeps
  fewer than one, and a value below 1 now stops the boot with a message.
- [Fix] **The first start after a restore no longer logs `database is
  locked`.** A recovered database is switched to WAL before it is handed over,
  instead of every connection of the next boot racing to do it.
- [Change] `mix openresults.backup --verify` and `--restore` accept a backup's
  name exactly as `--list` prints it.

- [Feature] **The admin panel's management pages.** Behind the `/admin` gate:
  a dashboard with both switches (opening registration, and pausing public
  publishing - which says plainly that it takes arbiters' live updates
  offline mid-event), counts of installations, tournaments and open reports,
  and the latest actions; tournaments, filterable, each with its owner,
  publish dates, snapshot size and reports, to approve, hide, unhide,
  transfer to another installation or delete; installations to suspend,
  unsuspend or revoke, with an explicit choice about hiding their
  tournaments; the report queue, each linked to its tournament, to resolve
  with a written resolution; address blocks, whose confirmation page shows
  how many installations were seen from the address before anything is
  blocked; and the whole action log, filterable and paged. Every change goes
  through a confirmation page and is logged with the admin's address. Input
  that cannot be used comes back to the form with a sentence saying why.
- [Feature] **Moving every tournament of an installation to another one, in
  one step.** A laptop restored from an OpenPairings backup comes back as a
  new installation, because no backup carries the installation key. The old
  installation's admin page now moves all of its tournaments - pending,
  listed and hidden - to the new one, after a confirmation page listing each
  tournament and showing which laptop they are going to (its client, version
  and when and where it was last seen). All of them move or none do. A
  suspended or revoked installation cannot receive them.
- [Feature] **What published tournaments cost in disk, in the admin panel.**
  Stored snapshot bytes and the database file's size on the dashboard, per
  installation on its page, and per tournament (the current snapshot and
  every kept version) on the tournament's page - the figures the coming
  decision about bounding storage needs.
- [Feature] **Public publishing, switched off until the operator turns it
  on.** With `OPENRESULTS_PUBLIC_PUBLISHING=enabled`, any copy of OpenPairings
  can publish here without the server's master token: it asks for an
  installation key of its own (`POST /api/installations`), asks the server for
  a tournament address (`POST /api/tournaments`), and publishes as before.
  `GET /api/server` says whether this server takes installations and who runs
  it. A self-hosted copy that upgrades without setting the variable looks
  exactly as it did - the new routes are not there. The contract, and every
  question the build had to settle, is `docs/public-publishing.md`.
- [Feature] **Tournaments now have a visibility: pending, listed or hidden.**
  Everything already published is listed and stays exactly where it was. A
  tournament published with an installation key starts pending: its own
  pages work from the first publish, so an event never waits for approval,
  but it carries `noindex` and stays off the front page and off players'
  cross-tournament history pages until the operator approves it - otherwise
  anybody could put invented results on a real player's history. A hidden
  tournament answers every page, form and API read with the same "not found"
  as an address nobody ever published.
- [Feature] **"Report this page"**, at the foot of every tournament page, in
  English, Dutch and French. It sends a short report - wrong or invented
  results, personal data, spam, or something else - to the operator of this
  site, not to the arbiter, and changes nothing until somebody has read it.
  Rate-limited like the entry form.
- [Feature] The moderation behind all of that (`OpenResults.Moderation`):
  approving, hiding and transferring tournaments, suspending and revoking
  installations, resolving reports, temporary address blocks, the two
  runtime switches, and an action log of who did what - including every use
  of the master token as break-glass. The admin panel that drives it arrives
  separately. A daily job forgets client addresses after 30 days, releases
  tournament addresses that were handed out and never used, and removes
  expired blocks.
- [Security] **An installation key can touch only the tournaments created
  for it, and nothing it was not explicitly allowed.** Publishing, deleting,
  reading the history and reading the entry queue - the one route with email
  addresses - are refused for an operator's tournament, one published before
  keys existed, another installation's, or an address never handed out. On
  any write route that has not opted in, an installation key gets the same
  answer as an unknown one, and a test walks the router to keep it that way.
  It never acts as the break-glass master key in either header. Snapshots
  published with one are capped at 3 MiB, a size measured against a
  500-player, 11-round open with its tie-break working.
- [Change] Every API error now carries a `detail` sentence beside its
  `error` code, including the 401. Clients that read `error` - which is all
  of them - see no difference.

- [Feature] **Dutch and French pages now write numbers and dates the way
  those languages do** - `5,5` rather than `5.5` for every score, tiebreak
  value and Keizer value on the site, and `29 augustus 2026` / `29 août
  2026` rather than `2026-08-29` for every date, including the projector
  screen and the entry form, with French's `1er` for the first of the
  month. This is the fix for the two things
  `docs/translations-audit-2026-09-12.md` found were not translated at all
  (findings 2 and 3) - **English is untouched**, still `5.5` and still
  `2026-08-29`. A tournament's own date range now reads idiomatically
  rather than as two dates joined by a word - `1-5 maart 2026` within one
  month, `30 augustus - 2 september 2026` across two - and a date this
  cannot parse still renders rather than taking the page down, exactly as
  an old snapshot's missing date always has. Nothing a script reads
  changed: the standings sort's `data-*` attributes keep the point, in
  every language, which is what lets the sort and filter script go on
  reading them with a plain `parseFloat`.

- [Feature] **The admin panel's front door: `/admin`, behind Cloudflare
  Access and checked again by the site itself.** Signing in goes through
  Cloudflare Access and Keycloak; the site then verifies the token Access
  attaches (its signature against Cloudflare's published keys, that it was
  issued for this application and this team, that it is current) and checks
  the email against its own list. A mistake in either place alone opens
  nothing. For now the panel is a dashboard saying who is signed in and a
  sign-out link; the moderation pages come with public publishing. It
  exists only when `OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN`,
  `OPENRESULTS_ADMIN_ACCESS_AUD` and `OPENRESULTS_ADMIN_EMAILS` are all set -
  otherwise, and for anyone without a valid Access token, `/admin` is the
  same "Not Found" as a page that does not exist. Setup, checks and
  troubleshooting are in `docs/admin.md`.
- [Security] **Admin pages are never stored, framed, indexed or scripted,
  and destructive actions will always ask first.** Every admin response is
  `Cache-Control: no-store`, refuses to be put in a frame, asks search
  engines to stay away and runs no JavaScript; none of it passes through the
  page cache that serves public pages. Anything that deletes or revokes goes
  through a confirmation page and a form protected against cross-site
  forgery. The public pages keep all of their own behaviour: still
  embeddable, still cached between publishes.
- [Security] **The public site now cannot set a session cookie even by
  mistake.** The session machinery used to be switched on for every
  request, and the public pages stayed cookie-free only because nothing on
  them happened to use it. It now exists on `/admin` alone, in a cookie of its
  own that the browser sends nowhere else.
- [Fix] **Sorting and filtering the standings did nothing on a tournament
  that opened before round 1** until the page was reloaded. The script that
  wires the sort buttons and the filter lived inside the standings table,
  which only renders once there are standings, so a page first opened on the
  starting list never ran it - and the 20-second refresh that later swapped
  in the real table found nothing listening. The script now renders on every
  standings page, and a sandboxed frame that forbids `history.replaceState`
  no longer stops it wiring the buttons.
- [Fix] **Three messages on the entry form were answered in English on
  Dutch and French pages**, even though all three had been translated since
  the day the site learned to speak them: the ones about a name being
  between 2 and 100 characters, an address being too long, and a club name
  being at most 100. The translations were fine; the site was looking them
  up the wrong way, as though they were the kind of sentence that changes
  with a number in it. The form is the one place here where a visitor is
  told they got something wrong, so it is the last place that should have
  been saying it in a language they did not ask for.
- [Fix] **Four French sentences said something other than their English
  originals.** The cross-table's key had the score coming from the
  opponent's side of the board rather than the player's; the player card
  called the arbiter's total "official", which is a claim this site does not
  make anywhere else; the player-history line was missing a word and read as
  broken French; and the hint under the entry form's Elo box used the same
  word this site uses for the standings, so it read as "the standings you
  play under".
- [Fix] **French punctuation spacing.** Fourteen French sentences could
  break a line and leave a colon or a question mark stranded at the start of
  the next one. They now hold the space French typography asks for.
- [Verified] First audit of the translations themselves - all three
  languages, both catalogues, read end to end. Written up in
  `docs/translations-audit-2026-09-12.md`, including what was checked and
  found correct (the page cache serves each language its own pages; every
  placeholder matches; French and Dutch chess vocabulary is the right
  vocabulary) and what was left for a separate decision - scores printing
  `5.5` and dates printing `2026-08-29` in every language, since fixed for
  Dutch and French (the entry at the top of this section).

- [Fix] **Keyboard and screen reader users keep their place when the page
  updates itself.** Every real update from the 20-second refresher dropped
  keyboard focus to the top of the page, closed any tie-break working a reader
  had opened, scrolled a wide cross-table back to its first round, emptied the
  front page's search box and put a sorted standings table back in rank order.
  All five now survive an update, and an update waits while a filter or a
  search box is in use instead of replacing it under the reader.
- [Fix] **What the page says is read out.** "updated just now", "not updating -
  connection lost", the standings filter's "Showing 4 of 32" and the entry
  form's FIDE search results were written where a screen reader could not
  announce them. They are now spoken, along with the new order after sorting a
  column and the front page's "No tournaments match your search."
- [Fix] **The player card behaves like a dialog.** Opened by right-click, or
  from the keyboard with the context-menu key or Shift+F10 on a player's name:
  focus now moves into the card, Tab stays inside it, and closing it - Escape,
  Close or a click outside - puts focus back on the name.
- [Feature] **A "Skip to content" link**, the first thing Tab reaches on every
  page, past the brand, the languages and the theme picker. The page's content
  is now marked as its main region, and the masthead as its banner, for screen
  readers that jump between them. The admin panel has the same link.
- [Change] **Stronger contrast where it was too weak.** The grey for things set
  aside - an unpublished round, a tie-break contribution that did not count, a
  result not yet in - was as faint as 2.3 to 1 and is now at least 4.5 to 1 in
  every theme: darker on Paper and Board, lighter on Night and Slate, same hue.
  Text boxes and dropdowns have a visible edge, and everything the keyboard can
  reach shows a focus ring in the theme's accent.
- [Fix] **Tables and forms tell a screen reader what they are.** Every table is
  named and every row has a header - the player, the board or the round - so
  moving along a row says whose numbers they are. A hyphen for a result not yet
  in, and an empty cross-table cell, say what they mean instead of "dash" and
  "blank". The current page in the round strip is announced as current, and a
  round link reads "Round 3" rather than "3". On both forms every error belongs
  to its field, required choices are announced as required, a refused form puts
  focus on the sentence saying nothing was sent, and the birth year can be
  filled in by the browser. The theme picker says which theme is on.
- [Fix] **No sideways scrolling at 320 pixels or 400% zoom.** The masthead and a
  player's tie-break summary pushed narrow screens sideways; both wrap now.
- [Verified] First accessibility pass, against WCAG 2.2 AA:
  `docs/accessibility-2026-09-13.md`, with a keyboard and an NVDA checklist.
  Every page is now audited by the test suite on every run - labels, names,
  table headers, landmarks, language - and every theme's contrast is computed
  from the stylesheet.

## [0.13.0] - 2026-09-12

- [Feature] **The version number in the footer is now a link to this
  changelog**, in your own language, the same way OpenPairings' does. The
  build stamp after the version (`+<commit>`) still shows exactly what it
  showed before - that part answers "did my deploy land", and clicking it
  changes nothing about that.
- [Fix] **A few hundred people looking at the same tournament at once could
  exhaust this site's database connections**, even though every one of them
  was asking for a page that had not changed. Working out "is there anything
  new" ran a real database query on every single request, including the
  quiet `304 Not Modified` answers that make up most of them; that lookup is
  now kept in memory instead, and only touches the database on a cold start
  or right after a tournament is taken down.
- [Verified] Re-ran the same load test against the fix with nothing else
  changed: the concurrency level that used to fail two out of five requests
  now completes all of them, at roughly four times the throughput.

## [0.12.0] - 2026-09-11

- [Feature] **Before round 1, the standings page now shows the starting
  rank** - every entered player, in starting order - instead of a blank page
  saying nothing has been published yet.
- [Fix] **The cross-table and a player's own card could show a round's live
  results before the arbiter had folded them into the published standings.**
  Both now stop at whichever round the standings actually cover, matching
  what the arbiter chose to publish rather than whatever has been typed in
  so far.

## [0.11.0] - 2026-09-11

- [Feature] **The front page now sorts every published tournament into Live,
  Upcoming and Finished**, worked out from each tournament's own dates and
  how many rounds it has published, and gains a search box over the list.
- [Fix] **Clicking a column header to sort the standings could scramble the
  table instead of reordering it, and the Rating column's own sort did
  nothing at all.** Both are fixed; found by actually clicking them, since
  neither bug could be seen from the test suite alone.

## [0.10.0] - 2026-09-11

- [Feature] **Every tiebreak value on the standings can now be opened**, by
  tap or by keyboard, to see how it was reached rather than only what it is
  - for the tournaments whose arbiter chose to publish that detail.
- [Feature] **A FIDE id is now a link to every tournament that player has
  appeared in on this site**, wherever a FIDE id already appears. Matched by
  id, never by name, since two players can share a name.
- [Feature] **The standings can be sorted and filtered** - by column, and by
  club, federation or category - entirely in your own browser; the page the
  server sends is unchanged either way.
- [Fix] **On a narrow phone screen, the cross-table's pinned name column
  could overlap its own pinned rating column**, hiding a digit of the
  rating or letting a result show through the gap. Fixed at both rest and
  mid-scroll.

## [0.9.0] - 2026-09-10

- [Feature] **A cross-table**: one row per player, one column per published
  round, showing who they played, which colour, and the result from that
  player's own side of the board. The single thing a visiting arbiter looks
  for first on a results site, and this one did not have it until now.
- [Fix] **A tournament whose arbiter withheld the standings still handed the
  same placings back through every player's own card.** Closed, the same
  way the cross-table already closes it.
- [Change] **OpenResults is now licensed under the Elastic License 2.0**,
  the same terms as OpenPairings, with an explicit permission allowing a
  federation to host it for its own member clubs. The repository had been
  public with no licence at all since the split, which is not a permissive
  default - it is "all rights reserved" - so nobody actually had the right
  to run their own copy.

## [0.8.0] - 2026-09-09

- [Security] **The entry form's rate limit could be exhausted by anyone
  submitting through it**, because every request looked like it came from
  the same address - the tunnel this site runs behind, not the actual
  visitor. It is now keyed by the visitor's own address.
- [Fix] **A tournament's entry queue had no limit on how many entries it
  would hold.** One tournament being flooded can no longer fill up and
  crowd out another's.
- [Security] **The page cache's own validator was predictable enough to
  work out from the outside in seconds.** It is now drawn from a secret this
  server never discloses, so a collision can no longer be produced to
  order.

## [0.7.0] - 2026-09-08

- [Feature] **This site now speaks Dutch and French as well as English**,
  chosen from your browser's own language automatically, with a switch in
  the header that remembers an explicit choice.
- [Feature] **A link to a tournament now names it when pasted into a chat
  app or club WhatsApp group** - a title, a short description and the
  tournament's own dates, instead of a bare URL - honouring whatever the
  arbiter has chosen to keep off the page.
- [Fix] **A board with an empty seat and a real result is now named for
  what it is** - a vacated seat - instead of being shown as an ordinary
  bye, on tournaments published from a version of OpenPairings that sends
  the difference.
- [Fix] **Several display switches an arbiter can turn off (hiding the
  city, the dates, or the standings) had quietly stopped working on the
  front page and the projector view**, even though they still worked
  everywhere else. All of them are now honoured on every page that shows
  the fact they control.
- [Fix] **Publishing one tournament could wipe every OTHER tournament's
  warm page cache.** No visitor was ever shown the wrong page because of
  it, but a busy weekend with several events running at once paid for a
  full re-render on all of them every time any one published. Each
  tournament's cache is now its own.

## [0.6.0] - 2026-09-06

- [Security] **Closed two denial-of-service advisories in this site's HTTP
  client** (the same `mint` advisories OpenPairings closed the same week):
  one could exhaust memory from a malicious response, the other could stall
  on pathological chunked data.
- [Fix] **A bye's label on the pairings table sat two or three columns to
  the left of where an opponent's name would be**, looking like it had
  landed in the wrong row even though the numbers added up. It now sits
  under "Opponent", where a name would be.

## [0.5.0] - 2026-09-04

- [Feature] **A projector view for a round's boards**: reached from a link
  on the round page, it pages through the boards a screenful at a time when
  they don't all fit on one screen, in a high-contrast theme meant for the
  back of a hall, and keeps itself current without ever needing a reload.

## [0.4.0] - 2026-08-31

- [Feature] **Right-click a player's name for a quick answer to "why am I
  in this position"** - rank, score, and each tiebreak's own working, in an
  overlay, without leaving the page you were reading. Left-click still goes
  to that player's full page, which now also carries a chart of their score
  through the tournament.
- [Feature] **When a tiebreak was used to order two players but is not
  itself shown**, the standings now say so, since the order can still
  depend on a number the page never printed.
- [Feature] **The footer now says which exact build is serving the page** -
  the release, the commit and when it was compiled - so a deploy that did
  not actually land is visible on the page instead of invisible.
- [Change] **Standings and player pages stopped re-fetching and re-decoding
  the whole published document from the database every 20 seconds for every
  reader.** An unchanged page now costs a single lookup instead of hundreds
  of kilobytes of JSON, and a round just published renders once and is sent
  to everyone waiting rather than once per reader.

## [0.3.0] - 2026-08-29

- [Feature] **Six colour themes**, chosen in the header and remembered on
  this device - a board green, a cool slate, and a high-contrast theme for
  a projector, alongside the original - and OpenResults' own mark, the same
  silhouette as OpenPairings' own in this site's colour.
- [Feature] **The entry form can search the arbiter's own FIDE list** to
  fill in a player's rating, title and federation, without this site
  keeping a copy of that list itself.
- [Feature] **`mix openresults.backup`** - list, verify and restore a
  complete backup of everything this site holds: every published
  tournament, its whole history, and the entry queue behind it.
- [Fix] **Embedding a tournament's page inside another site never actually
  worked**, silently blocked by a security header nobody had noticed was
  there. It works now: nothing on this site needs a login to protect, so
  there is nothing embedding could steal.
- [Fix] **A bye kept only the player's name, dropping the title and rating
  every other row on the same page shows for them**; a player with no
  rating at all now shows a dash rather than a blank cell, which used to
  read as "not entered yet" instead of "there is none".

## [0.2.0] - 2026-08-29

- [Feature] **A published tournament can now be taken down**, removing
  every trace of it - its whole history and the entry queue's email
  addresses included. Before this the only way was SSH and hand-editing
  the database directly, which meant in practice that a tournament
  published by accident stayed published.
- [Feature] **Each tournament now gets its own key for publishing to it**,
  instead of one key shared by every tournament on the server - so holding
  the key to publish one event no longer means being able to overwrite any
  other.
- [Fix] **This site had quietly stopped honouring two things the arbiter
  had already decided**: whether a tournament is still taking entries, and
  that a hand-set standings order was actually hand-set rather than
  computed from a tiebreak. Both are read from the published document and
  honoured again.

## [0.1.0] - 2026-08-28

- [Feature] **First public release.** A tournament published from
  OpenPairings is stored here and rendered as standings, pairings for each
  round, and a card for every player - read-only, with no accounts and
  nothing to log into.
- [Feature] **A public entry form**, and the endpoint the arbiter's own
  software uses to collect what it collects, rate-limited per address.
