#!/usr/bin/env bats
# test_idle_revive_cooldown.bats — cmd_1280 escalation 再警報 cooldown unit tests.
#
# Scope: scripts/idle_revive_scan.py の escalation latch 中 per-agent alert cooldown。
# 2026-07-14 incident: 枠制限中に consecutive=3 latch した agent 群へ cron 3分毎に
# idle_revive_escalation_alert を再送し続け karo inbox 未読212通に達した。
# Fix: clear_log entry の last_alert_ts で同一 agent 同一 task の再警報を
# --alert-cooldown-min (default 30分) 抑止。latch 解除で last_alert_ts クリア。
#
# Test IDs:
#   T-COOLDOWN-001: latch + last_alert_ts 10分前(同一task) → alert_cooldown (抑止)
#   T-COOLDOWN-002: latch + last_alert_ts 40分前 → escalation_stop + last_alert_ts 更新
#   T-COOLDOWN-003: latch + last_alert_ts なし (旧schema後方互換) → escalation_stop
#   T-COOLDOWN-004: busy 復帰 → consecutive=0 + last_alert_ts クリア (latch解除)
#   T-COOLDOWN-005: --alert-cooldown-min 短縮 (5分) → 10分前 alert でも escalation_stop
#   T-COOLDOWN-006: karo degrade escalation も cooldown 抑止
#   T-COOLDOWN-007: CLI --dry-run 経由で alert_cooldown が JSON に出る (E2E smoke)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_PY="$PROJECT_ROOT/scripts/idle_revive_scan.py"
    export VENV_PY="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$SCAN_PY" ] || return 1
    "$VENV_PY" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/idle_revive_cooldown.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/state"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_write_task() {
    local agent="$1" task_id="$2" status="$3"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: ${task_id}
  parent_cmd: cmd_test
  assigned_to: ${agent}
  status: ${status}
EOF
    touch -d '2 hours ago' "$Q/tasks/${agent}.yaml"
}

# scan() を固定 now で直接呼ぶ python harness。stdin に test code を渡す。
_run_scan_py() {
    # stdin: python code。環境変数 Q / SCAN_PY を参照可。
    "$VENV_PY" -
}

_py_prelude() {
    cat <<PY
import datetime, importlib.util, json, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
Q = Path(os.environ["Q"])
NOW = datetime.datetime(2026, 7, 14, 16, 0, 0)
def run_scan(pane_state, entry, **kw):
    results, log = irs.scan(
        Q / "tasks", Q / "reports", Q.parent, {"ashigaru9": pane_state},
        {"ashigaru9": entry} if entry is not None else {},
        stall_min=15, min_interval_min=5, max_consecutive=3, now=NOW, **kw)
    return results, log
PY
}

# --- T-COOLDOWN-001: 同一task・10分前alert → 抑止 ---

@test "T-COOLDOWN-001: latch + fresh last_alert_ts (10min ago, same task) → alert_cooldown" {
    _write_task ashigaru9 subtask_x assigned
    run _run_scan_py <<PY
$(_py_prelude)
entry = {"last_clear_ts": "2026-07-14T15:00:00", "consecutive": 3,
         "last_task_id": "subtask_x", "last_alert_ts": "2026-07-14T15:50:00"}
results, log = run_scan("idle", entry)
assert len(results) == 1, results
r = results[0]
assert r["action"] == "alert_cooldown", r
assert "_new_state" not in r, r
print("OK", r["action"])
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK alert_cooldown"
}

# --- T-COOLDOWN-002: 40分前alert → cooldown 期限切れ → escalation_stop + ts 更新 ---

@test "T-COOLDOWN-002: latch + stale last_alert_ts (40min ago) → escalation_stop, ts refreshed" {
    _write_task ashigaru9 subtask_x assigned
    run _run_scan_py <<PY
$(_py_prelude)
entry = {"last_clear_ts": "2026-07-14T15:00:00", "consecutive": 3,
         "last_task_id": "subtask_x", "last_alert_ts": "2026-07-14T15:20:00"}
results, log = run_scan("idle", entry)
r = results[0]
assert r["action"] == "escalation_stop", r
assert r["_new_state"]["last_alert_ts"] == "2026-07-14T16:00:00", r
assert r["_new_state"]["consecutive"] == 3, r
print("OK", r["action"])
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK escalation_stop"
}

# --- T-COOLDOWN-003: last_alert_ts 無し (旧schema) でも従来どおり alert (後方互換) ---

