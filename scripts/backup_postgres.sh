#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:?PGHOST is required}"
: "${PGPORT:?PGPORT is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

BACKUP_DIR="${MICUPOKER_BACKUP_DIR:-/var/backups/micupoker}"
RETENTION_DAYS="${MICUPOKER_BACKUP_RETENTION_DAYS:-30}"
[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]{0,2}$ ]] || {
  echo "MICUPOKER_BACKUP_RETENTION_DAYS must be between 1 and 999" >&2
  exit 1
}

[[ -d "$BACKUP_DIR" && ! -L "$BACKUP_DIR" ]] || {
  echo "backup directory must be a real directory: $BACKUP_DIR" >&2
  exit 1
}
[[ "$(stat -c '%u:%a' "$BACKUP_DIR")" == "$(id -u):700" ]] || {
  echo "backup directory must be owned by the service identity with mode 0700" >&2
  exit 1
}

umask 077
exec 9>"$BACKUP_DIR/.backup.lock"
flock -n 9 || { echo "another MicuPoker backup is already running" >&2; exit 1; }

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
final="$BACKUP_DIR/micupoker_${timestamp}.dump"
checksum="$final.sha256"
[[ ! -e "$final" && ! -e "$checksum" ]] || {
  echo "refusing to overwrite an existing backup" >&2
  exit 1
}
temporary=$(mktemp "$BACKUP_DIR/.micupoker_${timestamp}.XXXXXX")
checksum_temporary=$(mktemp "$BACKUP_DIR/.micupoker_${timestamp}.sha256.XXXXXX")

cleanup() {
  rm -f -- "$temporary" "$checksum_temporary"
}
trap cleanup EXIT

pg_dump \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-acl \
  --serializable-deferrable \
  --file "$temporary" \
  "$PGDATABASE"
pg_restore --list "$temporary" >/dev/null
chmod 0600 "$temporary"
mv -- "$temporary" "$final"
(
  cd "$BACKUP_DIR"
  sha256sum "$(basename "$final")" >"$(basename "$checksum_temporary")"
)
chmod 0600 "$checksum_temporary"
mv -- "$checksum_temporary" "$checksum"

find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'micupoker_*.dump' -o -name 'micupoker_*.dump.sha256' \) \
  -mtime "+$RETENTION_DAYS" -delete

echo "backup=created file=$final"
