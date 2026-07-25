#!/usr/bin/env bats
# test_idle_revive_quorum.bats — cmd_1339 停電型 (相関沈黙) quorum gate 変異試験.
#
# 2026-07-25 19:51-20:45 殿 token 切れで全8体が同時沈黙 → 45分閾値を素通りして
# 誤 clear が発生 (「閾値では解けぬ」)。quorum gate は同一 scan cycle の stall 判定を
# 集計し「≥3体 かつ scan対象の≥75%」で系イベントと判定、個別 clear を全面抑止して
# 家老へ警報1通のみ送る。本 file は task YAML の変異試験 (a)(b)(c)(d) を実装する:
#
#   (a) T-QRM-001: 3体以上同時 stall → clear 全面抑止 + 家老警報1通のみ + state非消費
#   (b) T-QRM-002: 1〜2体だけの stall → 抑止されず個別 clear が従来どおり出る
#   (c) T-QRM-003: quorum 判定を無効化 (--no-quorum-gate) すると (a) が落ちる
#       (= 検査が本当に効いている証明)
#   (d) T-QRM-004: pane 上流障害文字列で個別抑止 / 文字列を消すと発火せぬ
#   追加 T-QRM-005: ≥3体でも割合 <75% なら不成立 (busy 多数 = 系は健全)
#   追加 T-QRM-006: 停電型成立中は家老 degrade clear も抑止
#   追加 T-QRM-007: 警報 throttle = 2回連続 scan でも警報は1通のみ
#
# 本番 agent には触れない: fixture roster (ashigaru91-98 = 実在しない agent 名) +
# pane-state-file 注入 + IDLE_REVIVE_INBOX_WRITE stub (実 inbox 非汚染) +
# probe_agent_state / pane_upstream_text の monkeypatch で完全隔離。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_PY="$PROJECT_ROOT/scripts/idle_revive_scan.py"
    export VENV_PY="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$SCAN_PY" ] || return 1
    "$VENV_PY" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/idle_revive_quorum.XXXXXX")"
    export Q="$TEST_TMPDIR/queue"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/state"

    # inbox_write stub: 実 inbox へ書かず record file へ1行記録 (target|type|from|body)
    export INBOX_STUB_RECORD="$TEST_TMPDIR/inbox_record.txt"
    cat > "$TEST_TMPDIR/inbox_stub.sh" <<'STUB'
#!/bin/bash
printf '%s|%s|%s|%s\n' "$1" "$3" "$4" "$2" >> "$INBOX_STUB_RECORD"
exit 0
STUB
    chmod +x "$TEST_TMPDIR/inbox_stub.sh"
    export IDLE_REVIVE_INBOX_WRITE="$TEST_TMPDIR/inbox_stub.sh"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fixture agent: active task (2h前 mtime = stall 確実) を書く
_write_task() {
    local agent="$1"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: subtask_qrm_${agent}
  parent_cmd: cmd_test
  assigned_to: ${agent}
  status: assigned
EOF
    touch -d '2 hours ago' "$Q/tasks/${agent}.yaml"
}

# pane-state-file を書く: 引数 = "agent:state" の列
_write_pane_states() {
    : > "$TEST_TMPDIR/pane_state.yaml"
    local pair
    for pair in "$@"; do
        echo "${pair%%:*}: ${pair##*:}" >> "$TEST_TMPDIR/pane_state.yaml"
    done
}

