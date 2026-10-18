# Deployment

How the public half is run in production, and the two things a person has to
do by hand that no script can do for them.

For the arbiter's app see
[OpenPairings' own `docs/deployment.md`](https://github.com/teapot-chess/openpairings/blob/main/docs/deployment.md).
The two apps share a host, a deploy script and nothing else.

## Where it runs

| | |
| --- | --- |
| public URL | `https://openresults.zerotwo.cloud` |
| internal port | **4004**, plain HTTP, loopback-reachable only |
| app tree | `/apps/web/openresults` |
| systemd unit | `openresults.service` |
| database | `/var/lib/openresults/openresults.db` |

Same host and same deployment model as OpenPairings: not containerized, not
orchestrated - upload the source, compile it on the target, run it under
`systemd` with `MIX_ENV=prod`. This document omits the host's address, SSH
details and every credential; those live outside version control.

## Deploying

The deploy script is `deploy_openpairings.py`, kept on the maintainer's
machine rather than in either repository (it embeds host-specific paths and
reads credentials from a `.env` beside itself). It knows both apps:

```bash
python deploy_openpairings.py --openresults     # this app only
python deploy_openpairings.py                   # OpenPairings only (the default)
python deploy_openpairings.py --both            # both, in that order
```

**The two are independent.** Separate trees, separate units, separate
databases, separate `SECRET_KEY_BASE`. Deploying one neither touches nor
restarts the other, which is the point: the reason for the split is that a
busy results page and a live pairing session should not be able to take each
other down, and that would be a hollow promise if every deploy restarted
both.

What a run of `--openresults` does, in order:

1. **Checks port 4004 is free** (or already held by `openresults.service`
   itself) before uploading anything. Pointing a unit at an occupied port
   does not fail loudly - systemd starts it, Bandit cannot bind, the app
   dies, systemd restarts it forever - so this is checked first, while the
   answer is still cheap.
2. **Uploads the app tree by SFTP**, skipping `.git`, `_build`, `deps`,
   `node_modules`, `.env`, `erl_crash.dump` and every `*.db` file. Dev and
   test databases are never uploaded.
3. **Builds on the target**: `deps.get --only prod`, `compile`,
   `assets.setup`, `assets.deploy` - with a short-lived, root-only env file
   supplying `DATABASE_PATH`/`SECRET_KEY_BASE`/`PHX_HOST`, deleted
   immediately afterwards even on failure.
4. **Creates the database if absent and migrates it.** `ecto.create` is
   best-effort (it exists for a first deploy); `ecto.migrate` is not.
5. **Writes `openresults.service`** with the production environment in
   `Environment=` lines, `chmod 600` because one of them is
   `SECRET_KEY_BASE` and another is the ingest token. As on the other app, a
   `SECRET_KEY_BASE` from a prior deploy is **reused** rather than
   regenerated.
6. **Restarts, then proves it came back** - see below.

**Any failing build step stops the deploy** and leaves the old release
running, untouched and still serving. A deploy that could not build is a
deploy that has not happened.

### No countdown banner here

OpenPairings warns everyone with a page open before it restarts. This app
does not, and the absence is deliberate. There are no accounts, no sessions
and no half-filled forms held in server memory on the reading path, so there
is nobody to warn and nothing for them to save. The cost of this app
restarting is that somebody refreshes.

## Verifying, and why it is not optional

On **2026-08-28** the deploy script printed "Deployment Completed
Successfully!" directly underneath a `systemctl status` block showing the
service dead, and the site stayed down for six minutes past the window users
had been promised. The script restarted the service and never asked whether
it came back.

So the deploy is not finished when `systemctl restart` returns. It is
finished when the app answers. After every restart the script polls, up to
`DEPLOY_HEALTH_TIMEOUT` seconds (default 90), on two signals:

- **systemd.** `failed` or `inactive` means it is not coming back, and
  `NRestarts` above zero means it booted, died, and is being restarted in a
  loop. Either verdict is returned immediately rather than waiting out the
  timeout for news that has already arrived.
- **HTTP.** `active` only proves a process exists. So it also asks the app
  itself, over loopback.

If neither succeeds inside the timeout, the script dumps `systemctl status`
and the last 60 journal lines and **exits non-zero**.

The HTTP check accepts **any status code that is not `000` and not a `5xx`** -
not `200`. `curl` reports `000` when it got no response at all, and that,
plus a server error, is the real negative. Demanding `200` would be worse
than useless: on OpenPairings `GET /` is a `302` to the login page, and on
either app a request carrying the public `Host` header answers `301` from
`force_ssl`. A check that called those failures would fail every healthy
deploy.

This app's `GET /` is a genuine `200` (the list of published tournaments,
empty or not) because `config/prod.exs` excludes `localhost` and `127.0.0.1`
from `force_ssl`. That exclusion is what makes a plain-HTTP health check
possible at all; keep it.

### The `deps.get` failure, and its one automatic recovery

