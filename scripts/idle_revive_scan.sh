#!/usr/bin/env bash
# idle_revive_scan.sh — cmd_1154 柱1 bash wrapper.
# Delegates to scripts/idle_revive_scan.py; auto-selects .venv python when available.
# karo 非依存の idle-poll / auto-revive scan(stall_watchdog_scan.sh 兄弟構造)。
# Usage (same flags as the python entrypoint):
#   bash scripts/idle_revive_scan.sh [--dry-run] [--stall-min N] [--min-interval-min N] \
#       [--max-consecutive N] [--json] [--queue-root PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python3"
else
    PYTHON="$(command -v python3 || true)"
fi

if [ -z "${PYTHON:-}" ]; then
    echo "[idle_revive] ERROR: python3 not found (tried .venv and PATH)" >&2
    exit 2
fi

# ═══════════════════════════════════════════════════════════════════
# cmd_1339 ④: watcher_supervisor 生存監視 (cron 相乗り)
# ───────────────────────────────────────────────────────────────────
# 2026-07-17〜07-25 の8日間 supervisor + ledger_guard 不在に誰も気付けなかった
# 実害の再発防止。本 wrapper は cron (3分毎) で supervisor 非依存に走るゆえ、
# 「監視者の不在を監視する」場所として正しい (supervisor 自身や ledger_guard は
# 共倒れするため不適)。判定は lifetime lock (契約) + pgrep (旧世代 fallback)。
# 警告は 30 分 throttle (家老 inbox spam 防止)。emit 失敗は latch せず次回再試行。
# ═══════════════════════════════════════════════════════════════════
check_supervisor_liveness() {
    # shellcheck source=lib/proc_lock.sh
    . "$SCRIPT_DIR/scripts/lib/proc_lock.sh" 2>/dev/null || return 0
    local state="$SCRIPT_DIR/queue/state/supervisor_absent_notified"
    if proc_lock_is_held "watcher_supervisor" \
        || pgrep -f "scripts/watcher_supervisor\.sh" >/dev/null 2>&1; then
        rm -f "$state" 2>/dev/null || true
        return 0
    fi
    echo "[idle_revive] WARN: watcher_supervisor 不在を検知" >&2
    local now last=0
    now=$(date +%s)
    if [ -f "$state" ]; then
        last=$(head -1 "$state" 2>/dev/null || echo 0)
        case "$last" in (*[!0-9]*|'') last=0 ;; esac
    fi
    if [ $((now - last)) -lt 1800 ]; then
        return 0
    fi
    if bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo \
        "🚨watcher_supervisor不在を検知(idle_revive cron監視・cmd_1339 ④)。watcher自動復旧/ledger_guard維持/pane drift検知が全停止しておる(2026-07-17〜25に8日間不在で交差配達事故の温床となった構造)。復旧手順= cd $SCRIPT_DIR && nohup bash scripts/watcher_supervisor.sh >> logs/watcher_supervisor.log 2>&1 & — lifetime lockが二重起動を自動防止するゆえ安全に実行できる。本警告は30分に一度。" \
        warning idle_revive_scan >&2; then
        echo "$now" > "$state"
    else
        echo "[idle_revive] FATAL: supervisor不在警告の inbox_write 失敗 — 次回 cron で再試行" >&2
    fi
    return 0
}
mkdir -p "$SCRIPT_DIR/queue/state" 2>/dev/null || true
check_supervisor_liveness || true

exec "$PYTHON" "$SCRIPT_DIR/scripts/idle_revive_scan.py" "$@"
