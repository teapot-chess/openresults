# The admin panel: setting it up

`https://openresults.zerotwo.cloud/admin` is where the operator moderates
public publishing. This document is for the person switching it on: what to
click in Keycloak and in Cloudflare, which three variables to set on the
server, how to check it worked, how to sign out, and what each kind of
misconfiguration looks like.

The contract behind it is the "Admin panel: `/admin`" section of
[`public-publishing.md`](public-publishing.md). The code is
`OpenResultsWeb.Plugs.AdminAuth` and the modules under
`lib/openresults_web/admin_access/`.

## How the lock works

Two locks, and each one alone opens nothing.

1. **Cloudflare Access**, at the edge. An Access application covers
   `openresults.zerotwo.cloud/admin*`. Nobody reaches the server on those
   paths without signing in through Keycloak and being in the Keycloak group
   `openresults-admin`.
2. **The app itself.** Cloudflare attaches a signed token to every request
   it lets through (`Cf-Access-Jwt-Assertion`). The app verifies that token
   against Cloudflare's published keys, checks it was issued for *this*
   Access application and *this* team, and checks the email in it against its
   own list, `OPENRESULTS_ADMIN_EMAILS`.

The second lock is there because an Access policy is a form in a dashboard,
and forms get edited wrong. If the Access application is deleted, its path is
mistyped, or its policy is widened while testing, the panel stays shut: a
request without a valid token for this application gets the site's ordinary
"Not Found".

This app still talks to no identity provider itself. Keycloak is Cloudflare
Access's identity provider, not this app's; there are no accounts or
passwords here.

## Before you start

You need:

- admin rights in the Keycloak realm that Cloudflare Access signs people in
  with;
- admin rights in Cloudflare Zero Trust for the `zerotwo.cloud` account;
- root on the host, to add three environment variables.

Your **team domain** is shown under **Zero Trust → Settings → Team name and
domain**. It looks like `<team-name>.cloudflareaccess.com`. You need it twice
below. (Renaming the team later changes it, and the panel then answers "Not
Found" until the variable is updated too.)

## A single admin: skip Keycloak entirely

The zerotwo server has one admin, `jorian@zerotwo.cloud`. With one admin there is
no need for the `openresults-admin` group, the `groups` mapper or the `groups`
OIDC claim, so **steps 1 and 2 are skipped**. In step 3 the policy's **Include**
is **Emails** → `jorian@zerotwo.cloud` instead of the group claim, and the
application's only identity provider stays **Keycloak** (so the address can
only have come from a Keycloak sign-in, never a one-time PIN). The server's own
check is unchanged: `OPENRESULTS_ADMIN_EMAILS=jorian@zerotwo.cloud`. Both
locks still hold. Switch to the group the day a second admin is added.

## 1. Keycloak: the group, and groups in the token

If Keycloak is already an identity provider in Zero Trust for other
applications, its client exists; do only the group and the mapper check.

1. **Create the group.** Realm → **Groups → Create group**, name
   `openresults-admin`. Add the people who should administer the site
   (**Users → the user → Groups → Join group**). Each needs an email address
   set on their Keycloak user: that address is what reaches the app.
2. **The client, if there is none yet.** **Clients → Create client**, type
   *OpenID Connect*, a client ID such as `cloudflare-access`, **Client
   authentication** on. Valid redirect URI:
   `https://<team-name>.cloudflareaccess.com/cdn-cgi/access/callback`.
   Copy the client secret from the **Credentials** tab.
3. **Put the groups in the token.** **Clients → the Cloudflare client →
   Client scopes → the `…-dedicated` scope → Add mapper → By configuration →
   Group Membership**:
   - **Name**: `groups`
   - **Token Claim Name**: `groups`
   - **Full group path**: **off** (otherwise the value is
     `/openresults-admin`, and the policy below will not match it)
   - **Add to ID token**, **Add to access token**, **Add to userinfo**: on

## 2. Cloudflare: Keycloak as an identity provider

Skip this if Keycloak is already listed under **Zero Trust → Integrations →
Identity providers**, but check that its **OIDC Claims** include `groups`.

Otherwise: **Zero Trust → Integrations → Identity providers → Add new
identity provider → OpenID Connect**.

