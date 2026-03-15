#!/usr/bin/env bash
# Backward-compatible wrapper. Prefer service-runner.sh or service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/service-runner.sh" "$@"
