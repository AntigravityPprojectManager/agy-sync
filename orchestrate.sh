#!/usr/bin/env bash
# ============================================================================
# orchestrate.sh — Master orchestrator
#
# Runs the full cycle:
#   1. Sync local managed repos under ~/projects
#   2. Discover local GitHub repos and ensure PM projects are linked
#   3. Contribute across linked PM projects
#   4. Review across linked PM projects
#   5. Run a retry contribution pass for issues that received review feedback
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
REGISTRY_FILE_DEFAULT="${SCRIPT_DIR}/registry.tsv"
LOGS_DIR="${SCRIPT_DIR}/logs"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${LOGS_DIR}/orchestrate_${TIMESTAMP}.log"

DRY_RUN=false
SKIP_SYNC=false
REGISTRY_ONLY=false

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --skip-sync) SKIP_SYNC=true ;;
    --registry-only) REGISTRY_ONLY=true ;;
  esac
done

mkdir -p "$LOGS_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $1"
  exit 1
}

fetch_projects_json() {
  local attempt max_attempts body_file err_file http_code backoff
  max_attempts=3
  backoff=2

  for attempt in $(seq 1 "$max_attempts"); do
    body_file="$(mktemp)"
    err_file="$(mktemp)"

    http_code=$(curl -sS -o "$body_file" -w "%{http_code}" \
      "${PM_API}/api/projects" \
      -H "Authorization: Bearer ${PM_TOKEN}" 2>"$err_file") || {
        printf '[%s] ERROR: Failed to fetch projects from PM API (attempt %s/%s): %s\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$attempt" "$max_attempts" \
          "$(tr '\n' ' ' < "$err_file")" >&2
        rm -f "$body_file" "$err_file"
        if [ "$attempt" -lt "$max_attempts" ]; then
          sleep "$backoff"
          backoff=$((backoff * 2))
          continue
        fi
        return 1
      }

    if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 300 ]; then
      cat "$body_file"
      rm -f "$body_file" "$err_file"
      return 0
    fi

    printf '[%s] ERROR: PM API returned HTTP %s while fetching projects (attempt %s/%s).\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$http_code" "$attempt" "$max_attempts" >&2
    if [ -s "$body_file" ]; then
      printf '[%s] ERROR: Response body: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$(head -c 500 "$body_file" | tr '\n' ' ')" >&2
    fi
    rm -f "$body_file" "$err_file"

    if [ "${http_code}" -ge 500 ] && [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$backoff"
      backoff=$((backoff * 2))
      continue
    fi

    return 1
  done

  return 1
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

project_id_exists() {
  local projects_json="$1"
  local project_id="$2"

  [ -n "$project_id" ] || return 1

  printf '%s' "$projects_json" | python3 -c '
import json, sys
project_id = int(sys.argv[1])
for project in json.load(sys.stdin):
    if project["id"] == project_id:
        print(project_id)
        break
' "$project_id"
}

project_id_for_repo() {
  local projects_json="$1"
  local repo_full="$2"

  printf '%s' "$projects_json" | python3 -c '
import json, sys
repo = sys.argv[1].lower()
for project in json.load(sys.stdin):
    if (project.get("github_repo") or "").lower() == repo:
        print(project["id"])
        break
' "$repo_full"
}

project_id_for_name() {
  local projects_json="$1"
  local repo_name="$2"

  printf '%s' "$projects_json" | python3 -c '
import json, sys
name = sys.argv[1].lower()
matches = [
    project for project in json.load(sys.stdin)
    if (project.get("name") or "").lower() == name and not project.get("github_repo")
]
if len(matches) == 1:
    print(matches[0]["id"])
' "$repo_name"
}

ensure_project_link() {
  local project_id="$1"
  local repo_full="$2"

  local payload
  payload=$(python3 - "$repo_full" <<'PY'
import json, sys
print(json.dumps({
    "github_repo": sys.argv[1],
    "github_sync_enabled": True,
}))
PY
)

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would link project #${project_id} to ${repo_full}"
    return 0
  fi

  curl -sf -X PATCH "${PM_API}/api/projects/${project_id}" \
    -H "Authorization: Bearer ${PM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" > /dev/null || \
    log "WARNING: Failed to link project #${project_id} to ${repo_full}"
}

create_project_for_repo() {
  local project_name="$1"
  local repo_dir="$2"

  local payload
  payload=$(python3 - "$project_name" "$repo_dir" <<'PY'
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "description": f"Auto-discovered local repository at {sys.argv[2]}",
}))
PY
)

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would create PM project for ${project_name}"
    return 0
  fi

  curl -sf -X POST "${PM_API}/api/projects" \
    -H "Authorization: Bearer ${PM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

