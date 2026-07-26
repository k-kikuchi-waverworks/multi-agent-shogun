#!/usr/bin/env bats
# test_stall_watchdog_status_normalize.bats — status 注記正規化の変異試験 (cmd_1356 同型是正).
#
# ★なぜこの試験が在るか★:
#   2026-07-26 朝、idle_revive_scan が家老の帳簿慣行 'assigned   # 注記' を読めず
#   番人が盲目のまま走った (d8fc7fd で根治)。その申し送りで名指しされた同型の
#   生 exact match が本 scan にも在った:
#     - task 側 (旧 :114 `task_status != "assigned"`): 注記付き assigned は scan 対象外
#       = 帳簿漏れ (task=assigned のまま report=完遂) が注記1つで【永久に】検知されぬ
#     - report 側 (旧 :125 `.lower()` のみ): 注記付き 'completed   # …' を完了と読めぬ
#   帳簿漏れ alert は「撃たれなかった」ことに誰も気付けぬ型 (cmd_1352 沈黙 family =
#   data format drift による検知層の静かな無効化) ゆえ、照合の両側を正規化し、
#   折れば名指しで赤くなる変異を台帳へ登録する。
#
# 契約 (stall_watchdog_scan.py normalize_status — idle_revive_scan.py と同型):
#   T-SWD-001: 注記付き 'assigned   # …' task の帳簿漏れが★見える★ (HIT になる)
#   T-SWD-002: 注記付き 'done   # …' は assigned に化けぬ (正規化が偽 HIT を作らぬ)
#   T-SWD-003: 注記付き 'completed   # …' report も完了と読める + alert へは正規化 token
#   T-SWD-004: 'assigned:' 型の書き癖 drift でも読める (末尾 :;,. 落とし)
#   T-SWD-005: hit 0 件時に分母 (assigned=N) が印字される (家老裁定 09:24 = 無出力を
#              契約にせぬ。分母0の検知層は全PASSと区別がつかぬ — eligible=N と同処方)
#
# 変異登録 (config/mutation_registry.yaml): MUT-0552-001 (task側正規化を折る→T-SWD-001 赤) /
# MUT-0552-002 (report側正規化を折る→T-SWD-003 赤) /
# MUT-0552-003 (分母印字を折る→T-SWD-005 赤)。
# 本番 queue には触れない: --queue-root 隔離 (queue_root 指定時は inbox 通知経路に入らぬ
# = stall_watchdog_scan.py main() の契約) + fixture roster ashigaru91 (実在しない agent 名)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_SH="$PROJECT_ROOT/scripts/stall_watchdog_scan.sh"
    export SCAN_PY="$PROJECT_ROOT/scripts/stall_watchdog_scan.py"
    [ -f "$SCAN_SH" ] || return 1
    [ -f "$SCAN_PY" ] || return 1
    "$PROJECT_ROOT/.venv/bin/python3" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/stall_watchdog_swd.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fixture: status を引用符つきで書く (注記付き実慣行をそのまま書ける)。
_write_task_q() {
    local agent="$1" task_id="$2" status="$3"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: ${task_id}
  parent_cmd: cmd_test
  assigned_to: ${agent}
  status: '${status}'
EOF
}

_write_report_q() {
    local agent="$1" task_id="$2" status="$3" ts="$4"
    cat > "$Q/reports/${agent}_report.yaml" <<EOF
report:
  task_id: ${task_id}
  agent: ${agent}
  status: '${status}'
  timestamp: "${ts}"
EOF
}

_ts_minutes_ago() {
    date -d "$1 minutes ago" +"%Y-%m-%dT%H:%M:%S"
}

# ---------------------------------------------------------------------------
# T-SWD-001: 注記付き 'assigned   # …' の帳簿漏れが【見える】= HIT になる。
# これが落ちる形 = 注記1つで帳簿漏れ alert が永久に沈黙する穴の再来。
# ---------------------------------------------------------------------------
@test "T-SWD-001: annotated 'assigned   # note' task IS visible — bookkeeping omission becomes a hit (mutation proof: MUT-0552-001)" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task_q ashigaru91 subtask_swd_001 "assigned   # 2026-07-26 09:10 家老dispatch=同型穴の是正"
    _write_report_q ashigaru91 subtask_swd_001 "completed" "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru91"* ]]
    [[ "$output" == *"TASK_ID=subtask_swd_001"* ]]
}

# ---------------------------------------------------------------------------
# T-SWD-002: 注記付き 'done   # …' は assigned に化けぬ (正規化が偽 HIT を作らぬ側の契約)。
# ---------------------------------------------------------------------------
@test "T-SWD-002: annotated 'done   # note' task does NOT become assigned — no false hit, denominator assigned=0" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task_q ashigaru91 subtask_swd_002 "done   # 2026-07-26 07:45 完遂 = 台帳登録"
    _write_report_q ashigaru91 subtask_swd_002 "completed" "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=0"* ]]
}

# ---------------------------------------------------------------------------
# T-SWD-003: report 側の注記付き 'completed   # …' も完了と読める = HIT。
# 併せて alert へ運ばれる REPORT_STATUS が正規化 token であること (行末 = 注記なし)
# を検める — 注記の生文字列 (shell 敵対文字を含みうる) を inbox 本文へ流さぬ契約。
# ---------------------------------------------------------------------------
@test "T-SWD-003: annotated 'completed   # note' report still reads as completion; alert carries normalized token (mutation proof: MUT-0552-002)" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task_q ashigaru91 subtask_swd_003 "assigned"
    _write_report_q ashigaru91 subtask_swd_003 "completed   # 2026-07-26 注記付き完遂の慣行" "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru91"* ]]
    [[ "$output" == *"TASK_ID=subtask_swd_003"* ]]
    echo "$output" | grep -q "REPORT_STATUS=completed$"
}

# ---------------------------------------------------------------------------
# T-SWD-004: 'assigned:' 型の書き癖 drift でも読める (末尾 :;,. 落としの契約)。
# ---------------------------------------------------------------------------
@test "T-SWD-004: trailing-colon 'assigned:' drift is still readable" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task_q ashigaru91 subtask_swd_004 "assigned:"
    _write_report_q ashigaru91 subtask_swd_004 "done" "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru91"* ]]
    [[ "$output" == *"TASK_ID=subtask_swd_004"* ]]
}

# ---------------------------------------------------------------------------
# T-SWD-005: hit 0 件時に分母 (assigned=N) が印字される。注記付き assigned 2体・
# 完遂 report なし → hit は無いが assigned=2 が名指しで残る。この行が消えれば
# 「分母0 (盲目)」と「全員健全」が log 上再び区別できなくなる (無出力=沈黙の契約
# へ戻る)。正規化との合わせ技も検む = 注記付きが分母に【数えられる】こと。
# ---------------------------------------------------------------------------
@test "T-SWD-005: zero-hit run prints denominator assigned=N (annotated tasks counted) (mutation proof: MUT-0552-003)" {
    _write_task_q ashigaru91 subtask_swd_005a "assigned   # 2026-07-26 09:30 家老dispatch=実装中"
    _write_task_q ashigaru92 subtask_swd_005b "assigned   # 2026-07-26 09:31 家老dispatch=検証中"
    # report なし = 帳簿漏れではない (完遂記録がまだ無いだけ) → hit 0 件が正

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" != *"AGENT="* ]]
    [[ "$output" == *"hit なし。assigned=2"* ]]
}
