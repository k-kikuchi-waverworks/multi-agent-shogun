#!/usr/bin/env bash
# stall_watchdog_scan.sh — cmd_552 Phase 3 Watchdog bash wrapper.
# Delegates to scripts/stall_watchdog_scan.py; auto-selects .venv python when available.
# Usage (same flags as the python entrypoint):
#   bash scripts/stall_watchdog_scan.sh [--dry-run] [--threshold-min N] [--json] [--queue-root PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python3"
else
    PYTHON="$(command -v python3 || true)"
fi

if [ -z "${PYTHON:-}" ]; then
    echo "[stall_watchdog] ERROR: python3 not found (tried .venv and PATH)" >&2
    exit 2
fi

exec "$PYTHON" "$SCRIPT_DIR/scripts/stall_watchdog_scan.py" "$@"
