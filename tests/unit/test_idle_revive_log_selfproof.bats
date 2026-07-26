#!/usr/bin/env bats
# test_idle_revive_log_selfproof.bats — cmd_1394: ★番人が己の振舞いを証すか★の変異試験.
#
# ★なぜこの試験が在るか (2026-07-27 未明の実害)★:
#   番人 (idle_revive_scan) の log は ★【撃つと判じた】と【撃った】を一字も区別せなんだ★。
#   ACTION=revive の行は判定直後に無条件で print され、--dry-run の return も
#   発行直前 gate (probe/上流障害) も其の【後】に在る。⇒ ★log だけでは「抑止が
#   効いておったか」を永久に判じられぬ★。撃った証は clear_log.yaml の last_clear_ts
#   のみであった。之が家老を二度 誤らせた:
#     (1)「--dry-run ゆえ走っておることは証せる」と申したが【抑止が効いた証】は無かった
#     (2) 家老が log を見て「番人が撃ち始めた」と誤読した (実は配達 escalation の物)
#   併せて ★22:48〜23:18 の 11 scan は全て「対象なし」= 抑止は一度も試されておらぬ★=
#   ★害が無かったのは守りゆえでなく撃つ場面が無かったゆえ★ (「緑のtestが何も証明して
#   いない」の log 版)。
#   もう一つの穴 = ★走行そのものの欠測を名指す行が一つも無い★= 23:18:01 → 00:15:02 の
#   57 分 (*/3 ゆえ 18 scan 欠) が log から読めぬ。★「対象なし が出ておらぬ」と
#   「走っておらぬ」は別である★ — 後者は観測者の不在じゃ。
#
# 契約 (idle_revive_scan.py の log 出力):
#   T-LOG-001: ACTION 行が MODE= を名乗る = ★dry-run と live で文字列が現に異なる★
#   T-LOG-002: dry-run は OUTCOME=revive_not_fired REASON=dry_run を出し★撃たぬ★/
#              live は OUTCOME=revive_fired REASON=clear_command_sent を出し★撃つ★
#   T-LOG-003: 抑止 (発行直前 probe gate / 上流障害 gate) が★log 単独で読める★
#   T-LOG-004: ★決定 1 件 : OUTCOME 丁度 1 行★ (dry-run / live 両方) =
#              沈黙が「撃った」にも「撃たなんだ」にも化けられぬ
#   T-LOG-005: 欠測 WARN が★鳴る★(前回走行を古くした盤面) — MISSED まで名指す
#   T-LOG-006: 欠測 WARN が★鳴らぬ★(正常周期・周期1回分の揺らぎも許容) +
#              走行記録が無い時は NOTE=scan_history_absent で【判じられぬ】と名乗る
#   T-LOG-007: ★既存の読み手を壊しておらぬ★= ACTION 行の前置き
#              (ACTION=/AGENT=/TASK_ID=/IDLE_MIN=/CONSECUTIVE=) が 1 字も動いておらぬ
#              (cmd_1385 の契約 test / 家老の grep が見ておる並び)
#   T-LOG-008: dry-run は★走行の刻だけ★を記し、判定 state (clear_log) は 1 byte も書かぬ
#
# 変異登録 (config/mutation_registry.yaml へは★六号が単独書き手★ゆえ登録案は報告で回す):
#   MUT-1394-001 ACTION 行から MODE=/PHASE= を落とす            → T-LOG-001 赤
#   MUT-1394-002 dry-run の return を emit_outcome より前へ戻す  → T-LOG-002/004 赤
#   MUT-1394-003 probe gate の emit_outcome を落とす             → T-LOG-003/004 赤
#   MUT-1394-004 scan_gap_line の閾値を factor 倍から無限へ      → T-LOG-005 赤
#   MUT-1394-005 scan_gap_line を常時 WARN へ (閾値撤廃)         → T-LOG-006 赤
# 本番 agent には触れない: fixture roster (ashigaru93-94 = 実在せぬ agent 名) +
# pane-state-file 注入 + IDLE_REVIVE_INBOX_WRITE stub + probe monkeypatch で完全隔離
# (test_idle_revive_status_normalize.bats と同型ハーネス)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # ★SCAN_PY_OVERRIDE = 変異試験専用の口★: 番人は cron で毎3分 走っておるゆえ、
    # 生きた script を数十秒とはいえ変異体に差し替えるのは【半端な状態で走らせる】
    # ことになる。⇒ 変異は複写へ当て、其の複写を本 suite が読む。
    # ★対照 (無変異の複写で 8/8 緑) を先に撃つことで、複写が本物の代役たり得ることを
    # 実測してから変異へ進む★ (複写で緑は本物で緑ではない、の逆向きの用心)。
    export SCAN_PY="${SCAN_PY_OVERRIDE:-$PROJECT_ROOT/scripts/idle_revive_scan.py}"
    export VENV_PY="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$SCAN_PY" ] || return 1
    "$VENV_PY" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/idle_revive_log.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/state"

    export INBOX_STUB_RECORD="$TEST_TMPDIR/inbox_record.txt"
    cat > "$TEST_TMPDIR/inbox_stub.sh" <<'STUB'
