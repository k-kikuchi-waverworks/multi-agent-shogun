#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from>
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5
#
# Exit code contract (cmd_1338): 0 = message written & verified on disk / non-0 = NOT written.
#   Callers MUST NOT ignore a non-zero exit — the message is lost and must be resent.
# NOTE: overflow整理(50件超過時)は「unread全件 + read末尾30件」を残す仕様。
#   ★未読が配列先頭側へ並べ替えられ時系列順でなくなる★が、未読を落とさぬための設計 — 変更禁。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ${N:-} defaults: set -u の下で引数不足時も Usage 分岐へ到達させる (即死させない)
TARGET="${1:-}"
CONTENT="${2:-}"
TYPE="${3:-}"
FROM="${4:-}"

# Deprecated gunshi redirect (write-layer): gunshi/gunshi_a/gunshi_b → active gunshi (Round-robin)
# Ensures ashigaru reports land in active gunshi1/2 inboxes regardless of caller using deprecated name.
case "$TARGET" in
    gunshi|gunshi_a|gunshi_b)
        _LIB="$SCRIPT_DIR/scripts/lib/agent_list.sh"
        if [ -f "$_LIB" ]; then
            # shellcheck source=scripts/lib/agent_list.sh
            . "$_LIB"
            _ACTIVE_GUNSHI=$(get_active_gunshi_agents 2>/dev/null || true)
            if [ -n "$_ACTIVE_GUNSHI" ]; then
                # Round-robin: pick agent with fewest unread messages
                _BEST_TARGET=""
                _BEST_COUNT=999999
                while IFS= read -r _AGENT; do
                    [ -z "$_AGENT" ] && continue
                    _AGENT_INBOX="$SCRIPT_DIR/queue/inbox/${_AGENT}.yaml"
                    if [ -f "$_AGENT_INBOX" ]; then
                        _COUNT=$(grep -c "read: false" "$_AGENT_INBOX" 2>/dev/null || true)
                        _COUNT=${_COUNT:-0}
                    else
                        _COUNT=0
                    fi
                    if [ "$_COUNT" -lt "$_BEST_COUNT" ]; then
                        _BEST_COUNT=$_COUNT
                        _BEST_TARGET=$_AGENT
                    fi
                done <<< "$_ACTIVE_GUNSHI"
                if [ -n "$_BEST_TARGET" ]; then
                    echo "[inbox_write] REDIRECT: deprecated '$TARGET' → '$_BEST_TARGET' (active gunshi, unread=$_BEST_COUNT)" >&2
                    TARGET="$_BEST_TARGET"
                else
                    echo "[inbox_write] WARNING: redirect failed, defaulting '$TARGET' → 'gunshi1'" >&2
                    TARGET="gunshi1"
                fi
            else
                echo "[inbox_write] WARNING: no active gunshi found, defaulting '$TARGET' → 'gunshi1'" >&2
                TARGET="gunshi1"
            fi
        else
            echo "[inbox_write] WARNING: agent_list.sh not found, defaulting '$TARGET' → 'gunshi1'" >&2
            TARGET="gunshi1"
        fi
        ;;
esac

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from>" >&2
    exit 1
fi

# Self-send guard: reject messages where sender == target
if [ "$FROM" = "$TARGET" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Escalate suppression: skip if suppress flag file exists for this sender
SUPPRESS_FLAG="$SCRIPT_DIR/queue/suppress_escalate_${FROM}.flag"
if [ "$TYPE" = "escalate" ] && [ -f "$SUPPRESS_FLAG" ]; then
    echo "[inbox_write] SUPPRESSED: escalate from $FROM suppressed by flag file" >&2
    exit 0
fi

# Initialize inbox if not exists
# dangling symlink recovery: queue/inbox が壊れたシンボリックリンクならリンク先を再生成
_inbox_parent="$(dirname "$INBOX")"
if [ -L "$_inbox_parent" ] && [ ! -d "$_inbox_parent" ]; then
    mkdir -p "$(readlink "$_inbox_parent")"
fi
if [ ! -f "$INBOX" ]; then
    mkdir -p "$_inbox_parent"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-process lock: mkdir coordinates with OpenCode tools; flock is added when available.
LOCK_DIR="${LOCKFILE}.d"

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

# External inputs (content/from/type) and paths MUST NOT be interpolated into the
# python source: a body containing a backslash (e.g. a Windows path C:\Users\...)
# becomes a truncated \UXXXXXXXX escape → SyntaxError → all retries fail (cmd_1345),
# and a body containing ''' escapes the string literal entirely. Pass everything
# via environment variables; the python source below is a fixed single-quoted string.
export IW_INBOX="$INBOX"
export IW_MSG_ID="$MSG_ID"
export IW_FROM="$FROM"
export IW_TIMESTAMP="$TIMESTAMP"
export IW_TYPE="$TYPE"
export IW_CONTENT="$CONTENT"

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        trap _release_lock EXIT
        if "$SCRIPT_DIR/.venv/bin/python3" -c '
import os, sys, yaml

try:
    inbox = os.environ["IW_INBOX"]

    # Load existing inbox
    with open(inbox) as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get("messages"):
        data["messages"] = []

    # Add new message
    new_msg = {
        "id": os.environ["IW_MSG_ID"],
        "from": os.environ["IW_FROM"],
        "timestamp": os.environ["IW_TIMESTAMP"],
        "type": os.environ["IW_TYPE"],
        "content": os.environ["IW_CONTENT"],
        "read": False
    }
    data["messages"].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data["messages"]) > 50:
        msgs = data["messages"]
        unread = [m for m in msgs if not m.get("read", False)]
        read = [m for m in msgs if m.get("read", False)]
        # Keep all unread + newest 30 read messages
        data["messages"] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox), suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox)
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
'; then
            STATUS=0
        else
            STATUS=$?
        fi
        # Read-back verify (still under lock): python exit 0 でも実在を確かめる。
        # inbox は最大50件ゆえ grep 1回=軽量。書けたつもり事故の最終網 (cmd_1338)。
        if [ $STATUS -eq 0 ] && ! grep -qF "id: $MSG_ID" "$INBOX" 2>/dev/null; then
            echo "[inbox_write] VERIFY FAILED: $MSG_ID not found in $INBOX after write" >&2
            STATUS=1
        fi
        _release_lock
        trap - EXIT
        if [ $STATUS -eq 0 ]; then
            echo "[inbox_write] OK: $MSG_ID -> $TARGET" >&2
            exit 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] WRITE FAILED for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        fi
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done

# Retry exhausted = message was NOT written. Never fall through silently (cmd_1338).
echo "[inbox_write] FATAL: message NOT delivered to $TARGET after $max_attempts attempts (from=$FROM, type=$TYPE, msg_id=$MSG_ID). Message is LOST — sender must resend or escalate." >&2
exit 1
