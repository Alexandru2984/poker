# MicuPoker

Real-time multiplayer Texas Hold'em, running at `https://poker.micutu.com`.

Play money only. Chips are virtual and have no real-world value. There are no
deposits, withdrawals, payments, cash-out, crypto, or casino monetization
anywhere in the codebase, and any future real-money feature would need legal and
compliance review before it was written.

## What it does

**Table.** A GenServer owns each table. It holds the deck, deals, runs the
betting round, evaluates the showdown and settles the pot. Clients send
intentions; the server decides what happened. A player's hole cards exist only
in that process and in the socket of the player who holds them.

**Rules.** 52-card shuffle from `:crypto.strong_rand_bytes`, blinds and button
rotation by seat, the four betting streets, fold/check/call/bet/raise/all-in,
min-raise enforcement, a short all-in that does not reopen betting, the big
blind's option, uncalled-bet return, side pots and split pots, and a full
seven-card evaluator from high card to royal flush.

**Seats.** Sit out and sit back in between hands, buy back in after busting,
a disconnect grace period that holds your seat and stack, and reference-counted
connections so closing one tab does not disconnect a player who has another open.

**Identity.** Registered accounts with a username and password, or a guest seat
that needs no signup. A guest can be upgraded to an account in place without
losing their name or chips.

**Around the table.** Chat, an action log, hand history, per-player statistics,
a leaderboard, password-protected tables, spectator mode, and an invite link.

**Interface.** Built mobile-first. The table is drawn viewer-relative — you are
always at the bottom of the felt — with tap targets sized for a thumb, a sticky
action bar above the safe area, and keyboard shortcuts on desktop.

## Stack

Elixir 1.18 / OTP 27, Phoenix 1.7 with LiveView, PostgreSQL via Ecto, Bandit,
Tailwind and esbuild. nginx terminates TLS in front of it, behind Cloudflare.
systemd runs the release.

## Running it locally

```bash
cp .env.example .env      # then fill in DATABASE_URL and SECRET_KEY_BASE
chmod 600 .env
set -a; . ./.env; set +a

mix setup                 # deps, database, assets
mix test
mix phx.server
```

`mix setup` creates the database and runs migrations. The dev server listens on
`http://localhost:4000`.

## Configuration

Every setting lives in `.env`, which is git-ignored. `.env.example` documents
each variable, its default and what it affects.

Two classes of setting, deliberately:

- **Boot-time** (`DATABASE_URL`, `SECRET_KEY_BASE`, `PORT`, `BIND_IP`,
  `POOL_SIZE`) abort the boot when missing or malformed. A release that came up
  on the wrong port would look healthy to systemd while being unreachable.
- **Runtime** (everything else) is read through `MicuPoker.Config`, which falls
  back to its documented default when a value is missing or nonsensical. A typo
  in a blind size must not take the node down in the middle of a hand.

## Deploying

```bash
./scripts/deploy.sh --dry-run   # build and migrate, do not restart
./scripts/deploy.sh             # full deploy
```

The script builds assets, runs migrations and builds the release *before*
touching the running service, so a failure at any of those steps leaves the live
node alone. After the restart it polls `/health` and then runs the post-deploy
checks.

```bash
./scripts/deploy_check.sh
```

That verifies the service is active, `/health` answers on loopback and through
Cloudflare, every security header is present and not duplicated, the public
pages return 200, and `/admin/dashboard` is either authenticated or unmounted.

### Infrastructure

Config lives in the repo and is copied into place:

| Repo | Installed as |
| --- | --- |
| `deploy/nginx/poker.micutu.com.conf` | `/etc/nginx/sites-available/poker.micutu.com` |
| `deploy/nginx/micupoker-limits.conf` | `/etc/nginx/conf.d/micupoker-limits.conf` |
| `systemd/micupoker.service.example` | `/etc/systemd/system/micupoker.service` |

The vhost depends on the host-wide `conf.d/cloudflare-realip.conf` and
`conf.d/cloudflare-origin-guard.conf`, which are shared with the other sites on
this machine and are not duplicated here.

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl daemon-reload && sudo systemctl restart micupoker
systemd-analyze security micupoker.service   # after any unit change
```

The unit runs the release under a systemd sandbox: no capabilities, a read-only
filesystem apart from the app directory, a private `/tmp`, a filtered syscall
set and no Erlang distribution port. It deliberately does **not** set
`MemoryDenyWriteExecute` — the BEAM's JIT maps executable pages and the VM will
not start without them.

## Routes

| Route | Notes |
| --- | --- |
| `GET /` | Landing page. Static; creates no guest user. |
| `GET /lobby` | Table list and creation. |
| `GET /rooms/:id` | The table. LiveView. |
| `GET /leaderboard` | Rankings, plus your own numbers when signed in. |
| `GET /login`, `/register` | Accounts. Rate limited per IP and per username. |
| `GET /docs` | Rules and house policy. |
| `GET /health` | `{"status":"ok","service":"micupoker"}` |
| `GET /api/rooms`, `/api/rooms/:id`, `/api/stats` | Read-only JSON. |
| `GET /admin/dashboard` | LiveDashboard. 404 unless `ADMIN_USER` and a 16-byte `ADMIN_PASSWORD` are set. |

Public pages and the JSON API never insert a `users` row, so crawler traffic
does not grow the database.

### WebSocket

LiveView uses Phoenix's `/live` socket. The table channel is at `/socket`,
topic `table:<room_id>`.

Pages carry a signed `<meta name="socket-token">`; the channel client connects
with `?token=<signed_token>`. A raw `user_id` parameter is rejected — otherwise
anyone could act as anyone. Unknown topics return `room_not_found`, malformed
payloads return `invalid_payload`, and unknown events return `unknown_event`,
none of which raise.

Events: `phx_join`, `state`, `action` with
`{"action": "fold|check|call|bet|raise|all_in", "amount": 100}`, and `chat` with
`{"message": "..."}`.

## Database

Production `micupoker`, test `micupoker_test`, user `micupoker_user`. The
password is only ever in `.env`.

Finished hands write to `hands`, `hand_actions` and a zero-sum `chip_ledger`,
which is what the stats and leaderboard read back. Persisted winner summaries
carry no internal user IDs; the ledger keeps them for audit.

## Security

See [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the threat model, what was found
and fixed, and what is deliberately out of scope.

## Troubleshooting

```bash
sudo systemctl status micupoker.service
sudo journalctl -u micupoker.service -n 100 --no-pager
sudo nginx -t
curl -fsS http://127.0.0.1:4100/health
./scripts/deploy_check.sh
```

Certbot's nginx plugin cannot parse the global CrowdSec Lua config on this VPS,
so the certificate was issued with the webroot method and the TLS server block
was installed by hand. Renewals use webroot; do not switch the plugin.
