#!/usr/bin/env bash
# ============================================================================
# service-runner.sh — Long-running service wrapper for orchestrate.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOGS_DIR="${SCRIPT_DIR}/logs"
RUN_DIR="${SCRIPT_DIR}/run"
SERVICE_LOG="${LOGS_DIR}/service.log"
PID_FILE="${RUN_DIR}/service.pid"
HEARTBEAT_FILE="${RUN_DIR}/heartbeat"
LAST_EXIT_FILE="${RUN_DIR}/last_exit_code"
LAST_RUN_FILE="${RUN_DIR}/last_run_at"

ONCE=false
INTERVAL_OVERRIDE=""
FLAGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --once)
      ONCE=true
      ;;
    --interval-minutes)
      shift
      [ $# -gt 0 ] || { echo "Missing value for --interval-minutes" >&2; exit 1; }
      INTERVAL_OVERRIDE="$1"
      ;;
    *)
      FLAGS+=("$1")
      ;;
  esac
  shift
done

if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
fi

INTERVAL_MINUTES="${INTERVAL_OVERRIDE:-${INTERVAL_MINUTES:-30}}"
INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))

mkdir -p "$LOGS_DIR" "$RUN_DIR"
printf '%s\n' "$$" > "$PID_FILE"

cleanup() {
  if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PID_FILE"
  fi
}

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$SERVICE_LOG"
}

trap 'log "Service stopped (signal received)."; cleanup; exit 0' INT TERM
trap cleanup EXIT

log "============================================"
log "Agy Sync service started"
log "  Interval  : every ${INTERVAL_MINUTES} minutes"
log "  Script    : ${SCRIPT_DIR}/orchestrate.sh"
log "  PID       : $$"
log "  Once mode : ${ONCE}"
log "============================================"

cycle=0
while true; do
  cycle=$((cycle + 1))
  printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$HEARTBEAT_FILE"
  log "--- Cycle #${cycle} starting ---"

  exit_code=0
  bash "${SCRIPT_DIR}/orchestrate.sh" "${FLAGS[@]}" 2>&1 | tee -a "$SERVICE_LOG" || exit_code=$?

  printf '%s\n' "$exit_code" > "$LAST_EXIT_FILE"
  printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$LAST_RUN_FILE"

  if [ "$exit_code" -eq 0 ]; then
    log "--- Cycle #${cycle} completed successfully ---"
  else
    log "--- Cycle #${cycle} failed (exit=${exit_code}) ---"
  fi

  if [ "$ONCE" = true ]; then
    exit "$exit_code"
  fi

  log "Sleeping ${INTERVAL_MINUTES} minutes until next cycle..."
  sleep "$INTERVAL_SECONDS"
done
