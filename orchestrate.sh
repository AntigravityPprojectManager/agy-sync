#!/usr/bin/env bash
# ============================================================================
# orchestrate.sh — Master orchestrator
#
# Runs the full cycle:
#   1. Sync all repos (git pull)
#   2. Contribute to all projects (pick up todo issues, implement, create PRs)
#   3. Review all projects (review open PRs, approve+merge or reject)
#
# Usage:
#   bash orchestrate.sh              # full run
#   bash orchestrate.sh --dry-run    # dry run (no actual changes)
#   bash orchestrate.sh --skip-sync  # skip git sync phase
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOGS_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOGS_DIR}/orchestrate_${TIMESTAMP}.log"

DRY_RUN=false
SKIP_SYNC=false

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --skip-sync) SKIP_SYNC=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
mkdir -p "$LOGS_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $1"
  exit 1
}

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
  die ".env file not found at $ENV_FILE"
fi

set -a
source "$ENV_FILE"
set +a

PM_API="${PM_API:-https://pm.wfh.day}"
PM_TOKEN="${PM_TOKEN:?PM_TOKEN is required}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
AGY_BASE_DIR="${AGY_BASE_DIR:-$HOME/agy}"
CONTRIBUTOR_SCRIPT="${CONTRIBUTOR_SCRIPT:-${AGY_BASE_DIR}/project-contributer/contribute.sh}"
REVIEWER_SCRIPT="${REVIEWER_SCRIPT:-${AGY_BASE_DIR}/project-reviewer/review.sh}"
AI_PROVIDER="${AI_PROVIDER:-gemini}"
TARGET_MODEL="${TARGET_MODEL:-gemini-2.5-pro}"
CONTRIBUTOR_AGENT_NAME="${CONTRIBUTOR_AGENT_NAME:-auto-contributor}"
REVIEWER_AGENT_NAME="${REVIEWER_AGENT_NAME:-auto-reviewer}"

DRY_FLAG=""
if [ "$DRY_RUN" = true ]; then
  DRY_FLAG="--dry-run"
fi

log "=========================================="
log "Orchestrator run started"
log "  PM API         : $PM_API"
log "  AI Provider    : $AI_PROVIDER"
log "  Model          : $TARGET_MODEL"
log "  Base dir       : $AGY_BASE_DIR"
log "  Contributor    : $CONTRIBUTOR_SCRIPT"
log "  Reviewer       : $REVIEWER_SCRIPT"
log "  Dry run        : $DRY_RUN"
log "  Skip sync      : $SKIP_SYNC"
log "=========================================="

# =========================================================================
# Phase 1: Sync all repos
# =========================================================================
if [ "$SKIP_SYNC" = false ]; then
  log ""
  log "========== PHASE 1: GIT SYNC =========="
  bash "${SCRIPT_DIR}/sync.sh" 2>&1 | tee -a "$LOG_FILE" && \
    log "Git sync completed successfully." || \
    log "WARNING: Git sync had failures (continuing anyway)."
else
  log ""
  log "========== PHASE 1: GIT SYNC (SKIPPED) =========="
fi

# =========================================================================
# Phase 2 & 3: Discover projects, contribute, then review
# =========================================================================
log ""
log "========== DISCOVERING PROJECTS =========="

PROJECTS_JSON=$(curl -sf "${PM_API}/api/projects" \
  -H "Authorization: Bearer ${PM_TOKEN}") || die "Failed to fetch projects from PM API"

# Extract project IDs that have a github_repo linked
PROJECT_IDS=$(echo "$PROJECTS_JSON" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
for p in projects:
    repo = p.get('github_repo') or ''
    if repo and repo != 'None':
        print(p['id'])
" 2>/dev/null) || PROJECT_IDS=""

if [ -z "$PROJECT_IDS" ]; then
  log "No projects with linked GitHub repos found. Nothing to do."
  log "=========================================="
  log "Orchestrator run completed (no work to do)."
  log "=========================================="
  exit 0
fi

PROJECT_COUNT=$(echo "$PROJECT_IDS" | wc -l | tr -d ' ')
log "Found $PROJECT_COUNT project(s) with linked GitHub repos."

# Print project details
echo "$PROJECTS_JSON" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
for p in projects:
    repo = p.get('github_repo') or ''
    if repo and repo != 'None':
        print(f\"  Project #{p['id']}: {p['name']} → {repo}\")
" 2>/dev/null | tee -a "$LOG_FILE"

# =========================================================================
# Phase 2: Contribute to each project
# =========================================================================
log ""
log "========== PHASE 2: CONTRIBUTING =========="

if [ ! -f "$CONTRIBUTOR_SCRIPT" ]; then
  log "WARNING: Contributor script not found at $CONTRIBUTOR_SCRIPT — skipping contribute phase."
else
  for pid in $PROJECT_IDS; do
    PROJECT_NAME=$(echo "$PROJECTS_JSON" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
for p in projects:
    if p['id'] == $pid:
        print(p['name'])
        break
" 2>/dev/null) || PROJECT_NAME="Unknown"

    log "--- Contributing to Project #${pid} (${PROJECT_NAME}) ---"

    # Run contribute.sh with this project's ID
    (
      export PROJECT_ID="$pid"
      export PM_API="$PM_API"
      export PM_TOKEN="$PM_TOKEN"
      export GITHUB_TOKEN="$GITHUB_TOKEN"
      export AI_PROVIDER="$AI_PROVIDER"
      export TARGET_MODEL="$TARGET_MODEL"
      export AGENT_NAME="$CONTRIBUTOR_AGENT_NAME"
      bash "$CONTRIBUTOR_SCRIPT" $DRY_FLAG
    ) 2>&1 | tee -a "$LOG_FILE" && \
      log "--- Project #${pid} contribute completed ---" || \
      log "--- Project #${pid} contribute FAILED (exit=$?) ---"
  done
fi

# =========================================================================
# Phase 3: Review each project
# =========================================================================
log ""
log "========== PHASE 3: REVIEWING =========="

if [ ! -f "$REVIEWER_SCRIPT" ]; then
  log "WARNING: Reviewer script not found at $REVIEWER_SCRIPT — skipping review phase."
else
  for pid in $PROJECT_IDS; do
    PROJECT_NAME=$(echo "$PROJECTS_JSON" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
for p in projects:
    if p['id'] == $pid:
        print(p['name'])
        break
" 2>/dev/null) || PROJECT_NAME="Unknown"

    log "--- Reviewing Project #${pid} (${PROJECT_NAME}) ---"

    # Run review.sh with this project's ID
    (
      export PROJECT_ID="$pid"
      export PM_API="$PM_API"
      export PM_TOKEN="$PM_TOKEN"
      export GITHUB_TOKEN="$GITHUB_TOKEN"
      export AI_PROVIDER="$AI_PROVIDER"
      export TARGET_MODEL="$TARGET_MODEL"
      export AGENT_NAME="$REVIEWER_AGENT_NAME"
      bash "$REVIEWER_SCRIPT" $DRY_FLAG
    ) 2>&1 | tee -a "$LOG_FILE" && \
      log "--- Project #${pid} review completed ---" || \
      log "--- Project #${pid} review FAILED (exit=$?) ---"
  done
fi

# =========================================================================
# Done
# =========================================================================
log ""
log "=========================================="
log "Orchestrator run completed!"
log "=========================================="
