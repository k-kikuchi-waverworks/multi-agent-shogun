#!/usr/bin/env bats
# test_inbox_watcher_branches.bats — characterization tests for untested branches
# (cmd_1160 cmd-3A: test-only, NO changes to scripts/inbox_watcher.sh)
#
# Sources the REAL inbox_watcher.sh with __INBOX_WATCHER_TESTING__=1, same
# harness pattern as test_send_wakeup.bats. These tests LOCK current behavior
# before the cmd-3B..3E extraction stages — they assert what the code DOES
# today, not what it arguably should do.
#
# テスト構成:
#   T-CLI-001: get_effective_cli_type — pane/arg drift → pane値優先 + WARN
#   T-CLI-002: get_effective_cli_type — invalid pane値 → arg fallback + WARN
#   T-CLI-003: get_effective_cli_type — pane=gemini → antigravity 正規化
#   T-CLI-004: get_effective_cli_type — arg=agy → antigravity 正規化
#   T-CLI-005: get_effective_cli_type — 両方invalid → codex fail-closed
#   T-CLI-006: get_effective_cli_type — arg=cursor は invalid 扱い → codex fail-closed
#              (※cursor は is_valid_cli_type に含まれず、send_cli_command /
#               send_context_reset の cursor 分岐は通常解決では到達不能=現状仕様。
#               cmd-3D adapter table 化の際の要検討ポイントとして挙動を凍結)
#   T-NSC-001: normalize_special_command — clear_command→/clear, cli_restart→marker
#   T-CURSOR-101: send_cli_command cursor分岐 — /clear → /new-chat (強制解決時)
#   T-CURSOR-102: send_cli_command cursor分岐 — NEW_CONTEXT_SENT=1 → duplicate skip
#   T-CURSOR-103: send_cli_command cursor分岐 — /model は general path 送信 (skipしない)
#   T-KIMI-001: send_cli_command kimi — /clear は general path (C-c + /clear as-is)
#   T-KIMI-002: send_wakeup_with_escape kimi — Escape×2 + C-c + nudge
#   T-KIMI-003: send_context_reset kimi (ashigaru) — /clear 送信 + busy poll
#   T-AGY-101: send_wakeup_with_escape antigravity — Escape抑止 → plain nudge
#   T-CRESET-105: send_context_reset antigravity (ashigaru) — /clear 送信
#   T-CRESET-106: send_context_reset cursor分岐 — /new-chat (C-u/startup promptなし)
#   T-STARTUP-001: send_startup_prompt claude idle — x + C-u dismissal + fallback prompt
#   T-STARTUP-002: send_startup_prompt opencode — dismissal (x/C-u) をskipして送信
#   T-STARTUP-003: send_startup_prompt busy持続 — 3回retry後 "proceeding anyway" 送信
#   T-STALE-001: stale-busy safety net — ashigaru busy≥90s+未読 → idle flag強制 + stall_alert
#   T-STALE-002: stale-busy safety net — STALL_NOTIFIED=1 → stall_alert 再送しない
#   T-STALE-003: stale-busy safety net — 非ashigaru → idle flag強制のみ (stall_alertなし)
#   T-STALE-004: busy(claude)非stale — "Stop hook will deliver" + timer開始 + nudgeなし
#   T-STALE-005: busy(非claude)非stale — "pausing escalation timer" + nudgeなし

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/watcher_branches_test.XXXXXX")"

    # Log file for tmux mock calls (all tmux invocations recorded here)
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    # Create mock pgrep (default: no self-watch found)
    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    # Create test inbox directory
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Keep metrics writes inside the sandbox (update_metrics runs in process_unread)
    export METRICS_FILE="$TEST_TMPDIR/metrics_selfwatch.yaml"

    # Fake project root for tests that exercise the stall_alert path:
    # process_unread calls "bash $SCRIPT_DIR/scripts/inbox_write.sh karo ...".
    # Point SCRIPT_DIR here so the REAL karo inbox is never touched.
    # .venv is symlinked so the embedded-python helpers keep working.
    export FAKE_ROOT="$TEST_TMPDIR/fakeroot"
    mkdir -p "$FAKE_ROOT/scripts"
    ln -s "$PROJECT_ROOT/.venv" "$FAKE_ROOT/.venv"
    cat > "$FAKE_ROOT/scripts/inbox_write.sh" << MOCK
