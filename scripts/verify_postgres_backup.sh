#!/usr/bin/env bash
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "run this restore drill as root" >&2; exit 1; }

dump_file="${1:-}"
if [[ -z "$dump_file" || ! -f "$dump_file" ]]; then
  echo "usage: $0 /var/backups/micupoker/micupoker_TIMESTAMP.dump" >&2
  exit 2
fi

dump_file=$(readlink -f "$dump_file")
case "$dump_file" in
  /var/backups/micupoker/micupoker_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.dump) ;;
  *) echo "refusing unexpected backup path: $dump_file" >&2; exit 1 ;;
esac

checksum="$dump_file.sha256"
[[ -f "$checksum" ]] || { echo "backup checksum is missing" >&2; exit 1; }
[[ "$(stat -c '%U:%G:%a' "$dump_file")" == "micupoker-backup:micupoker-backup:600" ]] || {
  echo "backup ownership or mode is unsafe" >&2
  exit 1
}
[[ "$(stat -c '%U:%G:%a' "$checksum")" == "micupoker-backup:micupoker-backup:600" ]] || {
  echo "checksum ownership or mode is unsafe" >&2
  exit 1
}

expected_checksum_target=$(basename "$dump_file")
[[ "$(wc -l <"$checksum")" -eq 1 ]] || {
  echo "checksum file must contain exactly one record" >&2
  exit 1
}
recorded_checksum=$(awk 'NR == 1 {print $1}' "$checksum")
recorded_checksum_target=$(awk 'NR == 1 {print $2}' "$checksum")
[[ "$recorded_checksum" =~ ^[0-9a-f]{64}$ ]] || {
  echo "checksum record is malformed" >&2
  exit 1
}
[[ "$recorded_checksum_target" == "$expected_checksum_target" ]] || {
  echo "checksum references an unexpected file" >&2
  exit 1
}
(
  cd "$(dirname "$dump_file")"
  sha256sum --check --status "$(basename "$checksum")"
)
pg_restore --list "$dump_file" >/dev/null

restore_db="micupoker_restore_$(date -u +%Y%m%d%H%M%S)_$$"
restore_role="${restore_db}_role"
[[ "$restore_db" =~ ^micupoker_restore_[0-9]{14}_[0-9]+$ ]] || {
  echo "invalid restore database name" >&2
  exit 1
}
[[ "$restore_role" =~ ^micupoker_restore_[0-9]{14}_[0-9]+_role$ ]] || {
  echo "invalid restore role name" >&2
  exit 1
}

cleanup_restore() {
  runuser -u postgres -- dropdb --if-exists "$restore_db" >/dev/null 2>&1 || true
  runuser -u postgres -- psql -X -d postgres -c \
    "drop role if exists \"$restore_role\"" >/dev/null 2>&1 || true
}
trap cleanup_restore EXIT

runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres -c \
  "create role \"$restore_role\" nologin nosuperuser nocreatedb nocreaterole noreplication"
runuser -u postgres -- createdb --template=template0 --owner="$restore_role" "$restore_db"
runuser -u postgres -- pg_restore \
  --exit-on-error \
  --no-owner \
  --no-privileges \
  --role "$restore_role" \
  --dbname "$restore_db" <"$dump_file"

runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d "$restore_db" -Atqc "
  set role \"$restore_role\";
  select 'schema_migrations='||count(*)||'|latest='||coalesce(max(version)::text,'none')
    from schema_migrations;
  select 'rows|users='||(select count(*) from users)||
    '|rooms='||(select count(*) from rooms)||
    '|hands='||(select count(*) from hands)||
    '|actions='||(select count(*) from hand_actions)||
    '|ledger='||(select count(*) from chip_ledger)||
    '|tokens='||(select count(*) from user_tokens);
  select 'invalid_constraints='||count(*) from pg_constraint where not convalidated;
  select 'nonzero_hand_ledgers='||count(*) from (
    select hand_id from chip_ledger where hand_id is not null
    group by hand_id having sum(delta) <> 0
  ) inconsistent;
"

invalid_constraints=$(runuser -u postgres -- psql -X -d "$restore_db" -Atqc \
  "set role \"$restore_role\"; select count(*) from pg_constraint where not convalidated")
nonzero_ledgers=$(runuser -u postgres -- psql -X -d "$restore_db" -Atqc \
  "set role \"$restore_role\"; select count(*) from (select hand_id from chip_ledger where hand_id is not null group by hand_id having sum(delta) <> 0) inconsistent")
[[ "$invalid_constraints" == "0" && "$nonzero_ledgers" == "0" ]]

echo "backup_restore=passed database=$restore_db"
