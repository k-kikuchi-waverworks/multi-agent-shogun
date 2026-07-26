#!/usr/bin/env bats
# test_inbox_watcher_io.bats — characterization tests for the inbox I/O, recovery,
# metrics, throttle, and status-probe helpers of inbox_watcher.sh
# (cmd_1160 #3A: test-only, NO changes to scripts/inbox_watcher.sh)
#
# These fill the remaining §3-4 char-test gaps (design: gunshi2) around the leaf
# helpers that cmd-3B..3E will extract into lib/inbox_io.sh / lib/nudge.sh /
# lib/cli_adapter.sh. They LOCK current behavior as golden before extraction.
#
# Same harness pattern as test_inbox_watcher_branches.bats.
#
# テスト構成:
#   get_unread_count_fast : 0 / 1 / N / malformed-YAML fail-safe
#   get_unread_info       : normal vs special split, task_assigned flag, marks
#                           specials read (side effect), malformed fail-safe
#   update_metrics        : write metrics file, unread_latency w/ and w/o FIRST_UNREAD_SEEN
#   should_throttle_nudge : first-send / same-count throttle / codex 300s / different count
#   enqueue_recovery_task_assigned : enqueue / dedup / task cancelled / task idle
#   no_idle_full_read     : 4 gate branches
#   send_cli_command copilot : /clear → C-c + restart, /model → skip  (L606-621 gap)
#   pane_is_active / session_has_client / agent_has_self_watch : status probes

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export WATCHER_SCRIPT="$PROJECT_ROOT/scripts/inbox_watcher.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$WATCHER_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/watcher_io_test.XXXXXX")"

    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    export MOCK_PGREP="$TEST_TMPDIR/mock_pgrep"
    cat > "$MOCK_PGREP" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$MOCK_PGREP"

    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    export TEST_TASKS_DIR="$TEST_TMPDIR/queue/tasks"
    mkdir -p "$TEST_INBOX_DIR" "$TEST_TASKS_DIR"

    export METRICS_FILE="$TEST_TMPDIR/metrics_io.yaml"

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
# Redirect runtime helpers (python/.venv, inbox_write) to the sandbox.
SCRIPT_DIR="$FAKE_ROOT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ═══════════════════════════════════════════════════════════════
# get_unread_count_fast
# ═══════════════════════════════════════════════════════════════

@test "T-FAST-001: get_unread_count_fast returns 0 when all messages are read" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - {id: a, read: true, type: report_received}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_count_fast
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"count": 0'
}

@test "T-FAST-002: get_unread_count_fast counts a single unread message" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - {id: a, read: false, type: report_received}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_count_fast
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"count": 1'
}

@test "T-FAST-003: get_unread_count_fast counts multiple unread messages" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - {id: a, read: false, type: report_received}
  - {id: b, read: true,  type: report_received}
  - {id: c, read: false, type: task_assigned}
  - {id: d, read: false, type: clear_command}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_count_fast
    '
    [ "$status" -eq 0 ]
    # fast-path counts ALL unread regardless of type (specials included)
    echo "$output" | grep -q '"count": 3'
}

@test "T-FAST-004: get_unread_count_fast fails safe to 0 on malformed YAML" {
    printf 'messages: [\n' > "$TEST_INBOX_DIR/test_agent.yaml"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_count_fast
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"count": 0'
}

# ═══════════════════════════════════════════════════════════════
# get_unread_info
# ═══════════════════════════════════════════════════════════════

@test "T-INFO-001: get_unread_info separates normal count from specials and flags task_assigned" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - {id: a, read: false, type: task_assigned, content: "do work"}
  - {id: b, read: false, type: clear_command, content: "reset"}
  - {id: c, read: true,  type: report_received, content: old}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_info
    '
    [ "$status" -eq 0 ]
    # normal_count excludes the special; has_task_assigned true; specials list carries clear_command
    echo "$output" | grep -q '"count": 1'
    echo "$output" | grep -q '"has_task_assigned": true'
    echo "$output" | grep -q '"type": "clear_command"'
}

@test "T-INFO-002: get_unread_info marks special messages read as a side effect (normal untouched)" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - {id: normal1, read: false, type: report_received, content: hi}
  - {id: special1, read: false, type: clear_command, content: reset}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_info
    '
    [ "$status" -eq 0 ]

    # After the read, the special is marked read but the normal message is not.
    "$VENV_PYTHON" - "$TEST_INBOX_DIR/test_agent.yaml" << 'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
by_id = {m["id"]: m for m in data["messages"]}
assert by_id["special1"]["read"] is True, "special should be marked read"
assert by_id["normal1"]["read"] is False, "normal should stay unread"
print("OK")
PY
}