#!/bin/bash
echo "inbox_write \$*" >> "$MOCK_LOG"
exit 0
MOCK
    chmod +x "$FAKE_ROOT/scripts/inbox_write.sh"

    # Default mock control variables
    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE=""
    export MOCK_LIST_CLIENTS=""

    # Test harness: sets up mocks, then sources the REAL inbox_watcher.sh
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
# Variables required by inbox_watcher.sh functions
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

# Mock external commands (defined before sourcing so they override real commands)
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    if echo "\$*" | grep -q "capture-pane"; then
        echo "\${MOCK_CAPTURE_PANE:-}"
        return 0
    fi
    if echo "\$*" | grep -q "send-keys"; then
        return \${MOCK_SENDKEYS_RC:-0}
    fi
    if echo "\$*" | grep -q "show-options"; then
        echo "\${MOCK_PANE_CLI:-}"
        return 0
    fi
    if echo "\$*" | grep -q "list-clients"; then
        [ -n "\${MOCK_LIST_CLIENTS:-}" ] && echo "\$MOCK_LIST_CLIENTS"
        return 0
    fi
    if echo "\$*" | grep -q "display-message"; then
        if echo "\$*" | grep -q "pane_active"; then
            echo "\${MOCK_PANE_ACTIVE:-0}"
        else
            echo "mock_session"
        fi
        return 0
    fi
    return 0
}
timeout() { shift; "\$@"; }
pgrep() { "$MOCK_PGREP" "\$@"; }
sleep() { :; }
export -f tmux timeout pgrep sleep

# Production sources scripts/lib/agent_list.sh at startup (is_command_layer_agent).
# The testing guard skips that block, so load it here to match production behavior.
source "$PROJECT_ROOT/scripts/lib/agent_list.sh"

# Source the REAL inbox_watcher.sh (testing guard skips startup & main loop)
export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"

    # Default: create idle flag so agent_is_busy() returns idle (1) for claude CLI
    touch "$TEST_TMPDIR/shogun_idle_test_agent"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════
# get_effective_cli_type — drift / fallback / fail-closed
# ═══════════════════════════════════════════════════════════════

# --- T-CLI-001: pane/arg drift → pane value wins + WARN ---

@test "T-CLI-001: get_effective_cli_type prefers pane value on drift and warns" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        val=$(get_effective_cli_type 2>"'"$TEST_TMPDIR"'/stderr.log")
        echo "VAL=$val"
        cat "'"$TEST_TMPDIR"'/stderr.log"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VAL=codex"
    echo "$output" | grep -q "CLI drift detected"
}

# --- T-CLI-002: invalid pane value → arg fallback + WARN ---

@test "T-CLI-002: get_effective_cli_type falls back to arg when pane value is invalid" {
    run bash -c '
        MOCK_PANE_CLI="garbage_cli"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        val=$(get_effective_cli_type 2>"'"$TEST_TMPDIR"'/stderr.log")
        echo "VAL=$val"
        cat "'"$TEST_TMPDIR"'/stderr.log"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VAL=copilot"
    echo "$output" | grep -q "Invalid pane @agent_cli"
}

# --- T-CLI-003: pane=gemini → antigravity normalization ---

@test "T-CLI-003: get_effective_cli_type normalizes pane gemini to antigravity" {
    run bash -c '
        MOCK_PANE_CLI="gemini"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        val=$(get_effective_cli_type 2>/dev/null)
        echo "VAL=$val"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VAL=antigravity"
}

# --- T-CLI-004: arg=agy → antigravity normalization ---

@test "T-CLI-004: get_effective_cli_type normalizes arg agy to antigravity" {
    run bash -c '
        MOCK_PANE_CLI=""
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="agy"
        val=$(get_effective_cli_type 2>/dev/null)
        echo "VAL=$val"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VAL=antigravity"
}

# --- T-CLI-005: both invalid → codex fail-closed ---

@test "T-CLI-005: get_effective_cli_type fails closed to codex when unresolved" {
    run bash -c '
        MOCK_PANE_CLI=""
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="unknown_cli"
        val=$(get_effective_cli_type 2>"'"$TEST_TMPDIR"'/stderr.log")
        echo "VAL=$val"
        cat "'"$TEST_TMPDIR"'/stderr.log"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VAL=codex"
    echo "$output" | grep -q "Fallback=codex-safe"
}

