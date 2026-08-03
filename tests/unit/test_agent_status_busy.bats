#!/usr/bin/env bats
# test_agent_status_busy.bats — cmd_1280 narrow-pane busy detection unit tests.
#
# Scope: lib/agent_status.sh agent_is_busy_check / claude_code_live_spinner_check.
# 2026-07-14 incident: panes narrower than ~65 cols truncate the Claude Code
# status bar before 'esc to interrupt' ('⏵⏵ bypass permissions on          ·'),
# so busy agents were misread as idle → idle_revive_scan escalation alert spam.
# Fix: detect the live spinner row above the input box, anchored to the box so
# stale busy text in scroll-back can never match (T-BUSY-008 stays fixed).
#
# Test IDs:
#   T-NARROW-001: truncated status bar + live spinner row (elapsed truncated) → busy
#   T-NARROW-002: truncated status bar + spinner row with elapsed time → busy
#   T-NARROW-003: plain '*' spinner frame with elapsed time → busy
#   T-NARROW-004: idle pane (response text above input box, no spinner) → idle
#   T-NARROW-005: completed marker '✻ Crunched for 14m 9s' (no …/elapsed parens) → idle
#   T-NARROW-006: T-BUSY-008 regression — stale spinner text in scroll-back → idle
#   T-NARROW-007: wide pane 'esc to interrupt' status bar still busy (existing path)
#   T-NARROW-008: bare capture without input box structure → idle (no false-busy)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export LIB="$PROJECT_ROOT/lib/agent_status.sh"
    [ -f "$LIB" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/agent_status_busy.XXXXXX")"
    export MOCK_CAPTURE_FILE="$TEST_TMPDIR/capture.txt"

    # Mock tmux on PATH: agent_is_busy_check invokes `timeout 2 tmux ...`,
    # which exec's the binary — a shell function would not be seen. A PATH
    # shim intercepts display-message / show-options / capture-pane.
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/tmux" << 'MOCK'
#!/bin/bash
case "$*" in
    *display-message*) echo "%1"; exit 0 ;;
    *show-options*)    printf '%s\n' "${MOCK_PANE_CLI:-}"; exit 0 ;;
    *capture-pane*)    cat "${MOCK_CAPTURE_FILE:-/dev/null}"; exit 0 ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TMPDIR/bin/tmux"
    export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_run_busy_check() {
    run bash -c "source '$LIB'; agent_is_busy_check 'mock:0.4'"
}

# --- T-NARROW-001: 実戦incidentそのもの (幅31 pane・経過時間まで切れた spinner行) ---

@test "T-NARROW-001: truncated status bar + spinner row without elapsed → busy" {
    printf '%s\n' \
        '     160,169p src/a…' \
        '' \
        '✻ 城の隠段が一段多い…' \
        '' \
        '───────────────────────────────' \
        '❯ ' \
        '───────────────────────────────' \
        '  ⏵⏵ bypass permissions on  ·' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 0 ]
}

# --- T-NARROW-002: 幅39 pane (経過時間つき spinner行) ---

@test "T-NARROW-002: truncated status bar + spinner row with elapsed → busy" {
    printf '%s\n' \
        '✽ 画面の返品中… (9m 26s · thinking)' \
        '' \
        '───────────────────────────────────────' \
        '❯ ' \
        '───────────────────────────────────────' \
        '  ⏵⏵ bypass permissions on          ·' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 0 ]
}

# --- T-NARROW-003: spinner frame がプレーン '*' の巡回フレームでも busy ---

@test "T-NARROW-003: plain '*' spinner frame with elapsed → busy" {
    printf '%s\n' \
        '* 戦場ピクニック… (8m 50s)' \
        '' \
        '───────────────────────────────' \
        '❯ ' \
        '───────────────────────────────' \
        '  ⏵⏵ bypass permissions on  ·' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 0 ]
}

# --- T-NARROW-004: 真にidleな狭pane (spinner行なし・応答テキストのみ) → idle ---

@test "T-NARROW-004: idle narrow pane (response text, no spinner) → idle" {
    printf '%s\n' \
        '● 完遂した。報告YAMLを更新済み。' \
        '' \
        '───────────────────────────────' \
        '❯ ' \
        '───────────────────────────────' \
        '  ⏵⏵ bypass permissions on' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 1 ]
}

# --- T-NARROW-005: 完了マーカー行は glyph一致でも busy根拠(…/経過括弧)欠如 → idle ---
# 実測 (2026-07-14 multiagent:0.2): 完遂直後は '✻ Crunched for 14m 9s' が
# 入力ボックス直上に残る。busy中の '✻ 文言… (14m 9s · …)' と違い ellipsis も
# '(elapsed' も持たない。これを busy と誤ると完遂agentが永久busy扱いになる。

@test "T-NARROW-005: completed marker '✻ Crunched for 14m 9s' → idle" {
    printf '%s\n' \
        '✻ Crunched for 14m 9s' \
        '─────────────────────────────────────────────────────────────────────' \
        '❯ ' \
        '─────────────────────────────────────────────────────────────────────' \
        '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 1 ]
}

# --- T-NARROW-006: T-BUSY-008 非回帰 — scroll-back の古いbusy文言では busy にならぬ ---

@test "T-NARROW-006: stale spinner text in scroll-back does not cause false-busy" {
    printf '%s\n' \
        '✻ 古い作業中… (3m 2s · esc to interrupt)' \
        'some output line' \
        '● 完遂した。' \
        '' \
        '───────────────────────────────' \
        '❯ ' \
        '───────────────────────────────' \
        '  ⏵⏵ bypass permissions on' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 1 ]
}

# --- T-NARROW-007: 幅広pane の status bar 'esc to interrupt' 経路は従来どおり busy ---

@test "T-NARROW-007: wide pane 'esc to interrupt' status bar → busy" {
    printf '%s\n' \
        '❯ ' \
        '─────────────────────────────────────────────────────────────────────' \
        '  ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt …' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 0 ]
}

# --- T-NARROW-008: 入力ボックス構造なし (非Claude/生テキスト) では spinner検査は発火せぬ ---

@test "T-NARROW-008: spinner-like text without input box anchor → idle" {
    printf '%s\n' \
        '✻ 何か作業中… (2m 3s)' \
        'plain output' \
        '$ ' > "$MOCK_CAPTURE_FILE"
    _run_busy_check
    [ "$status" -eq 1 ]
}

# --- 直接unit: claude_code_live_spinner_check (mock不要) ---

@test "T-NARROW-009: claude_code_live_spinner_check direct — busy fixture returns 0" {
    run bash -c '
        source "'"$LIB"'"
        capture="$(printf "%s\n" \
            "✢ 足軽が地図を返す… (9m 26s · ↓ 26.5k tokens)" \
            "" \
            "──────────────" \
            "❯ " \
            "──────────────" \
            "  ⏵⏵ bypass permissions on  ·")"
        claude_code_live_spinner_check "$capture"
    '
    [ "$status" -eq 0 ]
}

@test "T-NARROW-010: claude_code_live_spinner_check direct — idle fixture returns 1" {
    run bash -c '
        source "'"$LIB"'"
        capture="$(printf "%s\n" \
            "● 済んだ。" \
            "" \
            "──────────────" \
            "❯ " \
            "──────────────" \
            "  ⏵⏵ bypass permissions on")"
        claude_code_live_spinner_check "$capture"
    '
    [ "$status" -eq 1 ]
}