@test "T-INFO-003: get_unread_info reports zero specials when only normal messages are unread" {
    cat > "$TEST_INBOX_DIR/test_agent.yaml" << 'YAML'
messages:
  - {id: a, read: false, type: report_received, content: hi}
  - {id: b, read: false, type: report_received, content: yo}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_info
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"count": 2'
    echo "$output" | grep -q '"has_task_assigned": false'
    echo "$output" | grep -q '"specials": \[\]'
}

@test "T-INFO-004: get_unread_info fails safe on malformed YAML" {
    printf 'messages: [\n' > "$TEST_INBOX_DIR/test_agent.yaml"
    run bash -c '
        source "'"$TEST_HARNESS"'"
        get_unread_info
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"count": 0'
    echo "$output" | grep -q '"specials": \[\]'
}

# ═══════════════════════════════════════════════════════════════
# update_metrics
# ═══════════════════════════════════════════════════════════════

@test "T-METRICS-001: update_metrics writes counters and a positive unread latency" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        METRICS_FILE="'"$METRICS_FILE"'"
        now=$(date +%s)
        FIRST_UNREAD_SEEN=$(( now - 10 ))
        update_metrics 100
    '
    [ "$status" -eq 0 ]
    [ -f "$METRICS_FILE" ]
    grep -q 'agent_id: "ashigaru9"' "$METRICS_FILE"
    grep -q 'read_count: 1' "$METRICS_FILE"
    grep -q 'bytes_read: 100' "$METRICS_FILE"
    grep -q 'estimated_tokens: 25' "$METRICS_FILE"
    # latency computed from FIRST_UNREAD_SEEN → strictly positive
    if grep -q 'unread_latency_sec: 0' "$METRICS_FILE"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効になりうる
}

@test "T-METRICS-002: update_metrics reports zero latency when FIRST_UNREAD_SEEN=0" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        METRICS_FILE="'"$METRICS_FILE"'"
        FIRST_UNREAD_SEEN=0
        update_metrics 40
    '
    [ "$status" -eq 0 ]
    grep -q 'unread_latency_sec: 0' "$METRICS_FILE"
    grep -q 'estimated_tokens: 10' "$METRICS_FILE"
}

# ═══════════════════════════════════════════════════════════════
# should_throttle_nudge
# ═══════════════════════════════════════════════════════════════

@test "T-THROTTLE-001: should_throttle_nudge allows the first send and records it" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        LAST_NUDGE_TS=0
        LAST_NUDGE_COUNT=""
        should_throttle_nudge 1 && echo "THROTTLED" || echo "ALLOWED"
        echo "LAST_NUDGE_COUNT=$LAST_NUDGE_COUNT"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ALLOWED"
    echo "$output" | grep -q "LAST_NUDGE_COUNT=1"
}

@test "T-THROTTLE-002: should_throttle_nudge throttles a repeat of the same count within 60s (claude)" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        now=$(date +%s)
        LAST_NUDGE_TS=$(( now - 10 ))   # 10s ago < 60s cooldown
        LAST_NUDGE_COUNT=1
        should_throttle_nudge 1 && echo "THROTTLED" || echo "ALLOWED"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "THROTTLED"
}

@test "T-THROTTLE-003: should_throttle_nudge uses the 300s cooldown for codex" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        now=$(date +%s)
        LAST_NUDGE_TS=$(( now - 100 ))   # 100s ago: >60s (claude) but <300s (codex)
        LAST_NUDGE_COUNT=1
        should_throttle_nudge 1 && echo "THROTTLED" || echo "ALLOWED"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "THROTTLED"
}

@test "T-THROTTLE-004: should_throttle_nudge allows a different unread count" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        now=$(date +%s)
        LAST_NUDGE_TS=$(( now - 5 ))
        LAST_NUDGE_COUNT=1
        should_throttle_nudge 2 && echo "THROTTLED" || echo "ALLOWED"
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ALLOWED"
}

# ═══════════════════════════════════════════════════════════════
# enqueue_recovery_task_assigned
# ═══════════════════════════════════════════════════════════════

@test "T-RECOV-001: enqueue_recovery_task_assigned appends an auto-recovery task_assigned" {
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - {id: old, read: true, type: report_received, content: done}
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "msg_auto_recovery_"
    grep -q "auto-recovery" "$TEST_INBOX_DIR/ashigaru9.yaml"
    grep -q "from: inbox_watcher" "$TEST_INBOX_DIR/ashigaru9.yaml"
}