The 2026-08-28 outage started as a dependency fetch. `mix.lock` moved a git
dependency to a new tag, that dependency's checkout under `deps/` had a stray
local edit, git refused to move a dirty working tree onto a different commit,
and `deps.get` aborted - taking `compile`, `assets.deploy` and `ecto.migrate`
down with it. Both apps carry git dependencies (`heroicons`, `daisyui`, and
`ainalrami` on the OpenPairings side), so the shape will recur.

A dirty checkout under `deps/` is never worth keeping: it is a cache of
somebody else's source. When `deps.get` fails, the script finds the dirty
checkouts, throws each away, and retries **once**.

```
mix deps.clean <dep>           removes deps/<dep> AND its build artifacts,
                               so the next deps.get re-clones clean. This is
                               the one that fixes it.

mix deps.clean --build <dep>   removes ONLY the build artifacts and leaves
                               deps/<dep> exactly as dirty as it was.
```

`--build` is the trap. It sounds like the more thorough of the two, and it
leaves the actual problem in place - the retry fails with the identical
message and it looks as though the recovery did nothing.

Only checkouts that are genuinely dirty are cleaned; a blanket
`deps.clean --all` would re-fetch and rebuild everything and turn a
thirty-second recovery into a long outage. And exactly one retry, never a
loop: if a clean re-fetch still cannot resolve the tree, the problem is the
lock file or the network, and grinding away only delays the moment the deploy
admits it is stuck.

## Production database

`DATABASE_PATH` points at `/var/lib/openresults/openresults.db`, **outside**
the uploaded app tree, so that re-running the deploy (which re-uploads the
whole app directory) can never touch it. Every deploy leaves the file alone
except for `ecto.migrate` applying new migrations.

Beside it, `fide_list.db` (or `FIDE_LIST_DATABASE_PATH`) holds this
server's copy of the FIDE rating list - see "FIDE rating list" below. It is
not backed up and need not be: deleting it costs one download.

The data here is not precious in the way the arbiter's database is - every
snapshot came from an arbiter's machine, which remains the source of truth
and can republish. The registration queue is the exception: an entry a
spectator typed in exists only here until an arbiter pulls it. Since public
publishing, so is moderation - who is suspended or revoked, what is hidden,
what was taken down - and that is the part a restore got wrong until the
moderation journal beside the database started putting it back; see
"What a restore undoes" below.

## Backups

`OpenResults.Backup.Scheduler` writes one a day: five minutes after a boot
when the newest backup on disk is at least a day old, otherwise when that one
comes due, and every 24 hours after that. `mix openresults.backup` writes one
on demand. Each is `openresults-<UTC time>.orbak` in `backups/` beside the
database (`/var/lib/openresults/backups`), and is a whole copy of the database -
every table, the public-publishing ones included (checked table by table in
the 2026-09-13 drill) - gzip-compressed, with **every client address nulled**:
where an installation registered from and was last seen from, and where a
report came from.

| Variable | Default | Purpose |
| --- | --- | --- |
| `BACKUP_DIR` | `backups/` beside the database | where they are written |
| `BACKUP_RETENTION` | 30 | how many **days** a backup is kept; the newest is always kept, however old. A whole number of at least 1, or the app refuses to boot |
| `OPENRESULTS_BACKUP_PASSPHRASE` | none | encrypts them (AES-256-GCM); the same value is needed to verify or restore one |

**Retention is days, since 2026-09-13.** It was a count of files, and every
boot and every manual run spent one: the drill's instance had four backups
inside twenty minutes. Now `BACKUP_RETENTION=30` keeps the last thirty days -
about one backup a day plus manual ones, however often the site restarts. **A
value set before that date means days now.**

**The deploy script sets none of these**, so on this host backups are
unencrypted, and they carry the entry form's email addresses and report
contact emails (see "Privacy" below). **Recommended: set
`OPENRESULTS_BACKUP_PASSPHRASE`** - from the deploy's `.env`, or in a drop-in
the deploy does not rewrite
(`/etc/systemd/system/openresults.service.d/backup.conf`, `[Service]`,
`Environment="OPENRESULTS_BACKUP_PASSPHRASE=..."`, then `systemctl
daemon-reload`), which step 1 below already reads. Keep the passphrase off
this box.

A backup on the same disk survives a bad deploy, not the disk. Nothing here
copies one off the box. And keep the copy you mean to restore from **outside**
`backups/`: a prune removes anything older than the window except the newest.

### The moderation journal, beside the database

