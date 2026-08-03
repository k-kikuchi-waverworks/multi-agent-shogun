#!/usr/bin/env bats
# test_inbox_watcher_process_unread.bats — characterization tests for process_unread()
# (cmd_1160 #3A: test-only, NO changes to scripts/inbox_watcher.sh)
#
# process_unread (L1057-1310) is the escalation orchestrator and the single
# highest-risk function in inbox_watcher.sh: BEFORE this file it had ZERO direct
# unit tests (design §3-4, gunshi2). It mutates 9 shared globals and fans out to
# 13 functions. These tests LOCK its current behavior as a golden safety net so
# the post-launch cmd-3B..3E extraction stages cannot silently regress the
# busy/idle escalation state machine.
#
# Same harness pattern as test_inbox_watcher_branches.bats: source the REAL
# inbox_watcher.sh under __INBOX_WATCHER_TESTING__=1 (startup + main loop skipped).
# All tmux/pgrep/sleep are mocked; SCRIPT_DIR is redirected to a fake root so the
# real karo inbox / .venv are never touched (only symlinked read access).
#
# テスト構成:
#   escalation ladder (idle claude/copilot/codex, controllable age via FIRST_UNREAD_SEEN):
#     T-PU-P1-001 : Phase 1 (age<120s)           → send_wakeup (plain nudge), no Escape/clear
#     T-PU-P2-001 : Phase 2 (120<=age<240, claude) → send_wakeup_with_escape → claude degrades to plain nudge
#     T-PU-P2-002 : Phase 2 (copilot)             → real Escape×2 + C-c + nudge through the full path
#     T-PU-P3-001 : Phase 3 (age>=240, claude ash) → /clear + LAST_CLEAR_TS set + FIRST_UNREAD_SEEN=0 + NEW_CONTEXT_SENT=0
#     T-PU-P3-002 : Phase 3 (codex)               → skip /clear, reset timer, plain nudge
#     T-PU-P3-003 : Phase 3 (command-layer karo)  → suppress /clear, reset timer, Escape+nudge
#     T-PU-P3-004 : Phase 3 (/clear cooldown active) → Escape+nudge, no /clear
#   orchestration branches:
#     T-PU-RESET-001 : all-read (full path)  → escalation reset, globals cleared, idle flag touched
#     T-PU-RESET-002 : all-read (fast path, timeout+count0) → no full read (no metrics), idle flag + C-u
#     T-PU-CR-001    : task_assigned first-seen → send_context_reset (/clear) + NEW_CONTEXT_SENT=1
#     T-PU-CR-002    : NEW_CONTEXT_SENT=1 already → context reset skipped, straight to nudge
#     T-PU-CR-003    : command-layer karo task_assigned → context reset suppressed
#     T-PU-STARTUP-001 : STARTUP_PROMPT_SENT=1 → nudge skipped this cycle, flag reset
#     T-PU-DISABLE-001 : ASW_DISABLE_ESCALATION=1 → escalation bypassed, plain nudge
#     T-PU-CLEAR-001 : clear_command special → /clear sent + auto-recovery task enqueued to inbox
#     T-PU-CLEAR-002 : clear_command while busy → /clear deferred (not sent)
#     T-PU-ONCE-001  : process_unread_once → runs full read with "startup" trigger

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/watcher_pu_test.XXXXXX")"

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Keep metrics writes inside the sandbox (update_metrics runs in process_unread)
    export METRICS_FILE="$TEST_TMPDIR/metrics_pu.yaml"

    # Fake project root: process_unread calls "bash $SCRIPT_DIR/scripts/inbox_write.sh karo"
    # (stall_alert) and enqueue_recovery uses "$SCRIPT_DIR/.venv/bin/python3". Redirect
    # SCRIPT_DIR here so the REAL karo inbox is never touched; .venv is symlinked so the
    # embedded-python helpers keep working.
    export FAKE_ROOT="$TEST_TMPDIR/fakeroot"
    mkdir -p "$FAKE_ROOT/scripts"
    ln -s "$PROJECT_ROOT/.venv" "$FAKE_ROOT/.venv"
    cat > "$FAKE_ROOT/scripts/inbox_write.sh" << MOCK
#!/bin/bash
echo "inbox_write \$*" >> "$MOCK_LOG"
exit 0
MOCK
    chmod +x "$FAKE_ROOT/scripts/inbox_write.sh"

    export MOCK_CAPTURE_PANE=""
    export MOCK_SENDKEYS_RC=0
    export MOCK_PANE_CLI=""
    export MOCK_PANE_ACTIVE=""
    export MOCK_LIST_CLIENTS=""

    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
