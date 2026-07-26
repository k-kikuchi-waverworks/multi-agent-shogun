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
#   T-SWD-004: 'assigned:' 型の書き癖 drift でも読める (末尾句読点耐性)
#   T-SWD-005: hit 0 件時に分母 (assigned=N) が印字される (家老裁定 09:24 = 無出力を
#              契約にせぬ。分母0の検知層は全PASSと区別がつかぬ — eligible=N と同処方)
#   T-SWD-006: '★assigned★家老dispatch★' (空白を挟まぬ ★ 密着) でも見える (軍師二号
#              OBS-2: 家老は ★ を常用ゆえ、空白を挟まぬ日に盲目が戻る現実の的)
#   T-SWD-007: OBS-2 の読めぬ 9 形すべて + 乗っ取り耐性の直接契約 (normalize_status
#              を module 直呼びで全形一括検分)
#
# 変異登録 (config/mutation_registry.yaml): MUT-0552-001 (task側正規化を折る→T-SWD-001 赤) /
# MUT-0552-002 (report側正規化を折る→T-SWD-003 赤) /
# MUT-0552-003 (分母印字を折る→T-SWD-005 赤) /
# MUT-0552-004 (allowlist 抽出を旧 blocklist 形へ退行→T-SWD-006 赤)。
# 本番 queue には触れない: --queue-root 隔離 (queue_root 指定時は inbox 通知経路に入らぬ
# = stall_watchdog_scan.py main() の契約) + fixture roster ashigaru91 (実在しない agent 名)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # ★番人は cron (15分毎) で現に走っておる★ ⇒ 変異は【複写】へ当てる。
    # ★之が無ければ、複写へ当てた変異が interpreter へ届かず【本番を撃って緑】=
    # 偽の安心になる (2026-07-27 に現に踏んだ)★。★口は三 suite で 1 つ★。
    export STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$PROJECT_ROOT}"
    export SCAN_SH="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.sh"
    export SCAN_PY="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
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

# ---------------------------------------------------------------------------
# T-SWD-006: '★assigned★家老dispatch★' (空白を挟まぬ ★ 密着) の帳簿漏れも見える。
# 軍師二号 OBS-2 の筆頭形: 家老は ★ を常用ゆえ「空白を挟まぬ日」は現実に来る。
# 旧実装 (空白 split + :;,. rstrip) はこの形で盲目に戻る = blocklist の宿命。
# これが落ちる形 = allowlist 抽出の退行 (MUT-0552-004 の的)。
# ---------------------------------------------------------------------------
@test "T-SWD-006: star-adjacent '★assigned★note★' (no whitespace) bookkeeping omission IS a hit (mutation proof: MUT-0552-004)" {
    local ts="$(_ts_minutes_ago 45)"
    _write_task_q ashigaru91 subtask_swd_006 "★assigned★家老dispatch=同型穴の是正★"
    _write_report_q ashigaru91 subtask_swd_006 "completed" "$ts"

    run bash "$SCAN_SH" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    [[ "$output" == *"AGENT=ashigaru91"* ]]
    [[ "$output" == *"TASK_ID=subtask_swd_006"* ]]
}

# ---------------------------------------------------------------------------
# T-SWD-007: OBS-2 の読めぬ 9 形すべての直接契約 + 乗っ取り耐性 (負例)。
# idle_revive 側 T-STA-007 と同型 — copy drift は各 copy の試験が独立に見張る。
# ---------------------------------------------------------------------------
@test "T-SWD-007: all 9 OBS-2 decorated forms normalize to 'assigned'; note words cannot hijack" {
    run "$PROJECT_ROOT/.venv/bin/python3" - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("sws", os.environ["SCAN_PY"])
sws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sws)
n = sws.normalize_status
forms = [
    "★assigned★家老dispatch=検知層の検分★",   # 1 ★密着 (空白なし)
    "assigned（2026-07-26 07:23 家老dispatch）",  # 2 全角括弧密着
    "【assigned】家老dispatch",                   # 3 全角隅付き括弧
    "assigned。手番待ち",                          # 4 全角句点密着
    "assigned、検証中",                            # 5 全角読点密着
    "assigned：注記",                              # 6 全角コロン密着
    "assigned…注記",                               # 7 三点リーダ密着
    "assigned—注記",                               # 8 em-dash 密着
    "assigned/注記",                               # 9 スラッシュ密着
]
ng = []
for f in forms:
    got = n(f)
    if got != "assigned":
        ng.append(f"形 {f!r} → {got!r} (expected 'assigned')")
for f, want in [
    ("done   # 家老dispatch=assigned直後に完遂", "done"),
    ("★completed★assigned側の検分済★", "completed"),
    ("完了", ""),
]:
    got = n(f)
    if got != want:
        ng.append(f"負例 {f!r} → {got!r} (expected {want!r})")
if ng:
    print("\n".join(ng))
    raise SystemExit(1)
print("ALL_9_FORMS_OK")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ALL_9_FORMS_OK"
}