`openresults-moderation.jsonl`, next to `openresults.db`, is not a backup and
is in none. Every action that makes the site safer is written there once it
has committed - deleting a tournament (the admin panel's, and an owner's or
the operator's `DELETE /api/tournaments/:slug`), hiding, revoking, suspending,
blocking an address, closing registration, pausing publishing - and at every
start, before the endpoint serves anything, each one the database does not know
about is applied again (`OpenResults.ModerationJournal`). Reversals - approve,
unhide, unsuspend, unblock, opening registration, unpausing - are never written,
so never replayed.

It is trimmed by itself to what a backup still on disk could bring back (the
retention window plus a week). Never delete it, and restore nothing over it.
If the site moves to another machine, copy it along with the backup.

## Restoring a backup

Rehearsed on 2026-09-13 - `docs/restore-drill-2026-09-13.md` has the run, the
timings and what broke. Every step below is there because the drill failed
without it, and what the drill found in the code is fixed. The commands take
about ten seconds; `mix` starting is most of that, so allow a minute on the
box.

Before you start: read "What a restore undoes", and if the current database
still opens, do not delete it. It is the only record of what happened after
the backup that the journal does not cover.

All as root.

**1. Give your shell the service's environment**, and a way to run `mix` as
the service account. The tasks need `DATABASE_PATH` and `SECRET_KEY_BASE`
(`config/runtime.exs` refuses to load without them) and the unit's
`MIX_HOME`/`HEX_HOME`; running them as the service account keeps anything
they write from being owned by root.

```bash
unit=/etc/systemd/system/openresults.service
for k in MIX_ENV DATABASE_PATH SECRET_KEY_BASE MIX_HOME HEX_HOME PATH PORT BACKUP_DIR OPENRESULTS_BACKUP_PASSPHRASE; do
  v=$(cat "$unit" "$unit".d/*.conf 2>/dev/null | sed -n "s|^Environment=\"$k=\(.*\)\"\$|\1|p" | tail -1)
  [ -n "$v" ] && export "$k=$v"
done
app() { (cd /apps/web/openresults && runuser --preserve-environment -u openresults -- mix "$@"); }
```

The values are read line by line and exported, never sourced, for the reason
OpenPairings' `app-role` wrapper gives: a value with a space in it would run
its own tail as a command. Drop-ins are read after the
unit, so they win, as they do for systemd - but only in the quoted
`Environment="KEY=value"` form.

**2. Choose and check the file.**

```bash
app openresults.backup --list
app openresults.backup --verify openresults-2026-09-13T00-23-22Z.orbak   # a name as listed, or any path
```

`--verify` decrypts, decompresses, and reads every page of the database
(`PRAGMA integrity_check`) on a copy in the temp directory, which it then
deletes. It refuses a damaged database; before the drill it only counted
tables, and passed a backup with a damaged `installations` table.

**3. Recover it beside the live database.**

```bash
app openresults.backup --restore openresults-2026-09-13T00-23-22Z.orbak
```

This writes `/var/lib/openresults/openresults.db.restored`, already switched
to WAL, and prints steps 4 to 7 with this box's paths. The live database is
not touched.

**4. Stop the service, and make sure it stopped.**

```bash
systemctl stop openresults
systemctl is-active openresults          # must print: inactive
```

**5. Swap - moving the WAL with the database.**

```bash
cd /var/lib/openresults
stamp=$(date -u +%Y%m%dT%H%M%SZ)
for f in openresults.db openresults.db-wal openresults.db-shm; do
  [ -e "$f" ] && mv "$f" "${f/openresults.db/openresults.db.before-restore-$stamp}"
done
mv openresults.db.restored openresults.db
chown --reference=. openresults.db
```

After a clean stop there is no `-wal` or `-shm`. After a crash, an OOM kill,
or a stop that ran into systemd's timeout, there is, and the newest writes
are in it. Moving the `.db` alone - which is what `--restore` used to print -
does two kinds of damage, both reproduced in the drill: the `before-restore`
copy lacks everything in the WAL, and the WAL left behind is read INTO the
restored file, because SQLite has no way to tell that it belongs to another
database. In the drill that gave a database that never existed - the action
log from the old one, the tournaments from the backup - with `PRAGMA
integrity_check` saying `ok`. Renamed together,
`openresults.db.before-restore-<stamp>` and its `-wal` still open as one
database. Leave `openresults-moderation.jsonl` where it is.

`chown`: a recovered file written by root is root's, and SQLite opens a file
it cannot write read-only - pages load and every publish fails. `--reference=.`
takes the owner of the directory, which the deploy gives the service account.

If the database file is gone altogether, the loop moves nothing, and that is
fine.

**6. Migrate.**

```bash
app ecto.migrate
```

The service runs `mix phx.server`, which does not migrate - only a release
does. A backup older than the code used to boot, answer `/changelog`, and fail
everything else: the drill restored a backup from before 2026-09-12 and every
tournament page, `GET /api/server` and every publish returned 500 with `no such
table: tournaments`. Since 2026-09-13 a production start refuses a database
that is behind the code instead - `systemctl start` fails, and the journal says
which migrations are pending and to run this step. Migrating also runs a
migration's backfill, which listed every tournament published before
visibility existed.

**7. Start, and check.**

```bash
systemctl start openresults
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:${PORT:-4004}/"   # 200
journalctl -u openresults -n 30 --no-pager
```

At the start the moderation journal applies again every safer action made
after the backup, before the site answers: one `Moderation journal: ... was not
in the database` line per action and a `re-applied N action(s)` summary, and
one action log row for each, by `restore-replay`, on the admin panel's action
log. Then work through "What a restore undoes" before telling anybody it is
done, and keep the `before-restore` files until you have.

## What a restore undoes

Everything written after the backup - except what the moderation journal puts
back at the start. On most apps a restore means data; on this one it also
means authority.

| After the backup, somebody... | After the restore |
| --- | --- |
| revoked or suspended an installation | **back in force** at the start: revoked again (with its tournaments hidden, if the revocation hid them), suspended again |
| closed `registration_open`, or paused publishing | **back in force**: closed, paused |
| blocked an address | **back in force** until the block's own expiry, as a block created by `restore-replay` (the reason says it was kept in force after a restore) |
| hid or deleted a tournament | **back in force**: hidden again; deleted again, with its history and its entry-form registrations |
| **withdrew their own tournament from OpenPairings** | **kept withdrawn**: the owner's `DELETE` is journalled too, so it is purged again at the start. (Before the fix it was back online with its entry form open, and that arbiter's machine had already thrown its key away.) |
| approved or unhid a tournament, unsuspended an installation, lifted a block, opened registration or unpaused | **as the backup had it** - these are never replayed. Redo them from the admin panel, deliberately |
| published a tournament for the first time | gone, and its key claim with it; the next publish that carries a key claims the address again |
| sent an entry or a report | lost |
| had a client address recorded | gone: backups hold no client addresses. The next request from that installation records a current one |

