# agy-sync — Orchestrator for ~/projects

Ties together `project-manager`, `project-contributor`, and `project-reviewer` into a continuous automated loop for explicitly registered GitHub-backed repos under `~/projects`.

## What it does

```
┌─────────────────────────────────────────────────────┐
│                   cron-runner.sh                     │
│                (every 30 minutes)                    │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │              orchestrate.sh                    │  │
│  │                                                │  │
│  │  1. SYNC    → sync managed repos in registry   │  │
│  │  2. CONTRIBUTE → for each PM project:          │  │
│  │       pick todo issue → AI implement → PR      │  │
│  │  3. REVIEW  → for each PM project:             │  │
│  │       fetch in-progress PRs → AI review        │  │
│  │       → approve+merge or request retry         │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Full lifecycle

1. **Issue created** via PM web UI or Telegram
2. **Contributor** picks it up from the shared registry-backed workspace → creates or reuses a feature branch → AI implements → pushes PR
3. **Reviewer** reviews the PR diff → AI approves+merges (→ `done`) or posts review feedback for another contributor retry
4. **Retry pass** contributor reuses the same issue/PR until approval or retry cap
5. **Sync** pulls merged changes back into clean local repos

## Setup

```bash
cp .env.example .env
# Edit .env with your tokens

# Build or refresh the managed repo registry:
bash discover-registry.sh

# One-off test:
bash orchestrate.sh --dry-run

# Preferred long-running service:
bash service.sh start
bash service.sh status
bash service.sh logs
bash service.sh stop

# One foreground cycle through the service wrapper:
bash service.sh run --once --dry-run
```

## Scripts

| Script | Purpose |
|---|---|
| `sync.sh` | Sync clean repos listed in `registry.tsv` |
| `orchestrate.sh` | Master loop: sync → registry/PM link → contribute → review → retry pass |
| `discover-registry.sh` | Discover local repos and write `registry.tsv` |
| `service-runner.sh` | Long-running loop wrapper for `orchestrate.sh` |
| `service.sh` | Start/stop/status/logs control script for the service |
| `cron-runner.sh` | Backward-compatible wrapper to `service-runner.sh` |

## Flags

- `--dry-run` — No actual changes, just log what would happen
- `--skip-sync` — Skip the git pull phase (orchestrate.sh only)
- `--registry-only` — Sync registry entries to PM projects, then stop before contributor/reviewer phases
- `--once` — Run exactly one service cycle and exit (`service-runner.sh`)
- `--interval-minutes N` — Override the service poll interval (`service-runner.sh`)

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PM_API` | `https://pm.wfh.day` | Project Manager API URL |
| `PM_TOKEN` | (required) | PM API token |
| `GITHUB_TOKEN` | (required) | GitHub PAT |
| `WORKSPACE_ROOT` | `~/projects` | Base directory containing local repos |
| `AI_PROVIDER` | `codex` | `codex`, `gemini`, or `antigravity` |
| `TARGET_MODEL` | `gpt-5-codex` | AI model to use |
| `AGY_BASE_DIR` | `~/projects` | Legacy alias for `WORKSPACE_ROOT` |
| `REGISTRY_FILE` | `./registry.tsv` | Explicit managed repo registry |
| `CONTRIBUTOR_SCRIPT` | `~/projects/project-contributor/contribute.sh` | Path to contributor script |
| `REVIEWER_SCRIPT` | `~/projects/project-reviewer/review.sh` | Path to reviewer script |
| `MAX_REVIEW_ATTEMPTS` | `3` | Retry cap before an issue is marked as needing human attention |
| `INTERVAL_MINUTES` | `30` | Cron interval |

## Registry

`registry.tsv` is now the source of truth. Each non-comment line is:

```text
enabled<TAB>repo_dir<TAB>github_repo<TAB>project_name<TAB>project_id
```

- `enabled=1` means the repo is actively managed by `agy-sync`
- `project_id` may be blank; `orchestrate.sh` will create or link the PM project on the next run
- third-party repos can stay in the file with `enabled=0`