@test "T-RECOV-002: enqueue_recovery_task_assigned is idempotent (dedup pending recovery)" {
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - content: "[auto-recovery] /clear 後の再着手通知。"
    from: inbox_watcher
    id: msg_auto_recovery_existing
    read: false
    timestamp: "2026-07-03T00:00:00+09:00"
    type: task_assigned
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIP_DUPLICATE"
    # No second recovery message added
    [ "$(grep -c 'msg_auto_recovery_' "$TEST_INBOX_DIR/ashigaru9.yaml")" -eq 1 ]
}

# Status guard contract (cmd_1356 OBS-4 rewrite): the guard reads BOTH the flat
# `status:` key and the standard nested `task: { status: ... }` format, and
# normalizes the value (first ASCII word run, lowercased — same shape as
# idle_revive/stall_watchdog normalize_status) before matching cancelled/idle.
#
# 旧 T-RECOV-005 は「ネスト形は guard を素通りする」を characterization として
# 固定していた (cmd-3D/3E で意識的に決めよ、との旗)。その決定が下った:
# 実 task YAML の大半 (実測 12/13) はネスト形ゆえ、素通り契約のままでは guard は
# 実運用でほぼ死んでいる — 家老が意図して止めた task へ auto-recovery が再着手を
# 促す fail-OPEN (軍師二号 OBS-4 名指し)。契約の削除でなく新契約 green で書換える
# (cmd_1357 二号の作法)。T-RECOV-003/004 (flat 形の skip) は無改変で残る。

@test "T-RECOV-003: enqueue_recovery_task_assigned skips when a flat-format task is cancelled" {
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - {id: old, read: true, type: report_received, content: done}
YAML
    cat > "$TEST_TASKS_DIR/ashigaru9.yaml" << 'YAML'
task_id: cmd_x
status: cancelled
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIP_CANCELLED:cancelled"
    if grep -q "auto-recovery" "$TEST_INBOX_DIR/ashigaru9.yaml"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効になりうる
}

@test "T-RECOV-004: enqueue_recovery_task_assigned skips when a flat-format task is idle" {
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - {id: old, read: true, type: report_received, content: done}
YAML
    cat > "$TEST_TASKS_DIR/ashigaru9.yaml" << 'YAML'
task_id: cmd_x
status: idle
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIP_CANCELLED:idle"
}

@test "T-RECOV-005: enqueue_recovery_task_assigned SKIPS for the standard nested task format (cmd_1356 OBS-4 new contract)" {
    # 旧契約 (素通り) の書換え。実 task YAML の大半はこのネスト形 — ここで guard が
    # 効かねば「家老が意図して止めた task へ再着手を促す」fail-OPEN が実運用の全数で開く。
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - {id: old, read: true, type: report_received, content: done}
YAML
    cat > "$TEST_TASKS_DIR/ashigaru9.yaml" << 'YAML'
task:
  task_id: cmd_x
  status: cancelled
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIP_CANCELLED:cancelled"
    if grep -q "auto-recovery" "$TEST_INBOX_DIR/ashigaru9.yaml"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効になりうる
}

@test "T-RECOV-006: annotated nested 'cancelled   # note' still skips — the raw exact match was the fail-OPEN (cmd_1356 OBS-4)" {
    # 家老の注記慣行そのまま (agent_status.sh で一覧するため書き続けられる)。
    # 旧実装は完全一致照合ゆえ注記1つで guard が外れた — 正規化 (最初の ASCII 語 run)
    # で読む新契約。★密着形も normalize 同型ゆえ同時に効く。
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - {id: old, read: true, type: report_received, content: done}
YAML
    cat > "$TEST_TASKS_DIR/ashigaru9.yaml" << 'YAML'
task:
  task_id: cmd_x
  status: 'cancelled   # 2026-07-26 家老が意図して停止 = 再着手を促すな'
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SKIP_CANCELLED:cancelled"
    if grep -q "auto-recovery" "$TEST_INBOX_DIR/ashigaru9.yaml"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効になりうる
}

@test "T-RECOV-007: annotated nested 'assigned   # note' does NOT skip — guard scope stays cancelled/idle only" {
    # 負例: 正規化が guard の守備範囲を広げぬ (assigned/done 等は従来どおり recovery 続行)。
    # これが落ちる形 = 正規化の入れ方を誤って「注記があるだけで skip」に化けた時。
    cat > "$TEST_INBOX_DIR/ashigaru9.yaml" << 'YAML'
messages:
  - {id: old, read: true, type: report_received, content: done}
YAML
    cat > "$TEST_TASKS_DIR/ashigaru9.yaml" << 'YAML'
task:
  task_id: cmd_x
  status: 'assigned   # 2026-07-26 07:23 家老dispatch=検知層の検分'
YAML
    run bash -c '
        source "'"$TEST_HARNESS"'"
        AGENT_ID="ashigaru9"
        INBOX="'"$TEST_INBOX_DIR"'/ashigaru9.yaml"
        LOCKFILE="${INBOX}.lock"
        enqueue_recovery_task_assigned
    '
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q "SKIP_CANCELLED"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効であった
    echo "$output" | grep -q "msg_auto_recovery_"
    grep -q "auto-recovery" "$TEST_INBOX_DIR/ashigaru9.yaml"
}