The action log is restored to the same moment as everything else; the replay
adds its own rows on top. While the old database still opens, this lists what
the journal does not put back - run it after step 7, so the replay has
happened, and it reads the old file's `-wal` with it:

```bash
cd /var/lib/openresults
runuser -u openresults -- python3 - openresults.db openresults.db.before-restore-$stamp <<'EOF'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
db.execute("ATTACH ? AS old", (f"file:{sys.argv[2]}?mode=ro",))
slugs = "SELECT slug FROM {0}.tournaments UNION SELECT tournament_slug FROM {0}.snapshots"
def show(title, sql):
    rows = db.execute(sql).fetchall()
    print(f"\n{title}: {len(rows)}")
    for r in rows: print("  ", *r)
show("BACK ONLINE - not in the old database (should be none after the replay)",
     f"SELECT s.slug, ifnull(t.status, 'listed') FROM ({slugs.format('main')}) s "
     f"LEFT JOIN main.tournaments t USING (slug) WHERE s.slug NOT IN ({slugs.format('old')})")
show("GONE - created or first published after the backup; their claims went with them",
     f"SELECT slug FROM ({slugs.format('old')}) WHERE slug NOT IN ({slugs.format('main')})")
show("status or owner differs - approvals, unhides and transfers to redo",
     "SELECT m.slug, m.status || ' -> ' || o.status, ifnull(m.installation_id, '-') || ' -> ' || ifnull(o.installation_id, '-') "
     "FROM main.tournaments m JOIN old.tournaments o USING (slug) "
     "WHERE m.status IS NOT o.status OR m.installation_id IS NOT o.installation_id")
show("installation status differs - unsuspensions to redo",
     "SELECT m.id, m.status || ' -> ' || o.status FROM main.installations m JOIN old.installations o USING (id) WHERE m.status <> o.status")
show("switches that differ (restored -> before) - openings to redo",
     "SELECT k, ifnull((SELECT value FROM main.settings WHERE key = k), 0) || ' -> ' || ifnull((SELECT value FROM old.settings WHERE key = k), 0) "
     "FROM (SELECT key AS k FROM main.settings UNION SELECT key FROM old.settings) "
     "WHERE ifnull((SELECT value FROM main.settings WHERE key = k), 0) <> ifnull((SELECT value FROM old.settings WHERE key = k), 0)")
show("address blocks that differ", "SELECT cidr, expires_at FROM old.address_blocks WHERE cidr NOT IN (SELECT cidr FROM main.address_blocks) UNION ALL SELECT cidr || ' (only here)', expires_at FROM main.address_blocks WHERE cidr NOT IN (SELECT cidr FROM old.address_blocks)")
show("moderation actions after the backup", "SELECT inserted_at, actor, action, target FROM old.moderation_actions WHERE inserted_at > (SELECT ifnull(max(inserted_at), '') FROM main.moderation_actions WHERE actor <> 'restore-replay') ORDER BY inserted_at")
EOF
```

It opens both files read-only, as the service account: SQLite may still
create a `-shm` beside a WAL database it only reads, and one created by root
is one the service cannot open.

For a tournament that is gone: if it was published with the operator token -
hosted OpenPairings, or any copy configured with a token - its arbiter's next
publish claims the address back with the key that machine still holds; the
drill's came back that way. If it was minted for an installation, the address
no longer belongs to one, and by the contract's ownership rule that
installation's publishes to it are refused as `not_owner` until it takes a
new address (not exercised in the drill). Anything the journal missed - it was
lost with the disk, or the backup is older than the journal's trimming - is
taken down with the operator token in the tournament-key position, logged as
break-glass:

```bash
curl -X DELETE "http://127.0.0.1:${PORT:-4004}/api/tournaments/<slug>" \
  -H "Authorization: Bearer $OPENRESULTS_INGEST_TOKEN" \
  -H "X-OpenResults-Key: $OPENRESULTS_INGEST_TOKEN"
```