# --- T-CLI-006: arg=cursor is treated as invalid → codex fail-closed ---
# CHARACTERIZATION: "cursor" is NOT in is_valid_cli_type's accepted list, so the
# cursor-specific branches in send_cli_command / send_context_reset are
# unreachable through normal CLI resolution today. Locked here so the cmd-3D
# adapter-table extraction must consciously decide whether to keep or fix this.

@test "T-CLI-006: get_effective_cli_type treats cursor as invalid (codex fail-closed)" {
    run bash -c '
        MOCK_PANE_CLI=""
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="cursor"
        val=$(get_effective_cli_type 2>"'"$TEST_TMPDIR"'/stderr.log")
        echo "VAL=$val"
        cat "'"$TEST_TMPDIR"'/stderr.log"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "VAL=codex"
    echo "$output" | grep -q "Fallback=codex-safe"
}

# ═══════════════════════════════════════════════════════════════
# normalize_special_command — clear_command / cli_restart marker
# ═══════════════════════════════════════════════════════════════

@test "T-NSC-001: normalize_special_command maps clear_command and cli_restart" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        c1=$(normalize_special_command "clear_command" "any payload")
        c2=$(normalize_special_command "cli_restart" "codex gpt-5")
        c3=$(normalize_special_command "unknown_type" "payload")
        echo "C1=$c1"
        echo "C2=$c2"
        echo "C3=[$c3]"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C1=/clear"
    echo "$output" | grep -q "C2=__CLI_RESTART__:codex gpt-5"
    echo "$output" | grep -q "C3=\[\]"
}

# ═══════════════════════════════════════════════════════════════
# send_cli_command — cursor branch (reachable only when the resolver
# returns "cursor"; forced here via function override — see T-CLI-006)
# ═══════════════════════════════════════════════════════════════

# --- T-CURSOR-101: cursor /clear → /new-chat ---

@test "T-CURSOR-101: send_cli_command cursor branch converts /clear to /new-chat" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_effective_cli_type() { echo "cursor"; }
        send_cli_command "/clear"
        echo "NEW_CONTEXT_SENT=$NEW_CONTEXT_SENT"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new-chat" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    # cursor branch returns before the general C-c + send path
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
    echo "$output" | grep -q "NEW_CONTEXT_SENT=1"
}

# --- T-CURSOR-102: cursor /clear duplicate guard ---

@test "T-CURSOR-102: send_cli_command cursor branch skips duplicate /new-chat" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_effective_cli_type() { echo "cursor"; }
        NEW_CONTEXT_SENT=1
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "already sent"
    ! grep -q "send-keys.*/new-chat" "$MOCK_LOG"
}

# --- T-CURSOR-103: cursor /model is NOT skipped (general path) ---
# CHARACTERIZATION: unlike codex/copilot/opencode/antigravity, the cursor case
# arm has no /model handler, so /model falls through to the general send path.

@test "T-CURSOR-103: send_cli_command cursor branch passes /model through general path" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_effective_cli_type() { echo "cursor"; }
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/model opus" "$MOCK_LOG"
    # non-codex CLIs get C-c stale-input clearing before the command
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*Enter" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# kimi branches
# ═══════════════════════════════════════════════════════════════

# --- T-KIMI-001: kimi /clear via general path ---
# kimi has no case arm in send_cli_command → /clear is sent as-is
# (C-c stale-input clear + /clear + Enter), no startup prompt (claude-only).

@test "T-KIMI-001: send_cli_command sends /clear as-is for kimi (general path)" {
    run bash -c '
        MOCK_PANE_CLI="kimi"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="kimi"
        send_cli_command "/clear"
        echo "LAST_CLEAR_TS=$LAST_CLEAR_TS"
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    # startup prompt after /clear is claude-only
    ! grep -q "Session Start" "$MOCK_LOG"
    # /clear timestamp recorded for the 30s busy cooldown
    ! echo "$output" | grep -q "LAST_CLEAR_TS=0"
    echo "$output" | grep -q "LAST_CLEAR_TS="
}

# --- T-KIMI-002: kimi Phase 2 escalation uses Escape×2 + C-c + nudge ---

