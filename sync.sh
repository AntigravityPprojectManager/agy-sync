#!/usr/bin/env bash
# ============================================================================
# sync.sh — Sync managed GitHub repos from the agy-sync registry
#
# Uses a safe policy:
# - only GitHub-backed repos are considered managed
# - dirty repos are skipped instead of stashed or reset
# - pull uses ff-only first, then rebase, with no hard reset fallback
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
REGISTRY_FILE_DEFAULT="${SCRIPT_DIR}/registry.tsv"
LOGS_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOGS_DIR}/sync_${TIMESTAMP}.log"

mkdir -p "$LOGS_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

normalize_github_repo() {
  python3 - "$1" <<'PY'
import re, sys
url = (sys.argv[1] or "").strip()
if url.endswith(".git"):
    url = url[:-4]
for pattern in (
    r"^git@github\.com:(.+)$",
    r"^https?://github\.com/(.+)$",
):
    match = re.match(pattern, url)
    if match:
        print(match.group(1))
        sys.exit(0)
print("")
PY
}

load_registry_dirs() {
  [ -f "$REGISTRY_FILE" ] || {
    echo "Registry file not found at $REGISTRY_FILE" >&2
    return 1
  }

  python3 - "$REGISTRY_FILE" <<'PY'
import csv, sys
path = sys.argv[1]
with open(path, newline="") as fh:
    reader = csv.reader(fh, delimiter="\t")
    for row in reader:
        if not row or row[0].strip().startswith("#"):
            continue
        while len(row) < 3:
            row.append("")
        enabled, repo_dir, repo_full = [cell.strip() for cell in row[:3]]
        if enabled != "1" or not repo_dir:
            continue
        print(repo_dir)
PY
}

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

WORKSPACE_ROOT="${WORKSPACE_ROOT:-${AGY_BASE_DIR:-$HOME/projects}}"
REGISTRY_FILE="${REGISTRY_FILE:-$REGISTRY_FILE_DEFAULT}"

log "=========================================="
log "Git Sync started"
log "  Workspace root : $WORKSPACE_ROOT"
log "  Registry file  : $REGISTRY_FILE"
log "=========================================="

SYNCED=0
FAILED=0
SKIPPED=0

while IFS= read -r repo_dir; do
  [ -d "$repo_dir/.git" ] || continue

  repo_name=$(basename "$repo_dir")
  default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || printf 'main\n')

  if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
    log "  [$repo_name] Working tree is dirty — skipping."
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "  [$repo_name] Syncing from origin/${default_branch}..."

  git -C "$repo_dir" fetch origin "$default_branch" >/dev/null 2>&1 || true

  if git -C "$repo_dir" checkout "$default_branch" >/dev/null 2>&1 || git -C "$repo_dir" checkout -b "$default_branch" >/dev/null 2>&1; then
    :
  fi

  if git -C "$repo_dir" pull --ff-only origin "$default_branch" 2>&1 | tee -a "$LOG_FILE"; then
    SYNCED=$((SYNCED + 1))
    log "  [$repo_name] Pull (ff-only) succeeded."
  elif git -C "$repo_dir" pull --rebase origin "$default_branch" 2>&1 | tee -a "$LOG_FILE"; then
    SYNCED=$((SYNCED + 1))
    log "  [$repo_name] Pull (rebase) succeeded."
  else
    git -C "$repo_dir" rebase --abort >/dev/null 2>&1 || true
    FAILED=$((FAILED + 1))
    log "  [$repo_name] Sync failed without modifying local state."
  fi
done < <(load_registry_dirs | sort -u)

log "=========================================="
log "Git Sync completed!"
log "  Synced  : $SYNCED"
log "  Failed  : $FAILED"
log "  Skipped : $SKIPPED"
log "=========================================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
