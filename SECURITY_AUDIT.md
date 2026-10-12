# MicuPoker Security Audit

Second full pass. Supersedes the 2026-05-31 audit, whose findings are all fixed
and are summarised at the bottom.

Date: 2026-08-07
Scope: application code, the realtime layer, card privacy, action validation,
authentication, the reverse proxy, the systemd sandbox, and the play-money
constraint.

Production isolation follow-up: 2026-10-12

## Production isolation follow-up

The October review closed the gap between the hardened application code and
the process that actually runs on the shared host:

- production runs from a checksummed, root-owned immutable release as the
  dedicated non-login `micupoker` account, not from the interactive checkout
  and not as `micu`;
- the service has no effective capabilities, has `NoNewPrivileges` enabled,
  cannot see the checkout in its mount namespace, and binds only to
  `127.0.0.1:4100`;
- runtime, migration and backup database access use separate credentials and
  least-privilege roles. The former `micupoker_user` and `micu` roles cannot
  connect to the production database;
- production secrets are root-owned systemd credentials. Builds receive only
  `TEST_DATABASE_URL` from `/etc/micupoker-build.env` and fail closed when that
  file is unavailable; there is no fallback to a checkout `.env`;
- a daily least-privilege backup creates protected, checksummed custom-format
  dumps. A restore drill proved the newest dump in a disposable database and
  checked migrations, row counts, constraints and ledger invariants;
- a five-minute independent probe checks both health paths, process identity,
  restart rate, release integrity and backup freshness. Service failures use
  the shared host e-mail alert path; both a real alert and duplicate throttling
  were exercised;
- the deployment path was tested through failure and rollback before a
  successful release switch. Obsolete checkout secrets, crash output and the
  old production build were moved into a root-only, checksummed quarantine so
  recovery remains possible without leaving them reachable by the service.

The exact revision `fa33666` subsequently passed a detached build without a
checkout `.env`: 300 tests, production compilation and release assembly, a
clean Hex security audit, and the formatting and shell gates. Live probes also
confirmed Cloudflare proxying, direct-origin denial, required headers,
authenticated admin access, approved WebSocket upgrade and denial of hostile
or missing WebSocket origins.

Residual production risks are explicit: database backups are still local to
this VPS rather than encrypted and replicated off-host; the alert-provider
credential needs its planned manual rotation; and the incident runbook still
needs a recorded tabletop exercise. These controls are not considered closed
until their external dependencies and recovery evidence exist.

## Threat model

The attacker is a player. They can hold a legitimate seat, open a WebSocket,
read every byte the server sends them, replay and forge any request, script
thousands of them, and open as many sessions as they like. They may also be
someone who never logs in and simply wants the service down or the database
full.

What must hold:

1. A player learns nothing about another player's hole cards before showdown.
2. A player cannot act out of turn, act as someone else, or move chips that are
   not theirs.
3. The card sequence is unpredictable and comes from the server.
4. No amount of traffic from one client degrades the table for everyone else.
5. The database does not grow without bound from traffic that never plays.

## Findings

Ordered by severity. Every one is fixed; the commit that fixed it is named.

### Critical

**The betting line could be reopened by a short all-in.** A player who was
all-in for less than a full raise reset `min_raise` and cleared the acted set,
which let a player who had already acted raise again. In a real game this is the
difference between a closed action and an unlimited one — it could be driven
deliberately to squeeze a third player. `MicuPoker.Poker.Betting.all_in/3` now
distinguishes a full raise from a short one: a short all-in advances
`current_bet` but records the players whose action is closed, and they can only
call or fold. *(a1a1057)*

**Postflop action started from the wrong seat.** Every street after the flop
resumed from the last aggressor's seat rather than from the first live player
left of the button, so a player could be given or denied position. Fixed in
`start_street_turn/1`, which now walks from `dealer_seat`. Verified by reverting
the fix and confirming the test suite fails. *(a1a1057)*

**An uncalled bet was swallowed by the pot.** When everyone folded to a raise,
the unmatched portion stayed in the pot instead of returning to the raiser.
`return_uncalled_bet/1` returns it before settlement. *(a1a1057)*

### High

**No Content-Security-Policy, HSTS, or cross-origin isolation headers.** Any
injected markup could load and exfiltrate to anywhere. `Plugs.SecurityHeaders`
now sends a policy with `script-src 'self'` — no inline scripts anywhere in the
app — `object-src 'none'`, `frame-ancestors 'none'`, `form-action 'self'`, and a
`connect-src` limited to the app's own WebSocket origins. HSTS is only sent over
a request that actually arrived on HTTPS. *(fed7f46)*

