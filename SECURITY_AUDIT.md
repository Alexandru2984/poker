# MicuPoker Security Audit

Date: 2026-05-31

Scope: Phoenix app code, realtime socket authorization, card privacy, action validation, deployment binding, Nginx proxying, and play-money constraints.

## Fixed During Audit

- Removed `/socket?user_id=...` authentication. Phoenix Channels now require the signed session or a server-signed socket token.
- Fixed mid-hand joins so a late player waits for the next hand instead of corrupting in-memory cards for active players.
- Added explicit `Your Hand` UI so each device can see its own cards clearly.
- Added hand summaries, board texture hints, and best-five display so pairs, flushes, straights, and stronger made hands are visible to the correct player.
- Added tests for multi-user card isolation, late-join behavior, mobile layout guardrails, hand summaries, signed socket tokens, and socket impersonation rejection.
- Disabled Erlang distribution in systemd so the release no longer opens a random BEAM listener on `0.0.0.0`.

## Current Protections

- The Phoenix release binds only to `127.0.0.1`, with Erlang distribution disabled.
- Nginx is the public HTTPS reverse proxy and includes WebSocket upgrade headers.
- `/health` returns minimal JSON and does not create a guest session.
- The server owns deck, hole cards, turns, legal actions, pot state, and winner calculation.
- PubSub broadcasts are sanitized; LiveView and Channel clients fetch personalized table state server-side.
- Spectators and waiting players receive no action buttons and no private cards.
- No real-money gambling features exist.

## Remaining Risks / TODO

- Full multiplayer side-pot accounting is not implemented yet.
- Guest identity is cookie/session based; persistent username/password accounts are not implemented.
- Password-protected rooms are disabled in v1 and incoming room password values are ignored until full access control is implemented with a proper password hashing library.
- Add per-user chat/action rate limiting before larger public use.
- Add automated browser-based mobile regression tests in CI if this project later gets CI infrastructure.
