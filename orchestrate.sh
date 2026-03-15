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

discover_local_repos() {
  find "$WORKSPACE_ROOT" -type d -name .git -prune 2>/dev/null | while IFS= read -r git_dir; do
    repo_dir="${git_dir%/.git}"
    case "$repo_dir" in
      "$WORKSPACE_ROOT/project-contributor/repos/"*) continue ;;
    esac

    origin=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
    repo_full=$(normalize_github_repo "$origin")
    if [ -n "$repo_full" ]; then
      printf '%s\t%s\n' "$repo_dir" "$repo_full"
    fi
  done | sort
}

project_id_for_repo() {
  local projects_json="$1"
  local repo_full="$2"

  printf '%s' "$projects_json" | python3 - "$repo_full" <<'PY'
import json, sys
repo = sys.argv[1].lower()
for project in json.load(sys.stdin):
    if (project.get("github_repo") or "").lower() == repo:
        print(project["id"])
        break
PY
}

project_id_for_name() {
  local projects_json="$1"
  local repo_name="$2"

  printf '%s' "$projects_json" | python3 - "$repo_name" <<'PY'
import json, sys
name = sys.argv[1].lower()
matches = [
    project for project in json.load(sys.stdin)
    if (project.get("name") or "").lower() == name and not project.get("github_repo")
]
if len(matches) == 1:
    print(matches[0]["id"])
PY
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
  local repo_name="$1"
  local repo_dir="$2"

  local payload
  payload=$(python3 - "$repo_name" "$repo_dir" <<'PY'
import json, sys
print(json.dumps({
    "name": sys.argv[1],
    "description": f"Auto-discovered local repository at {sys.argv[2]}",
}))
PY
)

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would create PM project for ${repo_name}"
    return 0
  fi

  curl -sf -X POST "${PM_API}/api/projects" \
    -H "Authorization: Bearer ${PM_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload"
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
    PROJECT_NAME=$(printf '%s' "$PROJECTS_JSON" | python3 - "$pid" <<'PY'
import json, sys
pid = int(sys.argv[1])
for project in json.load(sys.stdin):
    if project["id"] == pid:
        print(project["name"])
        break
PY
)

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
_EXT_AI_PROVIDER="${AI_PROVIDER:-}"
_EXT_TARGET_MODEL="${TARGET_MODEL:-}"
_EXT_MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-}"
_EXT_CONTRIBUTOR_AGENT_NAME="${CONTRIBUTOR_AGENT_NAME:-}"
_EXT_REVIEWER_AGENT_NAME="${REVIEWER_AGENT_NAME:-}"
_EXT_CONTRIBUTOR_SCRIPT="${CONTRIBUTOR_SCRIPT:-}"
_EXT_REVIEWER_SCRIPT="${REVIEWER_SCRIPT:-}"

set -a
source "$ENV_FILE"
set +a

[ -n "$_EXT_PM_API" ] && PM_API="$_EXT_PM_API"
[ -n "$_EXT_PM_TOKEN" ] && PM_TOKEN="$_EXT_PM_TOKEN"
[ -n "$_EXT_GITHUB_TOKEN" ] && GITHUB_TOKEN="$_EXT_GITHUB_TOKEN"
[ -n "$_EXT_WORKSPACE_ROOT" ] && WORKSPACE_ROOT="$_EXT_WORKSPACE_ROOT"
[ -n "$_EXT_AI_PROVIDER" ] && AI_PROVIDER="$_EXT_AI_PROVIDER"
[ -n "$_EXT_TARGET_MODEL" ] && TARGET_MODEL="$_EXT_TARGET_MODEL"
[ -n "$_EXT_MAX_REVIEW_ATTEMPTS" ] && MAX_REVIEW_ATTEMPTS="$_EXT_MAX_REVIEW_ATTEMPTS"
[ -n "$_EXT_CONTRIBUTOR_AGENT_NAME" ] && CONTRIBUTOR_AGENT_NAME="$_EXT_CONTRIBUTOR_AGENT_NAME"
[ -n "$_EXT_REVIEWER_AGENT_NAME" ] && REVIEWER_AGENT_NAME="$_EXT_REVIEWER_AGENT_NAME"
CONTRIBUTOR_SCRIPT="$_EXT_CONTRIBUTOR_SCRIPT"
REVIEWER_SCRIPT="$_EXT_REVIEWER_SCRIPT"

PM_API="${PM_API:-https://pm.wfh.day}"
PM_TOKEN="${PM_TOKEN:?PM_TOKEN is required}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/projects}"
AI_PROVIDER="${AI_PROVIDER:-gemini}"
TARGET_MODEL="${TARGET_MODEL:-gemini-2.5-pro}"
MAX_REVIEW_ATTEMPTS="${MAX_REVIEW_ATTEMPTS:-3}"
CONTRIBUTOR_AGENT_NAME="${CONTRIBUTOR_AGENT_NAME:-auto-contributor}"
REVIEWER_AGENT_NAME="${REVIEWER_AGENT_NAME:-auto-reviewer}"
CONTRIBUTOR_SCRIPT="${CONTRIBUTOR_SCRIPT:-}"
REVIEWER_SCRIPT="${REVIEWER_SCRIPT:-}"

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
log "  Dry run        : $DRY_RUN"
log "  Skip sync      : $SKIP_SYNC"
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
log "========== PHASE 2: DISCOVER LOCAL REPOS =========="

PROJECTS_JSON=$(fetch_projects_json) || die "Failed to fetch projects from PM API"

DISCOVERED=0
CREATED=0
LINKED=0

while IFS=$'\t' read -r repo_dir repo_full; do
  [ -n "$repo_full" ] || continue

  repo_name=$(basename "$repo_full")
  project_id=$(project_id_for_repo "$PROJECTS_JSON" "$repo_full")

  if [ -n "$project_id" ]; then
    log "Using existing PM project #${project_id} for ${repo_full}"
    ensure_project_link "$project_id" "$repo_full"
  else
    project_id=$(project_id_for_name "$PROJECTS_JSON" "$repo_name")

    if [ -n "$project_id" ]; then
      log "Linking existing PM project #${project_id} (${repo_name}) to ${repo_full}"
      ensure_project_link "$project_id" "$repo_full"
      LINKED=$((LINKED + 1))
    else
      log "Creating PM project for ${repo_full} (${repo_dir})"
      CREATE_RESPONSE=$(create_project_for_repo "$repo_name" "$repo_dir")
      if [ "$DRY_RUN" = false ]; then
        project_id=$(printf '%s' "$CREATE_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
      fi
      CREATED=$((CREATED + 1))
      if [ -n "$project_id" ]; then
        ensure_project_link "$project_id" "$repo_full"
        LINKED=$((LINKED + 1))
      fi
    fi
  fi

  DISCOVERED=$((DISCOVERED + 1))

  if [ "$DRY_RUN" = false ]; then
    PROJECTS_JSON=$(fetch_projects_json) || die "Failed to refresh projects from PM API"
  fi
done < <(discover_local_repos)

log "Local GitHub repos discovered : $DISCOVERED"
log "PM projects created           : $CREATED"
log "PM links updated              : $LINKED"

PROJECTS_JSON=$(fetch_projects_json) || die "Failed to refresh projects from PM API"

PROJECT_IDS=$(printf '%s' "$PROJECTS_JSON" | python3 -c '
import json, sys
for project in json.load(sys.stdin):
    repo = project.get("github_repo") or ""
    if repo and repo != "None":
        print(project["id"])
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
        print(f"  Project #{project['id']}: {project['name']} -> {repo}")
' | tee -a "$LOG_FILE"

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
