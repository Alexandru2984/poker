#!/usr/bin/env bash
#
# MicuPoker production deploy.
#
#   ./scripts/deploy.sh            full deploy
#   ./scripts/deploy.sh --dry-run  build and migrate, but do not restart
#
# Ordering matters: the release is built and the migrations run BEFORE the
# service is restarted, so a build failure or a bad migration leaves the running
# node untouched. The restart is the last reversible step.

set -euo pipefail

APP_DIR=/home/micu/poker
SERVICE=micupoker.service
RELEASE="$APP_DIR/_build/prod/rel/micu_poker/bin/micu_poker"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

cd "$APP_DIR"

if [[ ! -f .env ]]; then
  echo "error: .env is missing. Copy .env.example and fill it in." >&2
  exit 1
fi

# Secrets must not be world-readable; systemd reads this file as root.
perms=$(stat -c "%a" .env)
if [[ "$perms" != "600" ]]; then
  echo "error: .env is mode $perms, expected 600. Run: chmod 600 .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

export MIX_ENV=prod

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

step "Verifying the working tree is committed"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "warning: uncommitted changes are about to be deployed:" >&2
  git status --short >&2
fi
git --no-pager log -1 --oneline

step "Fetching dependencies"
mix deps.get --only prod

step "Compiling"
mix compile --warnings-as-errors

step "Building assets"
mix assets.deploy

step "Running migrations"
# Applied against the live database before the new code starts, so every
# migration must be backwards compatible with the code currently running.
mix ecto.migrate

step "Building the release"
mix release --overwrite

if [[ "$DRY_RUN" == "1" ]]; then
  step "Dry run: skipping restart"
  exit 0
fi

step "Restarting $SERVICE"
sudo systemctl restart "$SERVICE"

step "Waiting for the node to answer"
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "healthy after ${attempt}s"
    break
  fi
  if [[ "$attempt" == "30" ]]; then
    echo "error: no health response after 30s. Recent logs:" >&2
    sudo journalctl -u "$SERVICE" -n 50 --no-pager >&2
    exit 1
  fi
  sleep 1
done

step "Post-deploy checks"
"$APP_DIR/scripts/deploy_check.sh"
