#!/usr/bin/env bash
# ============================================================================
# service.sh — Control script for the agy-sync long-running service
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"
LOGS_DIR="${SCRIPT_DIR}/logs"
PID_FILE="${RUN_DIR}/service.pid"
HEARTBEAT_FILE="${RUN_DIR}/heartbeat"
LAST_EXIT_FILE="${RUN_DIR}/last_exit_code"
LAST_RUN_FILE="${RUN_DIR}/last_run_at"
SERVICE_RUNNER="${SCRIPT_DIR}/service-runner.sh"
SERVICE_LOG="${LOGS_DIR}/service.log"

mkdir -p "$RUN_DIR" "$LOGS_DIR"

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

usage() {
  cat <<'EOF'
Usage:
  bash service.sh start [service-runner flags...]
  bash service.sh stop
  bash service.sh restart [service-runner flags...]
  bash service.sh status
  bash service.sh run [service-runner flags...]
  bash service.sh logs

Common flags for the runner:
  --once
  --interval-minutes <n>
  --dry-run
  --skip-sync
EOF
}

action="${1:-status}"
shift || true

case "$action" in
  start)
    if is_running; then
      echo "agy-sync service is already running (pid $(cat "$PID_FILE"))."
      exit 0
    fi
    nohup bash "$SERVICE_RUNNER" "$@" >/dev/null 2>&1 &
    sleep 1
    if is_running; then
      echo "agy-sync service started (pid $(cat "$PID_FILE"))."
    else
      echo "agy-sync service failed to start. Check ${SERVICE_LOG}."
      exit 1
    fi
    ;;
  stop)
    if ! is_running; then
      echo "agy-sync service is not running."
      rm -f "$PID_FILE"
      exit 0
    fi
    kill "$(cat "$PID_FILE")"
    sleep 1
    if is_running; then
      echo "agy-sync service did not stop cleanly; sending SIGKILL."
      kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    echo "agy-sync service stopped."
    ;;
  restart)
    bash "$0" stop >/dev/null 2>&1 || true
    bash "$0" start "$@"
    ;;
  status)
    if is_running; then
      echo "agy-sync service is running (pid $(cat "$PID_FILE"))."
    else
      echo "agy-sync service is not running."
    fi
    [ -f "$HEARTBEAT_FILE" ] && echo "last heartbeat: $(cat "$HEARTBEAT_FILE")"
    [ -f "$LAST_RUN_FILE" ] && echo "last run: $(cat "$LAST_RUN_FILE")"
    [ -f "$LAST_EXIT_FILE" ] && echo "last exit code: $(cat "$LAST_EXIT_FILE")"
    echo "log file: $SERVICE_LOG"
    ;;
  run)
    exec bash "$SERVICE_RUNNER" "$@"
    ;;
  logs)
    exec tail -n 50 -f "$SERVICE_LOG"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
