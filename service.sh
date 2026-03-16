#!/usr/bin/env bash
# ============================================================================
# service.sh — launchd control script for the agy-sync service
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
RUN_DIR="${SCRIPT_DIR}/run"
LOGS_DIR="${SCRIPT_DIR}/logs"
HEARTBEAT_FILE="${RUN_DIR}/heartbeat"
LAST_EXIT_FILE="${RUN_DIR}/last_exit_code"
LAST_RUN_FILE="${RUN_DIR}/last_run_at"
SERVICE_RUNNER="${SCRIPT_DIR}/service-runner.sh"
SERVICE_LOG="${LOGS_DIR}/service.log"
LAUNCHD_STDOUT_LOG="${LOGS_DIR}/launchd.out.log"
LAUNCHD_STDERR_LOG="${LOGS_DIR}/launchd.err.log"
SERVICE_NAME="agy-sync"
LAUNCH_LABEL="com.antigravity.agy-sync"
LAUNCH_DOMAIN="gui/$(id -u)"
PLIST_FILE="${USER_HOME}/Library/LaunchAgents/${LAUNCH_LABEL}.plist"
DEFAULT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$RUN_DIR" "$LOGS_DIR" "$(dirname "$PLIST_FILE")"

launchd_target() {
  printf '%s/%s\n' "$LAUNCH_DOMAIN" "$LAUNCH_LABEL"
}

is_loaded() {
  launchctl print "$(launchd_target)" >/dev/null 2>&1
}

write_plist() {
  python3 - "$PLIST_FILE" "$LAUNCH_LABEL" "$SCRIPT_DIR" "$SERVICE_RUNNER" "$LAUNCHD_STDOUT_LOG" "$LAUNCHD_STDERR_LOG" "$DEFAULT_PATH" "$@" <<'PY'
import os
import plistlib
import sys

plist_path, label, workdir, runner, stdout_log, stderr_log, path, *flags = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", runner, *flags],
    "WorkingDirectory": workdir,
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": stdout_log,
    "StandardErrorPath": stderr_log,
    "EnvironmentVariables": {
        "PATH": path,
        "HOME": os.environ.get("HOME", os.path.expanduser("~")),
    },
}
with open(plist_path, "wb") as fh:
    plistlib.dump(payload, fh, sort_keys=False)
PY
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

print_status() {
  local info pid state
  if is_loaded; then
    info="$(launchctl print "$(launchd_target)" 2>/dev/null || true)"
    pid="$(printf '%s\n' "$info" | awk '/pid = /{print $3; exit}' | tr -d ';')"
    state="$(printf '%s\n' "$info" | awk -F'= ' '/state = /{print $2; exit}' | tr -d ';')"
    if [ -n "${pid:-}" ]; then
      echo "${SERVICE_NAME} service is loaded in launchd (pid ${pid}${state:+, state ${state}})."
    else
      echo "${SERVICE_NAME} service is loaded in launchd${state:+ (state ${state})}."
    fi
  else
    echo "${SERVICE_NAME} service is not loaded in launchd."
  fi
  [ -f "$HEARTBEAT_FILE" ] && echo "last heartbeat: $(cat "$HEARTBEAT_FILE")"
  [ -f "$LAST_RUN_FILE" ] && echo "last run: $(cat "$LAST_RUN_FILE")"
  [ -f "$LAST_EXIT_FILE" ] && echo "last exit code: $(cat "$LAST_EXIT_FILE")"
  echo "plist file: $PLIST_FILE"
  echo "service log: $SERVICE_LOG"
  echo "launchd stdout log: $LAUNCHD_STDOUT_LOG"
  echo "launchd stderr log: $LAUNCHD_STDERR_LOG"
}

load_service() {
  local attempt
  for attempt in 1 2 3; do
    if launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST_FILE"; then
      launchctl kickstart -k "$(launchd_target)"
      return 0
    fi
    sleep 1
  done
  return 1
}

action="${1:-status}"
shift || true

case "$action" in
  start)
    if is_loaded; then
      echo "${SERVICE_NAME} service is already loaded in launchd."
      exit 0
    fi
    write_plist "$@"
    load_service
    echo "${SERVICE_NAME} service started via launchd."
    ;;
  stop)
    if ! is_loaded; then
      echo "${SERVICE_NAME} service is not loaded in launchd."
      exit 0
    fi
    launchctl bootout "$(launchd_target)"
    echo "${SERVICE_NAME} service stopped."
    ;;
  restart)
    if is_loaded; then
      launchctl bootout "$(launchd_target)"
      sleep 1
    fi
    write_plist "$@"
    load_service
    echo "${SERVICE_NAME} service restarted via launchd."
    ;;
  status)
    print_status
    ;;
  run)
    exec bash "$SERVICE_RUNNER" "$@"
    ;;
  logs)
    exec tail -n 50 -f "$SERVICE_LOG" "$LAUNCHD_STDOUT_LOG" "$LAUNCHD_STDERR_LOG"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
