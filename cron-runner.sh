#!/usr/bin/env bash
# ============================================================================
# cron-runner.sh — Periodic runner for orchestrate.sh
#
# Runs orchestrate.sh in a loop every INTERVAL_MINUTES.
# Usage:
#   bash cron-runner.sh                  # run in foreground
#   nohup bash cron-runner.sh &          # run in background
#   INTERVAL_MINUTES=15 bash cron-runner.sh  # custom interval
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOGS_DIR="${SCRIPT_DIR}/logs"
CRON_LOG="${LOGS_DIR}/cron.log"

# Load .env for INTERVAL_MINUTES
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

INTERVAL_MINUTES="${INTERVAL_MINUTES:-30}"
INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))

mkdir -p "$LOGS_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$CRON_LOG"
}

log "============================================"
log "Orchestrator cron runner started"
log "  Interval  : every ${INTERVAL_MINUTES} minutes"
log "  Script    : ${SCRIPT_DIR}/orchestrate.sh"
log "  PID       : $$"
log "============================================"

# Trap SIGINT/SIGTERM for graceful shutdown
trap 'log "Cron runner stopped (signal received)."; exit 0' INT TERM

# Pass through any flags (e.g. --dry-run)
FLAGS="$*"

cycle=0
while true; do
  cycle=$((cycle + 1))
  log "--- Cycle #${cycle} starting ---"

  # Run orchestrate.sh, capturing exit code
  bash "${SCRIPT_DIR}/orchestrate.sh" $FLAGS 2>&1 | tee -a "$CRON_LOG" && \
    log "--- Cycle #${cycle} completed successfully ---" || \
    log "--- Cycle #${cycle} failed (exit=$?) ---"

  log "Sleeping ${INTERVAL_MINUTES} minutes until next cycle..."
  sleep "$INTERVAL_SECONDS"
done