| Field | Value |
|---|---|
| Name | `Keycloak` |
| Client ID | the client ID from step 1 |
| Client secret | the secret from step 1 |
| Auth URL | `https://<keycloak host>/realms/<realm>/protocol/openid-connect/auth` |
| Token URL | `https://<keycloak host>/realms/<realm>/protocol/openid-connect/token` |
| Certificate URL | `https://<keycloak host>/realms/<realm>/protocol/openid-connect/certs` |
| PKCE | on |
| OIDC Claims | add `groups` |

Save, then use **Test** on the provider: sign in as one of the admins and
check that the result shows `groups` containing `openresults-admin`.

## 3. Cloudflare: the Access application for `/admin`

**Zero Trust → Access controls → Applications → Add an application →
Self-hosted** (in some dashboards: *Self-hosted and private → Add public
hostname*).

| Field | Value |
|---|---|
| Application name | `OpenResults admin` |
| Session duration | `8 hours` (shorter is fine; this is how long a sign-in lasts) |
| Subdomain | `openresults` |
| Domain | `zerotwo.cloud` |
| Path | `admin*` |
| Identity providers | **Keycloak only**; *Apply instant authentication* on, so the Access login page is skipped |

**The path is `admin*`, not `admin/*` and not `admin`.** Cloudflare's path
rules are literal about this: `admin/*` covers `/admin/tournaments` but *not*
`/admin` itself, and `admin` without a wildcard covers only `/admin`. `admin*`
covers `/admin`, `/admin/` and everything beneath it. (It also covers any
other path starting with "admin"; the public site has none.)

Add one policy:

| Field | Value |
|---|---|
| Policy name | `openresults-admin group` |
| Action | **Allow** |
| Include | selector **OIDC Claims** (shown as *IdP OIDC Claim* in some dashboards), claim name `groups`, claim value `openresults-admin`. **A single admin:** selector **Emails**, value their address |
| Require (optional) | selector **Login Methods**, value `Keycloak` |

No other policy. In particular no *Bypass*, no *Service Auth* and no
*Everyone* rule on this application: a service token has no email and the app
would refuse it anyway, and a bypass would leave only the second lock.

Save the application. The existing tunnel route for `openresults.zerotwo.cloud`
(see [`deployment.md`](deployment.md)) does not change; Access sits in front
of it for the `/admin*` paths only, and every public page stays exactly as
open as it was.

## 4. The Application Audience (AUD) tag

**Zero Trust → Access controls → Applications →** `OpenResults admin` **→
Configure → Additional settings → Application Audience (AUD) Tag.** Copy it:
a long hexadecimal string.

It identifies this one application. A token Cloudflare issued for any other
Access application in the same team carries a different AUD and is refused.
Deleting and re-creating the application gives it a **new** AUD, and the
variable must be updated.

## 5. The three variables

**On the zerotwo server, put them in the deploy script's `.env`**
(`openpairings-deploy/.env`) and deploy. The script writes them into the
`openresults` unit on every run, so nothing is hand-edited on the host and no
deploy can lose them:

```ini
OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN=<team-name>.cloudflareaccess.com
OPENRESULTS_ADMIN_ACCESS_AUD=<the AUD tag>
OPENRESULTS_ADMIN_EMAILS=first.admin@example.org,second.admin@example.org
```