(`OPENRESULTS_INGEST_TOKEN` is in the unit; step 1 did not export it, on
purpose.)

If the old database is gone too, the table above is the checklist: the journal
has already put the removals back, and what is left is the reversals.

### Privacy

What a backup holds, measured in the drill rather than assumed, and what
changed since:

- **Client addresses**: none, since 2026-09-13. They are nulled in the copy
  and the copy is vacuumed, so they are not left in its free space either. In
  the drill a backup held them up to about two months old, and a restore
  brought back addresses retention had already forgotten.
- **Email addresses**: every entry-form registration, and a report's optional
  contact email, which no retention job touches.
- **Addresses retention never reaches**: every `block_address` and `unblock`
  row in the action log keeps the address or range it named, for good, and
  so does the moderation journal for a block until it is trimmed.

Recommended, and a decision for the operator rather than something this guide
settles: set the backup passphrase (above); give report contact emails and the
action log's block ranges a retention of their own, or stop writing the range
into `block_address`'s log details; keep fewer days of backups where the
entry-form emails are a concern. `docs/restore-drill-2026-09-13.md` has the
measurements.

## Configuration (environment variables)

All read in `config/runtime.exs`.

| Variable | Required in prod? | Purpose |
| --- | --- | --- |
| `DATABASE_PATH` | yes | absolute path to the SQLite file; the app refuses to boot without it |
| `SECRET_KEY_BASE` | yes | cookie/session signing - generate once, keep stable |
| `PHX_HOST` | yes | public hostname; drives generated absolute URLs |
| `PHX_ALLOWED_HOSTS` | no | comma-separated further hostnames whose pages may open the hall display's websocket (`check_origin`); `PHX_HOST` is always allowed |
| `PHX_REDIRECT_HOSTS` | no (off) | comma-separated old hostnames whose GET/HEAD requests get a 301 to `PHX_HOST`; also allowed as websocket origins. POST/PUT (publishing) are not redirected |
| `PHX_SHORT_HOST` | no (off) | one short-link hostname (e.g. `pairings.cloud`): `/` and `/t/...` 301 to the same path on `PHX_HOST`, anything else is a 404 |
| `PHX_SERVER` | yes (`true`) | actually serve HTTP |
| `PORT` | no (default 4000) | internal HTTP port - **the unit sets 4004**, see below |
| `OPENRESULTS_INGEST_TOKEN` | effectively | the bearer token an arbiter publishes with. Unset means every publish is refused with a 401 - except with an installation key, see "Public publishing" below |
| `BACKUP_DIR` / `BACKUP_RETENTION` / `OPENRESULTS_BACKUP_PASSPHRASE` | no | see "Backups" above |
| `POOL_SIZE` | no (default 10) | Ecto connection pool size |
| `OPENRESULTS_FIDE_LIST_SYNC` | no (default on) | `off` stops the daily FIDE list check; a list already here keeps answering searches |
| `OPENRESULTS_FIDE_LIST_HOUR` | no (default 3) | hour of the day, UTC, of that check (it runs at :17 past) |
| `FIDE_LIST_URL` | no | fetch the list from here instead of `ratings.fide.com` - only something you control |
| `FIDE_LIST_DATABASE_PATH` | no | the list's SQLite file; default `fide_list.db` beside `DATABASE_PATH` |
| `DNS_CLUSTER_QUERY` | no | multi-node clustering, unused here |

Notably absent, compared with OpenPairings: **no SMTP** (this app sends no
mail, and has no account-recovery path to send it for) and **no Keycloak**
(no accounts at all).

### BEAM scheduler count

Not an environment variable this app reads, but worth carrying in the unit
regardless: the 2026-09-12 load test (`docs/load-test-2026-09-12.md`) found
that leaving BEAM's scheduler count at its own default (one per logical CPU
on whatever machine compiled it) rather than matching the box's real 2 vCPUs
costs 25-35% throughput and materially worse tail latency, purely from
scheduler contention - independent of, and on top of, the connection-pool
fix above.

The unit is started with `mix phx.server` directly (no `mix release`), so
there is no `vm.args` to edit. The fix is the `ELIXIR_ERL_OPTIONS`
environment variable, which the `elixir`/`mix` launcher scripts read
regardless of how they are invoked:

```
Environment="ELIXIR_ERL_OPTIONS=+S 2:2"
```

Add it as a drop-in under
`/etc/systemd/system/openresults.service.d/`, **not** in the unit file
itself - the deploy script rewrites `openresults.service` on every run and
would wipe a hand-added line there (see "Secrets" below, which already
documents this pattern for other hand-managed values). `+S 2:2` means two
scheduler threads for two logical CPUs, matching this host's 2 vCPUs; change
the number if the box ever changes size.

### `OPENRESULTS_INGEST_TOKEN` is only on this side

The token is the whole of the trust boundary on the write path: anything
holding it can publish a tournament page, and nothing else can.
`OpenResultsWeb.Plugs.IngestAuth` compares it in constant time and fails
closed - a missing header, a wrong token and an unconfigured server all
produce the same 401.

