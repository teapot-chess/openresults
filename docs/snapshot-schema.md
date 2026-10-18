# The snapshot schema

The one contract between OpenPairings and OpenResults. An arbiter's machine
builds a snapshot and pushes it; this app stores it and renders it. Nothing
else crosses.

This file is the specification. Change it reluctantly.

## Why it looks like this

**It describes a tournament, not a database.** TRF16 has survived twenty
years because it describes chess rather than software; a payload shaped like
OpenPairings' Ecto schema would need a new version every time a column moved.
So: rounds, boards, standings - things an arbiter would recognise.

**Old clients must keep working.** A laptop running OpenPairings 0.17 will be
publishing to a server running 0.25 for months, because arbiters update when
they feel like it and that is how SwissManager has always worked. Therefore:

- **Additive only.** A field is never removed, never renamed, and never
  repurposed. If it stops being meaningful it becomes optional and is
  ignored.
- **The reader ignores what it does not recognise.** A newer client sending
  a field this server has never heard of must not be an error.
- **The envelope is versioned, not the fields.** `version` changes only for
  a break that cannot be expressed additively, which should be never.

**No database ids cross the boundary.** Players are referenced by their
tournament pairing number (`no`), which is the TRF start number - stable
within the event, meaningful to an arbiter, and useless to anyone trying to
correlate players across tournaments.

**The arbiter is the authority.** Standings arrive computed, with tiebreaks
already applied. This app never calculates a placing. That is deliberate:
the arbiter's screen and the public page must agree, and the printed
crosstable is the document of record. A server that recomputed could
silently disagree with the hall.

**Withholding is enforced at build time.** A round the arbiter has not
published, and a board they have hidden, are simply *absent from the
payload*. The server cannot leak what it was never sent - which is a
stronger guarantee than the current design, where a public page has to
remember to filter.

## The document

One JSON document per publish. It carries the whole tournament as known at
that moment, not a delta - a tournament is a few hundred kilobytes at worst,
deltas would need ordering guarantees over an unreliable network, and a
whole document is trivially idempotent.

```json
{
  "schema": "openresults/snapshot",
  "version": 1,
  "published_at": "2026-08-27T18:00:00Z",
  "source": { "app": "openpairings", "version": "0.17.1" },

  "tournament": {
    "slug": "gent-spring-open-2026",
    "name": "Gent Spring Open 2026",
    "city": "Ghent",
    "federation": "BEL",
    "start_date": "2026-03-01",
    "end_date": "2026-03-05",
    "rounds_count": 9,
    "system": "swiss",
    "arbiter": "Jorian Burssens",
    "fide_rated": true,
    "registration_open": true
  },

  "players": [
    {
      "no": 1,
      "name": "Carlsen, Magnus",
      "title": "GM",
      "rating": 2823,
      "federation": "NOR",
      "fide_id": 1503014,
      "club": "Offerspill",
      "category": "A"
    }
  ],

  "rounds": [
    {
      "number": 1,
      "date": "2026-03-01",
      "results_public": true,
      "boards": [
        { "board": 1, "white": 1, "black": 12, "result": "1-0" },
        { "board": 2, "white": 13, "black": 2, "result": null }
      ],
      "byes": [
        { "player": 40, "kind": "pairing-allocated", "points": 1.0 }
      ]
    }
  ],

  "standings": {
    "after_round": 5,
    "manual_order": false,
    "tiebreaks": [
      { "code": "BH", "label": "Buchholz" },
      { "code": "SB", "label": "Sonneborn-Berger" }
    ],
    "rows": [
      {
        "rank": 1,
        "player": 1,
        "points": 4.5,
        "tiebreaks": [22.5, 18.25],
        "working": {
          "BH": {
            "total": 22.5,
            "parts": [
              { "round": 1, "opponent": 12, "value": 4.0 },
              { "round": 2, "value": 2.5, "kind": "virtual" },
              { "round": 3, "opponent": 7, "value": 3.5, "kind": "cut" }
            ]
          }
        },
        "category": "A"
      }
    ]
  }
}
```

## Field notes, where the choice was not obvious

**`players[].no`** - the tournament pairing number. Every other reference in
the document (`boards[].white`, `byes[].player`, `standings.rows[].player`)
is one of these. Nothing else identifies a player.

**`players[].fide_id`, `rating`, `federation`, `club`, `title`** - all
optional, all frequently absent in club play. A missing key and a `null` mean
the same thing: not known.

**`tournament.live_boards`** - `true` when the arbiter says the tournament has
live boards (a hall relay reporting moves and clocks, see
`docs/live-boards-api.md`). Optional and additive; absent or anything but
`true` means no link. The static pages show a "Live boards" link on an
explicit `true` only, and never on whether a game has been reported, because
they are cached per snapshot. The moves themselves never travel in a
snapshot. `tournament.hall.live: false` leaves the live boards out of the hall
display's cycle.

**`tournament.categories`** - the tournament's category vocabulary (e.g.
`["U1800", "Women"]`), in the arbiter's own order - the order they defined on
the Categories page. **Gated**: present only when the arbiter's "Categories"
public-display setting is on (`tournament.display.category`, read by
`OpenResultsWeb.Tournament.show?/2` on this side). Omitted entirely - never
sent as `[]` - when that setting is off, or when talking to an OpenPairings
that predates this field. OpenResults reads absence as "no category filter
available for this tournament", never as "the tournament has no categories" -
the two are indistinguishable from here and the difference does not matter to
a reader either way; see `OpenResultsWeb.Tournament.Filter.categories/1`.

**`players[].categories`** - that one player's OWN categories, drawn from
`tournament.categories`'s vocabulary and in that same order, limited to
categories the tournament still lists - a tag a player once carried that the
tournament later removed is dropped, exactly like `standings.rows[].category`
already drops a category the arbiter stopped listing. Added in OpenPairings
0.53.0 and, since this version, gated the same way `tournament.categories` is
above: present only when categories are shown. **When absent** (an older
OpenPairings, or an individual player entry missing it even though
`tournament.categories` is present), OpenResults falls back to that player's
single `category` field below, wrapped in a one-element list when it is not
`null`, else `[]` - see `OpenResultsWeb.Tournament.Filter.player_categories/1`.
This is a richer, separate thing from `players[].category` just below: a
player can carry several of these (a junior AND a woman, say), where
`category` is the one the arbiter actually paired them by.