load_registry_entries() {
  [ -f "$REGISTRY_FILE" ] || die "Registry file not found at $REGISTRY_FILE"

  python3 - "$REGISTRY_FILE" <<'PY'
import csv, sys
path = sys.argv[1]
with open(path, newline="") as fh:
    reader = csv.reader(fh, delimiter="\t")
    for row in reader:
        if not row or row[0].strip().startswith("#"):
            continue
        while len(row) < 5:
            row.append("")
        enabled, repo_dir, repo_full, project_name, project_id = [cell.strip() for cell in row[:5]]
        if not repo_dir or not repo_full:
            continue
        print("\t".join([enabled or "1", repo_dir, repo_full, project_name, project_id]))
PY
}

run_agent_phase() {
  local phase_label="$1"
  local script_path="$2"
  local agent_name="$3"
  local dry_flag="$4"

  if [ ! -f "$script_path" ]; then
    log "WARNING: ${phase_label} script not found at $script_path — skipping."
    return 0
  fi

  for pid in $PROJECT_IDS; do
    PROJECT_NAME=$(printf '%s' "$PROJECTS_JSON" | python3 -c '
import json, sys
pid = int(sys.argv[1])
for project in json.load(sys.stdin):
    if project["id"] == pid:
        print(project["name"])
        break
' "$pid")

    log "--- ${phase_label} Project #${pid} (${PROJECT_NAME}) ---"

    (
      export PROJECT_ID="$pid"
      export PM_API="$PM_API"
      export PM_TOKEN="$PM_TOKEN"
      export GITHUB_TOKEN="$GITHUB_TOKEN"
      export AI_PROVIDER="$AI_PROVIDER"
      export TARGET_MODEL="$TARGET_MODEL"
      export AGENT_NAME="$agent_name"
      export WORKSPACE_ROOT="$WORKSPACE_ROOT"
      export MAX_REVIEW_ATTEMPTS="$MAX_REVIEW_ATTEMPTS"
      bash "$script_path" $dry_flag
    ) 2>&1 | tee -a "$LOG_FILE" && \
      log "--- Project #${pid} ${phase_label,,} completed ---" || \
      log "--- Project #${pid} ${phase_label,,} FAILED (exit=$?) ---"
  done
}

if [ ! -f "$ENV_FILE" ]; then
  die ".env file not found at $ENV_FILE"
fi

_EXT_PM_API="${PM_API:-}"
_EXT_PM_TOKEN="${PM_TOKEN:-}"
_EXT_GITHUB_TOKEN="${GITHUB_TOKEN:-}"
_EXT_WORKSPACE_ROOT="${WORKSPACE_ROOT:-}"
_EXT_AGY_BASE_DIR="${AGY_BASE_DIR:-}"
_EXT_AI_PROVIDER="${AI_PROVIDER:-}"
_EXT_TARGET_MODEL="${TARGET_MODEL:-}"
_EXT_MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-}"
_EXT_CONTRIBUTOR_AGENT_NAME="${CONTRIBUTOR_AGENT_NAME:-}"
_EXT_REVIEWER_AGENT_NAME="${REVIEWER_AGENT_NAME:-}"
_EXT_CONTRIBUTOR_SCRIPT="${CONTRIBUTOR_SCRIPT:-}"
_EXT_REVIEWER_SCRIPT="${REVIEWER_SCRIPT:-}"
_EXT_REGISTRY_FILE="${REGISTRY_FILE:-}"

set -a
source "$ENV_FILE"
set +a

