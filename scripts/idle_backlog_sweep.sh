#!/usr/bin/env bash
# idle_backlog_sweep.sh — wrapper for cron backstop (cmd_1095)
# cron: */20 * * * * bash <ROOT>/scripts/idle_backlog_sweep.sh >> <ROOT>/logs/idle_backlog_sweep.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# logs ディレクトリ確保
mkdir -p "$ROOT/logs"

exec python3 "$SCRIPT_DIR/idle_backlog_sweep.py" "$@"
