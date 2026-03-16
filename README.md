# agy-sync — Orchestrator for ~/projects

Ties together `project-manager`, `project-contributor`, and `project-reviewer` into a continuous automated loop for GitHub-backed repos under `~/projects`.

## What it does

```
┌─────────────────────────────────────────────────────┐
│                   cron-runner.sh                     │
│                (every 30 minutes)                    │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │              orchestrate.sh                    │  │
│  │                                                │  │
│  │  1. SYNC    → sync managed repos in ~/projects │  │
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
2. **Contributor** picks it up from the shared `~/projects` workspace → creates or reuses a feature branch → AI implements → pushes PR
3. **Reviewer** reviews the PR diff → AI approves+merges (→ `done`) or posts review feedback for another contributor retry
4. **Retry pass** contributor reuses the same issue/PR until approval or retry cap
5. **Sync** pulls merged changes back into clean local repos

## Setup

```bash
cp .env.example .env
# Edit .env with your tokens

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
| `sync.sh` | Recursively sync clean GitHub-backed repos under `~/projects/` |
| `orchestrate.sh` | Master loop: sync → discover/link repos → contribute → review → retry pass |
| `service-runner.sh` | Long-running loop wrapper for `orchestrate.sh` |
| `service.sh` | Start/stop/status/logs control script for the service |
| `cron-runner.sh` | Backward-compatible wrapper to `service-runner.sh` |

## Flags

- `--dry-run` — No actual changes, just log what would happen
- `--skip-sync` — Skip the git pull phase (orchestrate.sh only)
- `--once` — Run exactly one service cycle and exit (`service-runner.sh`)
- `--interval-minutes N` — Override the service poll interval (`service-runner.sh`)

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PM_API` | `https://pm.wfh.day` | Project Manager API URL |
| `PM_TOKEN` | (required) | PM API token |
| `GITHUB_TOKEN` | (required) | GitHub PAT |
| `AI_PROVIDER` | `codex` | `codex`, `gemini`, or `antigravity` |
| `TARGET_MODEL` | `gpt-5.4-xhigh` | AI model to use |
| `WORKSPACE_ROOT` | `~/projects` | Base directory containing managed repos |
| `AGY_BASE_DIR` | `~/projects` | Legacy alias for `WORKSPACE_ROOT` |
| `CONTRIBUTOR_SCRIPT` | `~/projects/project-contributor/contribute.sh` | Path to contributor script |
| `REVIEWER_SCRIPT` | `~/projects/project-reviewer/review.sh` | Path to reviewer script |
| `MAX_REVIEW_ATTEMPTS` | `3` | Retry cap before an issue is marked as needing human attention |
| `INTERVAL_MINUTES` | `30` | Cron interval |
