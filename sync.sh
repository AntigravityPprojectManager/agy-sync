#!/usr/bin/env bash
# ============================================================================
# sync.sh — Git-pull all repos under ~/agy/
#
# Iterates through every subdirectory of AGY_BASE_DIR that has a .git folder
# and pulls the latest changes from origin/main.
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOGS_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOGS_DIR}/sync_${TIMESTAMP}.log"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
mkdir -p "$LOGS_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

AGY_BASE_DIR="${AGY_BASE_DIR:-$HOME/agy}"

log "=========================================="
log "Git Sync started"
log "  Base dir : $AGY_BASE_DIR"
log "=========================================="

# ---------------------------------------------------------------------------
# Sync each repo
# ---------------------------------------------------------------------------
SYNCED=0
FAILED=0
SKIPPED=0

# Save and restore cwd
ORIG_DIR="$(pwd)"

for repo_dir in "$AGY_BASE_DIR"/*/; do
  # Skip if not a directory
  [ -d "$repo_dir" ] || continue

  repo_name=$(basename "$repo_dir")

  # Skip if not a git repo
  if [ ! -d "${repo_dir}.git" ]; then
    log "  [$repo_name] Not a git repo — skipping."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Skip if no remote origin configured (e.g. freshly init'd repo)
  if ! (cd "$repo_dir" && git remote get-url origin >/dev/null 2>&1); then
    log "  [$repo_name] No remote 'origin' — skipping."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "  [$repo_name] Syncing..."

  cd "$repo_dir"

  # Determine the default branch
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || DEFAULT_BRANCH="main"

  # Check for uncommitted changes
  HAS_CHANGES=false
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    HAS_CHANGES=true
  fi

  PULL_SUCCESS=false

  if [ "$HAS_CHANGES" = true ]; then
    log "  [$repo_name] Local changes detected — stashing before pull..."
    git stash push -m "agy-sync auto-stash ${TIMESTAMP}" 2>&1 | tee -a "$LOG_FILE" || true

    if git pull --ff-only origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
      log "  [$repo_name] Pull (ff-only) succeeded after stash."
      PULL_SUCCESS=true
    elif git pull --rebase origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
      log "  [$repo_name] Pull (rebase) succeeded after stash."
      PULL_SUCCESS=true
    else
      log "  [$repo_name] Pull failed even after stash. Aborting rebase if in progress."
      git rebase --abort 2>/dev/null || true
    fi

    # Re-apply stash
    git stash pop 2>&1 | tee -a "$LOG_FILE" || {
      log "  [$repo_name] WARNING: Stash pop failed — possible merge conflict."
      log "  [$repo_name] Stashed changes preserved. Run 'git stash list' to inspect."
    }

  else
    # Clean working tree — simple pull
    if git pull --ff-only origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
      PULL_SUCCESS=true
      log "  [$repo_name] Pull (ff-only) succeeded."
    elif git pull --rebase origin "$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
      PULL_SUCCESS=true
      log "  [$repo_name] Pull (rebase) succeeded."
    else
      log "  [$repo_name] Pull failed. Attempting hard reset to origin/$DEFAULT_BRANCH..."
      git rebase --abort 2>/dev/null || true
      if git reset --hard "origin/$DEFAULT_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        PULL_SUCCESS=true
        log "  [$repo_name] Hard reset to origin/$DEFAULT_BRANCH succeeded."
      fi
    fi
  fi

  if [ "$PULL_SUCCESS" = true ]; then
    SYNCED=$((SYNCED + 1))
  else
    FAILED=$((FAILED + 1))
    log "  [$repo_name] SYNC FAILED — manual intervention may be needed."
  fi

  # Return to original dir for next iteration
  cd "$ORIG_DIR"

done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "=========================================="
log "Git Sync completed!"
log "  Synced  : $SYNCED"
log "  Failed  : $FAILED"
log "  Skipped : $SKIPPED"
log "=========================================="

# Exit with error if any failed
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