**`players[].category`** - the single category this player was PAIRED by -
see OpenPairings' `PairingsEngine.Categories.pairing_category/2`. A string or
`null`, always present regardless of the display setting above, exactly as
before this document described `tournament.categories`/`players[].categories`.
This is also what `standings.rows[].category` (below) already carries per row;
`players[].category` is the same value read off the player instead of the row.

**`rounds[]`** - contains only PUBLISHED rounds. An unpublished round is
absent entirely, not present-and-flagged. Same for a hidden board: absent
from `boards`.

**`rounds[].results_public`** - whether the round's RESULTS are public, as
opposed to its pairings. Added 2026-09-13. **Absent means true**, because an
OpenPairings that predates the field sent every result it had.

`false` means the arbiter has published the round's pairings and switched its
results off ("Results round N" on their Pairings page, off for every new
round). The round still travels, with every board, but each `boards[].result`
is `null` because the result is withheld - not because the game is
unfinished. Withheld at build time, like a hidden board: the results are not
in the document. Nothing derived from them is either - `standings.after_round`
is always below a withheld round, because public standings after a round
force its results public on the arbiter's side. A `vacated-seat` row in
`byes` carries a result and is left out of a withheld round; every other bye
is part of the pairing sheet and still travels with its points. A reader must
not add those points to a running score, since everyone else's result in the
same round is unknown.

The arbiter's side sends `true` whenever the results are public for any
reason - the switch, public standings through that round, or the "immediate"
publish mode - so a reader never has to work that out.

**`boards[].result`** - the token OpenPairings already stores, verbatim, with
`null` for a game not yet reported. Taken from the app's own vocabulary rather
than invented here, because a contract that renames things is a contract that
drifts:

| token | meaning |
|---|---|
| `1-0`, `0-1`, `1/2-1/2` | the ordinary three |
| `1-0U`, `0-1U`, `1/2-1/2U` | played but UNRATED - the game happened, it does not count for rating |
| `1/2-0`, `0-1/2` | the VCL.13 asymmetric results |
| `0-0` | played, both score nothing |
| `1-0FF`, `0-1FF`, `0-0FF` | forfeits - unplayed under FIDE Art. 16 |

Carried unflattened because an arbiter reading the page needs to see that a
game was not played, and a spectator needs to understand why a 1-0 did not
move a rating. The renderer may present them however it likes; the token is
what travels.

Two legacy spellings, `+--` and `--+`, exist in historical and SWAR-imported
data for the single-sided forfeits. **The publish path normalises them to
`1-0FF` and `0-1FF`** rather than pushing both spellings across, so this
server only ever sees one vocabulary.

**`boards[].postponed`** - `true` on a board that is a postponed game still
to be played: the arbiter paired it and the two players will play it later.
**Absent means not postponed** - the key is only ever sent as `true`, never
as `false`. Its `result` is `null` while it is postponed, and OpenPairings
counts the game in the standings until it is played - as a draw by default,
but the tournament's rules can value it otherwise (see `boards[].postponed_as`
and `boards[].points` below, which say exactly how it is counted; see
`standings.provisional` below). Withheld (absent) when the round's results
are not public, like the result itself. Once the game is played the next
snapshot carries its real result and no flag, so a reader never has to clear
anything. A board carrying both a result token and the flag is read by its
result. OpenResults shows "Postponed" where the result goes instead of the
"not yet reported" hyphen, and does not count the board as one the round is
waiting on - a round whose only missing results are postponed games is not
shown as live.