The asymmetry is deliberate and worth stating plainly, because it is the
thing people get wrong: **OpenPairings does not read this variable.** An
arbiter types the endpoint and the token into that app's Settings page and
they are stored in that machine's own database
(`PairingsEngine.Publishing.put_endpoint/1` and `put_token/1`), because a
laptop in a school gym has no systemd unit to put them in. Setting
`OPENRESULTS_INGEST_TOKEN` on the server configures the *receiver*; the
*sender* is configured through the UI. See the manual steps below.

Unset, the app still boots and still serves every tournament already
published - only publishing is refused. That is the right failure: the read
side keeps working while the token is sorted out.

### It is also the break-glass key

The ingest token no longer settles who may touch a given tournament. Each
tournament is claimed by a per-tournament key the arbiter's machine generates
and sends in `X-OpenResults-Key`; this server keeps only a SHA-256 digest of
it. See `docs/snapshot-schema.md` for the contract and
`OpenResults.TournamentKeys` for the reasoning.

That leaves one operational hole - **the key lives on one laptop, and laptops
die** - so the ingest token doubles as the override. Send it *in the
tournament-key header* and the key check is bypassed:

```bash
# Republish a tournament whose key was lost with the machine that held it.
curl -X POST https://openresults.zerotwo.cloud/api/snapshots \
  -H "Authorization: Bearer $OPENRESULTS_INGEST_TOKEN" \
  -H "X-OpenResults-Key: $OPENRESULTS_INGEST_TOKEN" \
  -H 'Content-Type: application/json' --data @snapshot.json

# Or take it down entirely: every snapshot, the whole history, the
# registration queue and the key claim.
curl -X DELETE https://openresults.zerotwo.cloud/api/tournaments/<slug> \
  -H "Authorization: Bearer $OPENRESULTS_INGEST_TOKEN" \
  -H "X-OpenResults-Key: $OPENRESULTS_INGEST_TOKEN"
```

**Every override is logged**, at warning level, with the slug and the action:

```
[warning] BREAK-GLASS: publish on "gent-spring-open-2026" authorised with the
server-wide ingest token instead of the tournament key - ...
```

`journalctl -u openresults -g BREAK-GLASS` finds them. If that line appears
and nobody on the team was holding the glass hammer, the ingest token has
leaked and is the thing to rotate.

Rotating the ingest token is safe for the tournaments themselves: it is not
stored as anybody's tournament key (break-glass deliberately never claims a
slug), so rotating it costs each arbiter a visit to their Settings page and
costs no tournament its claim.

Every break-glass use is also written to the moderation action log with the
actor `break-glass`.

### Public publishing

Lets any OpenPairings copy publish here without the ingest token, by
obtaining an installation key of its own. The contract is
`docs/public-publishing.md`; read its "Before switching it on" first.

**Off unless `OPENRESULTS_PUBLIC_PUBLISHING=enabled`.** Unset - or set to
anything else - `/api/installations` and `/api/tournaments` do not exist (the
same 404 as a path nobody routed), an `orik_` key is an unknown token, and
`GET /api/server` reports `unavailable`. Every self-hosted copy is in that
state after upgrading. Enabling it does not yet let anybody register: the
`registration_open` switch in the database starts `false` and is flipped
from the admin panel.

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENRESULTS_PUBLIC_PUBLISHING` | off | `enabled` turns the feature on; nothing else does |
| `OPENRESULTS_OPERATOR_NAME` | none | the name OpenPairings' consent dialog asks the arbiter to trust; `null` in `GET /api/server` when unset |
| `OPENRESULTS_TERMS_URL` | this server's own `/terms` | the terms and acceptable-use page the dialog links to; unset, `GET /api/server` reports `https://<host>/terms`, the page this app serves |
| `OPENRESULTS_CONTACT_EMAIL` | none | an address shown on `/terms` for reaching the operator directly; unset, that page offers only the report form. One email address, or the app does not start |
| `OPENRESULTS_REGISTRATIONS_PER_ADDRESS` | 10 | installations one client address may register per 24 h (an IPv6 client counts by its /64) |
| `OPENRESULTS_REGISTRATIONS_PER_DAY` | 200 | installations the whole server registers per 24 h |
| `OPENRESULTS_INSTALLATION_PUBLISHES_PER_MINUTE` | 30 | mints plus publishes per installation per minute |
| `OPENRESULTS_INSTALLATION_MAX_TOURNAMENTS` | 50 | `pending` plus `listed` tournaments one installation may hold |
| `OPENRESULTS_INSTALLATION_MAX_SNAPSHOT_BYTES` | 3145728 | largest snapshot body an installation key may publish; measured, see the contract. The operator token keeps the 8 MB parser limit |
| `OPENRESULTS_INSTALLATION_MAX_VERSIONS` | 20 | stored versions an installation's tournament keeps; the oldest beyond it are pruned on its next publish. At least 1. Operator-published tournaments keep every version. The hosted unit sets 100 |
| `OPENRESULTS_MIN_FREE_DISK_PERCENT` | 10 | below this much free space on the database's volume (`df`'s Available, measured every minute), installation keys get 503 `storage_low` on mint and publish; delete and the operator token are unaffected. 0 to 100, 0 is off. A disk that cannot be measured refuses nothing - check the dashboard shows a measurement |