#!/bin/bash
printf '%s|%s|%s|%s\n' "$1" "$3" "$4" "$2" >> "$INBOX_STUB_RECORD"
exit 0
STUB
    chmod +x "$TEST_TMPDIR/inbox_stub.sh"
    export IDLE_REVIVE_INBOX_WRITE="$TEST_TMPDIR/inbox_stub.sh"
    : > "$TEST_TMPDIR/pane_state.yaml"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# idle 固着の的 (mtime 2h 前 = stall 閾値 15 分を確実に超過)。
_write_stuck_task() {
    local agent="$1"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: subtask_log_${agent}
  parent_cmd: cmd_1394
  assigned_to: ${agent}
  status: assigned
EOF
    touch -d '2 hours ago' "$Q/tasks/${agent}.yaml"
}

_write_pane_states() {
    : > "$TEST_TMPDIR/pane_state.yaml"
    local pair
    for pair in "$@"; do
        echo "${pair%%:*}: ${pair##*:}" >> "$TEST_TMPDIR/pane_state.yaml"
    done
}

# 前回走行の刻を任意の過去へ据える (欠測 WARN の盤面作り)。
_set_heartbeat_age() {
    local spec="$1" mode="${2:-live}"
    cat > "$Q/state/idle_revive_last_scan.yaml" <<EOF
last_scan_ts: '$(date -d "$spec" +%Y-%m-%dT%H:%M:%S)'
mode: ${mode}
pid: 4242
EOF
}

# ★負の主張は helper を通せ★ (2026-07-27 本任で現に踏んだ穴):
#   `! echo "$output" | grep -q X` は ★bats の set -e から明示的に免除される★
#   (bash: "the command's return value is being inverted with !" は exit 対象外) =
#   ★grep が当たっても test は緑のまま★。実際に MUT-1394-005 (常時 WARN) が
#   【変異体は現に WARN を吐いておるのに T-LOG-006 は緑】という形で生き残った。
#   ⇒ 明示的に return 1 する形へ倒す。★鳴らぬ側の契約は、此の helper でしか書くな★。
_refute_output() {
    if echo "$output" | grep -q -- "$1"; then
        echo "★出てはならぬ行が出た: $1★" >&2
        echo "$output" >&2
        return 1
    fi
    return 0
}

_refute_file() {   # $1=file $2=pattern (file 不在は「無い」と読む)
    [ -f "$1" ] || return 0
    if grep -q -- "$2" "$1"; then
        echo "★在ってはならぬ記録が在る: $2 in $1★" >&2
        cat "$1" >&2
        return 1
    fi
    return 0
}

# scan() を直に呼び ★分母 (eligible_count) を数える★ (印字に頼らぬ側の観測口)。
_scan_eligible_py() {
    "$VENV_PY" - <<'PY'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec); spec.loader.exec_module(irs)
q = Path(os.environ["Q"])
panes = irs.load_pane_state_file(Path(os.environ["TEST_TMPDIR"]) / "pane_state.yaml")
results, _, eligible = irs.scan(q / "tasks", q / "reports", Path("."), panes, {},
                                stall_min=15, min_interval_min=5, max_consecutive=3)
print(f"ELIGIBLE={eligible}")
print("ACTIONS=" + ",".join(r["action"] for r in results))
PY
}

