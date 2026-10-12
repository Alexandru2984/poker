#!/usr/bin/env bash
set -euo pipefail

SERVICE="${MICUPOKER_HEALTH_SERVICE:-micupoker.service}"
BACKUP_SERVICE="${MICUPOKER_BACKUP_SERVICE:-micupoker-backup.service}"
BACKUP_TIMER="${MICUPOKER_BACKUP_TIMER:-micupoker-backup.timer}"
LOCAL_URL="${MICUPOKER_HEALTH_LOCAL_URL:-http://127.0.0.1:4100/health}"
PUBLIC_URL="${MICUPOKER_HEALTH_PUBLIC_URL:-https://poker.micutu.com/health}"
RELEASE_ROOT="${MICUPOKER_RELEASE_ROOT:-/opt/micupoker}"
STATE_DIR="${MICUPOKER_MONITOR_STATE_DIR:-/var/lib/micupoker-monitor}"
MAX_RESTARTS="${MICUPOKER_MAX_RESTARTS_PER_INTERVAL:-3}"
BACKUP_MAX_AGE_HOURS="${MICUPOKER_BACKUP_MAX_AGE_HOURS:-36}"

for value in "$MAX_RESTARTS" "$BACKUP_MAX_AGE_HOURS"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "healthcheck thresholds must be non-negative integers" >&2
    exit 2
  }
done

problems=()
note() { problems+=("$1"); }

if ! systemctl is-active --quiet "$SERVICE"; then
  note "$SERVICE is not active"
fi

service_user=$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)
service_group=$(systemctl show "$SERVICE" -p Group --value 2>/dev/null || true)
if [[ "$service_user" != "micupoker" || "$service_group" != "micupoker" ]]; then
  note "$SERVICE identity drifted from micupoker:micupoker"
fi

for endpoint in "$LOCAL_URL" "$PUBLIC_URL"; do
  if ! curl --fail --silent --show-error --max-time 10 "$endpoint" >/dev/null; then
    note "health endpoint failed: $endpoint"
  fi
done

current_release=$(readlink -f "$RELEASE_ROOT/current" 2>/dev/null || true)
case "$current_release" in
  "$RELEASE_ROOT"/releases/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
    if ! integrity_output="$("$RELEASE_ROOT/current/ops/verify_release.sh" "$current_release" 2>&1)"; then
      note "release integrity failed: ${integrity_output:0:300}"
    fi
    ;;
  *) note "current release path is missing or unexpected" ;;
esac

restarts=$(systemctl show "$SERVICE" -p NRestarts --value 2>/dev/null || true)
if [[ "$restarts" =~ ^[0-9]+$ ]]; then
  marker="$STATE_DIR/nrestarts"
  previous=""
  if [[ -r "$marker" ]]; then
    previous=$(<"$marker")
  fi
  if [[ "$previous" =~ ^[0-9]+$ && "$restarts" -ge "$previous" ]]; then
    restart_delta=$((restarts - previous))
    if (( restart_delta > MAX_RESTARTS )); then
      note "$SERVICE restarted $restart_delta times since the previous probe"
    fi
  fi
  if ! printf '%s\n' "$restarts" >"$marker"; then
    note "restart state cannot be written"
  fi
else
  note "$SERVICE restart counter is unavailable"
fi

if ! systemctl is-enabled --quiet "$BACKUP_TIMER" || ! systemctl is-active --quiet "$BACKUP_TIMER"; then
  note "$BACKUP_TIMER is not enabled and active"
fi

backup_result=$(systemctl show "$BACKUP_SERVICE" -p Result --value 2>/dev/null || true)
backup_status=$(systemctl show "$BACKUP_SERVICE" -p ExecMainStatus --value 2>/dev/null || true)
backup_finished=$(systemctl show "$BACKUP_SERVICE" -p ExecMainExitTimestampMonotonic --value 2>/dev/null || true)
if [[ "$backup_result" != "success" || "$backup_status" != "0" ]]; then
  note "$BACKUP_SERVICE last result is not successful"
elif [[ ! "$backup_finished" =~ ^[1-9][0-9]*$ ]]; then
  note "$BACKUP_SERVICE has no successful completion timestamp for this boot"
else
  uptime_seconds=$(cut -d. -f1 /proc/uptime)
  now_monotonic=$((uptime_seconds * 1000000))
  if (( backup_finished > now_monotonic )); then
    note "$BACKUP_SERVICE completion timestamp is inconsistent"
  else
    backup_age_hours=$(((now_monotonic - backup_finished) / 3600000000))
    if (( backup_age_hours > BACKUP_MAX_AGE_HOURS )); then
      note "$BACKUP_SERVICE last successful run is ${backup_age_hours}h old"
    fi
  fi
fi

if (( ${#problems[@]} == 0 )); then
  echo "micupoker_healthcheck=passed"
  exit 0
fi

echo "micupoker healthcheck found ${#problems[@]} problem(s)" >&2
for problem in "${problems[@]}"; do
  echo "  - $problem" >&2
done
exit 1
