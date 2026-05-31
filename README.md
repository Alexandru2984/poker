# MicuPoker

MicuPoker is a production Phoenix application for a real-time multiplayer Texas Hold'em demo at `https://poker.micutu.com`.

This is play-money only. Chips are virtual demo chips with no real-world value. The app has no deposits, withdrawals, payments, cash-out, crypto, casino monetization, or real-money gambling support. Any future real-money feature requires legal and compliance review before implementation.

## Features

- Guest-mode identity with editable display names.
- Dark lobby with room filters and strict table creation validation.
- Real-time poker table using Phoenix LiveView, Phoenix Channels, PubSub, and a GenServer per table.
- Server-authoritative deck, private hole cards, turns, action validation, stack changes, pot, showdown, and winner calculation.
- Real card faces with suit symbols, own-hand summaries, board texture hints, and best-five display after enough board cards.
- Table chat with message length validation.
- Spectator-safe public table state: other players' private cards are hidden before showdown.
- `/health`, JSON room/stats APIs, and `/docs`.

## Stack

- Elixir, Erlang/OTP, Phoenix 1.7, LiveView.
- PostgreSQL via Ecto.
- Nginx reverse proxy with WebSocket upgrade support.
- Systemd service: `micupoker.service`.
- Let's Encrypt certificate via Certbot.

## Build And Run

From `/home/micu/poker`:

```bash
set -a; . ./.env; set +a
mix deps.get
mix compile
mix test
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix ecto.migrate
MIX_ENV=prod mix release
```

The production release starts with:

```bash
_build/prod/rel/micu_poker/bin/micu_poker start
```

In production, systemd runs it instead:

```bash
sudo systemctl status micupoker.service
sudo journalctl -u micupoker.service -f
sudo systemctl restart micupoker.service
```

## Environment

Runtime values live in `.env`, which is ignored by Git. Do not commit it.

Required variables:

- `PHX_HOST=poker.micutu.com`
- `PORT=4100`
- `BIND_IP=127.0.0.1`
- `DATABASE_URL=postgresql://.../micupoker`
- `SECRET_KEY_BASE=...`
- `POOL_SIZE=10`
- `PHX_SERVER=true`
- `PLAY_MONEY_ONLY=true`
- `DEFAULT_STARTING_CHIPS=1000`
- `DEFAULT_SMALL_BLIND=5`
- `DEFAULT_BIG_BLIND=10`
- `TURN_TIMEOUT_SECONDS=30`
- `DISCONNECT_GRACE_SECONDS=60`
- `MAX_ROOMS=100`
- `MAX_PLAYERS_PER_ROOM=9`
- `MAX_CHAT_MESSAGE_LENGTH=300`

## PostgreSQL

Production database: `micupoker`.

Production user: `micupoker_user`.

Test database: `micupoker_test`.

The database password is stored only in `.env`.

## Deployment

- Public URL: `https://poker.micutu.com`
- Local bind: `127.0.0.1:4100`
- Nginx config: `/etc/nginx/sites-available/poker.micutu.com`
- Enabled symlink: `/etc/nginx/sites-enabled/poker.micutu.com`
- Systemd unit: `/etc/systemd/system/micupoker.service`
- Example unit in repo: `systemd/micupoker.service.example`
- The systemd unit sets `RELEASE_DISTRIBUTION=none` so the release does not expose an Erlang distribution port.

Certbot's Nginx plugin cannot parse the existing global CrowdSec Lua config on this VPS, so the certificate was issued with the webroot method and the SSL server block was installed manually.

## API Routes

- `GET /health`
- `GET /`
- `GET /lobby`
- `GET /rooms/:id`
- `POST /rooms`
- `POST /rooms/:id/join`
- `POST /rooms/:id/leave`
- `GET /docs`
- `GET /api/rooms`
- `GET /api/rooms/:id`
- `GET /api/stats`

`/health` returns only:

```json
{"status":"ok","service":"micupoker"}
```

## WebSocket Protocol

- Endpoint: `/socket`
- Phoenix topic: `table:<room_id>`
- Browser pages include a signed `<meta name="socket-token">`; channel clients must connect with `?token=<signed_token>`. Raw `user_id` query parameters are rejected.
- Events:
  - `phx_join`
  - `state`
  - `action` with `{ "action": "fold|check|call|bet|raise|all_in", "amount": 100 }`
  - `chat` with `{ "message": "..." }`

LiveView uses Phoenix's standard `/live` WebSocket.

## Poker Rules Implemented

- 52-card secure shuffle.
- Texas Hold'em hole cards and community cards.
- Dealer rotation, blinds, preflop/flop/turn/river betting rounds.
- Fold, check, call, bet, raise, and heads-up all-in.
- Showdown evaluator for high card, pair, two pair, trips, straight, flush, full house, quads, straight flush, royal flush.
- Split pots for tied winners in the main pot.

## Known Limitations

- Full multi-player side-pot logic is not implemented in v1. Heads-up all-in is supported; larger all-in side pots are documented TODO and not silently claimed as complete.
- Guest mode is used instead of email/password accounts.
- Password-protected rooms are disabled in v1 until full access control is implemented.
- Disconnect grace is configured, but v1 reconnect handling is basic.

## Security And Fairness

- Phoenix binds only to `127.0.0.1`; Nginx is the public entry point.
- Erlang distribution is disabled in systemd; only the Phoenix HTTP listener is open locally.
- Nginx adds security headers and proxies WebSockets.
- The server owns deck, cards, turns, pot, stacks, and winners.
- Clients never receive other players' private cards before showdown.
- Chat and display names are length/format constrained and HTML-escaped by Phoenix templates.
- No shell commands are executed from web requests.
- No secrets are exposed in frontend code, README, or public APIs.

## Troubleshooting

```bash
sudo systemctl status micupoker.service
sudo journalctl -u micupoker.service -n 100 --no-pager
sudo nginx -t
curl -fsS http://127.0.0.1:4100/health
curl -fsS https://poker.micutu.com/health
scripts/deploy_check.sh
```

## Git

Git commits, pushes, and staging are manual. The agent did not run `git add`, `git commit`, or `git push`.