_run_main_py() {
    "$VENV_PY" - "$@" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
irs.probe_agent_state = lambda agent: os.environ.get("FAKE_PROBE_STATE", "idle")
irs.pane_upstream_text = lambda agent: os.environ.get("FAKE_PANE_TEXT", "")
argv = ["--queue-root", os.environ["Q"],
        "--pane-state-file", os.environ["TEST_TMPDIR"] + "/pane_state.yaml",
        "--stall-min", "15", "--no-karo-check"] + sys.argv[1:]
rc = irs.main(argv)
print(f"MAIN_RC={rc}")
PY
}

# ---------------------------------------------------------------------------
# T-LOG-001: ACTION 行が MODE= を名乗り、★dry-run と live で現に文字列が異なる★。
# これが落ちる形 = 2026-07-27 の log (どちらの mode でも一字一句同じ行が出る)。
# ---------------------------------------------------------------------------
@test "T-LOG-001: ACTION line carries MODE= and differs between dry-run and live (mutation proof: MUT-1394-001)" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle

    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    local dry_line
    dry_line="$(echo "$output" | grep '^ACTION=revive AGENT=ashigaru93')"
    echo "$dry_line" | grep -q "MODE=dry-run PHASE=decided"

    rm -f "$INBOX_STUB_RECORD"
    run _run_main_py
    [ "$status" -eq 0 ]
    local live_line
    live_line="$(echo "$output" | grep '^ACTION=revive AGENT=ashigaru93')"
    echo "$live_line" | grep -q "MODE=live PHASE=decided"

    # ★同じ盤面で文字列が現に異なる★ — 之が本任の一次証拠じゃ
    [ "$dry_line" != "$live_line" ]
}

# ---------------------------------------------------------------------------
# T-LOG-002: dry-run は【判じたが撃たぬ】を log で名乗り、実際に撃たぬ。
# live は【撃った】を log で名乗り、実際に撃つ。★log と実物が両側で一致する★。
# ---------------------------------------------------------------------------
@test "T-LOG-002: dry-run says revive_not_fired REASON=dry_run and fires nothing; live says revive_fired and fires (mutation proof: MUT-1394-002)" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle

    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OUTCOME=revive_not_fired AGENT=ashigaru93 TASK_ID=subtask_log_ashigaru93 REASON=dry_run"
    _refute_output "OUTCOME=revive_fired"
    [ ! -f "$INBOX_STUB_RECORD" ]   # 実物も撃たれておらぬ

    run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OUTCOME=revive_fired AGENT=ashigaru93 TASK_ID=subtask_log_ashigaru93 REASON=clear_command_sent"
    grep -q "^ashigaru93|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-LOG-003: 抑止が★log 単独で★読める。
#   (a) 発行直前 probe gate (再 probe で busy) → REASON=probe_gate:busy
#   (b) 上流障害 gate (pane に壁の文言) → REASON=upstream_gate
# 何れも ACTION=revive は出る (判じてはおる) が、撃っておらぬことが同じ log で判る。
# ---------------------------------------------------------------------------
@test "T-LOG-003: suppression is readable from the log alone — probe_gate / upstream_gate (mutation proof: MUT-1394-003)" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle

    FAKE_PROBE_STATE=busy run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru93"
    echo "$output" | grep -q "OUTCOME=revive_not_fired AGENT=ashigaru93 TASK_ID=subtask_log_ashigaru93 REASON=probe_gate:busy"
    [ ! -f "$INBOX_STUB_RECORD" ]

    FAKE_PANE_TEXT="You've hit your session limit · resets 4:30am" run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru93"
    echo "$output" | grep -q "OUTCOME=revive_not_fired AGENT=ashigaru93 TASK_ID=subtask_log_ashigaru93 REASON=upstream_gate"
    # ★/clear は撃たれておらぬ★ — 但し此の経路では cmd_1355 の上流障害検知警報が
    # 家老へ1通上がる (episode 初回)。ゆえに「record file が無い」では検められぬ =
    # ★撃たれておらぬのは当の agent への clear_command である★と名指して数える。
    _refute_file "$INBOX_STUB_RECORD" "^ashigaru93|clear_command|"
}

