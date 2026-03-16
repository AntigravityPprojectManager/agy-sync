#!/usr/bin/env bash
# ============================================================================
# discover-registry.sh — Build a managed repo registry for agy-sync
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
REGISTRY_FILE="${SCRIPT_DIR}/registry.tsv"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing .env at $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

PM_API="${PM_API:-https://pm.wfh.day}"
PM_TOKEN="${PM_TOKEN:?PM_TOKEN is required}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-${AGY_BASE_DIR:-$HOME/projects}}"

PROJECTS_FILE="$(mktemp)"
trap 'rm -f "$PROJECTS_FILE"' EXIT

curl -sf "$PM_API/api/projects" -H "Authorization: Bearer $PM_TOKEN" >"$PROJECTS_FILE"

python3 - "$WORKSPACE_ROOT" "$REGISTRY_FILE" "$PROJECTS_FILE" <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

workspace_root = Path(sys.argv[1]).resolve()
registry_file = Path(sys.argv[2]).resolve()
projects_file = Path(sys.argv[3]).resolve()
projects = json.loads(projects_file.read_text())

project_by_repo = {}
project_by_name_without_repo = {}
for project in projects:
    repo = (project.get("github_repo") or "").strip().lower()
    if repo:
        project_by_repo[repo] = project
    else:
        name = (project.get("name") or "").strip().lower()
        if name:
            project_by_name_without_repo.setdefault(name, []).append(project)

def normalize_repo(url: str) -> str:
    url = (url or "").strip()
    if url.endswith(".git"):
        url = url[:-4]
    patterns = (
        r"^git@github\.com:(.+)$",
        r"^https?://github\.com/(.+)$",
        r"^https://[^@]+@github\.com/(.+)$",
    )
    for pattern in patterns:
        match = re.match(pattern, url)
        if match:
            return match.group(1)
    return ""

def humanize_repo_name(repo_full: str) -> str:
    name = repo_full.split("/")[-1]
    return " ".join(part.capitalize() for part in name.replace("-", " ").replace("_", " ").split())

rows = []
for git_dir in sorted(workspace_root.rglob(".git")):
    repo_dir = git_dir.parent.resolve()
    if str(repo_dir).startswith(str((workspace_root / "project-contributor" / "repos").resolve())):
        continue
    try:
        origin = subprocess.check_output(
            ["git", "-C", str(repo_dir), "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except subprocess.CalledProcessError:
        continue
    repo_full = normalize_repo(origin)
    if not repo_full:
        continue

    project = project_by_repo.get(repo_full.lower())
    owner = repo_full.split("/")[0] if "/" in repo_full else ""
    enabled = "1" if owner == "AntigravityPprojectManager" else "0"
    if not project:
        candidate_name = humanize_repo_name(repo_full).lower()
        matches = project_by_name_without_repo.get(candidate_name, [])
        if len(matches) == 1:
            project = matches[0]
    project_name = project["name"] if project else humanize_repo_name(repo_full)
    project_id = str(project["id"]) if project else ""
    rows.append((enabled, str(repo_dir), repo_full, project_name, project_id))

header = [
    "# enabled\trepo_dir\tgithub_repo\tproject_name\tproject_id",
    "# enabled=1 means agy-sync will manage the repo",
]
body = ["\t".join(row) for row in rows]
registry_file.write_text("\n".join(header + body) + "\n")

enabled_count = sum(1 for row in rows if row[0] == "1")
print(f"Wrote {len(rows)} discovered repos to {registry_file}")
print(f"Enabled by default: {enabled_count}")
PY
