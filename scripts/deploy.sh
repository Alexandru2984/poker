#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${MICUPOKER_DEPLOY_BRANCH:-main}"
SERVICE="${MICUPOKER_SERVICE:-micupoker.service}"
RELEASE_ROOT="${MICUPOKER_RELEASE_ROOT:-/opt/micupoker}"
LOCK_FILE="${MICUPOKER_DEPLOY_LOCK:-/tmp/micupoker-deploy.lock}"
BUILD_ENV="${MICUPOKER_BUILD_ENV:-/etc/micupoker/build.env}"
BUILD_ONLY=false

case "${1:-}" in
  "") ;;
  --build-only) BUILD_ONLY=true ;;
  *) echo "usage: $0 [--build-only]" >&2; exit 2 ;;
esac

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

for command in curl flock git mix nginx sha256sum shellcheck sudo systemctl; do
  require_command "$command"
done

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "another MicuPoker deploy holds $LOCK_FILE" >&2; exit 1; }

cd "$ROOT_DIR"
[[ -z "$(git status --porcelain)" ]] || {
  echo "refusing deploy from a dirty working tree" >&2
  git status --short >&2
  exit 1
}
[[ "$(git branch --show-current)" == "$BRANCH" ]] || {
  echo "refusing deploy outside branch $BRANCH" >&2
  exit 1
}

release_sha=$(git rev-parse --verify 'HEAD^{commit}')
release_id="${release_sha:0:12}-$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$release_id" =~ ^[0-9a-f]{12}-[0-9]{8}T[0-9]{6}Z$ ]] || {
  echo "invalid release identifier" >&2
  exit 1
}

if [[ ! -r "$BUILD_ENV" ]]; then
  BUILD_ENV="$ROOT_DIR/.env"
fi
[[ -r "$BUILD_ENV" ]] || { echo "no readable build environment" >&2; exit 1; }

temporary_root=$(mktemp -d /tmp/micupoker-build.XXXXXX)
build_dir="$temporary_root/repo"
worktree_added=false