The same `.env` also carries public publishing itself, if you are switching it
on (see [`public-publishing.md`](public-publishing.md), "Before switching it
on"):

```ini
OPENRESULTS_PUBLIC_PUBLISHING=enabled
OPENRESULTS_OPERATOR_NAME=ZeroTwo
# optional: shown on /terms as a direct way to reach the operator
OPENRESULTS_CONTACT_EMAIL=takedown@example.org
# optional: only to link a terms page OTHER than this server's own /terms,
# which GET /api/server reports when this is unset
# OPENRESULTS_TERMS_URL=https://example.org/terms
```

The deploy warns, loudly, about the two half-states: only some of the three
admin variables set (the panel stays off), and public publishing enabled
without the admin panel (safe - registration starts closed - but nobody can
open it or moderate).

**On a host that does not use that deploy script**, use a systemd drop-in
instead - not `openresults.service` itself, which a deploy rewrites:

```ini
# /etc/systemd/system/openresults.service.d/admin.conf
[Service]
Environment="OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN=<team-name>.cloudflareaccess.com"
Environment="OPENRESULTS_ADMIN_ACCESS_AUD=<the AUD tag>"
Environment="OPENRESULTS_ADMIN_EMAILS=first.admin@example.org,second.admin@example.org"
```

```bash
chmod 600 /etc/systemd/system/openresults.service.d/admin.conf
systemctl daemon-reload
systemctl restart openresults
journalctl -u openresults -g "admin panel" -n 5
```

| Variable | What it is |
|---|---|
| `OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN` | the team domain from "Before you start". With or without `https://` and a trailing slash; anything that is not a plain host name counts as unset |
| `OPENRESULTS_ADMIN_ACCESS_AUD` | the AUD tag from step 4 |
| `OPENRESULTS_ADMIN_EMAILS` | comma separated, spaces around commas ignored, compared case-insensitively. The exact address Keycloak has for each admin |

**All three or nothing.** With any one missing, every `/admin` path answers
"Not Found" exactly as a page that does not exist. A club's own copy of
OpenResults, which sets none of them, therefore has no admin panel at all.

After the restart the journal should say:

```
[info] admin panel: enabled behind Cloudflare Access
```

## 6. Checking it works

Do all of these once, after setting it up and after changing anything in
Access.

1. **An admin gets in.** In a private window open
   `https://openresults.zerotwo.cloud/admin`. Keycloak's sign-in appears (or
   Cloudflare's, if instant authentication is off); after it, the dashboard
   says **Signed in as** your address, and **Checked by** says *Cloudflare
   Access, and this server's own check of the Access token*.
2. **Someone outside the group does not.** Sign in as a Keycloak user who is
   not in `openresults-admin`. Cloudflare shows its own access-denied page;
   the request never reaches the server.
3. **Someone in the group but not on the list gets a 403.** Temporarily
   leave one admin's address out of `OPENRESULTS_ADMIN_EMAILS` (or test with a
   third group member). They see a plain page: *Forbidden - Signed in as ...,
   which is not on this server's list of administrators.* Put the address
   back.
4. **The app's own lock holds without Access.** On the host, bypassing
   Cloudflare entirely:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4004/admin
   curl -s -o /dev/null -w '%{http_code}\n' -H 'Cf-Access-Jwt-Assertion: forged' http://127.0.0.1:4004/admin
   ```

   Both must print `404`. The journal shows
   `admin panel: refused GET /admin (no_access_token)` and `(malformed)`.
5. **The admin pages are never stored or framed.** In the browser's developer
   tools, on the dashboard's response: `cache-control: no-store`,
   `x-frame-options: DENY`, and a `content-security-policy` ending in
   `frame-ancestors 'none'`.
6. **The public site is unchanged.**

   ```bash
   curl -sI https://openresults.zerotwo.cloud/ | grep -i set-cookie
   ```

   prints nothing.

## Signing out

**Sign out**, top right, goes to `/cdn-cgi/access/logout` on this hostname.
Cloudflare answers that address itself: it ends the Access session and clears
its cookie, and the next visit to `/admin` goes back through Access's sign-in.

What it does not end is **Keycloak's own session**. Keycloak may still
remember you, in which case the next visit to `/admin` signs you straight back
in without asking for a password. On a shared or borrowed machine, also sign
out of Keycloak (its account console,
`https://<keycloak host>/realms/<realm>/account`, **Sign out**), or close the
browser.

The panel's own cookie, `_openresults_admin`, holds only a form token and
one-off messages. It says nothing about who you are and ends with the browser
session; who is signed in is re-checked from Cloudflare's token on every
request.

## Using the panel

Everything that changes something goes through a confirmation page that says
what will happen, then a button. Nothing needs JavaScript. Every change is
written to the action log with your address.

- **Dashboard.** The two switches, what needs attention (pending tournaments,
  open reports), what published tournaments take on disk, the free space on
  the database's volume against the free-disk floor, the version cap, the
  FIDE rating list the entry form searches (its date, how many players, the
  last daily look and what came of it), and the latest actions. While free space is below the floor a warning sits at the
  top: installation keys cannot publish or create tournaments until there is
  room (deleting still works). "Not measured" means the floor is not
  protecting anything. **Pausing public publishing takes arbiters' live updates offline
  in the middle of their events**: every tournament published from
  OpenPairings desktop stops updating until you resume. Tournaments published
  with the operator token are not affected. When
  `OPENRESULTS_PUBLIC_PUBLISHING` is not enabled the dashboard says so, and
  the switches are stored but change nothing.