# python harness: main() を monkeypatch (probe=idle固定・pane本文=FAKE_PANE_TEXT env)
# つきで非 dry-run 実行する。fixture agent の pane は実在しないため、probe を
# 固定しないと発行直前 gate (cmd_1339 (e)) が absent 判定で clear を握ってしまい、
# quorum の有無による差が観測できない。
# cmd_1355 追加注入口:
#   STRIP_PATTERNS=1     → 追加 pattern (session limit / /usage-credits) を外して実行
#                          (「pattern を外すと検知が落ちる」の scan 級 両側実測用)
#   FAKE_PROBE_STATE     → probe_agent_state の固定値 (default idle)
_run_main_py() {
    "$VENV_PY" - "$@" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
irs.probe_agent_state = lambda agent: os.environ.get("FAKE_PROBE_STATE", "idle")
irs.pane_upstream_text = lambda agent: os.environ.get("FAKE_PANE_TEXT", "")
if os.environ.get("STRIP_PATTERNS") == "1":
    irs.UPSTREAM_FAILURE_PATTERNS = tuple(
        p for p in irs.UPSTREAM_FAILURE_PATTERNS
        if p not in ("session limit", "/usage-credits"))
argv = ["--queue-root", os.environ["Q"],
        "--pane-state-file", os.environ["TEST_TMPDIR"] + "/pane_state.yaml",
        "--stall-min", "15"] + sys.argv[1:]
rc = irs.main(argv)
print(f"MAIN_RC={rc}")
PY
}

_count_record() {
    # $1 = grep pattern。record 無しは 0。
    [ -f "$INBOX_STUB_RECORD" ] || { echo 0; return; }
    grep -c "$1" "$INBOX_STUB_RECORD" || true
}

# ---------------------------------------------------------------------------
# (a) T-QRM-001: 4体同時 stall (100% ≥ 75%, 4 ≥ 3) → 全面抑止 + 警報1通 + state非消費
# ---------------------------------------------------------------------------
@test "T-QRM-001 (a): 3+ simultaneous stalls suppress all clears and send exactly one karo warning" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:idle ashigaru94:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "MAIN_RC=0"
    # 個別 clear は 1本も出ていない
    [ "$(_count_record 'clear_command')" -eq 0 ]
    # 家老への warning がちょうど1通
    [ "$(_count_record '^karo|warning|')" -eq 1 ]
    grep -q "停電型" "$INBOX_STUB_RECORD"
    # 抑止が log に明示される (黙って止まらない)
    echo "$output" | grep -q "BLACKOUT抑止"
    # state 非消費: clear_log に last_clear_ts が積まれていない = 復帰後は即座に従来判定
    if [ -f "$Q/state/clear_log.yaml" ]; then
        ! grep -q "last_clear_ts" "$Q/state/clear_log.yaml"
    fi
    # throttle state が記録された
    [ -f "$Q/state/blackout_suppress" ]
}

# ---------------------------------------------------------------------------
# (b) T-QRM-002: 2体だけ stall (2/4=50%, 2<3) → 抑止されず個別 clear が従来どおり
# ---------------------------------------------------------------------------
@test "T-QRM-002 (b): only 1-2 stalls → no suppression, individual clears fire as before" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:busy ashigaru94:busy

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    # stall した2体へ個別 clear が出る (過剰抑止でない証明)
    [ "$(_count_record 'clear_command')" -eq 2 ]
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
    grep -q "^ashigaru92|clear_command|" "$INBOX_STUB_RECORD"
    # 停電型警報は出ない
    [ "$(_count_record '停電型')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (c) T-QRM-003: quorum 判定を無効化すると (a) の期待が落ちる = 検査が効いている証明
# ---------------------------------------------------------------------------
@test "T-QRM-003 (c): disabling the quorum gate breaks (a)'s expectations (mutation proof)" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:idle ashigaru94:idle

    run _run_main_py --no-karo-check --no-quorum-gate
    [ "$status" -eq 0 ]
    # (a) の期待「clear 0本」が破れる: 4本全て発行される
    [ "$(_count_record 'clear_command')" -eq 4 ]
    # (a) の期待「警報1通」も破れる: 0通
    [ "$(_count_record '停電型')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (d) T-QRM-004: 上流障害文字列 → 個別抑止 / 文字列を消すと発火せぬ (両側)
# ---------------------------------------------------------------------------
@test "T-QRM-004 (d): upstream-failure string suppresses the clear; removing it un-suppresses" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    # 1体のみ stall = quorum 不成立 → 上流障害 gate 単独の挙動を観測
    _write_pane_states ashigaru91:idle ashigaru92:busy ashigaru93:busy ashigaru94:busy

    # 上流障害文字列あり → 抑止
    FAKE_PANE_TEXT="Claude usage limit reached · resets at 3am" \
        run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'clear_command')" -eq 0 ]
    echo "$output" | grep -q "上流障害gate"

    # 文字列を消す → 従来どおり発行 (検知が本当に文字列を見ている証明)
    rm -f "$INBOX_STUB_RECORD"
    FAKE_PANE_TEXT="normal tool output, nothing suspicious here" \
        run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'clear_command')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# T-QRM-005: 3体 stall でも割合 37.5% < 75% → 不成立 (busy 多数 = 系は健全)