cleanup_build() {
  set +e
  if [[ "$worktree_added" == "true" ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$build_dir" >/dev/null 2>&1
  fi
  rmdir -- "$temporary_root" >/dev/null 2>&1 || true
}
trap cleanup_build EXIT

git worktree add --detach "$build_dir" "$release_sha"
worktree_added=true

(
  set -a
  # shellcheck disable=SC1090
  source "$BUILD_ENV"
  set +a
  : "${TEST_DATABASE_URL:?TEST_DATABASE_URL is required for the deploy test gate}"

  cd "$build_dir"
  mix deps.get
  env MIX_ENV=test mix test
  env MIX_ENV=prod mix deps.get --only prod
  env MIX_ENV=prod mix compile --warnings-as-errors
  env MIX_ENV=prod mix assets.deploy
  env MIX_ENV=prod mix release --overwrite
  mix hex.audit
  mix deps.unlock --check-unused
  mix format --check-formatted
  shellcheck scripts/*.sh
)

if [[ "$BUILD_ONLY" == "true" ]]; then
  echo "build_gate=passed commit=$release_sha"
  exit 0
fi

sudo -n true >/dev/null 2>&1 || { echo "non-interactive sudo is required" >&2; exit 1; }
for path in \
  /etc/micupoker/app.env \
  /etc/micupoker/credentials/database_url \
  /etc/micupoker/credentials/migrate_database_url \
  /etc/micupoker/credentials/secret_key_base \
  /etc/micupoker/credentials/admin_password; do
  sudo test -s "$path" || { echo "required production configuration is missing: $path" >&2; exit 1; }
done

release="$RELEASE_ROOT/releases/$release_id"
previous=$(readlink -f "$RELEASE_ROOT/current" 2>/dev/null || true)
rollback_dir="/home/micu/backups/service-migrations/micupoker-deploy-$release_id"
switched=false
deploy_ok=false
unit_installed=false

rollback() {
  if [[ "$deploy_ok" == "true" ]]; then
    return
  fi

  set +e
  if [[ "$switched" == "true" && -n "$previous" && -d "$previous" ]]; then
    echo "deploy failed; restoring release $previous" >&2
    sudo ln -s "$previous" "$RELEASE_ROOT/.rollback-$release_id"
    sudo mv -Tf "$RELEASE_ROOT/.rollback-$release_id" "$RELEASE_ROOT/current"
    sudo systemctl restart "$SERVICE"
  elif [[ "$unit_installed" == "true" && -f "$rollback_dir/micupoker.service" ]]; then
    echo "initial deploy failed; restoring the legacy service unit" >&2
    sudo cp -a "$rollback_dir/micupoker.service" /etc/systemd/system/micupoker.service
    sudo systemctl daemon-reload
    if [[ "$switched" == "true" ]]; then
      sudo systemctl restart "$SERVICE"
    fi
  fi
}
trap 'rollback; cleanup_build' EXIT

sudo test ! -e "$release"
sudo install -d -o root -g root -m 0755 "$RELEASE_ROOT" "$RELEASE_ROOT/releases" "$release"
sudo cp -a "$build_dir/_build/prod/rel/micu_poker/." "$release/"
printf '%s\n' "$release_sha" | sudo tee "$release/.release-commit" >/dev/null
sudo chown -R root:root "$release"
sudo bash -c 'cd "$1" && find . -type f ! -name .release-manifest.sha256 -print0 | sort -z | xargs -0 sha256sum >.release-manifest.sha256' -- "$release"
sudo find "$release" -type d -exec chmod 0555 {} +
sudo find "$release" -type f -exec chmod a-w {} +
"$ROOT_DIR/scripts/verify_release.sh" "$release"

sudo install -d -o root -g root -m 0700 "$rollback_dir"
if sudo test -f /etc/systemd/system/micupoker.service; then
  sudo cp -a /etc/systemd/system/micupoker.service "$rollback_dir/micupoker.service"
fi
printf '%s\n' "$previous" | sudo tee "$rollback_dir/previous-release" >/dev/null

sudo install -o root -g root -m 0644 \
  "$ROOT_DIR/systemd/micupoker.service.example" \
  /etc/systemd/system/micupoker.service
sudo install -o root -g root -m 0644 \
  "$ROOT_DIR/systemd/micupoker-migrate@.service.example" \
  /etc/systemd/system/micupoker-migrate@.service
unit_installed=true
sudo nginx -t
sudo systemctl daemon-reload

if systemctl list-unit-files micupoker-backup.service --no-legend 2>/dev/null | grep -q micupoker-backup; then
  sudo systemctl start micupoker-backup.service
fi

sudo systemctl reset-failed "micupoker-migrate@$release_id.service" >/dev/null 2>&1 || true
sudo systemctl start "micupoker-migrate@$release_id.service"

sudo ln -s "$release" "$RELEASE_ROOT/.next-$release_id"
sudo mv -Tf "$RELEASE_ROOT/.next-$release_id" "$RELEASE_ROOT/current"
switched=true
sudo systemctl restart "$SERVICE"

for _attempt in {1..80}; do
  if curl -fsS --max-time 2 http://127.0.0.1:4100/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

curl -fsS --max-time 2 http://127.0.0.1:4100/health >/dev/null
"$ROOT_DIR/scripts/deploy_check.sh"
"$ROOT_DIR/scripts/verify_release.sh" "$release"

[[ "$(systemctl show "$SERVICE" -p User --value)" == "micupoker" ]]
main_pid=$(systemctl show "$SERVICE" -p MainPID --value)
process_exe=$(sudo readlink -f "/proc/$main_pid/exe")
[[ "$process_exe" == "$release"/* ]]

deploy_ok=true
echo "release=$release_id status=healthy rollback=$rollback_dir"