@test "T-KIMI-002: send_wakeup_with_escape sends Escape and C-c for kimi" {
    run bash -c '
        MOCK_PANE_CLI="kimi"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="kimi"
        send_wakeup_with_escape 3
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*Escape" "$MOCK_LOG"
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*inbox3" "$MOCK_LOG"
}

# --- T-KIMI-003: send_context_reset kimi → /clear ---

@test "T-KIMI-003: send_context_reset sends /clear for kimi ashigaru" {
    run bash -c '
        MOCK_PANE_CLI="kimi"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="kimi"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    echo "$output" | grep -q "CONTEXT-RESET"
}

# ═══════════════════════════════════════════════════════════════
# antigravity branches
# ═══════════════════════════════════════════════════════════════

# --- T-AGY-101: antigravity Phase 2 escalation falls back to plain nudge ---

@test "T-AGY-101: send_wakeup_with_escape suppresses Escape for antigravity (plain nudge)" {
    run bash -c '
        MOCK_PANE_CLI="antigravity"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="antigravity"
        send_wakeup_with_escape 2
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "suppressing Escape escalation"
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*inbox2" "$MOCK_LOG"
}

# --- T-CRESET-105: send_context_reset antigravity → /clear ---

@test "T-CRESET-105: send_context_reset sends /clear for antigravity ashigaru" {
    run bash -c '
        MOCK_PANE_CLI="antigravity"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru3"
        CLI_TYPE="antigravity"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    echo "$output" | grep -q "CONTEXT-RESET.*antigravity"
}

# --- T-CRESET-106: send_context_reset cursor branch → /new-chat ---
# Forced resolver (see T-CLI-006). cursor path: no C-u (cursor excluded),
# no "x" dismissal (codex-only), no startup prompt (codex-only).

@test "T-CRESET-106: send_context_reset cursor branch sends /new-chat without C-u or startup prompt" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_effective_cli_type() { echo "cursor"; }
        AGENT_ID="ashigaru3"
        send_context_reset
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/new-chat" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*C-u" "$MOCK_LOG"
    ! grep -q "Session Start" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# send_startup_prompt
# ═══════════════════════════════════════════════════════════════

# --- T-STARTUP-001: claude idle → dismissal + fallback prompt ---
# In testing mode lib/cli_adapter.sh is not sourced, so get_startup_prompt is
# undefined and the built-in fallback prompt ("Session Start ...") is used.

@test "T-STARTUP-001: send_startup_prompt sends x + C-u dismissal and fallback prompt when idle (claude)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_startup_prompt
        echo "STARTUP_PROMPT_SENT=$STARTUP_PROMPT_SENT"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "idle after 1×5s"
    # Suggestion-UI dismissal: literal "x" then C-u
    grep -qE "send-keys -t test:0.0 x$" "$MOCK_LOG"
    grep -q "send-keys.*C-u" "$MOCK_LOG"
    # Prompt sent literally (-l) with the fallback Session Start text + Enter
    grep -q "send-keys -l" "$MOCK_LOG"
    grep -q "Session Start" "$MOCK_LOG"
    grep -q "send-keys.*Enter" "$MOCK_LOG"
    echo "$output" | grep -q "STARTUP_PROMPT_SENT=1"
}

# --- T-STARTUP-002: opencode skips dismissal keystrokes ---

@test "T-STARTUP-002: send_startup_prompt skips x/C-u dismissal for opencode" {
    run bash -c '
        MOCK_PANE_CLI="opencode"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="opencode"
        send_startup_prompt
    '
    [ "$status" -eq 0 ]

    ! grep -qE "send-keys -t test:0.0 x$" "$MOCK_LOG"
    ! grep -q "send-keys.*C-u" "$MOCK_LOG"
    grep -q "send-keys -l" "$MOCK_LOG"
    grep -q "Session Start" "$MOCK_LOG"
}

# --- T-STARTUP-003: busy persists → proceed anyway after 3 attempts ---

@test "T-STARTUP-003: send_startup_prompt proceeds anyway after 15s busy" {
    rm -f "$TEST_TMPDIR/shogun_idle_test_agent"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        send_startup_prompt
        echo "STARTUP_PROMPT_SENT=$STARTUP_PROMPT_SENT"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "still busy after 3×5s"
    echo "$output" | grep -q "proceeding with startup prompt anyway"
    # Prompt is still sent
    grep -q "send-keys -l" "$MOCK_LOG"
    echo "$output" | grep -q "STARTUP_PROMPT_SENT=1"
}

