#!/usr/bin/env bash
#
# Post-deploy verification. Checks the things that break silently: a header the
# app stopped sending, a proxy that forgot to upgrade WebSockets, an origin that
# became reachable without Cloudflare.

set -euo pipefail

cd /home/micu/poker
set -a
# shellcheck disable=SC1091
. ./.env
set +a

ORIGIN="http://127.0.0.1:${PORT}"
PUBLIC="https://${PHX_HOST}"
ORIGIN_IP="${ORIGIN_IP:-185.254.97.77}"

failures=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

echo "Service"
if systemctl is-active --quiet micupoker.service; then
  ok "micupoker.service is active"
else
  fail "micupoker.service is not active"
fi

echo "Origin ($ORIGIN)"
if curl -fsS --max-time 5 "$ORIGIN/health" >/dev/null; then
  ok "/health responds on loopback"
else
  fail "/health does not respond on loopback"
fi

echo "Public ($PUBLIC)"
if curl -fsS --max-time 10 "$PUBLIC/health" >/dev/null; then
  ok "/health responds publicly"
else
  fail "/health does not respond publicly"
fi

resolved=$(dig +short "$PHX_HOST" A | head -1)
if [[ "$resolved" =~ ^(104\.(1[6-9]|2[0-9]|3[01])\.|172\.6[4-9]\.|172\.7[0-1]\.|173\.245\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|103\.2[12]\.|103\.31\.|131\.0\.72\.) ]]; then
  ok "$PHX_HOST is proxied by Cloudflare ($resolved)"
else
  fail "$PHX_HOST is not proxied by Cloudflare ($resolved)"
fi

direct_code=$(curl -ksS --http1.1 --max-time 8 --resolve "$PHX_HOST:443:$ORIGIN_IP" \
  -o /dev/null -w '%{http_code}' "$PUBLIC/" 2>/dev/null || true)
if [[ "$direct_code" == "000" || "$direct_code" == "403" ]]; then
  ok "direct origin is denied"
else
  fail "direct origin returned $direct_code"
fi

headers=$(curl -fsSI --max-time 10 "$PUBLIC/" || true)

check_header() {
  local name="$1" pattern="$2"
  if grep -qi "^${name}:.*${pattern}" <<<"$headers"; then
    ok "$name"
  else
    fail "$name missing or unexpected"
  fi
}

echo "Security headers"
check_header "content-security-policy" "default-src 'self'"
check_header "strict-transport-security" "max-age="
check_header "x-frame-options" "DENY"
check_header "x-content-type-options" "nosniff"
check_header "referrer-policy" "strict-origin"
check_header "cross-origin-opener-policy" "same-origin"

# Two CSP headers mean nginx is adding its own again; the browser then enforces
# the intersection, which is confusing at best and broken at worst.
if [[ $(grep -ci "^content-security-policy:" <<<"$headers") -gt 1 ]]; then
  fail "content-security-policy is sent twice (nginx is duplicating the app header)"
else
  ok "content-security-policy is sent once"
fi

echo "Pages"
for path in / /lobby /leaderboard /docs /login /register; do
  code=$(curl -fsS --max-time 10 -o /dev/null -w "%{http_code}" "$PUBLIC$path" || echo 000)
  if [[ "$code" == "200" ]]; then
    ok "$path -> 200"
  else
    fail "$path -> $code"
  fi
done

echo "Admin"
code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" "$PUBLIC/admin/dashboard" || echo 000)
case "$code" in
  401) ok "/admin/dashboard requires authentication" ;;
  404) ok "/admin/dashboard is unmounted (ADMIN_USER/ADMIN_PASSWORD unset)" ;;
  *)   fail "/admin/dashboard -> $code (expected 401 or 404)" ;;
esac

echo "WebSockets"
probe_dir=$(mktemp -d)
cookie_file="$probe_dir/cookies"
lobby_file="$probe_dir/lobby"

cleanup_probe() {
  rm -f -- "$cookie_file" "$lobby_file"
  rmdir -- "$probe_dir" 2>/dev/null || true
}
trap cleanup_probe EXIT

if curl -fsS --max-time 10 -c "$cookie_file" "$PUBLIC/lobby" >"$lobby_file"; then
  socket_token=$(sed -n 's/.*<meta name="socket-token" content="\([^"]*\)".*/\1/p' \
    "$lobby_file" | head -1)
else
  socket_token=""
fi

websocket_status() {
  local origin="$1"
  local origin_args=()
  if [[ -n "$origin" ]]; then
    origin_args=(-H "Origin: $origin")
  fi

  curl -ksS --http1.1 --max-time 3 -b "$cookie_file" -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${origin_args[@]}" \
    "$PUBLIC/socket/websocket?token=$socket_token&vsn=2.0.0" 2>/dev/null || true
}

websocket_local_denial_status() {
  local origin="$1"
  local origin_args=()
  if [[ -n "$origin" ]]; then
    origin_args=(-H "Origin: $origin")
  fi

  curl -ksS --http1.1 --max-time 3 --resolve "$PHX_HOST:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${origin_args[@]}" \
    "$PUBLIC/socket/websocket?token=invalid&vsn=2.0.0" 2>/dev/null || true
}

if [[ -z "$socket_token" ]]; then
  fail "could not obtain a signed socket token"
else
  good_origin=$(websocket_status "$PUBLIC")
  bad_origin=$(websocket_status "https://evil.example")
  missing_origin=$(websocket_status "")
  local_bad_origin=$(websocket_local_denial_status "https://evil.example")
  local_missing_origin=$(websocket_local_denial_status "")

  if [[ "$good_origin" == "101" ]]; then
    ok "approved Origin -> 101"
  else
    fail "approved Origin -> $good_origin"
  fi

  case "$bad_origin" in
    403|502) ok "hostile Origin is blocked (edge status $bad_origin)" ;;
    *) fail "hostile Origin -> $bad_origin" ;;
  esac

  case "$missing_origin" in
    403|502) ok "missing Origin is blocked (edge status $missing_origin)" ;;
    *) fail "missing Origin -> $missing_origin" ;;
  esac

  if [[ "$local_bad_origin" == "403" && "$local_missing_origin" == "403" ]]; then
    ok "nginx rejects hostile and missing Origin with 403"
  else
    fail "nginx Origin gate -> hostile=$local_bad_origin missing=$local_missing_origin"
  fi
fi

echo
if [[ "$failures" -gt 0 ]]; then
  printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
  exit 1
fi

printf '\033[32mmicupoker deployment checks passed\033[0m\n'