**Client IP was taken from whatever header the client sent.** Every per-IP limit
could be bypassed with one forged `X-Forwarded-For`. `Plugs.RemoteIp` only
honours forwarded headers when the TCP peer is inside `TRUSTED_PROXIES`, walks
`X-Forwarded-For` right to left, and prefers `CF-Connecting-IP` only when
`TRUST_CLOUDFLARE` is set. nginx overwrites `CF-Connecting-IP` with the
resolved address, so a client cannot supply its own. *(fed7f46)*

**No rate limiting anywhere.** `MicuPoker.RateLimiter` is a fixed-window ETS
counter using `:ets.update_counter/4`, with `Plugs.RateLimit` in front of the
route groups that cost something: 20/min on auth, 10/min on room writes, 120/min
on the JSON API. nginx enforces the same shape one layer out so the BEAM never
sees the flood. *(fed7f46)*

**LiveDashboard was mounted for anyone in dev and the session was reused across
login.** The dashboard exposes process, memory and query internals. It now lives
at `/admin/dashboard` behind basic auth, mounted only when `ADMIN_USER` and an
`ADMIN_PASSWORD` of at least 16 bytes are both set, and returning 404 when they
are not — an unconfigured dashboard should not even advertise its existence.
*(e1dba15)*

**Session fixation.** Logging in kept the pre-auth session ID, so an attacker
who could plant a cookie kept access after the victim authenticated.
`UserAuth.log_in_user/3` calls `renew_session` — `clear_session` plus
`configure_session(renew: true)` — before writing the token. *(8eaae64)*

**A crash in one table took down every table.** `TableServer` calls were
unwrapped `GenServer.call`s, so a restarting or dead table process propagated
the exit into the caller's LiveView and killed the player's page. Every call now
goes through a wrapper that catches `:noproc`, `:normal`, `:shutdown` and
`:timeout` and returns `{:error, :table_unavailable}`. *(74fe625)*

### Medium

**A malformed environment variable crashed the node.** `String.to_integer/1` on
an operator-supplied value raised — `Room.max_players/0` is called from a
changeset, so `MAX_PLAYERS_PER_ROOM=nine` meant a 500 on every lobby render, and
the same parse inside `TableServer` killed the table mid-hand. All runtime
settings now go through `MicuPoker.Config`, which range-checks and falls back to
the documented default. Boot-time settings still fail loudly and on purpose.
*(74fe625, this commit)*

**Table processes and their rate-limit state leaked.** A table with no players
stayed resident forever, and its per-player limiter map grew without bound.
Tables now shut down after `TABLE_IDLE_SHUTDOWN_MINUTES` of no connected players
— state is already persisted, so the next visitor restarts it — and stale
limiter entries are pruned. *(74fe625)*

**Usernames collided case-insensitively.** `Admin` and `admin` were different
accounts, which is an impersonation primitive. A `unique_index` on
`lower(username)` was added after confirming the production table had no
existing duplicates. *(8eaae64)*

**Login leaked which usernames exist through timing.** A miss returned
immediately; a hit spent ~200 ms hashing. `Password.no_user_verify/0` runs the
same work on a miss. Attempts are limited to 10 per IP and 5 per username per 15
minutes, so the equalised cost is also a budget. *(8eaae64)*

**Open redirect on login.** `?return_to=` was followed unvalidated.
`safe_return_to/1` accepts only a path, rejecting protocol-relative `//evil.com`
along with absolute URLs. *(8eaae64)*

**Public pages created a database row per visitor.** `GET /` redirected into the
guest pipeline, so every crawler hit inserted a `users` row. `/` is now a real
landing page outside that pipeline, as are `/leaderboard`, `/docs`, `/health`
and the JSON API. Guests with no room history are reaped after
`UNUSED_GUEST_RETENTION_MINUTES`. *(fd59695, e1dba15)*

**A rebuy counted as a losing hand.** Stats summed the whole ledger, so topping
up looked like a loss and could be used to manipulate a ranking. Only
`showdown` and `uncontested` entries count toward results. *(e1dba15)*

### Low

**`CF-Connecting-IP` was attacker-controlled.** `TRUST_CLOUDFLARE` was on, but
`poker.micutu.com` is a DNS-only record: visitors hit the origin directly, so
the app's TCP peer is always loopback — which is trusted. A request carrying its
own `CF-Connecting-IP` therefore chose its own identity and got a fresh bucket
in every per-IP limit. Closed twice over: nginx now overwrites the header with
the resolved peer address on the way through, and `TRUST_CLOUDFLARE` is off so
the app does not consult it at all. *(this commit)*

