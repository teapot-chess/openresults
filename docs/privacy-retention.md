# Personal data: what is kept, and for how long

What this server holds about people, and the longest any of it can survive.
Everything time-based below is done by the daily job, `OpenResults.Retention`
(run by `OpenResults.Retention.Scheduler`, first run ten minutes after boot,
then every 24 hours) - so any window can be overrun by up to one day.

## Backups

Nothing can be scrubbed out of a backup that has already been written. But
backups rotate: each is deleted after `BACKUP_RETENTION` days (default 30). So
anything removed from the live database is gone from **every** backup at most
`BACKUP_RETENTION` days later, and the true worst case for any row below is
its own window **plus** `BACKUP_RETENTION`.

## The table

Defaults assume `BACKUP_RETENTION` is unset (30 days).

| data | where | why it is kept | removed from the live database | longest it can survive, backups included |
|---|---|---|---|---|
| Entry-form submissions: name, email, rating, FIDE id and the rest of the entry | `registrations.payload` | the arbiter pulls them to decide who plays and to reach the player | the whole queue, `OPENRESULTS_REGISTRATION_RETENTION_DAYS` (default **30**) days after the tournament's `end_date`; with no usable `end_date`, that many days after its last publish - but never while its `start_date` is in the future. A tournament that never published keeps its queue until it is deleted. Also removed immediately by any tournament delete. | window + 30 (default **60 days** after the tournament ends) |
| Report contact email | `reports.contact_email` | so the operator can ask the reporter about the report | `OPENRESULTS_REPORT_CONTACT_RETENTION_DAYS` (default **90**) days after the report is resolved. **An open report keeps it**, however old. | window + 30 (default **120 days** after resolution) |
| Reporter's client address | `reports.client_address` | to judge an address block | 30 days after the report was made (fixed) | **60 days** |
| Installation addresses: where it registered, where it was last seen | `installations.created_from`, `installations.last_seen_from` | to judge an address block | 30 days after registering / after last being seen, each by its own timestamp (fixed) | **60 days** after that timestamp |
| Blocked address range, in the action log | `moderation_actions.details["cidr"]` on `block_address` and `unblock` rows | the operator's audit trail of a block | `OPENRESULTS_BLOCK_ADDRESS_RETENTION_DAYS` (default **30**) days after the block ended - its `expires_at`, or the moment it was lifted early. The rest of the row (that a block happened, when, why, by whom) stays. | window + 30 (default **60 days** after the block ended) |
| The live block itself | `address_blocks.cidr` | enforcing the block | the day after it expires, or immediately when lifted (fixed) | **31 days** after it ended |
| Free-text report details | `reports.details` | the report itself | not removed by retention, and a tournament delete leaves reports in place too. The form asks reporters not to add personal data. | until an operator deletes the database row |
| Reader counts, per day and per tournament: unique readers, page views, refreshes, bot hits | `traffic_days`, `traffic_tournament_days` | the admin stats page's Readers section | no address, user agent, cookie or query string is kept. A reader is a hash under a salt drawn fresh each day and held only in memory; the database gets arithmetic (counts per day). Rows older than the retention are deleted by the stats module's own flush, not the daily job | **400 days** (fixed in `OpenResults.Stats.Viewers`) |
| The FIDE rating list: id, name, federation, title, birth year, three ratings | `fide_players` in the separate `fide_list.db` | the entry form's "find yourself" search | replaced whole by the next list FIDE publishes (`OpenResults.FideList`). A public dataset FIDE distributes itself; sex, game counts, K-factors and the inactivity flag are in FIDE's file and are not stored | not in the backups at all: they copy the main database only |
| Admin email addresses | `moderation_actions.actor`, `reports.resolved_by`, `address_blocks.created_by` | who did what - the audit trail | never (the audit trail is the point) | for as long as the log is kept |
| Player names and results an arbiter published | `snapshots.payload` | the published tournament | when the tournament is deleted (by its arbiter through the API, or by the admin panel) | 30 days after the delete |
| Publisher email and host, from a hosted OpenPairings' `publisher` field | `tournaments.owner_email`, `tournaments.owner_host` | admin-panel moderation contact: who to ask about a tournament published from a hosted account, added 2026-09-14 | as long as the tournament exists - removed with its `tournaments` row when the tournament is deleted or purged, exactly like the owner installation is | 30 days after the delete, same as the tournament's snapshots |

The publisher's email and host are shown only in the admin panel (the
tournaments list and a tournament's own page) - never on a public page,
public JSON, or a feed; `GET /api/tournaments/:slug` strips `publisher` from
the stored payload before serving it. See `docs/snapshot-schema.md`'s
`publisher` field.

## Outside the database

`openresults-moderation.jsonl` (`OpenResults.ModerationJournal`), kept beside
the database so a restore cannot undo moderation, records blocked ranges
(`cidr`) and deleted slugs. It is not in any backup, and it **is** trimmed:
`ModerationJournal.trim/1` runs after each boot's replay and after each
scheduled backup, and drops lines older than the oldest backup that could still
be restored - `BACKUP_RETENTION` days plus a week's margin, or longer if an
older backup is still on disk (the newest backup is always kept, whatever its
age). So a blocked range lives in the journal for at most about
`BACKUP_RETENTION` + 7 days after the block, or for as long as the oldest backup
on disk is older than that. It cannot be shorter without a restore losing the
block it exists to keep.

## Configuration

All three new variables take a whole number of days, at least 1; anything
else stops the app at boot, the same as `BACKUP_RETENTION`.

| variable | default |
|---|---|
| `OPENRESULTS_REGISTRATION_RETENTION_DAYS` | 30 |
| `OPENRESULTS_REPORT_CONTACT_RETENTION_DAYS` | 90 |
| `OPENRESULTS_BLOCK_ADDRESS_RETENTION_DAYS` | 30 |
| `BACKUP_RETENTION` | 30 |

## Where the public reads this

The public page `/terms` (`OpenResultsWeb.TermsController`) states these
periods to players and publishers, read from the same configuration at
request time - registrations, report contacts, the fixed 30 days for
addresses, blocked ranges and `BACKUP_RETENTION` - so changing a variable
changes the page. A change to what is kept, or why, is a change to that
page's wording too.