# ═══════════════════════════════════════════════════════════════
# stale-busy safety net (process_unread busy branch)
# ═══════════════════════════════════════════════════════════════

# Helper inbox: one unread NORMAL message (not task_assigned → no context reset)
write_unread_inbox() {
    local inbox_path="$1"
    cat > "$inbox_path" << 'YAML'
messages:
  - id: msg_norm
    from: karo
    timestamp: "2026-07-02T12:00:00+09:00"
    type: report_received
    content: hello
    read: false
YAML
}

# --- T-STALE-001: ashigaru busy ≥90s with unread → force idle flag + stall_alert ---

@test "T-STALE-001: stale-busy forces idle flag and sends stall_alert to karo for ashigaru" {
    write_unread_inbox "$TEST_INBOX_DIR/ashigaru9.yaml"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        rm -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru9"   # busy (no idle flag, claude)
        FIRST_UNREAD_SEEN=$(( $(date +%s) - 100 ))     # ≥ stale_busy_limit(90s)
        process_unread event
        echo "STALL_NOTIFIED=$STALL_NOTIFIED"
        [ -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru9" ] && echo "FLAG_CREATED"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "forcing idle flag"
    echo "$output" | grep -q "FLAG_CREATED"
    echo "$output" | grep -q "STALL_NOTIFIED=1"
    # stall_alert delivered via inbox_write.sh (mocked) to karo, exactly once
    grep -q "inbox_write karo" "$MOCK_LOG"
    grep -q "stall_alert" "$MOCK_LOG"
    [ "$(grep -c "inbox_write karo" "$MOCK_LOG")" -eq 1 ]
    # After forcing the flag, execution falls through to the normal nudge path
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-STALE-002: stall_alert throttled to once per stall event ---

@test "T-STALE-002: stale-busy does not resend stall_alert when STALL_NOTIFIED=1" {
    write_unread_inbox "$TEST_INBOX_DIR/ashigaru9.yaml"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        rm -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru9"
        FIRST_UNREAD_SEEN=$(( $(date +%s) - 100 ))
        STALL_NOTIFIED=1
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "forcing idle flag"
    ! grep -q "inbox_write karo" "$MOCK_LOG"
}

# --- T-STALE-003: non-ashigaru stale-busy → flag forced, no stall_alert ---

@test "T-STALE-003: stale-busy forces idle flag but skips stall_alert for non-ashigaru" {
    write_unread_inbox "$TEST_INBOX_DIR/test_agent.yaml"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        rm -f "$IDLE_FLAG_DIR/shogun_idle_test_agent"
        FIRST_UNREAD_SEEN=$(( $(date +%s) - 100 ))
        process_unread event
        [ -f "$IDLE_FLAG_DIR/shogun_idle_test_agent" ] && echo "FLAG_CREATED"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "forcing idle flag"
    echo "$output" | grep -q "FLAG_CREATED"
    ! grep -q "inbox_write karo" "$MOCK_LOG"
}

# --- T-STALE-004: busy (claude) not yet stale → Stop hook deferral, no nudge ---

@test "T-STALE-004: busy claude agent defers to Stop hook and starts the stale timer" {
    write_unread_inbox "$TEST_INBOX_DIR/test_agent.yaml"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        rm -f "$IDLE_FLAG_DIR/shogun_idle_test_agent"   # busy
        FIRST_UNREAD_SEEN=0
        process_unread event
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "Stop hook will deliver"
    # Timer started so the stale-busy safety net can fire later
    ! echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
    # No nudge while busy
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-STALE-005: busy (non-claude) → escalation timer paused, no nudge ---

@test "T-STALE-005: busy non-claude agent pauses escalation timer without nudge" {
    write_unread_inbox "$TEST_INBOX_DIR/test_agent.yaml"
    run bash -c '
        MOCK_PANE_CLI="copilot"
        MOCK_CAPTURE_PANE="◦ Working on task (12s • esc to interrupt)"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        SCRIPT_DIR="'"$FAKE_ROOT"'"
        FIRST_UNREAD_SEEN=0
        process_unread event
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "pausing escalation timer"
    ! echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}