The Cloudflare origin guard the other sites on this host use is written into the
vhost but left commented out, because on a grey-clouded record it returns 444 to
every real visitor. It is the right control once the record is proxied, and the
condition for turning it on is documented next to it. Until then, the origin is
reachable directly by anyone who knows the address — accepted, since that is
simply what a DNS-only record means.

**nginx duplicated the app's security headers.** Two `X-Frame-Options` headers
arrive as `DENY, DENY`, which some browsers treat as malformed and ignore
outright, and two CSP headers force the browser to satisfy both. The app is now
the single source of truth and nginx adds none, which also means a local run is
as hardened as production. *(this commit)*

**`Connection: upgrade` was sent on every proxied request**, including plain
page loads. Now mapped from `$http_upgrade`. *(this commit)*

**The systemd unit had no sandbox.** The release ran with the full ambient
capability set and write access to the whole filesystem. It now runs with no
capabilities, `ProtectSystem=strict` plus a single `ReadWritePaths`, a private
`/tmp`, `ProtectProc=invisible`, a filtered syscall set and no Erlang
distribution port. *(this commit)*

## Current controls

**Cards.** The deck is shuffled from `:crypto.strong_rand_bytes`. Hole cards
live in the table process and are written into the socket of exactly one player.
Broadcasts carry sanitized state; each client fetches its own personalised view.
A fold or an uncontested pot never reveals cards — only a real showdown does.
Sanitized state exposes `user_id` only for the viewer; opponents are identified
by seat and display name.

**Authority.** The server owns the deck, the turn order, the legal action set,
the pot, the stacks and the winner. Bet and raise amounts are clamped to the
server's own valid range before they are applied, and persisted action amounts
for calls and all-ins are the server's numbers, not the client's.

**Identity.** Passwords are PBKDF2-HMAC-SHA512 at 210,000 iterations, chosen by
benchmarking ~198 ms on this host. Session tokens are 32 random bytes; only the
SHA-256 digest is stored, so a database read does not yield a usable token.
Comparisons use `Plug.Crypto.secure_compare`. Cookies are `secure`, `http_only`,
`SameSite=Lax`, signed and encrypted.

**Sockets.** Channels require the signed session or a server-signed socket
token; a raw `user_id` parameter is rejected. `check_origin` is the public host.
Unknown topics, malformed payloads and unknown events all return errors rather
than raising. Disconnected players cannot chat or act — only the server's own
timeout handling can advance their turn.

**Availability.** Per-IP limits in nginx and in the app, per-player chat and
action spacing in the table process, a connection cap per IP, request-phase
timeouts against slowloris, `client_max_body_size 64k`, `MAX_ROOMS`, idle table
shutdown, and a supervised janitor that completes stale rooms without deleting
hand history or ledger rows.

**Integrity.** Finished hands persist stacks, pot total, winner summary and
zero-sum `chip_ledger` entries in one transaction. Winner summaries carry no
internal user IDs; the ledger keeps them for audit.

**Isolation.** The release binds `127.0.0.1` only. Erlang distribution is off.
nginx is the only public entry point and is itself reachable only through
Cloudflare. No web request executes a shell command. No secret appears in the
frontend, the README or any public response.

## Out of scope, and why

- **Real money.** None of it exists. Adding any of it needs legal review first.
- **Collusion between players at one table.** Two players sharing their hole
  cards over another channel cannot be detected from inside the app. The hand
  history and ledger exist so it can be investigated after the fact.
- **Multi-accounting.** Guest seats are free by design, which is what makes the
  game frictionless. Table passwords are the control for a game that needs a
  known set of players.
- **Automated play.** A bot is indistinguishable from a fast human over this
  API. Not worth defending against for play money.
- **Browser-based mobile regression tests.** The layout has unit coverage;
  end-to-end device testing is not wired up.

## Verifying

```bash
mix test                        # 300 tests
mix compile --warnings-as-errors
./scripts/deploy_check.sh       # headers, duplication, pages, admin route
./scripts/check_database_privileges.sh
sudo systemctl start micupoker-healthcheck.service
systemd-analyze security micupoker.service
```

## The 2026-05-31 pass

All fixed, kept here for the record: `/socket?user_id=...` authentication,
mid-hand joins corrupting active players' cards, no side-pot settlement, Erlang
distribution listening on `0.0.0.0`, no chat or action rate limits, silent
truncation of oversized chat, hand persistence outside a transaction, public
APIs starting table processes as a side effect, unparsed room IDs raising out of
controllers and channels, and spectator mode enforced inconsistently across
LiveView, the controller and the channel.