[ -n "$_EXT_PM_API" ] && PM_API="$_EXT_PM_API"
[ -n "$_EXT_PM_TOKEN" ] && PM_TOKEN="$_EXT_PM_TOKEN"
[ -n "$_EXT_GITHUB_TOKEN" ] && GITHUB_TOKEN="$_EXT_GITHUB_TOKEN"
[ -n "$_EXT_WORKSPACE_ROOT" ] && WORKSPACE_ROOT="$_EXT_WORKSPACE_ROOT"
[ -n "$_EXT_AGY_BASE_DIR" ] && AGY_BASE_DIR="$_EXT_AGY_BASE_DIR"
[ -n "$_EXT_AI_PROVIDER" ] && AI_PROVIDER="$_EXT_AI_PROVIDER"
[ -n "$_EXT_TARGET_MODEL" ] && TARGET_MODEL="$_EXT_TARGET_MODEL"
[ -n "$_EXT_MAX_REVIEW_ATTEMPTS" ] && MAX_REVIEW_ATTEMPTS="$_EXT_MAX_REVIEW_ATTEMPTS"
[ -n "$_EXT_CONTRIBUTOR_AGENT_NAME" ] && CONTRIBUTOR_AGENT_NAME="$_EXT_CONTRIBUTOR_AGENT_NAME"
[ -n "$_EXT_REVIEWER_AGENT_NAME" ] && REVIEWER_AGENT_NAME="$_EXT_REVIEWER_AGENT_NAME"
CONTRIBUTOR_SCRIPT="$_EXT_CONTRIBUTOR_SCRIPT"
REVIEWER_SCRIPT="$_EXT_REVIEWER_SCRIPT"
REGISTRY_FILE="$_EXT_REGISTRY_FILE"

PM_API="${PM_API:-https://pm.wfh.day}"
PM_TOKEN="${PM_TOKEN:?PM_TOKEN is required}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-${AGY_BASE_DIR:-$HOME/projects}}"
AI_PROVIDER="${AI_PROVIDER:-codex}"
if [ -z "${TARGET_MODEL:-}" ]; then
  case "$AI_PROVIDER" in
    codex) TARGET_MODEL="gpt-5.4-xhigh" ;;
    antigravity) TARGET_MODEL="agent" ;;
    *) TARGET_MODEL="gemini-2.5-pro" ;;
  esac
fi
MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-3}"
CONTRIBUTOR_AGENT_NAME="${CONTRIBUTOR_AGENT_NAME:-auto-contributor}"
REVIEWER_AGENT_NAME="${REVIEWER_AGENT_NAME:-auto-reviewer}"
CONTRIBUTOR_SCRIPT="${CONTRIBUTOR_SCRIPT:-}"
REVIEWER_SCRIPT="${REVIEWER_SCRIPT:-}"
REGISTRY_FILE="${REGISTRY_FILE:-$REGISTRY_FILE_DEFAULT}"

if [ -z "$CONTRIBUTOR_SCRIPT" ]; then
  CONTRIBUTOR_SCRIPT="${WORKSPACE_ROOT}/project-contributor/contribute.sh"
fi

if [ -z "$REVIEWER_SCRIPT" ]; then
  REVIEWER_SCRIPT="${WORKSPACE_ROOT}/project-reviewer/review.sh"
fi

if [ ! -f "$CONTRIBUTOR_SCRIPT" ] && [ -f "${WORKSPACE_ROOT}/project-contributer/contribute.sh" ]; then
  CONTRIBUTOR_SCRIPT="${WORKSPACE_ROOT}/project-contributer/contribute.sh"
fi

DRY_FLAG=""
if [ "$DRY_RUN" = true ]; then
  DRY_FLAG="--dry-run"
fi

log "=========================================="
log "Orchestrator run started"
log "  PM API         : $PM_API"
log "  AI Provider    : $AI_PROVIDER"
log "  Model          : $TARGET_MODEL"
log "  Workspace root : $WORKSPACE_ROOT"
log "  Contributor    : $CONTRIBUTOR_SCRIPT"
log "  Reviewer       : $REVIEWER_SCRIPT"
log "  Registry       : $REGISTRY_FILE"
log "  Dry run        : $DRY_RUN"
log "  Skip sync      : $SKIP_SYNC"
log "  Registry only  : $REGISTRY_ONLY"
log "=========================================="

if [ "$SKIP_SYNC" = false ]; then
  log ""
  log "========== PHASE 1: GIT SYNC =========="
  WORKSPACE_ROOT="$WORKSPACE_ROOT" bash "${SCRIPT_DIR}/sync.sh" 2>&1 | tee -a "$LOG_FILE" && \
    log "Git sync completed successfully." || \
    log "WARNING: Git sync had failures (continuing anyway)."
else
  log ""
  log "========== PHASE 1: GIT SYNC (SKIPPED) =========="
fi

log ""
log "========== PHASE 2: SYNC REGISTRY =========="