AGENT_ID="test_agent"
PANE_TARGET="test:0.0"
CLI_TYPE="claude"
INBOX="$TEST_INBOX_DIR/test_agent.yaml"
LOCKFILE="\${INBOX}.lock"
SCRIPT_DIR="$PROJECT_ROOT"
export IDLE_FLAG_DIR="$TEST_TMPDIR"

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

source "$PROJECT_ROOT/scripts/lib/agent_list.sh"

export __INBOX_WATCHER_TESTING__=1
source "$WATCHER_SCRIPT"
# Redirect to fake root AFTER sourcing (agent_status.sh tail-load needs the real
# repo path at source time; runtime helpers use the sandbox afterwards).
SCRIPT_DIR="$FAKE_ROOT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ─── inbox fixtures ───

write_normal_unread() {
    cat > "$1" << 'YAML'
messages:
  - id: msg_norm
    from: karo
    timestamp: "2026-07-02T12:00:00+09:00"
    type: report_received
    content: hello
    read: false
YAML
}

write_task_unread() {
    cat > "$1" << 'YAML'
messages:
  - id: msg_task
    from: karo
    timestamp: "2026-07-02T12:00:00+09:00"
    type: task_assigned
    content: "read your task"
    read: false
YAML
}

write_clear_unread() {
    cat > "$1" << 'YAML'
messages:
  - id: msg_clear
    from: karo
    timestamp: "2026-07-02T12:00:00+09:00"
    type: clear_command
    content: "reset context"
    read: false
YAML
}

write_all_read() {
    cat > "$1" << 'YAML'
messages:
  - id: msg_done
    from: karo
    timestamp: "2026-07-02T12:00:00+09:00"
    type: report_received
    content: hello
    read: true
YAML
}

# ═══════════════════════════════════════════════════════════════
# Escalation ladder — idle agent, age driven by FIRST_UNREAD_SEEN
# ═══════════════════════════════════════════════════════════════

# --- T-PU-P1-001: Phase 1 (fresh, age<120s) → plain nudge ---

@test "T-PU-P1-001: process_unread Phase 1 sends a plain nudge for a fresh unread (idle claude)" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"   # idle
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        process_unread event
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*inbox1" "$MOCK_LOG"
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! echo "$output" | grep -q "escalating"
    ! echo "$output" | grep -q "ESCALATION Phase 3"
}

# --- T-PU-P2-001: Phase 2 (claude) degrades to plain nudge ---
# CHARACTERIZATION: claude suppresses the Phase-2 Escape escalation (Stop hook
# owns delivery), so the ladder enters Phase 2 but the actual keystroke is a
# plain nudge — no Escape reaches the pane.

@test "T-PU-P2-001: process_unread Phase 2 enters escalation but claude falls back to plain nudge" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 150 ))   # 120 <= age < 240 → Phase 2
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "escalating: Escape+nudge"
    echo "$output" | grep -q "suppressing Escape escalation"
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
    ! grep -q "send-keys.*Escape" "$MOCK_LOG"
}

# --- T-PU-P2-002: Phase 2 (copilot) → real Escape×2 + C-c + nudge ---

@test "T-PU-P2-002: process_unread Phase 2 sends Escape+C-c+nudge for copilot" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    run bash -c '
        MOCK_PANE_CLI="copilot"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        CLI_TYPE="copilot"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 150 ))
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "ESCALATION Phase 2: Escape"
    grep -q "send-keys.*Escape" "$MOCK_LOG"
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-PU-P3-001: Phase 3 (claude ashigaru) → /clear + timer/flag reset ---

@test "T-PU-P3-001: process_unread Phase 3 sends /clear and resets escalation state for ashigaru" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 300 ))   # age >= 240 → Phase 3
        LAST_CLEAR_TS=0                       # cooldown expired
        NEW_CONTEXT_SENT=1
        process_unread event
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
        echo "NEW_CONTEXT_SENT=$NEW_CONTEXT_SENT"
        echo "LAST_CLEAR_TS=$LAST_CLEAR_TS"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "ESCALATION Phase 3: Agent ashigaru9 unresponsive"
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
    echo "$output" | grep -q "NEW_CONTEXT_SENT=0"
    ! echo "$output" | grep -q "LAST_CLEAR_TS=0"
}

# --- T-PU-P3-002: Phase 3 (codex) → skip /clear, plain nudge ---

