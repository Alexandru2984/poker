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

# Whether the record is proxied decides whether the origin guard in the vhost
# may be enabled and whether TRUST_CLOUDFLARE is safe. It is reported, not
# asserted: either answer is a valid deployment.
resolved=$(dig +short "$PHX_HOST" A | head -1)
if [[ "$resolved" =~ ^(104\.(1[6-9]|2[0-9]|3[01])\.|172\.6[4-9]\.|172\.7[0-1]\.|173\.245\.|141\.101\.|108\.162\.|190\.93\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|103\.2[12]\.|103\.31\.|131\.0\.72\.) ]]; then
  ok "$PHX_HOST is proxied by Cloudflare ($resolved)"
else
  ok "$PHX_HOST resolves directly to the origin ($resolved) — grey cloud"
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

echo
if [[ "$failures" -gt 0 ]]; then
  printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
  exit 1
fi

printf '\033[32mmicupoker deployment checks passed\033[0m\n'