**`boards[].pending`** (added 2026-10-15) - `true` on a board in an
individual round robin that nobody has entered a result for, in a round the
tournament has since moved past: a LATER round is complete. OpenPairings
counts it in the standings exactly as an unnamed postponed game - its
`points` and `postponed_as` say how - so the standings can go through the
latest round instead of stopping before it for the rest of the season
(OpenPairings' `docs/postponed-rethink.md`). **Absent means not pending**;
only ever `true`, only beside `result: null`, and never together with
`postponed` - nobody postponed it, and it may be a game that was played and
not typed in. Withheld with the results, like `postponed`. OpenResults reads
it like a postponed board everywhere it adds points up or decides whether a
round is live, and words it "Result not yet in" rather than "Postponed".

**`boards[].postponed_date`** - `"YYYY-MM-DD"`, the date the two players
agreed to play a postponed game. Present only when `postponed` is `true` AND
the arbiter entered an agreed date; **absent means no agreed date**, not "no
date needed". It is not a deadline. OpenResults shows it as "Postponed, to
be played <date>" in the reader's locale, and only when the arbiter's
`display.dates` tick is on - the same tick that hides a round's own date,
since both say when games are played.

**`byes[].kind`** - `"pairing-allocated"`, `"half-point"`, `"zero-point"`,
`"full-point"`, `"absent"`, `"vacated-seat"`, `"not-joined"` (a round before
a late entrant joined), `"not-paired"` (no board and no bye in the round:
withdrawn, or taken off a board by hand; always 0 points). The kind and its point value are
both carried because the value is configurable and the kind is what an arbiter
recognises. A kind this server does not recognise is rendered verbatim rather
than dropped or relabelled, which is what makes the list safe to extend.

**`vacated-seat` is not a bye**, and that is why it has its own word rather
than borrowing one. The arbiter emptied one seat of a board and recorded a
result against it anyway - usually a forfeit, and the shape a SWAR or TRF
import can carry ready-made. Such rows travelled as `"pairing-allocated"` with
the tournament's bye value until 2026-09-08, so a player who forfeited a round
appeared here with a full point for it, and every later figure on their player
card moved with it while the `standings` block in the same document said
something else.

**`byes[].result`** - present only on a `vacated-seat` row, carrying the same
token vocabulary as `boards[].result`. The points alone do not explain
themselves on that row: a `0` against a name reads as a zero-point bye until
something says the game was forfeited.

**`tournament.registration_open`** - whether the arbiter is accepting entries
through this site's form. Added 2026-08-29. **Absent means open.**

That default is load-bearing rather than merely tolerant. The arbiter's app
enforced this flag itself until it stopped serving its own entry form; every
snapshot published before then is silent, and this server accepted entries
for all of them. Reading silence as "closed" would have shut every
already-published form the moment the field shipped, with nothing in either
app to explain why. The failure directions are not symmetric either: an entry
that should not have been taken lands in a queue an arbiter reads and
rejects, while a form that is shut when it should be open turns a real person
away and tells nobody.

**`tournament.scoring`** - the tournament's point system as OpenPairings
applies it. Added 2026-10-02. **Absent means an older publisher**, and a
reader then falls back to 1 / 1/2 / 0 read from the result token.

```json
"scoring": { "win": 3.0, "draw": 1.0, "loss": 0.0, "bye": 3.0,
             "forfeit_win": 3.0, "forfeit_loss": 0.0, "presence": null }
```

| key | meaning |
|---|---|
| `win`, `draw`, `loss` | what one result pays |
| `bye` | what a pairing-allocated bye pays, presence add-on included |
| `forfeit_win`, `forfeit_loss` | what a forfeit pays the winner and the loser |
| `presence` | the SWAR 3-2-1 presence point added to every game a player turned up for, or `null` when the tournament has none |

It is for explaining a figure ("3 for a win"). **Nothing is added up from it**:
the per-game figures that matter travel as `boards[].points` and
`byes[].points`, already including presence points and postponed valuations.

**`boards[].points`** - what each seat scored on the board, as OpenPairings
scores it: `{ "white": 0.5, "black": 0.5 }`, in the tournament's own point
system. Added 2026-10-02. Present on a board with a result and on a postponed
board (where it is what the game is credited with while it waits); **absent**
on a board with no result and no postponement, and withheld with the result
when the round's results are not public. **Absent also means an older
publisher**, and a reader then reads the points off the result token as 1 /
1/2 / 0. A reader adds these up for a running score; it does not interpret the
result token for points when this is present. The figures are the ones the
standings are computed from, so a running score built from them agrees with
`standings.rows[].points`.

**`boards[].postponed_as`** - on a postponed or pending board only: how each seat's game
counts until it is played, `{ "white": "draw", "black": "draw" }`, each
`"win"`, `"draw"` or `"loss"`. A draw unless the tournament counts it
otherwise for the player who asked to postpone. The points it is worth are
already in `boards[].points`.

**`tournament.group`** (OpenPairings' tournament groups, added 2026-10-10,
additive) - the event this tournament is one section of, when the arbiter
grouped it with others AND at least one of those is published too:

```json
"group": {
  "id": "5c1f0e9a7b3d2c4e6f",
  "name": "Gent Spring Festival 2026",
  "label": "U20",
  "position": 2,
  "siblings": [
    {"slug": "gent-spring-open-2026", "label": "Open", "name": "Gent Spring Open 2026"}
  ]
}
```

`id` is a random id the arbiter's app minted for the group (6-64 characters
of `A-Z a-z 0-9 _ -`); it is the event's address here, `/e/<id>`, and says
nothing about that app's own rows. `name` is the event's name. `label` is
this tournament's short name in the event ("Open", "U20"); `position` its
place, from 1, among itself and `siblings`. `siblings` are the OTHER
sections, in the event's order, each by its public `slug`, `label` and
`name`. Contract fixture: `test/fixtures/snapshot_swiss_grouped.json`.

Absent means the tournament is in no event, which is every snapshot before
this date - and every grouped tournament whose siblings are not published:
the arbiter's app names only siblings that are on this server, and sends no
block at all when there are none. A block that is not this shape is read as
absent, whole.

**What this server does with it, and what it does not believe.** The block
becomes a tab strip at the top of the tournament's pages (each tab opens the
same page of the sibling when it has one - standings to standings, round 3
to round 3 - and its overview when not), an event page at `/e/<id>` listing
the sections as cards, and one entry under the event's name on the front
page. But a snapshot is a claim by whoever published it, so a sibling is
shown only when this server's own facts agree: it is public here (published,
not hidden), **its own** newest snapshot carries the same `id`, and it has
the same publisher (the same installation, or both published with the
operator token). A sibling that fails any of those is not shown anywhere -
not greyed out, not counted. A section that is not `listed` is never linked
from one that is. The event page belongs to the publisher that claimed the
`id` first; it answers 404 unless at least two sections can be shown. See
`OpenResults.TournamentGroups` and `OpenResultsWeb.EventGroup`.

The hall display, the projector and the live-board pages are full-screen
views and carry no strip.

**`tournament.hall`** - the arbiter's settings for the hall display
(`/t/<slug>/hall`, see `docs/public-extras.md`). Added 2026-09-30. **Absent
means the defaults**, and so does any key that is absent, out of range or of
the wrong shape - a tournament published before the display existed gets a
display, not an empty screen.

```json
"hall": {
  "pairings": true, "names": true, "results": true, "standings": true,
  "standings_top": 10, "page_seconds": 15, "hold_new_round": true,
  "announcement": "Round 6 starts at 14:00."
}
```

| key | meaning | default |
|---|---|---|
| `pairings`, `names`, `results`, `standings` | whether the cycle includes that view | `true` |
| `standings_top` | how many standings rows, 3-50 | `10` |
| `page_seconds` | how long each page stays up, 5-120 | `15` |
| `hold_new_round` | while the newest round has no result in, cycle only the pairings, the names and the announcement | `true` |
| `announcement` | the arbiter's text, shown as a page of its own; absent when blank | none |

Sent resolved like `display` - every key, except `announcement`, which is
left out when there is none. These choose among things the public may
already see and never widen it: `display` and the round levels still decide
what exists, and the display reads them exactly as the pages do. The
announcement is prose the arbiter chose to publish, like `arbiter`.

**`tournament.registration`** - the form's window, the size of the field and
whether the entry list is shown on the form. Added 2026-09-30; see "The entry
form's own settings" under "Registration, the other direction".

**`standings.tiebreaks`** - declared once, ordered, with a human label.
`rows[].tiebreaks` is positional against it. This is what lets the renderer
stay dumb: it does not know what BH means, how many there are, or what order
the arbiter chose.

**`standings.tiebreaks`** carries only the tie-breaks the arbiter publishes.
An arbiter can hide them one at a time, and a hidden one is absent from this
list, from every `rows[].tiebreaks` (which stays positional against it, so
there is no gap and no `null`) and from `rows[].working`. Withheld at build
time, like a round or a board.

**`standings.tiebreaks_withheld`** - whether the ORDER above used a tie-break
that is not in that list. Added 2026-08-30. Absent means no.