@test "T-PU-P3-002: process_unread Phase 3 skips /clear for codex and sends plain nudge" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        CLI_TYPE="codex"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 300 ))
        LAST_CLEAR_TS=0
        process_unread event
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "cli=codex — skipping /clear"
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    ! grep -q "send-keys.*/new" "$MOCK_LOG"
    ! echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
}

# --- T-PU-P3-003: Phase 3 (command-layer karo) → suppress /clear, Escape+nudge ---

@test "T-PU-P3-003: process_unread Phase 3 suppresses /clear for command-layer karo" {
    write_normal_unread "$TEST_INBOX_DIR/karo.yaml"
    touch "$TEST_TMPDIR/shogun_idle_karo"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="karo"
        INBOX="'"$TEST_INBOX_DIR"'/karo.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 300 ))
        LAST_CLEAR_TS=0
        process_unread event
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "suppressed (command-layer"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
    ! echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
}

# --- T-PU-P3-004: Phase 3 with active /clear cooldown → Escape+nudge, no /clear ---

@test "T-PU-P3-004: process_unread Phase 3 falls back to Escape+nudge while /clear cooldown is active" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 300 ))   # Phase 3
        LAST_CLEAR_TS=$(( now - 100 ))       # within 300s cooldown, but > 30s (not busy)
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "/clear cooldown, using Escape+nudge"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# All-read reset paths
# ═══════════════════════════════════════════════════════════════

# --- T-PU-RESET-001: all messages read (full path) → escalation reset ---

@test "T-PU-RESET-001: process_unread resets escalation state when all messages are read" {
    write_all_read "$TEST_INBOX_DIR/ashigaru9.yaml"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 50 ))    # non-zero so the reset log fires
        NEW_CONTEXT_SENT=1
        STALL_NOTIFIED=1
        process_unread event
        echo "FIRST_UNREAD_SEEN=$FIRST_UNREAD_SEEN"
        echo "NEW_CONTEXT_SENT=$NEW_CONTEXT_SENT"
        echo "STALL_NOTIFIED=$STALL_NOTIFIED"
        [ -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru9" ] && echo "FLAG_CREATED"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "All messages read for ashigaru9 — escalation reset"
    echo "$output" | grep -q "FIRST_UNREAD_SEEN=0"
    echo "$output" | grep -q "NEW_CONTEXT_SENT=0"
    echo "$output" | grep -q "STALL_NOTIFIED=0"
    echo "$output" | grep -q "FLAG_CREATED"
}

# --- T-PU-RESET-002: fast-path (timeout + count 0) skips the full read ---
# CHARACTERIZATION: no_idle_full_read short-circuits the expensive full read on a
# timeout tick when FIRST_UNREAD_SEEN==0 and unread==0. update_metrics is only
# reached on the full-read path, so its absence proves the fast path was taken.

@test "T-PU-RESET-002: process_unread fast-path skips full read on idle timeout tick" {
    write_all_read "$TEST_INBOX_DIR/ashigaru9.yaml"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"
    rm -f "$METRICS_FILE"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        METRICS_FILE="'"$METRICS_FILE"'"
        FIRST_UNREAD_SEEN=0
        process_unread timeout
        [ -f "$IDLE_FLAG_DIR/shogun_idle_ashigaru9" ] && echo "FLAG_CREATED"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "FLAG_CREATED"
    grep -q "send-keys.*C-u" "$MOCK_LOG"
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
    [ ! -f "$METRICS_FILE" ]   # full read (update_metrics) never ran
}

# ═══════════════════════════════════════════════════════════════
# Context reset on task_assigned
# ═══════════════════════════════════════════════════════════════

# --- T-PU-CR-001: task_assigned first-seen → send_context_reset (/clear) ---

@test "T-PU-CR-001: process_unread sends context reset (/clear) on first task_assigned" {
    write_task_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        process_unread event
        echo "NEW_CONTEXT_SENT=$NEW_CONTEXT_SENT"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "CONTEXT-RESET.*Sending /clear.*ashigaru9"
    grep -q "send-keys.*/clear" "$MOCK_LOG"
    echo "$output" | grep -q "NEW_CONTEXT_SENT=1"
}

# --- T-PU-CR-002: NEW_CONTEXT_SENT=1 → context reset skipped ---

@test "T-PU-CR-002: process_unread skips context reset when NEW_CONTEXT_SENT=1" {
    write_task_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=1
        LAST_CLEAR_TS=0
        process_unread event
    '
    [ "$status" -eq 0 ]

    ! echo "$output" | grep -q "CONTEXT-RESET"
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
}

