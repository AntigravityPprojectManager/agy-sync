# agy-sync — Orchestrator for ~/agy/

Ties together `project-manager`, `project-contributer`, and `project-reviewer` into a continuous automated loop.

## What it does

```
┌─────────────────────────────────────────────────────┐
│                   cron-runner.sh                     │
│                (every 30 minutes)                    │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │              orchestrate.sh                    │  │
│  │                                                │  │
│  │  1. SYNC    → git pull all repos in ~/agy/     │  │
│  │  2. CONTRIBUTE → for each PM project:          │  │
│  │       pick todo issue → AI implement → PR      │  │
│  │  3. REVIEW  → for each PM project:             │  │
│  │       fetch in-progress PRs → AI review        │  │
│  │       → approve+merge or reject                │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Full lifecycle

1. **Issue created** via PM web UI or Telegram
2. **Contributor** picks it up → creates feature branch → AI implements → pushes PR → sets issue to `in_progress`
3. **Reviewer** reviews the PR diff → AI approves+merges (→ `done`) or rejects+closes (→ `error`)
4. **Sync** pulls the merged changes back into all local repos

## Setup

```bash
cp .env.example .env
# Edit .env with your tokens

# One-off test:
bash orchestrate.sh --dry-run

# Start the loop:
nohup bash cron-runner.sh &
```

## Scripts

| Script | Purpose |
|---|---|
| `sync.sh` | Git-pull all repos in `~/agy/` with merge failure handling |
| `orchestrate.sh` | Master loop: sync → contribute (all projects) → review (all projects) |
| `cron-runner.sh` | Periodic wrapper that runs `orchestrate.sh` every N minutes |

## Flags

- `--dry-run` — No actual changes, just log what would happen
- `--skip-sync` — Skip the git pull phase (orchestrate.sh only)

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PM_API` | `https://pm.wfh.day` | Project Manager API URL |
| `PM_TOKEN` | (required) | PM API token |
| `GITHUB_TOKEN` | (required) | GitHub PAT |
| `AI_PROVIDER` | `gemini` | `gemini` or `antigravity` |
| `TARGET_MODEL` | `gemini-2.5-pro` | AI model to use |
| `AGY_BASE_DIR` | `~/agy` | Base directory containing all repos |
| `CONTRIBUTOR_SCRIPT` | `~/agy/project-contributer/contribute.sh` | Path to contributor script |
| `REVIEWER_SCRIPT` | `~/agy/project-reviewer/review.sh` | Path to reviewer script |
| `INTERVAL_MINUTES` | `30` | Cron interval |