# ═══════════════════════════════════════════════════════════════
# no_idle_full_read
# ═══════════════════════════════════════════════════════════════

@test "T-NOIDLE-001: no_idle_full_read returns true on an idle timeout tick" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        ASW_NO_IDLE_FULL_READ=1
        FIRST_UNREAD_SEEN=0
        no_idle_full_read timeout
    '
    [ "$status" -eq 0 ]
}

@test "T-NOIDLE-002: no_idle_full_read returns false for non-timeout triggers" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        ASW_NO_IDLE_FULL_READ=1
        FIRST_UNREAD_SEEN=0
        no_idle_full_read event
    '
    [ "$status" -eq 1 ]
}

@test "T-NOIDLE-003: no_idle_full_read returns false when escalation is in progress" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        ASW_NO_IDLE_FULL_READ=1
        FIRST_UNREAD_SEEN=12345
        no_idle_full_read timeout
    '
    [ "$status" -eq 1 ]
}

@test "T-NOIDLE-004: no_idle_full_read returns false when the feature flag is off" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        ASW_NO_IDLE_FULL_READ=0
        FIRST_UNREAD_SEEN=0
        no_idle_full_read timeout
    '
    [ "$status" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════
# send_cli_command copilot branch (L606-621, previously uncovered)
# ═══════════════════════════════════════════════════════════════

@test "T-COPILOT-001: send_cli_command copilot /clear sends Ctrl-C + restart (not literal /clear)" {
    touch "$TEST_TMPDIR/shogun_idle_test_agent"   # idle guard passes
    run bash -c '
        MOCK_PANE_CLI="copilot"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        send_cli_command "/clear"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "Copilot /clear: sending Ctrl-C + restart"
    grep -q "send-keys.*C-c" "$MOCK_LOG"
    grep -q "send-keys.*copilot --yolo" "$MOCK_LOG"
    # copilot never sends the literal /clear or /new
    if grep -q "send-keys.*/clear" "$MOCK_LOG"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効であった
    if grep -q "send-keys.*/new" "$MOCK_LOG"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効になりうる
}

@test "T-COPILOT-002: send_cli_command copilot /model is skipped (unsupported)" {
    run bash -c '
        MOCK_PANE_CLI="copilot"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="copilot"
        send_cli_command "/model opus"
    '
    [ "$status" -eq 0 ]

    echo "$output" | grep -q "not supported on copilot"
    if grep -q "send-keys.*/model" "$MOCK_LOG"; then return 1; fi   # cmd_1401: `! cmd` は set -e 免除ゆえ無効になりうる
}

# ═══════════════════════════════════════════════════════════════
# pane_is_active / session_has_client / agent_has_self_watch
# ═══════════════════════════════════════════════════════════════

@test "T-PANE-001: pane_is_active returns true when the pane is focused" {
    run bash -c '
        MOCK_PANE_ACTIVE=1
        source "'"$TEST_HARNESS"'"
        pane_is_active
    '
    [ "$status" -eq 0 ]
}

@test "T-PANE-002: pane_is_active returns false when the pane is not focused" {
    run bash -c '
        MOCK_PANE_ACTIVE=0
        source "'"$TEST_HARNESS"'"
        pane_is_active
    '
    [ "$status" -eq 1 ]
}

@test "T-CLIENT-001: session_has_client returns true when a client is attached" {
    run bash -c '
        MOCK_LIST_CLIENTS="/dev/pts/1: multiagent [80x24]"
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -eq 0 ]
}

@test "T-CLIENT-002: session_has_client returns false when no client is attached" {
    run bash -c '
        MOCK_LIST_CLIENTS=""
        source "'"$TEST_HARNESS"'"
        session_has_client
    '
    [ "$status" -eq 1 ]
}

@test "T-SELFWATCH-001: agent_has_self_watch returns false for non-claude CLIs" {
    run bash -c '
        MOCK_PANE_CLI="codex"
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="codex"
        agent_has_self_watch
    '
    [ "$status" -eq 1 ]   # 1 = no self-watch
}

@test "T-SELFWATCH-002: agent_has_self_watch returns false for claude when no inotifywait exists" {
    run bash -c '
        source "'"$TEST_HARNESS"'"
        CLI_TYPE="claude"
        agent_has_self_watch
    '
    [ "$status" -eq 1 ]   # 1 = no self-watch (pgrep finds nothing)
}