# --- T-PU-CR-003: command-layer karo task_assigned → context reset suppressed ---

@test "T-PU-CR-003: process_unread suppresses context reset for command-layer karo" {
    write_task_unread "$TEST_INBOX_DIR/karo.yaml"
    touch "$TEST_TMPDIR/shogun_idle_karo"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="karo"
        INBOX="'"$TEST_INBOX_DIR"'/karo.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        LAST_CLEAR_TS=0
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "suppressing context reset (command-layer agent)"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# STARTUP_PROMPT_SENT skip & ASW_DISABLE_ESCALATION
# ═══════════════════════════════════════════════════════════════

# --- T-PU-STARTUP-001: STARTUP_PROMPT_SENT=1 → skip nudge this cycle ---

@test "T-PU-STARTUP-001: process_unread skips the nudge for one cycle after a startup prompt" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        STARTUP_PROMPT_SENT=1
        process_unread event
        echo "STARTUP_PROMPT_SENT=$STARTUP_PROMPT_SENT"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "Startup prompt just sent to ashigaru9 — skipping nudge"
    echo "$output" | grep -q "STARTUP_PROMPT_SENT=0"
    ! grep -q "send-keys.*inbox" "$MOCK_LOG"
}

# --- T-PU-DISABLE-001: ASW_DISABLE_ESCALATION=1 → escalation bypassed, plain nudge ---

@test "T-PU-DISABLE-001: process_unread bypasses escalation and sends a plain nudge when ASW_DISABLE_ESCALATION=1" {
    write_normal_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 300 ))   # would be Phase 3, but escalation disabled
        ASW_DISABLE_ESCALATION=1
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "escalation disabled"
    grep -q "send-keys.*inbox1" "$MOCK_LOG"
    ! echo "$output" | grep -q "ESCALATION Phase 3"
    ! grep -q "send-keys.*/clear" "$MOCK_LOG"
}

# ═══════════════════════════════════════════════════════════════
# clear_command special handling + auto-recovery enqueue
# ═══════════════════════════════════════════════════════════════

# --- T-PU-CLEAR-001: clear_command (idle) → /clear sent + auto-recovery enqueued ---

@test "T-PU-CLEAR-001: process_unread sends /clear and enqueues an auto-recovery task for a clear_command" {
    write_clear_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    touch "$TEST_TMPDIR/shogun_idle_ashigaru9"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
        process_unread event
    '
    [ "$status" -eq 0 ]

    grep -q "send-keys.*/clear" "$MOCK_LOG"
    echo "$output" | grep -q "AUTO-RECOVERY.*queued task_assigned for ashigaru9"
    # Startup prompt follows /clear for claude
    grep -q "Session Start" "$MOCK_LOG"
    # The recovery message was physically appended to the inbox
    grep -q "auto-recovery" "$TEST_INBOX_DIR/ashigaru9.yaml"
}

# --- T-PU-CLEAR-002: clear_command while busy → /clear deferred ---
# CHARACTERIZATION: get_unread_info marks the special read BEFORE the busy check,
# so a deferred clear_command is consumed this cycle (locked here as-is).

@test "T-PU-CLEAR-002: process_unread defers /clear for a busy agent (clear_command)" {
    write_clear_unread "$TEST_INBOX_DIR/ashigaru9.yaml"
    rm -f "$TEST_TMPDIR/shogun_idle_ashigaru9"   # busy (no idle flag, claude)
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        FIRST_UNREAD_SEEN=0
        process_unread event
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "busy — /clear (clear_command) deferred to next cycle"
    ! grep -q "send-keys.*Session Start" "$MOCK_LOG"
    ! echo "$output" | grep -q "AUTO-RECOVERY.*queued"
}

# ═══════════════════════════════════════════════════════════════
# process_unread_once
# ═══════════════════════════════════════════════════════════════

# --- T-PU-ONCE-001: process_unread_once runs a full read with "startup" trigger ---
# no_idle_full_read only short-circuits on trigger="timeout", so the "startup"
# trigger always takes the full-read path (update_metrics writes the metrics file).

@test "T-PU-ONCE-001: process_unread_once takes the full-read path (startup trigger)" {
    write_all_read "$TEST_INBOX_DIR/ashigaru9.yaml"
    rm -f "$METRICS_FILE"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        METRICS_FILE="'"$METRICS_FILE"'"
        FIRST_UNREAD_SEEN=0
        process_unread_once
    '
    [ "$status" -eq 0 ]

    [ -f "$METRICS_FILE" ]   # full read ran → metrics written
}