The numeric ones must be whole numbers; anything else stops the app at boot,
like `BACKUP_RETENTION`.

Rate-limit windows live in memory, so a restart resets them. The daily
retention job (`OpenResults.Retention`) runs whether or not the feature is
enabled - ten minutes after boot, then every 24 hours - and with nothing to do
it does nothing: it forgets client addresses older than 30 days, releases
minted slugs that never published, and removes expired address blocks.

### Admin panel

`/admin` exists only when all three of these are set; with any one missing,
every `/admin` path answers 404 exactly like a page that does not exist.
Setting up the Cloudflare Access application and the Keycloak group they
refer to, and checking the result, is in [`admin.md`](admin.md).

| Variable | Required in prod? | Purpose |
| --- | --- | --- |
| `OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN` | for the panel | the Zero Trust team domain, `<team-name>.cloudflareaccess.com`: where the app fetches Access's signing keys and the issuer it accepts |
| `OPENRESULTS_ADMIN_ACCESS_AUD` | for the panel | the Access application's Application Audience (AUD) tag |
| `OPENRESULTS_ADMIN_EMAILS` | for the panel | comma-separated addresses allowed in, compared case-insensitively |

Hand-managed, so they belong in a drop-in under
`/etc/systemd/system/openresults.service.d/`, not in the unit the deploy
rewrites. This app still talks to no identity provider itself: Keycloak signs
admins in for Cloudflare Access, and the app only verifies the token Access
attaches.

The panel is the one place this app now sets a session cookie
(`_openresults_admin`, `Path=/admin`), and makes an outbound request of its
own besides the FIDE list's daily look: Access's keys, from the team domain,
at most once every 30 seconds.

### FIDE rating list

The entry form's "find yourself on the FIDE list" search reads a copy of
FIDE's combined rating list that this server keeps itself
(`OpenResults.FideList`). It used to ask the arbiter's OpenPairings over
`localhost` instead (`FIDE_LOOKUP_ENDPOINT` / `FIDE_LOOKUP_TOKEN`, both gone
now and ignored if still set), which worked only where both apps share a box.

- **When.** Once a day at :17 past `OPENRESULTS_FIDE_LIST_HOUR` (UTC,
  default 3), and a minute after boot when there is no list yet or the last
  look is more than a day old. A failed look is retried an hour later, three
  times, then waits for the next day.
- **Only if new.** The look is a `HEAD`; its `ETag` (or `Last-Modified` and
  `Content-Length`) is compared with the list that was imported, and an
  unchanged list is not downloaded. Ratings change monthly, but FIDE rebuilds
  the file more often than that (new registrations; the one served on
  2026-10-18 was dated the day before), so count on a 45 MB download on some
  days and a few hundred bytes on the rest - at most one download a day.
- **How.** The zip streams to `fide_list_work/` beside the list's database
  and is deleted afterwards; its text is read without being unpacked, a
  thousand rows at a time, at low priority, into a scratch table that is
  indexed and then swapped in by rename in one transaction. A search sees
  the whole old list or the whole new one. A list less than half the size of
  the current one, or one that is not FIDE's layout, is refused and the old
  one stays. Measured on 1.9 million rows: about 30 MB of memory above the
  service's usual footprint, about a minute on a fast PC - several on this
  box, which nobody is awake to notice at three in the morning.