# ---------------------------------------------------------------------------
# T-LOG-004: ★決定 1 件 : OUTCOME 丁度 1 行★。2体を同時に固着させ、dry-run/live の
# 双方で数が一致することを数える。★沈黙が「撃った」にも「撃たなんだ」にも化けられぬ★
# = 分岐を足す者が emit_outcome を忘れた瞬間に此処が赤くなる (本試験の主目的)。
# ---------------------------------------------------------------------------
@test "T-LOG-004: every decided ACTION has exactly one OUTCOME line (dry-run and live)" {
    _write_stuck_task ashigaru93
    _write_stuck_task ashigaru94
    _write_pane_states ashigaru93:idle ashigaru94:idle

    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    local a o
    a="$(echo "$output" | grep -c '^ACTION=')"
    o="$(echo "$output" | grep -c 'OUTCOME=')"
    [ "$a" -eq 2 ]
    [ "$a" -eq "$o" ]

    run _run_main_py
    [ "$status" -eq 0 ]
    a="$(echo "$output" | grep -c '^ACTION=')"
    o="$(echo "$output" | grep -c 'OUTCOME=')"
    [ "$a" -eq 2 ]
    [ "$a" -eq "$o" ]
}

# ---------------------------------------------------------------------------
# T-LOG-005: 欠測が★現に鳴る★。前回走行を 57 分前に据える = 2026-07-26 23:18:01 →
# 00:15:02 の実欠測そのものの盤面。*/3 (180秒) ゆえ 18 scan 欠を名指す。
# ---------------------------------------------------------------------------
@test "T-LOG-005: scan gap WARNs and names how many scans were missed (mutation proof: MUT-1394-004)" {
    _set_heartbeat_age '57 minutes ago' live

    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "WARN=scan_gap"
    echo "$output" | grep -q "MISSED=18"
    echo "$output" | grep -q "EXPECTED_SEC=180"
    echo "$output" | grep -q "PREV_MODE=live"
    # 走行の刻は本走行で更新される (次回は欠測でなくなる)
    grep -q "last_scan_ts" "$Q/state/idle_revive_last_scan.yaml"

    # 閾値の直ぐ外 (周期の2倍超) でも鳴る = 1 scan 欠を見逃さぬ
    _set_heartbeat_age '400 seconds ago' live
    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "WARN=scan_gap"
    echo "$output" | grep -q "MISSED=1"
}

# ---------------------------------------------------------------------------
# T-LOG-006: 正常周期では★鳴らぬ★(両方向の片側)。周期 1 回分の揺らぎ (200秒) も
# 許容する = 毎 scan 鳴る WARN は読まれぬゆえ黙っておるのと同じになる。
# 併せて【走行記録が無い】時に沈黙で誤魔化さず NOTE=scan_history_absent と名乗る。
# ---------------------------------------------------------------------------
@test "T-LOG-006: normal cadence does NOT warn; absent history says so explicitly (mutation proof: MUT-1394-005)" {
    _set_heartbeat_age '60 seconds ago' live
    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    _refute_output "WARN=scan_gap"

    _set_heartbeat_age '200 seconds ago' live   # 周期超だが 2 倍以内 = 揺らぎ
    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    _refute_output "WARN=scan_gap"

    rm -f "$Q/state/idle_revive_last_scan.yaml"
    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    _refute_output "WARN=scan_gap"
    echo "$output" | grep -q "NOTE=scan_history_absent"
}

# ---------------------------------------------------------------------------
# T-LOG-007: ★既存の読み手を壊しておらぬ★。cmd_1385 の契約 test と家老の grep が
# 見ておる前置きを、位置ごと固定する (MODE= を前へ差し込む改変が此処で赤くなる)。
# ---------------------------------------------------------------------------
@test "T-LOG-007: existing readers are intact — ACTION line prefix is byte-for-byte unchanged" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle

    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    # 旧来の並び: ACTION= AGENT= TASK_ID= IDLE_MIN= CONSECUTIVE= が此の順で先頭に在る
    echo "$output" | grep -Eq '^ACTION=revive AGENT=ashigaru93 TASK_ID=subtask_log_ashigaru93 IDLE_MIN=[0-9.]+ CONSECUTIVE=[0-9]+ '
    # 既存 test (T-STA-001 等) と同じ grep が今も通る
    echo "$output" | grep -q "ACTION=revive AGENT=ashigaru93"
}