# ---------------------------------------------------------------------------
@test "T-QRM-005: 3 stalls among 8 eligible (37.5% < 75%) → no quorum, clears fire" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94 ashigaru95 ashigaru96 ashigaru97 ashigaru98; do
        _write_task "$a"
    done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:idle \
        ashigaru94:busy ashigaru95:busy ashigaru96:busy ashigaru97:busy ashigaru98:busy

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'clear_command')" -eq 3 ]
    [ "$(_count_record '停電型')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# T-QRM-006: 停電型成立中は家老 degrade clear も抑止 (clear「全面」抑止の全面性)
# ---------------------------------------------------------------------------
@test "T-QRM-006: blackout also suppresses the karo degrade clear" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:idle ashigaru94:idle
    # 家老 degrade 成立条件: stale dashboard (60分前) + active task 存在
    echo "# dashboard" > "$TEST_TMPDIR/dashboard.md"
    touch -d '60 minutes ago' "$TEST_TMPDIR/dashboard.md"

    run _run_main_py --dashboard-path "$TEST_TMPDIR/dashboard.md"
    [ "$status" -eq 0 ]
    # karo への clear_command は出ない
    [ "$(_count_record '^karo|clear_command|')" -eq 0 ]
    [ "$(_count_record 'clear_command')" -eq 0 ]
    echo "$output" | grep -q "家老degrade判定を抑止"
    # 警報は1通
    [ "$(_count_record '^karo|warning|')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# T-QRM-007: 警報 throttle — 連続2 scan でも警報は合計1通のみ
# ---------------------------------------------------------------------------
@test "T-QRM-007: second scan within throttle window does not re-alert (exactly one warning)" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:idle ashigaru94:idle

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "throttle"
    [ "$(_count_record '^karo|warning|')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# T-QRM-009: 家老労働証跡 gate (2026-07-25 23:39 家老誤clear 実データの再発防止)
#   dashboard stale でも K2 (task YAML書込) / K3 (from:karo inbox) が window 内なら
#   家老を clear しない。証跡を消すと従来どおり revive = 検査が本当に効いている両側証明。
# ---------------------------------------------------------------------------
@test "T-QRM-009: karo labor evidence (K2/K3) blocks the degrade clear; removing it re-enables" {
    _write_task ashigaru91
    echo "# dashboard" > "$TEST_TMPDIR/dashboard.md"
    touch -d '60 minutes ago' "$TEST_TMPDIR/dashboard.md"
    mkdir -p "$Q/inbox"

    run "$VENV_PY" - <<'PY'
import datetime, importlib.util, os, subprocess
from pathlib import Path
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
Q = Path(os.environ["Q"])
dash = Q.parent / "dashboard.md"
task = Q / "tasks" / "ashigaru91.yaml"

def degrade():
    hit, _ = irs.scan_karo_degrade(
        dash, Q / "tasks", Q / "reports", {},
        karo_stale_min=20, karo_min_interval_min=20, max_consecutive=3)
    return hit

# Side B (証跡なし・23:39 以前の挙動): task YAML は 2h 前 → 従来どおり revive 判定
hit = degrade()
assert hit is not None and hit["action"] == "revive", hit

# Side A-K2: 家老が 5 分前に task を dispatch した (task YAML 書込) → clear されない
subprocess.run(["touch", "-d", "5 minutes ago", str(task)], check=True)
assert degrade() is None, "K2 (task YAML書込) が生存証跡として効いていない"

# K2 証跡を老化させると再び revive = 検査が mtime を本当に見ている証明
subprocess.run(["touch", "-d", "2 hours ago", str(task)], check=True)
hit = degrade()
assert hit is not None and hit["action"] == "revive", hit

# Side A-K3: 3 分前の from:karo inbox メッセージ → clear されない
ts = (datetime.datetime.now() - datetime.timedelta(minutes=3)).isoformat(timespec="seconds")
(Q / "inbox" / "ashigaru91.yaml").write_text(
    "messages:\n- content: test\n  from: karo\n  id: m1\n  read: true\n"
    f"  timestamp: '{ts}'\n  type: task_assigned\n", encoding="utf-8")
assert degrade() is None, "K3 (from:karo inbox) が生存証跡として効いていない"

# K3 の from を karo 以外へ変えると再び revive = from 判定が本物
(Q / "inbox" / "ashigaru91.yaml").write_text(
    "messages:\n- content: test\n  from: ashigaru91\n  id: m1\n  read: true\n"
    f"  timestamp: '{ts}'\n  type: report_received\n", encoding="utf-8")
hit = degrade()
assert hit is not None and hit["action"] == "revive", hit
print("OK karo labor gate both sides")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK karo labor gate both sides"
}

# ---------------------------------------------------------------------------
# detect_upstream_failure 単体: 具申4種 (usage limit/credit/auth/rate limit) を全て検知
# ---------------------------------------------------------------------------
# ═══════════════════════════════════════════════════════════════════════════
# cmd_1355: 実 pane 文言 (2026-07-26 全軍3h停止) の検知・台帳・再開通知
# fixture = tests/fixtures/upstream_session_limit_pane.txt (capture-pane 採取・byte 凍結)
# ═══════════════════════════════════════════════════════════════════════════

_load_real_pane_text() {
    export FAKE_PANE_TEXT="$(cat "$PROJECT_ROOT/tests/fixtures/upstream_session_limit_pane.txt")"
}

# ---------------------------------------------------------------------------
# T-QRM-010: 実文言で /clear 抑止 + 台帳記録 + 家老へ検知警報ちょうど1通 (episode once)
# ---------------------------------------------------------------------------
@test "T-QRM-010 (cmd_1355): real session-limit banner suppresses clear, records ledger, alerts karo exactly once" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    # 1体のみ stall = quorum 不成立 → 個別経路の挙動を観測 (今夜の実態: 対象が少数でも起きる)
    _write_pane_states ashigaru91:idle ashigaru92:busy ashigaru93:busy ashigaru94:busy
    _load_real_pane_text

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    # /clear は 1本も出ない (実文言 "session limit" が gate に掛かる)
    [ "$(_count_record 'clear_command')" -eq 0 ]
    echo "$output" | grep -q "上流障害gate"
    # 台帳へ記録された (agent + pattern + 検知文言 + resets ETA)
    [ -f "$Q/state/upstream_outage.yaml" ]
    grep -q "ashigaru91" "$Q/state/upstream_outage.yaml"
    grep -q "session limit" "$Q/state/upstream_outage.yaml"
    grep -q "resets_eta: '2" "$Q/state/upstream_outage.yaml"   # parse 成功 (非 null)
    grep -q "subtask_qrm_ashigaru91" "$Q/state/upstream_outage.yaml"  # task_id 記録
    # 家老へ検知警報ちょうど1通
    [ "$(_count_record '上流障害(枠切れ/account系)検知')" -eq 1 ]
    # 2回目 scan でも再警報しない (episode 1通 + throttle)
    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record '上流障害(枠切れ/account系)検知')" -eq 1 ]
    [ "$(_count_record 'clear_command')" -eq 0 ]
    # 再開通知はまだ出ない (resets ETA は検知時点から見て未来ゆえ)
    [ "$(_count_record '再開せよ')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# T-QRM-011: ★家老 clear にも同じ guard★ (2026-07-26 01:57 家老被弾の再発防止・両側)
# ---------------------------------------------------------------------------
@test "T-QRM-011 (cmd_1355): karo degrade clear is suppressed by upstream banner; benign text re-enables (both sides)" {
    _write_task ashigaru91
    _write_pane_states ashigaru91:busy
    echo "# dashboard" > "$TEST_TMPDIR/dashboard.md"
    touch -d '60 minutes ago' "$TEST_TMPDIR/dashboard.md"

    # Side A: 家老 pane に実 banner → karo /clear は出ない + 台帳に karo が載る
    _load_real_pane_text
    run _run_main_py --dashboard-path "$TEST_TMPDIR/dashboard.md"
    [ "$status" -eq 0 ]
    [ "$(_count_record '^karo|clear_command|')" -eq 0 ]
    echo "$output" | grep -q "SKIP(上流障害gate): karo"
    grep -q "karo" "$Q/state/upstream_outage.yaml"

    # Side B: banner が無ければ従来どおり karo clear が出る (guard が文言を見ている証明)
    rm -f "$INBOX_STUB_RECORD" "$Q/state/upstream_outage.yaml" "$Q/state/upstream_alert_throttle" "$Q/state/clear_log.yaml"
    FAKE_PANE_TEXT="normal tool output, nothing suspicious here" \
        run _run_main_py --dashboard-path "$TEST_TMPDIR/dashboard.md"
    [ "$status" -eq 0 ]
    [ "$(_count_record '^karo|clear_command|')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# T-QRM-012: ★枠が戻った時に誰が起こすのか★ — resets ETA 経過で家老へ再開通知1通のみ。
#            banner が pane に残存したままでも鳴る (banner は枠回復後も消えぬと実測済)。
#            全員実働へ戻れば通知なしで episode close。
# ---------------------------------------------------------------------------
@test "T-QRM-012 (cmd_1355): resume notice fires once after resets ETA even with banner still on pane; closes silently when all recover" {
    _write_task ashigaru91
    _write_pane_states ashigaru91:idle
    _load_real_pane_text

    _seed_ledger() {
        mkdir -p "$Q/state"
        cat > "$Q/state/upstream_outage.yaml" <<EOF
episode:
  first_detected: '$(date -d '2 hours ago' +%Y-%m-%dT%H:%M:%S)'
  resets_hint: "You've hit your session limit · resets 4:30am"
  resets_eta: '$(date -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S)'
  detect_notified_ts: '$(date -d '2 hours ago' +%Y-%m-%dT%H:%M:%S)'
  resume_notified_ts: null
  agents:
    ashigaru91:
      detected_ts: '$(date -d '2 hours ago' +%Y-%m-%dT%H:%M:%S)'
      pattern: session limit
      task_id: subtask_qrm_ashigaru91
      excerpt: "You've hit your session limit · resets 4:30am"
EOF
    }
    _seed_ledger

    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    # 再開通知がちょうど1通 (R1: ETA+grace 経過。banner 残存でも鳴る)
    [ "$(_count_record '再開せよ')" -eq 1 ]
    grep -q "resume_notified_ts: '2" "$Q/state/upstream_outage.yaml"
    grep -q "R1" "$INBOX_STUB_RECORD"
    # 2回目 scan で重複しない (1 episode 1通)
    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record '再開せよ')" -eq 1 ]

    # 全員実働へ戻った場合: 通知なしで episode close (起こす相手が居らぬ)
    rm -f "$INBOX_STUB_RECORD" "$Q/state/upstream_outage.yaml" "$Q/state/upstream_alert_throttle"
    _seed_ledger
    _write_pane_states ashigaru91:busy
    FAKE_PROBE_STATE=busy run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record '再開せよ')" -eq 0 ]
    [ ! -f "$Q/state/upstream_outage.yaml" ]
    echo "$output" | grep -q "episode close"
}

# ---------------------------------------------------------------------------
# T-QRM-013: 変異の scan 級 両側実測 — 追加 pattern を外すと今夜の誤 clear が再現する
#            (= pattern が「偶然でなく契約として」誤 clear を止めている証明)
# ---------------------------------------------------------------------------
@test "T-QRM-013 (cmd_1355): stripping the added patterns reproduces tonight's wrong clear (mutation both sides at scan level)" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:busy ashigaru93:busy ashigaru94:busy
    _load_real_pane_text

    # pattern 有り → 抑止 (T-QRM-010 と同じ側)
    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'clear_command')" -eq 0 ]

    # pattern を外す → 実 banner が素通りし /clear が撃たれる = 2026-07-26 未明の再現
    rm -f "$INBOX_STUB_RECORD" "$Q/state/upstream_outage.yaml" "$Q/state/upstream_alert_throttle" "$Q/state/clear_log.yaml"
    STRIP_PATTERNS=1 run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'clear_command')" -eq 1 ]
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-QRM-014: escalation にも上流障害 gate — 枠切れ agent への「復帰せず」警報 (今夜の
#            10通 spam の型) を出さず台帳へ記録。文言が無ければ従来どおり警報 (両側)。
# ---------------------------------------------------------------------------
@test "T-QRM-014 (cmd_1355): upstream banner suppresses escalation alert and records ledger; benign text re-enables (both sides)" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:busy ashigaru93:busy ashigaru94:busy
    # escalation latch 直行: consecutive=3 (max) + last_alert_ts なし (旧 schema = 即警報側)
    mkdir -p "$Q/state"
    cat > "$Q/state/clear_log.yaml" <<EOF
agents:
  ashigaru91:
    last_clear_ts: '$(date -d '20 minutes ago' +%Y-%m-%dT%H:%M:%S)'
    consecutive: 3
    last_task_id: subtask_qrm_ashigaru91
EOF

    # Side A: banner あり → escalation 警報を出さず台帳記録
    _load_real_pane_text
    run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'idle_revive_escalation_alert')" -eq 0 ]
    echo "$output" | grep -q "上流障害gate/escalation"
    grep -q "ashigaru91" "$Q/state/upstream_outage.yaml"

    # Side B: banner なし → 従来どおり escalation 警報が出る
    rm -f "$INBOX_STUB_RECORD" "$Q/state/upstream_outage.yaml" "$Q/state/upstream_alert_throttle"
    FAKE_PANE_TEXT="normal tool output, nothing suspicious here" \
        run _run_main_py --no-karo-check
    [ "$status" -eq 0 ]
    [ "$(_count_record 'idle_revive_escalation_alert')" -eq 1 ]
}

@test "T-QRM-008: detect_upstream_failure catches all four advised pattern families, not plain text" {
    run "$VENV_PY" - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
f = irs.detect_upstream_failure
assert f("Claude usage limit reached") is not None
assert f("Your credit balance is too low") is not None
assert f("API Error: authentication_error") is not None
assert f("OAuth token has expired. Please run /login") is not None
assert f("rate_limit_error: Number of requests exceeded") is not None
assert f("Rate limit exceeded, retrying...") is not None
assert f("") is None
assert f("⏵⏵ bypass permissions on (shift+tab to cycle)") is None
assert f("writing tests for the scanner") is None
print("OK all patterns")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK all patterns"
}