- **Disk.** `fide_list.db` is about 145 MB after the first import and about
  290 MB from the second on (the old copy's pages are kept for the next one
  to reuse), plus the 45 MB zip for the minutes it is being read. The index
  build sorts in a temporary file, which SQLite puts in `/var/tmp` (the
  unit's private one) unless `SQLITE_TMPDIR` says otherwise.
- **Watching it.** The admin dashboard shows the live list's date and size,
  the last look and its outcome, and what the sync is doing now. A failure
  is logged as a warning and shown there; it never takes the old list away.

## Ports on this host

Nothing is reachable from the internet except SSH - firewalld's public zone
opens exactly one port, and every public hostname arrives through the
Cloudflare tunnel, which dials these over loopback. A port number here is not
a security boundary, only a promise not to collide with a neighbour.

| Port | Service |
| --- | --- |
| 3000 | `dataplatform-api.service` |
| 4001 | `pairingsengine.service` - OpenPairings |
| 4002 | `personalsite.service` (`python3 -m http.server`) |
| 4003 | `kbsb-database-manager.service` |
| **4004** | **`openresults.service` - this app** |
| 5432 | PostgreSQL |
| 8080 | nginx, in front of Keycloak on 8081 |
| 8099 | nginx default server |

**Why 4004.** This app's *dev* config defaults to 4002 so both halves of the
split can run side by side on one laptop. On this host 4002 is taken by the
personal site and 4003 by the KBSB database manager, so production takes
4004: the first free port in the same block, which keeps the two halves of
the split adjacent and easy to remember.

**Why not 4000,** which is also free. 4000 is what `mix phx.server` binds when
`PORT` is unset, so anything that loses its `PORT=` line - a stray dev server,
a hand-edited unit, a release someone runs by hand to check something - lands
there. Leaving it unclaimed means that accident collides with nothing instead
of quietly stealing traffic from a live service.

Override with `DEPLOY_OPENRESULTS_PORT` in the deploy script's `.env` if this
ever has to move; the script checks the port is actually free before it
uploads anything.

## Reverse proxy / TLS

The app listens on plain HTTP on 4004. TLS termination and the public
hostname both happen in **cloudflared**, which runs on the box as
`cloudflared.service` and dials 4004 over loopback. nginx is on this host but
is not involved - it fronts Keycloak only.

`config/prod.exs` sets `force_ssl` with `rewrite_on: [:x_forwarded_proto]`, so
the app trusts the forwarded-proto header the tunnel sets rather than
terminating TLS itself. `localhost` and `127.0.0.1` are excluded from it,
which is what lets the deploy's health check speak plain HTTP over loopback.

**The entry form's rate limit depends on this topology.** Every visitor
reaches the app as 127.0.0.1, so `OpenResultsWeb.ClientAddress` reads
`cf-connecting-ip` to tell one visitor from another - and it believes that
header only when the request arrived from a loopback address, because on this
host nothing but the tunnel can. Two changes would break that reasoning and
both need a visit to that module first: exposing 4004 to anything but the
tunnel, which would let a caller name its own address and hand a flooder an
unlimited supply of rate-limit buckets, and moving the proxy to another host,
where its requests would no longer arrive from loopback and every visitor
would collapse back into one bucket.

## Manual steps a script cannot do

Two, both one-time.

### 1. Add the hostname in the Cloudflare dashboard

**This cannot be automated from the box, and it is not an oversight.** The
tunnel is run token-based:

```
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token <token>
```

There is no `config.yml`, no `/etc/cloudflared` ingress file, nothing on the
server that says which hostname maps to which port. A token-based tunnel
fetches its entire routing table from Cloudflare at connect time, so the
routing lives in the dashboard and the dashboard is the only place it can be
edited. Writing an ingress file on the box would change nothing.

In **Cloudflare Zero Trust → Networks → Tunnels →** the tunnel serving
`zerotwo.cloud` **→ Public Hostnames → Add a public hostname**:

| Field | Value |
| --- | --- |
| Subdomain | `openresults` |
| Domain | `zerotwo.cloud` |
| Path | *(empty)* |
| Type | `HTTP` |
| URL | `localhost:4004` |

`HTTP`, not `HTTPS`: the tunnel terminates TLS at Cloudflare's edge and
speaks plain HTTP to the app, which is exactly what `force_ssl`'s
`x_forwarded_proto` rewrite expects. Setting `HTTPS` here points the tunnel
at a TLS listener that does not exist.

The DNS record is created for you when the hostname is added to a zone
Cloudflare already manages. Nothing on the box needs restarting - the tunnel
picks the new route up on its own.

The `PORT` in the unit and the port in this mapping have to agree. If one
moves, move both.

The tunnel token itself is not recorded in this repository, in the deploy
script, or anywhere else in version control, and must not be.

### 2. Point OpenPairings at this server

In **OpenPairings → Settings → the publishing card**, set:

- **endpoint**: `https://openresults.zerotwo.cloud`
- **token**: the same value as `OPENRESULTS_INGEST_TOKEN` on this server

Both halves are required - `PairingsEngine.Publishing.configured?/0` returns
false unless each is a non-empty string, because an endpoint with no token
would fail every send with a 401, which is a worse experience than saying so
up front. Publishing is then per-tournament, opt-in, via that tournament's
**Publish to OpenResults** toggle.

This step exists because, as above, the sender keeps its configuration in its
own database rather than in the environment. The deploy script prints a
reminder after a successful `--openresults` run.

## Secrets

Nothing production-sensitive is committed to this repository.

- The deploy script lives outside both repos and reads credentials from its
  own local, gitignored `.env`.
- The systemd unit (containing `SECRET_KEY_BASE` and
  `OPENRESULTS_INGEST_TOKEN`) is `chmod 600`, root-only.
- `config/config.exs` sets `:ingest_token` to `nil` on purpose: a default
  that works is a default that reaches production.
- The Cloudflare tunnel token exists only in `cloudflared.service` on the
  box. Note that it is therefore visible in that unit's `ExecStart` and in
  `ps` output to anyone who can read them; that is a property of token-based
  tunnels, not something this app chose.

Long-lived, hand-managed environment values belong in a drop-in under
`/etc/systemd/system/openresults.service.d/`, **not** in the unit itself: the
deploy rewrites `openresults.service` on every run and anything hand-added
there is wiped. (This is how `KEYCLOAK_*` is handled on the OpenPairings
side.)

## Setting up a fresh host

A target reachable over SSH, plus Java + Erlang + Elixir (the deploy script
installs these if absent on a Rocky/RHEL-family target), a free port, and a
hostname routed to it. No SMTP account and no identity provider are needed -
this app has neither.