- **Tournaments.** Filter by status, open reports or a search. A tournament's
  page shows its owner, first and last publish, snapshot sizes, its reports
  and what has been done to it. A pending tournament is already public - at its
  address, on the front page and in its search - and only missing from
  players' cross-tournament history pages, so the panel shows it as "pending:
  not on player pages yet". **Show on player pages** (approve: pending to
  listed) is what puts it there; check the results are not invented against
  real FIDE ids first. Hide, unhide,
  transfer to another installation by its `in_...` id (this clears the
  tournament key, so that installation's next publish claims it), or delete
  (every stored version and the entry list with its email addresses; it
  cannot be undone). A delete leaves a tombstone on the address: every later
  publish to it is refused with `tournament_deleted`, including a hosted
  OpenPairings publishing with the operator token, which then switches
  publishing off for that tournament and tells its arbiter. Without that, the
  next result typed in would have put the page straight back. Only a
  break-glass publish (the operator token sent as the tournament key too)
  lifts a tombstone, and the action log records it as `lift_tombstone`.
- **Installations.** Suspend (its key stops publishing until unsuspended),
  unsuspend, or revoke (final; you choose whether to hide its tournaments
  too). Addresses show as "forgotten after 30 days" once retention has
  cleared them.
- **Trusted installations.** On an installation's page, **Trust** is for a
  machine you know, such as a federation's laptop: tournaments it creates
  from then on start listed, on player pages at once. The confirmation has an
  unticked checkbox to put its pending tournaments on player pages too.
  **Stop trusting** makes its next tournaments pending again; revoking ends
  trust as well; suspending does not, but a suspended key publishes nothing.
  **Own limits…** gives any installation, trusted or not, its own tournament
  limit, snapshot size cap, publishes per minute or version cap. Leave a field
  empty for the server's value.
- **A laptop restored from backup** comes back as a new installation, because
  no OpenPairings backup carries the installation key. On the old
  installation's page, **Move all tournaments to another installation…** takes
  the new one's id and shows its client, version and when and where it was
  last seen, so you can check it is the right laptop, then moves every
  tournament at once. Each one's tournament key is cleared, so the new
  laptop's next publish claims it. A suspended or revoked installation cannot
  receive them.
- **Reports.** The open queue, each report with a link to its tournament
  and the reference the reporter was given (eight base32 characters, shown
  as `ABCD-EFGH`; reports from before references existed have none), and
  Resolve with a written resolution. The reporter can look the reference up
  at `/report/status` and sees only whether the report is open or dealt
  with, and what they wrote themselves; your resolution text stays here. Resolving does not change the
  tournament; hide or delete it separately.
- **Address blocks.** An address or CIDR range, for a number of hours or days
  (at most 30), with a reason. Before you confirm, the page shows how many
  installations were seen from that range in the last 30 days: a club's wifi
  can be many people.
- **Action log.** Everything above, plus break-glass uses of the operator
  token and retention runs, filterable by who, what and target.
- **Settings.** The operator name, the terms link, the contact email and the
  public-publishing limits, each showing the value in force and whether it comes from the
  panel, the environment (`.env`) or the built-in default. **Change** checks
  the value against the same rules the server applies to `.env` at boot and
  shows a confirmation; a saved value wins over `.env` from the next request,
  with no deploy. **Reset to default** removes the panel's value, so `.env`
  (or the default) applies again. Below them, the variables the panel never
  changes - the public-publishing gate, the three admin variables, the ingest
  token, backup settings, database and host - listed by name with whether each
  is set; secret values are never shown. Change those in `.env` and deploy.
- **The terms page** (`/terms`, public, in English, Dutch and French). Terms,
  acceptable use, how to have something removed, and privacy, with the
  retention periods the server is actually running with. It shows the
  operator name, and the **contact email** when one is set; with none, it
  offers only the report form, and never an invented address. With no
  **terms link** set, `GET /api/server` reports this server's own
  `https://<host>/terms`, so OpenPairings' consent dialog links it with no
  configuration; set the terms link only to point somewhere else. The page is
  rendered on every request, so a change here shows on the next load. The
  address is wrapped in Cloudflare's `email_off` markers, so it stays a plain
  `mailto:` link. Its "last updated" date is `@updated` in
  `OpenResultsWeb.TermsController`: change it with the wording.
- **Public notice** (on the settings page). A short message on every public
  page, such as "Maintenance tonight 22:00-22:30": English required, Dutch and
  French optional (visitors whose language has no text get the English),
  plain text up to 300 characters, information or warning, and an optional
  expiry in UTC after which it disappears by itself. **Preview** shows it in
  each language before you confirm. It is not shown on the projector view.
  Clearing it is one confirmation. Every page's cached copy and ETag change
  with it, so visitors see the change on their next load.
- **Stats.** Read-only, and reloads itself every 30 seconds. Traffic (requests
  by route group, status classes, page-cache hit rate, response times, the
  busiest tournaments), server health (CPU and load, memory, schedulers online
  against logical CPUs, run queue, open connections), publishing and refusals
  in the last 24 hours, and the database (file and WAL size, row counts, query
  and pool-queue times). Traffic and health are counted in memory since the last
  restart, which the page names. The Readers section is kept in the database:
  daily unique readers, real page views, refreshes and bot hits, and the top
  tournaments by unique readers, from a hash of address and user agent that
  is salted afresh each day and never stored; no addresses, user agents or
  query strings are kept. "Schedulers: 2 online of 2" is how to confirm the deploy's
  `+S 2:2` took effect. CPU, load and system memory come from `/proc` and say
  "not measured" anywhere else.

## When it does not work

Every refusal of a configured panel is logged with its reason (never with the
token). Start with:

```bash
journalctl -u openresults -g "admin panel" -n 20
```

| What you see | Log | Cause |
|---|---|---|
| "Not Found" on every `/admin` path | at boot: `admin panel: OFF, every /admin path answers 404 - missing or unusable: …` | a variable is missing, empty, or (team domain) not a host name. The line names which |
| "Not Found", no log at all | nothing | none of the three variables is set: the panel is off, as on every club's own copy |
| "Not Found" | `refused GET /admin (no_access_token)` | the request did not come through Access: no Access application covers this path, its path is `admin/*` or `admin`, or it is disabled. The app stayed shut, but fix Access |
| "Not Found" | `(wrong_audience)` | `OPENRESULTS_ADMIN_ACCESS_AUD` is another application's tag, or the application was re-created and has a new one |
| "Not Found" | `(unknown_key)`, often with `could not fetch Cloudflare Access certs for …` and an HTTP status or connection error | the team domain is wrong (another team's, a typo, or the team was renamed), or the host cannot reach `https://<team domain>/cdn-cgi/access/certs` (outbound HTTPS, DNS) |
| "Not Found" | `(wrong_issuer)` | the keys matched but the token names a different issuer: the configured team domain is not the exact `<team-name>.cloudflareaccess.com` shown under Settings → Team name and domain |
| "Not Found" | `(expired)` or `(not_yet_valid)` | the server's clock is off by more than a minute: `timedatectl` |
| plain "Forbidden - Signed in as …" | `"…" passed Cloudflare Access but is not in OPENRESULTS_ADMIN_EMAILS` | that address is not on the list. Compare it with the Keycloak user's email |
| Cloudflare's own access-denied page | nothing (the request never arrived) | the Access policy refused: not in the group, the `groups` mapper missing or with *Full group path* on, or `groups` not listed under the provider's **OIDC Claims** |
| the service does not start | `refusing to start: the admin panel's development bypass is configured …` | `:admin_dev_bypass` reached production configuration. Remove it; it belongs in `config/dev.exs` only |

### Signing keys

The app fetches Cloudflare's signing keys from the team domain and keeps them.
It fetches again when a token names a key it has not seen (Cloudflare rotates
keys every six weeks) and when its copy is more than an hour old - but never
more than once every 30 seconds, whatever the requests say, so a flood of
made-up tokens cannot turn the server into a request generator aimed at
Cloudflare. If a fetch fails, the keys already held stay in use.

In practice that means one visible effect: in the first 30 seconds after the
server has just fetched keys, a token signed with a brand-new key is refused
("Not Found", `unknown_key`). Reloading a moment later works.

## Local development

`config/dev.exs` turns on a development bypass: on `mix phx.server`, `/admin`
signs you in as `admin@localhost` with no Cloudflare in front, and says so in a
banner on every page. It exists only in development and test configuration,
is never read from an environment variable, is ignored outside those two
environments, and a production start with it configured refuses to boot.
