#!/usr/bin/env bats
# test_stall_watchdog_scan.bats — cmd_552 Phase 3 Watchdog scan unit tests.
#
# Scope: scripts/stall_watchdog_scan.{sh,py} report↔task YAML 突合 scan.
# Covers positive detection + four false-positive guards + multi-doc / nested /
# primary_task variants.

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_SH="$PROJECT_ROOT/scripts/stall_watchdog_scan.sh"
    export SCAN_PY="$PROJECT_ROOT/scripts/stall_watchdog_scan.py"
    [ -f "$SCAN_SH" ] || return 1
    [ -f "$SCAN_PY" ] || return 1
    "$PROJECT_ROOT/.venv/bin/python3" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stall_watchdog.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_write_task() {
    local agent="$1" task_id="$2" parent_cmd="$3" status="$4"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: ${task_id}
  parent_cmd: ${parent_cmd}
  assigned_to: ${agent}
  status: ${status}
EOF
}

_write_report_flat() {
    local agent="$1" task_id="$2" parent_cmd="$3" status="$4" ts="$5"
    cat > "$Q/reports/${agent}_report.yaml" <<EOF
worker_id: ${agent}
task_id: ${task_id}
parent_cmd: ${parent_cmd}
status: ${status}
timestamp: "${ts}"
EOF
}

_write_report_nested() {
    local agent="$1" task_id="$2" parent_cmd="$3" status="$4" ts="$5"
    cat > "$Q/reports/${agent}_report.yaml" <<EOF
report:
  task_id: ${task_id}
  parent_cmd: ${parent_cmd}
  agent: ${agent}
  status: ${status}
  timestamp: "${ts}"
EOF
}

_ts_minutes_ago() {
    local minutes="$1"
    date -d "${minutes} minutes ago" +"%Y-%m-%dT%H:%M:%S"
}

# =============================================================================
# T-001: 正例 — assigned + completed + 31 分経過 → HIT 1 件
# =============================================================================
@test "T-001: positive — assigned task + completed report 31min old → 1 hit" {
    local ts="$(_ts_minutes_ago 31)"
    _write_task ashigaru3 subtask_demo_positive cmd_999 assigned
    _write_report_flat ashigaru3 subtask_demo_positive cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru3"* ]]
    [[ "$output" == *"TASK_ID=subtask_demo_positive"* ]]
    [[ "$output" == *"REPORT_STATUS=completed"* ]]
}

# =============================================================================
# T-002: 負例 — task status=done は scan 対象外
# =============================================================================
@test "T-002: negative — task status=done is skipped" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_demo_done cmd_999 done
    _write_report_flat ashigaru3 subtask_demo_done cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# T-003: 負例 — report status=in_progress は完遂未達ゆえ skip
# =============================================================================
@test "T-003: negative — report status=in_progress is not completion" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_demo_ip cmd_999 assigned
    _write_report_flat ashigaru3 subtask_demo_ip cmd_999 in_progress "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# T-004: 負例 — 経過 15 分は閾値未満ゆえ skip
# =============================================================================
@test "T-004: negative — elapsed 15min below threshold 30" {
    local ts="$(_ts_minutes_ago 15)"
    _write_task ashigaru3 subtask_demo_fresh cmd_999 assigned
    _write_report_flat ashigaru3 subtask_demo_fresh cmd_999 done "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# T-005: 負例 — task_id 不一致 (報告は別 task の記録) は skip
# =============================================================================
@test "T-005: negative — task_id mismatch between task YAML and report" {
    local ts="$(_ts_minutes_ago 60)"
    _write_task ashigaru3 subtask_current cmd_999 assigned
    _write_report_flat ashigaru3 subtask_previous cmd_998 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# T-006: nested (report:) 形式 report でも正例検出
# =============================================================================
@test "T-006: positive — nested 'report:' wrapper is recognised" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_nested cmd_999 assigned
    _write_report_nested ashigaru3 subtask_nested cmd_999 done "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru3"* ]]
    [[ "$output" == *"TASK_ID=subtask_nested"* ]]
    [[ "$output" == *"REPORT_STATUS=done"* ]]
}

# =============================================================================
# T-007: 複数 doc (`---`) report から timestamp 最新 entry を採用
# =============================================================================
@test "T-007: positive — multi-doc report picks latest by timestamp" {
    local ts_old="$(_ts_minutes_ago 180)"
    local ts_new="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_new_task cmd_999 assigned
    cat > "$Q/reports/ashigaru3_report.yaml" <<EOF
worker_id: ashigaru3
task_id: subtask_old_task
parent_cmd: cmd_998
status: completed
timestamp: "${ts_old}"
---
worker_id: ashigaru3
task_id: subtask_new_task
parent_cmd: cmd_999
status: completed
timestamp: "${ts_new}"
EOF

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru3"* ]]
    [[ "$output" == *"TASK_ID=subtask_new_task"* ]]
}

# =============================================================================
# T-008: gunshi primary_task キー名でも正例検出
# =============================================================================
@test "T-008: positive — gunshi 'primary_task' key matches task_id" {
    local ts="$(_ts_minutes_ago 60)"
    _write_task gunshi subtask_qc_demo cmd_999 assigned
    cat > "$Q/reports/gunshi_report.yaml" <<EOF
report:
  primary_task: subtask_qc_demo
  parent_cmd: cmd_999
  agent: gunshi
  status: done
  timestamp: "${ts}"
EOF

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=gunshi"* ]]
    [[ "$output" == *"TASK_ID=subtask_qc_demo"* ]]
}

# =============================================================================
# T-009: JSON 出力形式
# =============================================================================
@test "T-009: --json emits JSON array with hit fields" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task ashigaru3 subtask_json cmd_999 assigned
    _write_report_flat ashigaru3 subtask_json cmd_999 completed "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30 --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"\"agent\": \"ashigaru3\""* ]]
    [[ "$output" == *"\"task_id\": \"subtask_json\""* ]]
    [[ "$output" == *"\"elapsed_min\":"* ]]
}

# =============================================================================
# T-010: report YAML 不存在は 警告なしで skip
# =============================================================================
@test "T-010: missing report YAML is gracefully skipped" {
    _write_task ashigaru3 subtask_no_report cmd_999 assigned
    # no report file written

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