PROJECTS_JSON=$(fetch_projects_json) || die "Failed to fetch projects from PM API"

REGISTERED=0
CREATED=0
LINKED=0
RESOLVED_PROJECT_IDS=""

while IFS=$'\t' read -r enabled repo_dir repo_full project_name preferred_project_id; do
  [ "$enabled" = "1" ] || continue
  [ -n "$repo_full" ] || continue

  if [ ! -d "$repo_dir/.git" ]; then
    log "WARNING: Registry repo path missing or not a git repo: $repo_dir"
    continue
  fi

  resolved_project_id="$(project_id_exists "$PROJECTS_JSON" "$preferred_project_id" || true)"
  if [ -z "$resolved_project_id" ]; then
    resolved_project_id="$(project_id_for_repo "$PROJECTS_JSON" "$repo_full")"
  fi
  if [ -z "$resolved_project_id" ] && [ -n "$project_name" ]; then
    resolved_project_id="$(project_id_for_name "$PROJECTS_JSON" "$project_name")"
  fi

  if [ -n "$resolved_project_id" ]; then
    log "Using PM project #${resolved_project_id} for ${repo_full}"
  else
    if [ -z "$project_name" ]; then
      project_name="$(basename "$repo_full")"
    fi
    log "Creating PM project for ${repo_full} (${repo_dir})"
    CREATE_RESPONSE=$(create_project_for_repo "$project_name" "$repo_dir")
    if [ "$DRY_RUN" = false ]; then
      resolved_project_id=$(printf '%s' "$CREATE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
    fi
    CREATED=$((CREATED + 1))
  fi

  if [ -n "$resolved_project_id" ]; then
    ensure_project_link "$resolved_project_id" "$repo_full"
    LINKED=$((LINKED + 1))
    RESOLVED_PROJECT_IDS="${RESOLVED_PROJECT_IDS}${resolved_project_id}"$'\n'
  fi

  REGISTERED=$((REGISTERED + 1))

  if [ "$DRY_RUN" = false ]; then
    PROJECTS_JSON=$(fetch_projects_json) || die "Failed to refresh projects from PM API"
  fi
done < <(load_registry_entries)

log "Registry repos processed       : $REGISTERED"
log "PM projects created           : $CREATED"
log "PM links updated              : $LINKED"

PROJECTS_JSON=$(fetch_projects_json) || die "Failed to refresh projects from PM API"

PROJECT_IDS=$(printf '%s' "$RESOLVED_PROJECT_IDS" | python3 -c '
import sys
seen = []
for line in sys.stdin:
    value = line.strip()
    if value and value not in seen:
        seen.append(value)
for value in seen:
    print(value)
')

if [ -z "$PROJECT_IDS" ]; then
  log "No linked GitHub projects found after discovery. Nothing to do."
  exit 0
fi

PROJECT_COUNT=$(echo "$PROJECT_IDS" | wc -l | tr -d ' ')
log "Found $PROJECT_COUNT linked GitHub project(s)."

printf '%s' "$PROJECTS_JSON" | python3 -c '
import json, sys
for project in json.load(sys.stdin):
    repo = project.get("github_repo") or ""
    if repo and repo != "None":
        print("  Project #{}: {} -> {}".format(project["id"], project["name"], repo))
' | tee -a "$LOG_FILE"

if [ "$REGISTRY_ONLY" = true ]; then
  log ""
  log "Registry sync only requested. Skipping contributor/reviewer phases."
  log "=========================================="
  log "Orchestrator run completed!"
  log "=========================================="
  exit 0
fi

log ""
log "========== PHASE 3: CONTRIBUTING =========="
run_agent_phase "Contributing to" "$CONTRIBUTOR_SCRIPT" "$CONTRIBUTOR_AGENT_NAME" "$DRY_FLAG"

log ""
log "========== PHASE 4: REVIEWING =========="
run_agent_phase "Reviewing" "$REVIEWER_SCRIPT" "$REVIEWER_AGENT_NAME" "$DRY_FLAG"

log ""
log "========== PHASE 5: RETRY CONTRIBUTION PASS =========="
run_agent_phase "Retrying" "$CONTRIBUTOR_SCRIPT" "$CONTRIBUTOR_AGENT_NAME" "$DRY_FLAG"

log ""
log "=========================================="
log "Orchestrator run completed!"
log "=========================================="