Hiding a column hides the arithmetic, not its effect: two players can sit one
above the other with every published number identical and nothing to say why,
which reads as a broken table rather than a withheld one. So the document
says it happened and the page prints a line. It is compared against the
tie-breaks that actually ranked, not the configured ones - a tie-break C.07
Article 10 already dropped never affected the order, so hiding it withholds
nothing and must not raise the flag.

**`standings.rows[].working`** - how each tie-break number was reached, keyed
by code. Added 2026-08-30. Absent, or `{}`, means no working was published.

Each entry is a `total` and a list of `parts`, one per round, and the parts
sum to the total. A part carries:

| field | meaning |
| --- | --- |
| `round` | the round it came from - the join key against `rounds[]` and a player's card |
| `opponent` | the opponent's `no`, **absent** when there is nobody to name |
| `value` | what it contributed |
| `kind` | `played` (**absent** means this), `virtual`, `cut` or `excluded` |

`virtual` is FIDE Article 16's notional opponent for a round the player did
not play. `cut` is a real contribution that a cut modifier discarded, and
`excluded` is one the tie-break's own rule did not count - a Koya opponent
below the threshold. **Both are sent and both must be left out of the sum**;
they are here so a reader can see what did not count and why, which is the
half a bare number never showed.

`opponent` and `kind` are omitted at their commonest values rather than sent
as `null` and `"played"`. There are as many parts as players x codes x
rounds, so those two keys cost more than the rest of the document put
together on a large event. Absent-means-the-default is how `listed` and
`manual_order` already read.

**Only the tie-breaks that cannot be re-derived here are sent.** The Buchholz
family, Sonneborn-Berger, Koya and average rating - everything built on an
opponent's Article 16 **adjusted** score, which is not in this document and
cannot be, because it depends on that opponent's own unplayed rounds. Wins,
games with Black and the running score are visible in the results already, so
they are not sent. Direct Encounter is never sent: it is a mini-match among
players tied on everything else, not a per-round sum.

That restriction is the reason this travels at all rather than being computed
here. Adding up the opponents' finishing scores on this side would look
right and be wrong: it would print a total that disagrees with the number
beside it, in front of the players. See the app's first rule, above - the
arbiter is the authority.

Sending it costs roughly 3.4x the payload on a 300-player, 11-round event
(173 KB to 583 KB, measured), and every changed version is kept, so the
growth compounds across a tournament's publishes. Well inside the body limit,
but worth knowing before adding more.

**Withheld with the tie-break columns.** An arbiter who turns off
`display.tiebreaks` is hiding the arithmetic, and this is more of it than the
columns ever showed, so it is not sent at all rather than sent and hidden -
the same rule as a withheld round or board.

**`rows[].uncounted`** - `true` on the row of a round-robin player whose
results are not counted: FIDE C.05 6.6, a player who withdrew or was
expelled with fewer than half of their games played. The results "remain in
the tournament table" and count for nobody. Added 2026-10-11, additive;
absent on every other row, so an older payload and a tournament with no
such player read exactly as before.

What travels with it, and what this server makes of it:

- The row is still there, **last**, and still has a `rank` and its own
  `points` - a server that has never heard of the key prints it as it
  always did. This one prints no place for it (a dash), mutes the row, says
  "results not counted (withdrawn)" beside the name and explains the rule
  under the table: standings, cross-table and the player's own page. The
  hall display's standings list ranked rows only. "of N" beside a place
  counts the ranked rows.
- The other rows' `points`, `tiebreaks` and `working` are already without
  the games against that player - OpenPairings computed them that way.
- `rounds[].boards` still carry those games, with the points they paid:
  they were played and the cross-table shows them. So this server leaves
  them out when it adds a running score up (`Tournament.card/2`,
  `scores_before/2`) and marks the game "not counted" on the opponent's
  card - otherwise a card would end on a total the standings do not have.
  The withdrawn player's own card adds up as played.

Contract fixture: `test/fixtures/snapshot_roundrobin_uncounted.json`.

**`rows[].rounds_played`** - how many rounds that player was there for, byes
included. Optional, and sent only by a tournament whose arbiter turned the
column on (OpenPairings' "Rds" setting, added 2026-09-19); absent means the
column is not shown at all, which is what every tournament before it sends.

It exists for club championships that give a prize for attending every round.
The arbiter's app decides what counts - a game played (any result), a bye
given because the field was odd, a win by forfeit - and this site prints the
number it is handed, like every other computed column here, and lets a reader
sort on it.

`display.rounds_played` decides whether it travels, and unlike every other
display key it starts OFF - the arbiter opts in, so most tournaments send
nothing. Whether the arbiter shows the column on their OWN screen is a preference of
their browser and has no bearing on this, in either direction. Withheld means
absent, so a tournament that turns it off looks, from here, exactly like one
that never had it.

**`rows[].performance`** (OpenPairings' "Performance" tick, added 2026-10-17,
additive) - an integer: the player's performance rating after that round,
the average rating of the opponents met in finished games plus
400 x (wins - losses) / games, rounded; the same number as the "Perf" column on
the arbiter's Players page. Optional, and sent only on Swiss and round-robin
standings by a tournament whose arbiter turned "Performance" on, which starts
OFF. A player with no finished game has no key (never null or 0). Absent from
every row means no Performance column; the site prints the number it is handed.
`display.performance` says whether the tick is on, but the rows carry the
answer. Contract fixtures carry only the `display` flag, `false`.

**`tournament.display.flags`** (OpenPairings' "Federation flags" tick,
added 2026-10-10, additive) - `true` asks for a small flag beside each
player's federation code. **Absent means off**, the one display key read
that way here: every other key hides something the arbiter already
publishes, this one adds a picture, and a snapshot from an app that has
never heard of flags has not asked for any. Anything but `true` is off.
Also off wherever `display.federation` is `false` - no code, no flag
(OpenPairings sends `false` there itself since 2026-10-11, and does not
offer the tick while "Federations" is off). Where it is drawn: beside the
federation code where a page prints one (starting list, player card, entry
list, hall display, live boards), and before the player's name where it
does not (standings, pairings, cross-table, team pages). The
flag is chosen from the player's `federation` (FIDE's three-letter code) by
a table this site keeps (`OpenResultsWeb.Flags`); a code that is not in it -
`FID`, a federation that no longer exists, a typo - is printed without one.
`RUS` and `BLR` get their national flags, since the snapshot is what says
which of the two a player is under.
OpenPairings sends `true` unless the arbiter unticks it.