@test "T-COOLDOWN-003: latch without last_alert_ts (old schema) → escalation_stop" {
    _write_task ashigaru9 subtask_x assigned
    run _run_scan_py <<PY
$(_py_prelude)
entry = {"last_clear_ts": "2026-07-14T15:00:00", "consecutive": 3,
         "last_task_id": "subtask_x"}
results, log = run_scan("idle", entry)
r = results[0]
assert r["action"] == "escalation_stop", r
assert r["_new_state"]["last_alert_ts"] == "2026-07-14T16:00:00", r
print("OK", r["action"])
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK escalation_stop"
}

# --- T-COOLDOWN-004: busy 復帰で latch 解除 → consecutive=0 + last_alert_ts クリア ---

@test "T-COOLDOWN-004: busy detection resets consecutive and clears last_alert_ts" {
    _write_task ashigaru9 subtask_x assigned
    run _run_scan_py <<PY
$(_py_prelude)
entry = {"last_clear_ts": "2026-07-14T15:00:00", "consecutive": 3,
         "last_task_id": "subtask_x", "last_alert_ts": "2026-07-14T15:50:00"}
results, log = run_scan("busy", entry)
assert results == [], results
e = log["ashigaru9"]
assert e["consecutive"] == 0, e
assert "last_alert_ts" not in e, e
print("OK reset")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK reset"
}

# --- T-COOLDOWN-005: --alert-cooldown-min 可変 (5分指定なら10分前alertは期限切れ) ---

@test "T-COOLDOWN-005: alert_cooldown_min=5 lets a 10min-old alert fire again" {
    _write_task ashigaru9 subtask_x assigned
    run _run_scan_py <<PY
$(_py_prelude)
entry = {"last_clear_ts": "2026-07-14T15:00:00", "consecutive": 3,
         "last_task_id": "subtask_x", "last_alert_ts": "2026-07-14T15:50:00"}
results, log = run_scan("idle", entry, alert_cooldown_min=5)
r = results[0]
assert r["action"] == "escalation_stop", r
print("OK", r["action"])
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK escalation_stop"
}

# --- T-COOLDOWN-006: karo degrade escalation も同 cooldown で抑止 ---

@test "T-COOLDOWN-006: karo degrade escalation respects alert cooldown" {
    _write_task ashigaru9 subtask_x assigned
    # stale dashboard (60分前) + active task 存在 = degrade 成立条件
    echo "# dashboard" > "$TEST_TMPDIR/dashboard.md"
    touch -d '60 minutes ago' "$TEST_TMPDIR/dashboard.md"
    run _run_scan_py <<PY
$(_py_prelude)
dash = Q.parent / "dashboard.md"
entry = {"last_clear_ts": "2026-07-14T15:00:00", "consecutive": 3,
         "last_task_id": "karo_degrade", "last_alert_ts": "2026-07-14T15:50:00"}
hit, log = irs.scan_karo_degrade(
    dash, Q / "tasks", Q / "reports", {"karo": entry},
    karo_stale_min=20, karo_min_interval_min=20, max_consecutive=3, now=NOW)
assert hit is not None and hit["action"] == "alert_cooldown", hit
# 期限切れなら escalation_stop + ts 更新
entry2 = dict(entry); entry2["last_alert_ts"] = "2026-07-14T15:20:00"
hit2, _ = irs.scan_karo_degrade(
    dash, Q / "tasks", Q / "reports", {"karo": entry2},
    karo_stale_min=20, karo_min_interval_min=20, max_consecutive=3, now=NOW)
assert hit2["action"] == "escalation_stop", hit2
assert hit2["_new_state"]["last_alert_ts"] == "2026-07-14T16:00:00", hit2
print("OK karo cooldown")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK karo cooldown"
}

# --- T-COOLDOWN-007: CLI --dry-run smoke (fixture 注入・実発行 0・実 tmux 不要) ---

@test "T-COOLDOWN-007: CLI --dry-run reports alert_cooldown via JSON" {
    _write_task ashigaru9 subtask_x assigned
    cat > "$Q/state/clear_log.yaml" <<EOF
agents:
  ashigaru9:
    last_clear_ts: '$(date -d '-60 minutes' '+%Y-%m-%dT%H:%M:%S')'
    consecutive: 3
    last_task_id: subtask_x
    last_alert_ts: '$(date -d '-10 minutes' '+%Y-%m-%dT%H:%M:%S')'
EOF
    cat > "$TEST_TMPDIR/pane_state.yaml" <<EOF
ashigaru9: idle
EOF
    run "$VENV_PY" "$SCAN_PY" --dry-run --json \
        --queue-root "$Q" \
        --pane-state-file "$TEST_TMPDIR/pane_state.yaml" \
        --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"action": "alert_cooldown"'
    echo "$output" | grep -q '"agent": "ashigaru9"'
}