# ---------------------------------------------------------------------------
# T-LOG-009 (cmd_1394 (3)): ★【読めなんだ】を【沈黙】と混ぜぬ★。
# report YAML が壊れておる idle 固着 agent へは ★/clear を撃たず★、★書き手を名指す★。
# ★何故これが要るか★= 従来は parse 落ちを「未完」へ倒しており、
# ★働いておる agent の report が壊れておるだけで番人が /clear を撃ちうる★ 形であった
# (実測: logs/idle_revive_scan.log の "report YAML parse failed" は書き手 8 名全員に前科)。
# ---------------------------------------------------------------------------
@test "T-LOG-009: unreadable report is NOT silence — no clear fired, writer named (mutation proof: MUT-1394-006)" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle
    # ★YAML として壊れた report★ (tab 混入 + 閉じぬ引用符 = safe_load_all が上げる)
    printf 'report:\n\tstatus: "done\n  task_id: subtask_log_ashigaru93\n' \
        > "$Q/reports/ashigaru93_report.yaml"
    touch -d '2 hours ago' "$Q/reports/ashigaru93_report.yaml"

    run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "report YAML parse failed"
    echo "$output" | grep -q "^ACTION=report_unreadable AGENT=ashigaru93"
    echo "$output" | grep -q "書き手 ashigaru93"          # ★名指しておる★
    echo "$output" | grep -q "OUTCOME=revive_not_fired AGENT=ashigaru93 TASK_ID=subtask_log_ashigaru93 REASON=report_unreadable"
    # ★撃っておらぬ★ (本病の実害はこれ)
    _refute_file "$INBOX_STUB_RECORD" "^ashigaru93|clear_command|"
    # ★分母にも数えておらぬ★ = 判じられぬ物を quorum の割合へ混ぜぬ。
    # 「対象なし」行は results が空の時しか出ぬゆえ、★scan() を直に呼んで分母を数える★
    # (印字に頼れば、印字が無いことを「0 であった」と読み違える)。
    run _scan_eligible_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ELIGIBLE=0"
    echo "$output" | grep -q "ACTIONS=report_unreadable"
}

# ---------------------------------------------------------------------------
# T-LOG-010 (cmd_1394 (3) 逆向き): ★除外が過剰でない★。
# 同じ盤面で report が★健全★なら従前どおり revive を撃つ。
# (これが無ければ「全部を読めぬ扱いにして黙る」実装でも T-LOG-009 は緑になる)
# ---------------------------------------------------------------------------
@test "T-LOG-010: a healthy report on the same board still fires revive (the exclusion is not over-broad)" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle
    cat > "$Q/reports/ashigaru93_report.yaml" <<'EOF'
report:
  task_id: subtask_log_ashigaru93
  agent: ashigaru93
  status: in_progress
  timestamp: '2026-07-27T00:00:00'
EOF
    touch -d '2 hours ago' "$Q/reports/ashigaru93_report.yaml"

    run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "ACTION=report_unreadable"
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru93"
    echo "$output" | grep -q "OUTCOME=revive_fired AGENT=ashigaru93"
    grep -q "^ashigaru93|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-LOG-008: dry-run は★走行の刻だけ★を記す。判定 state (clear_log) は書かぬ =
# 「番人は走ったか」と「番人は撃ったか」を別の器で答える (混ぜれば dry-run が
# rate limit を消費し、次の live が撃てなくなる)。
# ---------------------------------------------------------------------------
@test "T-LOG-008: dry-run records only the run heartbeat — clear_log stays untouched" {
    _write_stuck_task ashigaru93
    _write_pane_states ashigaru93:idle

    run _run_main_py --dry-run
    [ "$status" -eq 0 ]
    [ -f "$Q/state/idle_revive_last_scan.yaml" ]
    [ ! -f "$Q/state/clear_log.yaml" ]

    run _run_main_py
    [ "$status" -eq 0 ]
    [ -f "$Q/state/clear_log.yaml" ]   # live では従来どおり撃った証が残る
    grep -q "last_clear_ts" "$Q/state/clear_log.yaml"
}