**`players[].sex`** (OpenPairings' "Sex" tick, added 2026-10-17, additive) -
`"M"` or `"F"`, the player's sex as the arbiter recorded it. Optional, and
sent only by a tournament whose arbiter turned "Sex" on, which starts OFF:
it is personal data, and nothing was published before it existed. Absent
means no Sex column on the standings or the starting list, and a player with
no sex recorded simply has no key. Withheld means absent, not blank, so a
tournament that never sent it and one that turned it off look the same from
here. There is no `display.sex` to read: the players carry the answer.

**`standings.manual_order`** - whether the arbiter set `rows[].rank` by hand
instead of computing it from the tiebreaks. Added 2026-08-29. Absent means
no.

It changes nothing about how the rows are read: they are rendered in the sent
order regardless, because that order is the arbiter's answer either way. It
exists so the page can say which kind of answer it is. Until this field
existed the disclosure lived only on the arbiter app's own public standings
page, which was removed - so the ordering would have travelled while the fact
that a person chose it did not.

**`standings.after_round`** - which round the placings reflect. Not
necessarily the highest published round: an arbiter may publish pairings for
round 6 while standings still stand after 5.

**`standings.provisional`** and **`standings.postponed_games`** -
`provisional: true` and a count, present only while a postponed game
(`boards[].postponed`) in the rounds the standings cover is still to be
played. **Absent means the standings are not provisional.** The placings
count each such game as its `postponed_as` valuation (a draw unless the
tournament says otherwise) until it is played, so the table is correct
for now and will move when the game is in. OpenResults prints one line above
the standings saying so, with the count when it is a positive integer, and
never recomputes anything.

```json
"standings": { "after_round": 5, "provisional": true, "postponed_games": 2, "rows": [] }
```

**`standings.pending_games`** (added 2026-10-15) - every game the standings
count before it has a result, in the rounds they cover: the postponed boards
AND the pending boards (`boards[].pending`). Present, with `provisional:
true`, whenever it is above zero; absent otherwise. Since then
`postponed_games` counts postponed boards only and is absent at zero, so
`provisional: true` can arrive with `pending_games` and no `postponed_games`.
OpenResults prints `pending_games` when it is there and falls back to
`postponed_games`, and calls the games "postponed" only when every one of
them is (`pending_games` equal to `postponed_games`).

```json
"standings": { "after_round": 4, "provisional": true, "postponed_games": 1, "pending_games": 2, "rows": [] }
```

**`system`** - `"swiss"`, `"roundrobin"` or `"keizer"`. Keizer standings
carry different columns (value, Keizer points, score), so the renderer keys
off this. The alternative - a generic column list - was considered and
rejected as harder to read for the two extra cases it buys.

## Team tournaments

Added this version. **Absent means an individual tournament** - every field
below is additive, and a payload with none of them is read exactly as it was
before they existed.

```json
{
  "tournament": { "team_event": true },

  "teams": [
    {
      "no": 1,
      "name": "Antwerp Knights",
      "short_name": null,
      "captain": "Jan Peeters",
      "players": [1, 2, 3]
    }
  ],

  "rounds": [
    {
      "number": 1,
      "matches": [
        {
          "number": 1,
          "team_a": 1,
          "team_b": 4,
          "bye": false,
          "board1_white_team": 1,
          "boards": [1, 2],
          "game_points": { "a": 2.5, "b": 1.5 },
          "match_points": { "a": 2.0, "b": 0.0 },
          "forfeit_decision": null
        }
      ]
    }
  ],

  "team_standings": {
    "after_round": 3,
    "tiebreaks": [{ "code": "BB", "label": "Board points weighted (Berlin)" }],
    "rows": [
      { "rank": 1, "team": 1, "mp": 6.0, "gp": 12.5, "tiebreaks": [21.0], "working": {} }
    ]
  },

  "board_stats": [
    {
      "player": 1,
      "team": 1,
      "board": 1,
      "games": 3,
      "points": 2.5,
      "percentage": 83.3,
      "performance": 2340
    }
  ]
}
```

**`tournament.team_event`** - `true` for a team round robin or a team Swiss.
Absent means an individual tournament, exactly as before this field existed.

**`teams[]`** - every team OpenPairings has frozen a pairing number for
(`teams[].no`, the team's own TPN, the same idea as `players[].no` one level
up - the only handle anything else in the document uses to refer to a team).
Before a team round robin's first round is paired, no team has one yet; the
snapshot still carries a provisional `no` in seeding order so a page has
something to link to, the same accommodation `players[].no` gets before round
1 (see `PairingsEngine.Snapshot`'s moduledoc).

**`teams[].captain`** - a name the arbiter typed on the Teams page, not a
player record - so the personal-data allowlist that keeps `players[]` to name,
rating, federation, club, title and category does not apply to it. It travels
like `tournament.arbiter` and `tournament.deputy` do: prose an arbiter chose
to make public.

**`teams[].players`** - the roster in board order, as `players[].no` values.
Only players who have ever sat at a board are numbered and therefore listed -
a reserve who never played (a roster longer than the match size) has no
pairing number yet and is not on this list, exactly as an unpaired individual
player is absent from `players[]` before round 1.

**`teams[].rating`** (OpenPairings since 2026-10-03, additive) - the team's
rating as OpenPairings' Teams page shows it: by default the average of its
highest-rated players, one per board (the Olympiad's rule), or another
method the arbiter chose, or a rating typed for the team. A whole number, or
`null` when there is none (a team with no players and nothing typed in).
Worked out by OpenPairings, never by a reader; the team list shows it in a
*Rating* column when any team has one. Absent in an older payload.

**A team event without players** (OpenPairings' optional line-ups, since
2026-10-03): a team may have an empty `players` list, and a match may list
boards (`matches[].boards`, `board_positions`) of which few or none appear
in `rounds[].boards` - those carry no players, so there is no game to show,
but their results are in the match's `game_points` and `match_points` and in
`team_standings`. Nothing else in the document changes; a reader that shows
a missing board as an empty slot already shows this correctly.

**`rounds[].matches`** - one entry per match scheduled that round, present
only when `tournament.team_event` is `true`. A team round robin's bye (an
odd-sized field) is `{ "team_a": <no>, "team_b": null, "bye": true }` with no
points and no boards - it scores nothing, the same as a bye scores nothing in
`PairingsEngine.TeamStandings`.

**A team Swiss carries matches exactly like a round robin.** Since
OpenPairings 0.62.0 a team Swiss is paired team against team (C.04.6), so
every round has its `matches`. An odd field gives a pairing-allocated bye,
`{ "team_a": <no>, "team_b": null, "bye": true }`, which in a Swiss is scored as
a drawn match: it carries `game_points.a` and `match_points.a` (a round
robin's bye carries none). Nothing in the document tells the two apart but
`tournament.system`.

**`matches[].board1_white_team`** - which team has White on board 1 of the
match (and, by the FIDE convention this app follows, on every odd board -
see `PairingsEngine.TeamRoundRobin`'s moduledoc). Named explicitly rather than
left for a reader to infer from `team_a`, so a page can print "Team A (White)"
without knowing that convention itself.

**`matches[].boards`** - the real board numbers (`boards[].board`, not the
printed `label`) that belong to this match, in the round's own numbering. A
board the arbiter hid is left out of this list for the same reason a hidden
board is absent from `boards[]`, though it still counts in `game_points` -
hidden is a display flag on `boards[]`, not on the arithmetic.

**`matches[].board_positions`** (OpenPairings since 2026-10-03, additive) -
each listed board as `{ "board": n, "k": k }`, `k` its place inside the match
(1 to `tournament.team_boards`), worked out by OpenPairings from the board's
own number - so a hidden board, left out of the list, does not shift the ones
after it. `Tournament.match_slots/2` uses it; a payload from an older
publisher, without it, falls back to the position in the sorted `boards`
list, which is exact unless the arbiter hid a board. A board that is in
`matches[].boards` but not in `rounds[].boards` is one seat that nobody
filled: the opponent has the point, counted in `game_points`, and there is
no game to show.

**`tournament.team_boards`** (since 2026-10-03, team events only) - how
many boards one match is played on. `Tournament.team_boards/1` reads it;
`nil` for an older payload.

**`matches[].double_forfeit`** (since 2026-10-03) - `true` for a match
neither team turned up for: every board is a forfeit loss for both players,
and both teams lose the match (the loss's match points to each). Sent only
with the match points, absent for every other match. The match line says
"Neither team turned up: both lost by forfeit" (`forfeit_decision/1`).

**`matches[].game_points`/`match_points`** - **withheld exactly like a
board's own result**: `null` on both while the round's results are not public
(`rounds[].results_public`), even though the two teams are always named - a
match is on the pairing sheet before it is a result, the same reason
`boards[].white`/`black` still travel with a `null` result. `match_points` is
additionally `null` until every board in the match has a result - a
half-reported match has game points and no match points yet, exactly as
`PairingsEngine.TeamStandings` computes it - except for a postponed board
(`boards[].postponed`), which counts as a draw, so a match whose only
missing results are postponed games does carry `match_points` (see
`matches[].postponed_boards` below). Never recomputed here: both numbers are
OpenPairings' own arithmetic.

**`matches[].postponed_boards`** - how many of the match's boards are
postponed games still to be played. Present only when it is above zero and
the round's results are public; **absent means none**. While it is present,
`game_points` and `match_points` are PROVISIONAL: each postponed board is
counted as a draw. `match_points` is still sent, because the team standings
count that provisional score and the next round is paired with it.
OpenResults shows the score as it arrived with "1 board pending" (or "N
boards pending") beside it, so it does not read as final.

```json
{ "number": 1, "team_a": 1, "team_b": 4, "bye": false, "board1_white_team": 1,
  "boards": [1, 2], "board_positions": [{ "board": 1, "k": 1 }, { "board": 2, "k": 2 }],
  "game_points": { "a": 1.5, "b": 0.5 },
  "match_points": { "a": 2.0, "b": 0.0 }, "forfeit_decision": null,
  "postponed_boards": 1 }
```

**`matches[].forfeit_decision`** - added with match forfeits by decision.
`{ "to": <team no> }` when the arbiter forfeited the match as a whole to one
team (OpenPairings' *Forfeit by decision*: every board becomes that team's
forfeit win), `null` for a match decided on its boards. **Absent means
none** - a payload from a publisher older than the field is read exactly as a
`null`. Withheld exactly when `match_points` is: `null` while the round's
results are not public, and `null` while the match is incomplete, because it
says who won the match. The match's `game_points`/`match_points` already
reflect the decision (the boards carry the forfeit results), and a decision
taken after games were played leaves those boards in `boards[]` with their
forfeit results. Never inferred here: a match whose boards all show
forfeits is not a decision unless this field says so.

```json
{ "number": 2, "team_a": 2, "team_b": 3, "bye": false, "board1_white_team": 2,
  "boards": [3, 4], "game_points": { "a": 2.0, "b": 0.0 },
  "match_points": { "a": 2.0, "b": 0.0 }, "forfeit_decision": { "to": 2 } }
```

**`team_standings`** - the same shape as `standings`, one level up, for
teams: `after_round`, `tiebreaks` (declared once, `rows[].tiebreaks`
positional against it, exactly like the individual table) and `rows[].working`
in the same per-round-parts shape as `standings.rows[].working` - only
`team` replaces `player` as the row's identity, and there is no `category`,
`points` (game score already has a name here, `gp`) or Keizer-shaped fields, a
team event never being Keizer. Gated by the same `standings_through` setting
as the individual table (`PairingsEngine.Tournaments.effective_standings_through/1`),
so nothing here can show a round the individual standings would still
withhold.

**`board_stats[]`** - one row per player who ever sat at a board, for a board
prizes page. `board` is the board they played most often (the lower one on a
tie - `PairingsEngine.TeamStandings.board_stats/2`'s own rule), which is what
a board prize is normally awarded against rather than every board a reserve
ever filled in for. Gated the same way `team_standings` is: empty until
standings have been published through at least one round.

## `publisher` - who published, hosted server only

Added 2026-09-14. **Absent means unknown** - an older OpenPairings, a
local/desktop publish (which has no accounts to name and already identifies
itself with its installation key), or a hosted publish whose tournament owner
could not be resolved.

```json
{ "publisher": { "email": "jan.peeters@example.invalid", "host": "pairings.example.org" } }
```

- **`publisher.email`** - the hosted account that owns the tournament being
  published. OpenPairings' account schema carries only an email today, no
  separate display name, so that is the whole identity sent; a `name` key may
  be added later, additively, without this key changing shape.
- **`publisher.host`** - the hosted instance's own public host
  (`PHX_HOST`/the endpoint's configured host), so a server aggregating
  publishes from more than one hosted OpenPairings can say which one.
- **Moderation contact only.** This field exists so the admin panel can show
  who published a tournament instead of the generic "operator" every
  operator-token publish otherwise shows. It is personal data (an email) and
  **must never reach a public page, public JSON, or a feed** - see
  `docs/privacy-retention.md` for what is stored, why, and for how long.
- Stored on the tournament row (`owner_email`, `owner_host`), updated on every
  publish that carries it, and left alone (not cleared) by a publish that
  omits it - so a tournament keeps showing its last known publisher even if a
  later snapshot (an older client, or a re-publish in local mode after a
  handoff) does not repeat it. Deleting or purging a tournament removes it
  along with everything else.
- An installation-key publish never carries this field: public-mode
  publishing already identifies its installation in the admin panel, and an
  installation is not a hosted account.

## What is deliberately NOT in here

**Anything a spectator has no business seeing.** No email addresses, no
phone numbers, no birth dates, no national ID numbers. The publish path
strips these; they exist in the arbiter's database and stay there. A
birth *year* would be defensible for age categories and is not included until
something needs it - which is the additive-only rule working as intended.

**Pairing rationale.** The engine's explanation of *why* a round was paired
that way is an arbiter's diagnostic, and it references internal player ids
that mean nothing here.

**Anything that would let the server rank.** No float history, no colour
history, no tie-break inputs beyond what `working` shows. Per-game points DO
travel (`boards[].points`, since 2026-10-02) - not so the server can calculate
a placing, which it still never does, but so a running score is exactly what
the arbiter's screen shows under any point system.

## The tournament key, and taking a tournament down

Not part of the document. It travels in a **header**, and the reason is worth
stating because the alternative looks tidier: the snapshot is stored whole and
verbatim, and `GET /api/tournaments/:slug` serves that stored document to the
public. A credential inside the payload would therefore be written to disk in
plaintext and then published on a web page. The document describes a
tournament; a secret is a fact about the transport, and it belongs beside the
bearer token.

```
POST /api/snapshots
Authorization: Bearer <the server's ingest token, or an installation key>
X-OpenResults-Key: <a random key this machine generated for this tournament>
```

`Authorization` carries one of two credentials. The **operator token** is the
server-wide ingest token below, unchanged. An **installation key** (`orik_`
and 43 characters) is what an OpenPairings copy obtains for itself when public
publishing is enabled; it reaches only tournaments minted for it. See
"Installation keys" at the end of this section, and `docs/public-publishing.md`
for that contract.

Two questions, deliberately separated:

| header | answers |
|---|---|
| `Authorization` | may this machine talk to this server at all |
| `X-OpenResults-Key` | may it touch THIS tournament |

The names invite one specific mistake, so it is worth saying once: **both
headers carry an OpenResults secret and they are not the same secret.**
`Authorization` holds the server-wide ingest token that an operator put in
`openresults.service`; `X-OpenResults-Key` holds a per-tournament key the
arbiter's machine generated and only that machine has. When a publish is
being debugged, establish which of the two is wrong before anything else.

**The client generates the key**, once per tournament, at random, and keeps
it. This server stores only a SHA-256 digest of it and can never show it back.

**Trust on first use.** The first publish of a slug that carries a key claims
it; every later publish of that slug, and any delete, must present the same
key. It is TOFU, and that is acceptable here because with the operator token
nothing reaches this check but a machine an operator configured - so the
exposure it closes is *accident*, two machines picking the same obvious slug,
rather than attack. With an installation key the claimant is the public, and
what keeps TOFU safe there is that the server chose the slug and bound it to
that installation before the first publish - see "Installation keys".

**A publish with no key is accepted for a slug nobody has claimed.** This is
the additive-only rule applied to authentication. Snapshots already exist from
before any of this, so slugs exist with a season of history and no key, and
laptops in the field will not send one until their arbiters update. Refusing
them would take live tournaments off the air mid-event.

So there is no backfill and no admin step: **a legacy slug is adopted by the
first publish that carries a key.** Once claimed, a keyless publish to that
slug is refused - otherwise an old client could take over a claimed tournament
by simply omitting the header, and the whole thing would be decorative.

| slug | request | result |
|---|---|---|
| unclaimed | no key | published, stays unclaimed |
| unclaimed | a key | published, **claims the slug** |
| claimed | the same key | published |
| claimed | a different key | `403 key_mismatch`, nothing changes |
| claimed | no key | `403 key_required`, nothing changes |

**403, not 401.** A 401 comes from the pipeline and means "you may not talk to
this server". A 403 means "you may, but not to this tournament". An arbiter
whose round will not publish needs to know which secret to go and check.

Every error body is `{"error": "<code>", "detail": "<sentence>"}`; clients
dispatch on `error` only (`docs/public-publishing.md`, "Error bodies").

### Taking a tournament down

```
DELETE /api/tournaments/:slug
Authorization: Bearer <ingest token>
X-OpenResults-Key: <the tournament's key>
```

Removes **everything** this server holds for the slug: every snapshot
including the whole history, the registration queue with its email addresses,
and the key claim itself.

Every snapshot, not the current one, and that distinction is the whole route.
The table is append-only and `/history` serves earlier rows by `?at=`, so
deleting only the current snapshot would empty every public page - and leave
the entire event, names and ratings and federations and any round since
retracted, one query away for anyone holding the ingest token. It would look
like it worked.

The key claim goes too, so the slug returns to unclaimed and can be published
again with a fresh key. Answers `200` with counts even when nothing was there,
because a delete is idempotent and a retry after a timeout is not an error:

```json
{
  "status": "deleted",
  "slug": "gent-spring-open-2026",
  "deleted": { "snapshots": 11, "registrations": 3, "key": 1 }
}
```

An **unclaimed** slug can be deleted by any holder of the ingest token. That
is deliberate: it is the same authority that could already overwrite the
tournament into an empty one, and refusing would mean a tournament published
before keys existed could never be taken down at all - which is the hole this
route exists to close, left open for exactly the tournaments that have been
public longest.

### Break-glass

A key lives on one laptop, and laptops die. A request may present the
**server-wide ingest token** in `X-OpenResults-Key`, and the key check is
overridden. Every use is logged at warning level with the slug and the action.

It never claims a slug: storing the master secret as a tournament key would
mean rotating the ingest token locked out every tournament claimed that way.

Every use is also written to the moderation action log, with `break-glass` as
the actor, where the admin panel shows it.

Break-glass belongs to the operator token only. On a request authenticated
with an installation key, the operator token in `X-OpenResults-Key` is just a
wrong key - `403 key_mismatch` - and on an unclaimed slug it is refused rather
than stored.

### Installation keys

Only when the server runs with `OPENRESULTS_PUBLIC_PUBLISHING=enabled`;
otherwise an `orik_` key is an unknown token and gets the ordinary 401. The
whole contract - registration, minting, moderation, error codes - is
`docs/public-publishing.md`. What it changes on the routes above:

| route | with an installation key |
|---|---|
| `POST /api/snapshots` | only to a slug minted for this installation (`403 not_owner`), not to one moderation hid (`403 tournament_hidden`), at most 3 MiB (`413 snapshot_too_large`), 30 a minute (`429 rate_limited`) |
| `DELETE /api/tournaments/:slug` | only its own; allowed even while suspended, revoked, paused or blocked |
| `GET /api/tournaments/:slug/history` | only its own |
| `GET /api/tournaments/:slug/registrations` | only its own - the route with email addresses |

The tournament key applies on top, exactly as in the table above: an
installation's first keyed publish to its minted slug claims it, and every
later one must present the same key.

**The server mints the slug.** `POST /api/tournaments` returns twelve random
characters bound to the installation; the snapshot's `tournament.slug` must
be that value. There is no way for an installation to publish under a name it
chose, and so no way to claim an operator's tournament, a legacy one with no
key, or another installation's.

A tournament published with an installation key starts `pending`: reachable at
its address, carrying `noindex`, and left off the front page and the player
pages until the operator approves it.

## Registration, the other direction

The only payload that travels the other way. The server accepts these from
the public form and holds them; the arbiter's machine pulls, and the arbiter
decides. The server never writes to a tournament.

```json
{
  "schema": "openresults/registration",
  "version": 1,
  "received_at": "2026-02-01T09:12:00Z",
  "tournament_slug": "gent-spring-open-2026",
  "player": {
    "name": "De Vos, Ilse",
    "rating": 1804,
    "federation": "BEL",
    "fide_id": 2503014,
    "club": "KGSRL",
    "email": "...",
    "title": "WFM",
    "birth_year": 1994,
    "national_id": "12345",
    "requested_byes": [3, 4]
  }
}
```

`email` is the one piece of personal data the server holds, because the
arbiter needs to reach the player. It is not part of any snapshot and is
never rendered.

`title` and `birth_year` travel too (added 2026-08-29), and so does
**`national_id`** (added 2026-09-30): the member number at the player's
national federation - in Belgium the KBSB/FRBE number. A **string**, not a
number, because a national id is an identifier rather than a quantity:
KBSB's "G licences" are negative numbers that are different people from the
positive number with the same digits, and other federations use letters. The
arbiter's machine looks it up in its own national list when the entry is
accepted, exactly as it looks up `fide_id` in the FIDE list.

### The entry form's own settings: `tournament.registration`

Added 2026-09-30. An object in the snapshot's `tournament`, beside
`registration_open`, carrying what the arbiter decided about the form. Every
key is optional. For the four that restrict the form **an absent key means no
restriction** - the same reading `registration_open` gives silence, for the
same reason: a snapshot published before the key existed took entries without
it. `list_public` is the exception and reads the other way, below.

```json
"registration": {
  "opens_at": "2026-02-01T08:00:00Z",
  "closes_at": "2026-02-28T22:00:00Z",
  "max_players": 60,
  "taken": 42,
  "list_public": true,
  "fee": { "amount": "12.50", "currency": "EUR", "note": "Free for juniors" },
  "pending": [{ "name": "Waiting, Wim" }]
}
```

- `opens_at`, `closes_at` - an ISO 8601 instant in UTC. The form takes
  entries from `opens_at` (inclusive) until `closes_at` (exclusive). Judged
  by the server's clock at the moment of the request, so the form opens and
  closes on time without the arbiter's machine being online to republish.
- `max_players` - the size of the field. The form stops taking entries once
  `taken` plus the entries this server received after the snapshot reaches
  it. Counting what arrived since is what keeps the cap honest while the
  arbiter's laptop is closed: those entries are not in `taken` yet.
- `taken` - players already on the entry list **plus** entries waiting on
  the arbiter's machine for a decision. A count; names are `pending`, below.
- `list_public` - whether the form page may list who has entered so far.
  The list is `players[]`, which the snapshot already publishes, rendered
  with the same `display` switches as every other page, followed by
  `pending` when that is present. **Absent means not listed**: this key
  decides whether a page shows names in a place the arbiter never chose to
  put them, and the arbiter's app sends it `false` unless they switch it on.

- `fee` - what the form says taking part costs, **a statement and nothing
  more**; no payment is taken anywhere. `amount` is a decimal string with at
  most two decimals (`"12"`, `"12.50"`), `currency` three capital letters,
  `note` free text of at most 120 characters ("Free for juniors"). Any part
  may be missing; no `fee` means none stated. The page prints `amount` and
  `currency` together and the note beside them, and drops a part that does
  not have the stated shape.
- `pending` (added 2026-10-18) - the entries still waiting for the arbiter,
  by name, in the order they arrived: `[{"name": "..."}]` and nothing else
  about the entrant. The arbiter's app sends it **only** while `list_public`
  is true and the arbiter has left "also list entries waiting for your
  decision" on (the default); at most 200 names of at most 100 characters,
  control characters removed. The form page shows them after the players,
  each marked *unconfirmed*, with every name escaped. The arbiter's Discard
  (or Accept, when the entry becomes a player) takes the name out of the
  next snapshot, and every decision enqueues a publish. This server keeps no
  list of its own, so there is nothing to keep in step; older stored
  versions of the snapshot may still hold a name until they are pruned, but
  only the latest is ever rendered. Absent means none. Nothing is e-mailed
  to anybody at any stage.

`registration_open: false` still closes the form outright, whatever this
object says. None of it is enforced anywhere but on this server's form, and
none of it changes what the pull returns: an entry that is already in the
queue is the arbiter's to decide.
