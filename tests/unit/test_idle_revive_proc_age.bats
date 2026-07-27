#!/usr/bin/env bats
# test_idle_revive_proc_age.bats — cmd_1392: ★観測者の不在を観測値に混ぜぬ★の変異試験.
#
# ★何が起きたか (2026-07-27 00:24:04 の実害・軍師二号が刻を並べて実測)★:
#   00:13:45 supervisor が lifetime lock = 環境の建て直しが始まる
#   00:14:00 ★家老が pause を解き、番人を実射へ戻した★
#   00:17:19 ★tmux shell 誕生 = 見張られる側が【此処で生まれた】★ (番人の 3分19秒 後)
#   00:24:04 ★番人が齢 6.5 分の process へ「91.5 / 95.4 分の沈黙」を名乗って /clear★
#            = ★14.1 倍の不可能★。番人は己が 57 分 寝ておった事も知らなんだ。
#
# ★停電型 quorum は【最初は効いておった】★ (00:15/00:18 は 4 体とも抑止) —
#   ★agent が一体ずつ戻ると分子が 3 を割り、まだ戻らぬ 2 体が「少数の固着」に見えた★
#   = ★復旧の途中には必ず穴が開く★。⇒ 症状 (全員沈黙) を見る守りは在ったが、
#     病 (存在せなんだ区間を観測値に混ぜる) を見る守りは無かった。
#
# ★本層が問うのは真偽でなく【存在】である★:
#   「其の process は、名乗ろうとしておる沈黙の間、存在しておらなんだ」— 之だけ。
#   ⇒ 世界知識も他 agent の状態も要らず ★agent 1 体で閉じる★ = quorum と独立に効く。
#
# 契約:
#   T-AGE-001 矛盾成立 → /clear を撃たぬ + log 単独で読める        (MUT-1392-001 の的)
#   T-AGE-002 齢は【最も古い子】を取る・子 0 件は齢 0 に化けぬ      (MUT-1392-002/005 の的)
#   T-AGE-003 連続 3 回で起き直り警報が★丁度1通★ (/clear は撃たぬ) (MUT-1392-003 の的)
#   T-AGE-004 抑止は state を消費せぬ                                (MUT-1392-004 の的)
#   T-AGE-005 ★CLI 不在 (齢 判じられぬ) は矛盾の証ではない★= 従来判定 (MUT-1392-005 の的)
#   T-AGE-006 抑止行が★両方の数★を運ぶ (元の数を黙って捨てぬ)      (MUT-1392-006 の的)
#   T-AGE-007 ★★負の対照 = 本物の固着は今も撃たれる★★  ← ★之が最も重い1本★
#   T-AGE-008 牙(1) 齢は必ず育つ = 抑止は【遅延】であって【免除】ではない
#   T-AGE-009 牙(3) 抑止の総量を毎 scan 名乗る (0 の時も名乗る)
#   T-AGE-010 成り立たぬ主張を quorum の分子へ混ぜぬ (家老へ偽の停電型を上げぬ)
#   T-AGE-011 ★境界の帯 [0.5, 1.0) の内側★= 比 0.99 でも抑止は効く   (軍師一号 差し戻し)
#   T-AGE-012 ★帯の上端の直上★= 比 1.01 は抑止せぬ (T-AGE-011 と両側で挟む)
#
# ★★軍師一号の差し戻し (2026-07-27 03:16) = 「変異は【点】を撃つ。境界は【帯】である」★★
#   T-AGE-001〜010 が使う 齢/沈黙 の比 = 0.07 / 0.25 / 1.26 / 2.0 の ★4 点のみ★ で、
#   ★[0.5, 1.0) の帯を一本も跨いでおらなんだ★ ⇒ 閾を `age_sec < claimed` から
#   ★`age_sec <= claimed * 0.5`★ へ緩める変異が ★10/10 緑のまま生き残った★
#   (拙者も 03:2x に己の複写で再現 = 10/10 緑)。
#   ★実害の形★= 齢 80 分の pane が「沈黙 95 分」と名乗られる (比 0.84) =
#   真に不可能な主張であるのに抑止が外れる ⇒ ★00:24 の実害の【時間が伸びた版】★。
#   ⇒ T-AGE-011/012 は ★点でなく帯の両端を挟む★ ために在る。
#
# ★負の対照 (T-AGE-007) が要である理由★:
#   本設計の最大の危険は ★撃たなくなること★ である。他の 9 本は「抑止が効くか」
#   しか見ておらぬ ⇒ ★全部緑でも番人が死んでおる形が作れる★。
#   T-AGE-007 だけが其の方向を縛る (軍師二号 設計 §6)。
#
# 本番 agent には触れぬ: fixture roster (ashigaru91-94 = 実在せぬ agent 名) +
# pane-state-file 注入 + IDLE_REVIVE_INBOX_WRITE stub + 齢/probe の monkeypatch。
# ★番人は cron で毎3分 走っておるゆえ、変異は SCAN_PY_OVERRIDE の複写へ当てる★。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_PY="${SCAN_PY_OVERRIDE:-$PROJECT_ROOT/scripts/idle_revive_scan.py}"
    export VENV_PY="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$SCAN_PY" ] || return 1
    "$VENV_PY" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/idle_revive_age.XXXXXX")"
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
    unset FAKE_PROC_AGE
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# 固着の的。$2 = task YAML の mtime (= 名乗られる沈黙の長さ)。既定 2 時間前。
_write_stuck_task() {
    local agent="$1" age="${2:-2 hours ago}"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: subtask_age_${agent}
  parent_cmd: cmd_1392
  assigned_to: ${agent}
  status: assigned
EOF
    touch -d "$age" "$Q/tasks/${agent}.yaml"
}

_write_pane_states() {
    : > "$TEST_TMPDIR/pane_state.yaml"
    local pair
    for pair in "$@"; do
        echo "${pair%%:*}: ${pair##*:}" >> "$TEST_TMPDIR/pane_state.yaml"
    done
}

# ★負の主張は helper を通せ★ (cmd_1401): bats の `! cmd` は set -e から免除ゆえ
# ★当たっても緑★ になる。明示的に return 1 する形でしか「鳴らぬ側」は書けぬ。
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

_count_record() {
    [ -f "$INBOX_STUB_RECORD" ] || { echo 0; return; }
    grep -c "$1" "$INBOX_STUB_RECORD" || true
}

# ★齢の注入★: FAKE_PROC_AGE_<agent> が優先・無ければ FAKE_PROC_AGE・
# 何れも無ければ ★None (= 判じられぬ)★ = 従来どおりの盤面になる。
_run_main_py() {
    "$VENV_PY" - "$@" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
irs.probe_agent_state = lambda agent: os.environ.get("FAKE_PROBE_STATE", "idle")
irs.pane_upstream_text = lambda agent: os.environ.get("FAKE_PANE_TEXT", "")

# ★now_ts を受ける (cmd_1392 是正 2026-07-27)★= 本体が
#   `agent_proc_age_sec(agent, now_ts=now_ts)` で呼ぶ様になったゆえ。
# ★之を怠れば TypeError で main が落ち、本 suite 15 本中 13 本が【production の
#   非でなく stub の非で】赤くなる★ — 実際に 10:1x に其の形で赤くなった。
def fake_age(agent, now_ts=None):
    v = os.environ.get("FAKE_PROC_AGE_" + agent, os.environ.get("FAKE_PROC_AGE", ""))
    v = v.strip()
    if v in ("", "none", "None"):
        return None
    return int(v)

# ★★此処が本 suite の【最大の盲点】である (2026-07-27 10:2x に名乗る)★★
#   ★齢の口そのものを丸ごと差し替えておる★ ⇒ ★本 suite は【齢を如何に測るか】を
#   一度も検めておらぬ★ = cmd_1392 の是正 (ps 一族 → mtime 一族) は、
#   ★本 suite が全部緑でも壊れうる★。
#   ⇒ ★ゆえに T-AGE-002 / T-AGE-016 / T-AGE-017 は stub を通さず実物を撃つ★。
irs.agent_proc_age_sec = fake_age
argv = ["--queue-root", os.environ["Q"],
        "--pane-state-file", os.environ["TEST_TMPDIR"] + "/pane_state.yaml",
        # ★本番の値でも撃てる口★ (家老 04:01・cmd_1392)= ★既定は従前どおり 15★。
        # ★之が無ければ「15 でしか赤くならぬ牙 = 本番では死んでおる牙」を誰も見つけられぬ★
        # (★本番の cron は --stall-min 45 で走っておる★= T-AGE-014 が其の差を名乗る)。
        "--stall-min", os.environ.get("STALL_MIN_UNDER_TEST", "15"),
        "--no-karo-check"] + sys.argv[1:]
rc = irs.main(argv)
print(f"MAIN_RC={rc}")
PY
}

# ---------------------------------------------------------------------------
# T-AGE-001 (MUT-1392-001 の的): ★00:24:04 の実害そのものの盤面★。
# 齢 6.5 分 (390秒) の process へ 120 分の沈黙を名乗ろうとする ⇒ 撃たぬ。
# ---------------------------------------------------------------------------
@test "T-AGE-001: a claim older than the process itself suppresses the /clear (the 00:24:04 shape)" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    echo "$output" | grep -q "OUTCOME=revive_not_fired AGENT=ashigaru91 TASK_ID=subtask_age_ashigaru91 REASON=impossible_claim"
    # ★撃っておらぬ★ — 本病の実害はこれ
    _refute_file "$INBOX_STUB_RECORD" "^ashigaru91|clear_command|"
    # ★判じた事は log 単独で読める★ (沈黙で誤魔化さぬ)
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM抑止: ashigaru91"
    # 決定 1 件 : OUTCOME 丁度 1 行 (cmd_1394 の契約を破っておらぬ)
    local a o
    a="$(echo "$output" | grep -c '^ACTION=')"
    o="$(echo "$output" | grep -c 'OUTCOME=')"
    [ "$a" -eq "$o" ]
}

# ---------------------------------------------------------------------------
# T-AGE-002 (MUT-1392-002 / 005 の的): 齢の取り方そのものを直に撃つ。
#   ★最大を取る★= 子が複数在る過渡 (旧 CLI が終いきらぬ) で若い方を取れば
#     ★抑止が広がる★ = 真の固着を見逃す。★抑止は狭い側へ倒す★。
#   ★子 0 件は None★= 齢 0 に化ければ ★何もかもを抑止する門★ になる。
# ---------------------------------------------------------------------------
@test "T-AGE-002: the age is the OLDEST child, and zero children is None (never age 0)" {
    run "$VENV_PY" - <<'PY'
import datetime, importlib.util, os, subprocess, time
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec); spec.loader.exec_module(irs)
f = irs._oldest_child_age_from_pids
now = datetime.datetime.now().timestamp()

# ★★入力は【pid の並び】であって【齢の並び】ではない (cmd_1392 是正)★★
#   ★之が本牙の芯である★= 以前は `ps -o etimes=` の【秒】を受けており、
#   ★族の混線 (ps 一族 vs mtime 一族) の入口が此処であった★。
#   ⇒ ★秒として読む実装へ戻れば、pid の数がそのまま齢になる★ = 下の 2 本が捕える。
kid = subprocess.Popen(["sleep", "30"])
try:
    time.sleep(0.3)
    a = f(str(kid.pid), datetime.datetime.now().timestamp())
    assert a is not None, "生きた pid を渡して None は誤り"
    # 生まれたての子ゆえ齢は数秒。★pid を秒と読めば数万秒になる★。
    assert 0 <= a < 60, f"齢が生年から測られておらぬ (a={a}, pid={kid.pid})"
    assert abs(a - kid.pid) > 60, f"★pid の値が齢として返っておる★ (a={a}, pid={kid.pid})"

    # ★最も古い子を取る★= pid 1 (init) と生まれたての子を並べれば、init の齢が返る。
    #   ★若い方を取れば抑止が広がる = 真の固着を見逃す★ゆえ ★抑止は狭い側へ倒す★。
    now2 = datetime.datetime.now().timestamp()
    both = f(f"1 {kid.pid}", now2)
    want = now2 - os.stat("/proc/1").st_mtime
    assert abs(both - want) < 2.0, f"最も古い子 (init) の齢でない: {both} vs {want}"
    assert both > a, "init より生まれたての子が古いと判じておる (min/max が逆)"
finally:
    kid.kill(); kid.wait()

# ★子 0 件は None★ = 齢 0 に化ければ ★何もかもを抑止する門★ になる。
assert f("", now) is None, "子 0 件は None でなければならぬ (齢 0 は全面抑止を招く)"
assert f("\n  \n", now) is None
# ★死んだ pid / 雑音は捨てる★ (読めた物が 1 つも無ければ None)
assert f("not-a-number\n", now) is None
assert f("2147483646\n", now) is None, "在らぬ pid は読めた事にせぬ"
# ★負の齢は None★ = 生年が now より後 = 計器が壊れておる ⇒ 黙って 0 へ丸めぬ。
assert f("1", 0.0) is None, "負の齢は None へ倒さねばならぬ (0 に丸めるな)"
print("OK oldest-child + none-when-childless + pid-not-seconds")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK oldest-child"
}

# ---------------------------------------------------------------------------
# T-AGE-003 (MUT-1392-003 の的): 牙(2) crash-loop の罠。
# ★之が無ければ、絶えず落ちて生まれ直す agent が【永久に免除】される★ =
# 「撃たぬ側へ倒すだけ」の罠は此処に在る。
# 閾 3 の根拠 = cron 180秒 × 3 = 9分 < stall_min 15分 ⇒
#   ★正常な再起動 (1回きり) では絶対に鳴らぬ★・★loop なら stall_min 前に鳴る★。
# ---------------------------------------------------------------------------
@test "T-AGE-003: three consecutive impossible claims raise exactly one restart-loop alert (and never a /clear)" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle

    # 1回目・2回目 = 警報は鳴らぬ (正常な再起動 1 回きりで鳴らせぬため)
    FAKE_PROC_AGE=120 run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "ACTION=restart_loop_alert"
    FAKE_PROC_AGE=130 run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "ACTION=restart_loop_alert"
    [ "$(_count_record 'restart_loop\|起き直り')" -eq 0 ]

    # 3回目 = 鳴る (齢が育たぬまま抑止が続いておる)
    FAKE_PROC_AGE=140 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=restart_loop_alert AGENT=ashigaru91"
    echo "$output" | grep -q "AGES=120,130,140"
    echo "$output" | grep -q "OUTCOME=restart_loop_alert_fired AGENT=ashigaru91"
    [ "$(_count_record '^karo|warning|')" -eq 1 ]
    grep -q "起き直り続ける agent" "$INBOX_STUB_RECORD"

    # 4回目 = ★1 episode 1通★ (家老 inbox を毎3分 叩かぬ = cmd_1280 の轍を踏まぬ)
    FAKE_PROC_AGE=150 run _run_main_py
    [ "$status" -eq 0 ]
    [ "$(_count_record '^karo|warning|')" -eq 1 ]
    # ★終始 /clear は 1 本も撃っておらぬ★ (撃っても直らぬ族ゆえ)
    _refute_file "$INBOX_STUB_RECORD" "clear_command"
}

# ---------------------------------------------------------------------------
# T-AGE-004 (MUT-1392-004 の的): ★state 非消費★。
# 抑止が rate limit / consecutive を食えば、齢が育った其の scan で撃てなくなる =
# ★抑止が【遅延】でなく【免除】に化ける★。
# ---------------------------------------------------------------------------
@test "T-AGE-004: suppression does not consume revive state (no last_clear_ts, CONSECUTIVE stays 0)" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91 TASK_ID=subtask_age_ashigaru91 IDLE_MIN=[0-9.]* CONSECUTIVE=0 "
    # ★撃った証 (last_clear_ts) を焼いておらぬ★ = 停電型抑止と同じ作法
    _refute_file "$Q/state/clear_log.yaml" "last_clear_ts"
}

# ---------------------------------------------------------------------------
# T-AGE-005 (MUT-1392-005 の的): ★CLI 不在は【矛盾の証】ではない★。
# 齢を判じられぬ (子 0 件 / pane 解決不能) 時に抑止へ倒せば、
# ★番人を止めるのと同じ★になる。判じられぬ時は従来判定へ渡す。
# ---------------------------------------------------------------------------
@test "T-AGE-005: an unknowable age is NOT an impossible claim — the old judgement still runs" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=none run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "ACTION=impossible_claim_suppressed"
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru91"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-AGE-006 (MUT-1392-006 の的): ★数を黙って捨てぬ★。
# 抑止行は【元の主張】と【齢】と【比】を同じ行に載せる = 家老規律「前の数も残せ」。
# IDLE_MIN を齢で上書きする実装は、後から「何を名乗ろうとしたか」を永久に消す。
# ---------------------------------------------------------------------------
@test "T-AGE-006: the suppression line carries BOTH numbers plus the ratio and the gap flag" {
    _write_stuck_task ashigaru91 '120 minutes ago'
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    local line
    line="$(echo "$output" | grep '^ACTION=impossible_claim_suppressed AGENT=ashigaru91')"
    # 元の主張 (120分前後) が生きておる
    echo "$line" | grep -Eq 'IDLE_MIN=1[12][0-9]\.[0-9]'
    # 齢 6.5 分と、比 (≒18倍) が同じ行に在る
    echo "$line" | grep -q "PROC_AGE_MIN=6.5"
    echo "$line" | grep -Eq "CLAIM_RATIO=1[0-9]\.[0-9]"
    # 直前に欠測が在ったか否かも同じ行で判る (閾は動かさず【名乗り】だけ足す)
    echo "$line" | grep -q "SCAN_GAP_BEFORE="
}

# ---------------------------------------------------------------------------
# ★★T-AGE-007 = 負の対照 (設計 §6・最も重い1本)★★
# 何も壊さぬ盤面。齢 120 分 の process が 95 分 黙っておる = ★本物の固着★。
# ⇒ ★従来どおり /clear が撃たれる★。之が落ちる時 = 番人が死んだ時。
# ---------------------------------------------------------------------------
@test "T-AGE-007 (negative control): a REAL stall (age 120min > silence 95min) still fires the /clear" {
    _write_stuck_task ashigaru91 '95 minutes ago'
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=7200 run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "ACTION=impossible_claim_suppressed"
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru91"
    echo "$output" | grep -q "OUTCOME=revive_fired AGENT=ashigaru91"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-AGE-008: 牙(1) ★齢は必ず育つ = 抑止は【遅延】であって【免除】ではない★。
# 同じ agent・同じ盤面で、齢だけが主張を追い越した瞬間に従来判定へ★自動で★戻る。
# 併せて ★連続の数珠が切れる★ (切れねば一度 3 回続いた agent が永久に鳴り続ける)。
# ---------------------------------------------------------------------------
@test "T-AGE-008: suppression is a DELAY not an exemption — once the age outgrows the claim, the clear fires" {
    # ★沈黙 95 分★ — ★20 分では【本番の閾 45 分】に届かず slow-gen へ落ちる★ =
    # ★本牙が本番では一度も此の枝へ入らぬ盤面であった (2026-07-27 04:0x 実測)★。
    # ⇒ ★閾を実行時に読んで合わせるのではなく、両方の閾の上に在る値を焼き付ける★
    #   (15 でも 45 でも同じ枝を通る = ★試験が閾と一緒に動かぬ★)。
    _write_stuck_task ashigaru91 '95 minutes ago'
    _write_pane_states ashigaru91:idle

    # 齢 5 分 < 沈黙 95 分 → 抑止 (連続 1)
    FAKE_PROC_AGE=300 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    grep -q "impossible_consecutive: 1" "$Q/state/clear_log.yaml"

    # 齢 120 分 > 沈黙 95 分 → 従来判定へ戻り、現に撃つ
    FAKE_PROC_AGE=7200 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru91"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
    # ★連続の数珠は切れておる★
    _refute_file "$Q/state/clear_log.yaml" "impossible_consecutive"
}

# ---------------------------------------------------------------------------
# T-AGE-009: 牙(3) ★抑止の総量を毎 scan 名乗らせる★。
# ★常に鳴る門が外されるのと同じく、常に抑止する門も外されるべき★ =
# 人が数で見られねば、抑止の常態化に誰も気付けぬ。★0 の時も名乗る★。
# ---------------------------------------------------------------------------
@test "T-AGE-009: every scan declares how many claims it suppressed — including zero" {
    _write_stuck_task ashigaru91
    _write_stuck_task ashigaru92
    _write_pane_states ashigaru91:idle ashigaru92:idle

    # 抑止 0 体でも名乗る (沈黙を「起きなんだ」とも「見ておらぬ」とも読ませぬ)
    FAKE_PROC_AGE=none run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM 抑止 = 0 体"

    # 2 体を抑止すれば 2 と名乗る
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml"
    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM 抑止 = 2 体 (うち連続 3 回以上 = 0 体)"
}

# ---------------------------------------------------------------------------
# T-AGE-010 (設計に無い一点・実装者が足した): ★成り立たぬ主張を quorum の分子へ
# 混ぜぬ★。混ぜれば家老へ「4 体が同時に沈黙」と★偽の停電型★を上げ、上流障害台帳へ
# も其の 4 体を焼く = ★病の同じ顔が一段上で戻る★。
# ★分母 (eligible) には残す★ = 見ておらぬのではない、見た上で「言えぬ」と申しておる。
# ---------------------------------------------------------------------------
@test "T-AGE-010: impossible claims are kept OUT of the quorum numerator (no false blackout to karo)" {
    for a in ashigaru91 ashigaru92 ashigaru93 ashigaru94; do _write_stuck_task "$a"; done
    _write_pane_states ashigaru91:idle ashigaru92:idle ashigaru93:idle ashigaru94:idle

    # 4 体すべてが生まれたて = 従来なら 4/4 で停電型が成立してしまう盤面
    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    [ "$(_count_record '停電型')" -eq 0 ]
    _refute_output "ACTION=blackout_alert"
    [ "$(_count_record 'clear_command')" -eq 0 ]
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM 抑止 = 4 体"

    # ★対照★= 同じ 4 体が【本物に古い】なら停電型は従来どおり成立する
    # (= 分子から外す処置が停電型そのものを殺しておらぬ証明)
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml" "$Q/state/blackout_suppress"
    FAKE_PROC_AGE=99999 run _run_main_py
    [ "$status" -eq 0 ]
    [ "$(_count_record '停電型')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# ★★T-AGE-011 (軍師一号 差し戻し・帯の【内側】)★★
# 齢 94 分 の process が「沈黙 95 分」と名乗られる = ★比 0.99★。
# ★1 分でも足らねば其の主張は成り立たぬ★ = 抑止は此処でも効かねばならぬ。
# ⇒ 閾を `< claimed` から `<= claimed * 0.5` へ緩める変異は、★此の 1 本でのみ★赤くなる
#   (T-AGE-001〜010 の比 0.07/0.25 は緩めた閾でも尚 抑止側ゆえ緑のまま)。
# ★余裕★= 主張 95 分 と 齢 94 分 の差は 60 秒 = scan までの経過 (数秒) に対し十分。
# ---------------------------------------------------------------------------
@test "T-AGE-011: the band's inside — age 94min vs silence 95min (ratio 0.99) still suppresses" {
    _write_stuck_task ashigaru91 '95 minutes ago'
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=5640 run _run_main_py          # 94 分
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    echo "$output" | grep -q "PROC_AGE_MIN=94.0"
    # ★撃っておらぬ★ — 帯の内側でも実害 (/clear) は起きぬ
    _refute_file "$INBOX_STUB_RECORD" "clear_command"
    _refute_output "^ACTION=revive AGENT=ashigaru91"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-012 (帯の【上端の直上】= T-AGE-011 の対★)★★
# 齢 96 分 > 沈黙 95 分 = ★比 1.01★ ⇒ 主張は成り立つ ⇒ ★従来どおり撃つ★。
# T-AGE-007 は比 1.26 で同じ向きを縛るが、★境界から遠い点★である =
# 抑止を上へ僅かに広げる誤り (例 `< claimed * 1.05`) は ★1.26 では捕えられず 1.01 で捕える★
# (実測 = 其の変異で T-AGE-012 のみ赤・T-AGE-007 は緑)。
# ★T-AGE-011 と併せて、境界の帯を両側から挟む★。
# ★限界を先に名乗る★= 丁度の等号 (`<=` へ倒す誤り) は本 2 本では捕えられぬ =
#   claimed は task YAML の mtime から scan 時に測るゆえ、齢と丁度 等しい盤面は作れぬ。
# ---------------------------------------------------------------------------
@test "T-AGE-012: just above the band — age 96min vs silence 95min (ratio 1.01) fires as before" {
    _write_stuck_task ashigaru91 '95 minutes ago'
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=5760 run _run_main_py          # 96 分
    [ "$status" -eq 0 ]
    _refute_output "ACTION=impossible_claim_suppressed"
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru91"
    echo "$output" | grep -q "OUTCOME=revive_fired AGENT=ashigaru91"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-013 (家老 03:54 の規・第三の形)★★
#
# ★本 suite は契約の値を【引数で上書きして】撃っておる★ (_run_main_py の --stall-min 15) =
#   ★焼き付けても居らず、実行時に読んでも居らぬ = 契約の値が試験の目の外に在る★
#   = ★試験が production を一度も見ておらぬ★ (拙者が stall_watchdog で実測した第三の形)。
# ⇒ ★契約の値を此処に【宣言】し、production と突合する★。
#   ★意図して動かすなら下の DECLARED も直せ★= ★其の一行が【意図の記録】になる★。
# ★割れたら、どちらへも寄らず【割れを名乗る】★ (宣言と実装の両方を印字する)。
# ---------------------------------------------------------------------------
@test "T-AGE-013: idle_revive's contract values are declared here and must match production" {
    run "$VENV_PY" - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec); spec.loader.exec_module(irs)

# ★契約 (焼き付ける = 動けば赤くなるのが正しい)★
DECLARED = {
    # 「出力が N 分 動かねば固着とみなす」= 番人の最も重い約束。
    # ★但し cron は之を 45 で上書きしておる★ (T-AGE-014 が其の差を名乗る)。
    "DEFAULT_STALL_MIN": 15,
    # cmd_1392: 「不可能な主張が N 回 続いたら起き直り loop と見て警報」=
    # ★閾 3 の根拠 = cron 180秒 × 3 = 9分 < stall_min 15分★ ゆえ、
    # ★stall_min を動かす日は此の 3 も一緒に検め直さねばならぬ★ (根拠が崩れる)。
    "DEFAULT_IMPOSSIBLE_LOOP_THRESHOLD": 3,
}
bad = []
for name, want in DECLARED.items():
    got = getattr(irs, name, None)
    if got != want:
        bad.append(f"{name}: 宣言 {want} ≠ 実装 {got}")
if bad:
    raise SystemExit(
        "★契約と実装が割れておる★ (どちらへも寄らず、割れを名乗る):\n  "
        + "\n  ".join(bad)
        + "\n  ⇒ 意図して動かしたのなら、本試験の DECLARED も直せ"
          " (其の一行が【意図の記録】になる)"
        + "\n  ⇒ ★DEFAULT_STALL_MIN を動かすなら、閾 3 の根拠 (cron 180秒×3 < stall_min)"
          " も併せて検め直せ★")
print("OK contract values match:", DECLARED)
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK contract values match"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-014 (家老 03:54 の下命)★★
# ★★cron の上書き (45) と既定 (15) の差そのものを名乗らせる★★
#
# ★之が無ければ、次の者は「既定 15 が効いておる」と読む★ =
#   ★番人の本体が、己の契約の値を一度も検めておらぬことになる★。
# ★本試験は【差が在ること】を契約として持ち、【実物の cron】と突合する★。
# ★読めぬ時は緑にせぬ★ = 同 repo の先例 (T-WIR-003「crontab 自体が見えぬ時は
#   UNDETERMINED 側へ倒す」) と同じ流儀 = ★検められぬ物を「検めた」と読ませぬ★。
# ---------------------------------------------------------------------------
@test "T-AGE-014: the cron override (45) is declared, differs from the default (15), and matches the real crontab" {
    local declared_default=15 declared_cron=45
    # (1) ★上書きしておる、という事実そのものを契約にする★
    if [ "$declared_default" -eq "$declared_cron" ]; then
        echo "★宣言が上書きの事実を失うておる (既定と cron が同値になっておる)★" >&2
        return 1
    fi
    # (2) ★実物の cron と突合する★
    run crontab -l
    if [ "$status" -ne 0 ]; then
        echo "★crontab を読めなんだ = 上書きの事実を検められぬ★" >&2
        echo "★之を緑にすれば「既定が効いておる」と次の者が読む★ (先例 = T-WIR-003)" >&2
        return 1
    fi
    local line actual
    line="$(echo "$output" | grep 'idle_revive_scan' || true)"
    if [ -z "$line" ]; then
        echo "★cron に idle_revive_scan の行が無い = 番人が誰にも呼ばれておらぬ★" >&2
        echo "$output" >&2
        return 1
    fi
    actual="$(echo "$line" | grep -oE '\-\-stall-min[= ]+[0-9]+' | grep -oE '[0-9]+' | head -1)"
    if [ -z "$actual" ]; then
        echo "★cron の行に --stall-min が無い = 実際には【既定】で走っておる★" >&2
        echo "  cron 行: $line" >&2
        echo "  ⇒ 宣言 ($declared_cron) と実物が割れておる。どちらかを直せ" >&2
        return 1
    fi
    if [ "$actual" != "$declared_cron" ]; then
        echo "★宣言と実物が割れておる★: 宣言 $declared_cron ≠ 実物 $actual" >&2
        echo "  cron 行: $line" >&2
        echo "  ⇒ どちらへも寄らず割れを名乗る。意図して動かしたなら本試験の宣言も直せ" >&2
        return 1
    fi
    echo "OK cron override: 既定 $declared_default → cron $actual (現に上書きしておる)"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-015 (家老 04:01 の下命への直の答)★★
# ★★本番の閾 (45) と試験の既定 (15) では【入る枝そのものが違う】ことを固定する★★
#
# ★由来★= 04:0x の実測 = 本 suite を 45 で撃ち直したところ ★T-AGE-008 が赤★ になった =
#   ★沈黙 20 分の盤面は、本番では slow-gen として判定の手前で捨てられておった★ =
#   ★★牙は生きておるが、其の牙が守る盤面が本番には存在せなんだ★★。
#   (★守りが死んでおるのではない = 守りの【的】が本番の外に在った★ — 別の形の空虚である)
#
# ★本牙が縛るもの★= ★沈黙 30 分 (15 と 45 の間) の盤面★:
#   閾 15 → 判定へ入る (何らかの ACTION が出る)
#   閾 45 → ★判定の手前で捨てられる (ACTION は一つも出ぬ)★
# ⇒ ★之が壊れる時 = 誰かが既定か cron を動かした時★ (T-AGE-013/014 と対を成す)。
# ★併せて本牙は STALL_MIN_UNDER_TEST の口が現に効いておることの canary でもある★=
#   ★口が死んでおれば両者は同じ結果になり、本牙は落ちる★。
# ---------------------------------------------------------------------------
@test "T-AGE-015: the production threshold (45) and the suite default (15) enter DIFFERENT branches" {
    _write_stuck_task ashigaru91 '30 minutes ago'
    _write_pane_states ashigaru91:idle

    # (1) 試験の既定 15 → 沈黙 30 分は閾を越えており、判定へ入る
    FAKE_PROC_AGE=390 STALL_MIN_UNDER_TEST=15 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"

    # (2) ★本番の値 45★ → 同じ盤面が slow-gen として判定の手前で捨てられる
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml"
    FAKE_PROC_AGE=390 STALL_MIN_UNDER_TEST=45 run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    _refute_output "^ACTION=revive AGENT=ashigaru91"
    # ★判定へ入っておらぬのだから、抑止の総量も 0 と名乗る★ (0 を canary の後に読む)
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM 抑止 = 0 体"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-016 (cmd_1392 是正・2026-07-27 = 軍師二号が code の内側で見つけた汚れ)★★
# ★★齢は【mtime 一族】から採る = ps 一族を二度と混ぜぬ★★
#
# ★病★= `age_sec < claimed_silence_sec` は
#   ・齢   … `ps -o etimes=` = ★/proc/uptime 起点の単調時計★
#   ・沈黙 … file の st_mtime = ★CLOCK_REALTIME★
#   の ★別々の物差しを直に引き算しておった★。
# ★実測 (2026-07-27 10:2x・母数 10 agent / 齢を判じられたのは両者とも 9)★=
#   ★差 (mtime齢 − etimes齢) 中央 1,937.8 秒 = 32.3 分・★負は 0 本★★
#   ⇒ ★ps は齢を【必ず短く】申す★ ⇒ ★`age < claimed` が成立しやすい★ =
#     ★★抑止が過剰 = 真に固着した agent が revive を受けられぬ側★★。
#
# ★本牙は【源】を縛る (源が戻れば数も戻るゆえ)★:
#   ★限界を先に名乗る = 之は【source 面の門】であって挙動の門ではない★。
#   挙動の側は T-AGE-002 (pid を秒と読めば赤) と T-AGE-018 (実害の形) が持つ。
#   ★二つで挟んでおる★ = 源を直しても挙動が戻れば 002/018 が鳴る。
# ---------------------------------------------------------------------------
@test "T-AGE-016: the age is read from the mtime family — the ps clock must never come back" {
    run "$VENV_PY" - <<'PY'
import importlib.util, inspect, os
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec); spec.loader.exec_module(irs)

# (1) ★齢を採る bash から ps 一族が消えておる★
bash = irs._PANE_PROC_AGE_BASH
for needle in ("etimes", "etime", "lstart"):
    assert needle not in bash, (
        f"★齢の口へ ps 一族 ({needle}) が戻っておる★ — 沈黙は st_mtime ゆえ "
        "★族の違う時計を引き算する形★に戻る (中央 32.3 分・片側にずれる)")

# (2) ★生年は stat = 沈黙と同じ syscall★ であることを源で縛る
src = inspect.getsource(irs._proc_start_mtime)
assert "os.stat" in src and "st_mtime" in src, (
    "★生年が stat 由来でない★ = 沈黙 (newest_output_mtime) と同じ族でなくなる")

# (3) ★沈黙の側も同じ族のままか★ (片側だけ直しても混線は消えぬ)
src2 = inspect.getsource(irs.newest_output_mtime)
assert "st_mtime" in src2, "★沈黙の側が mtime 一族から外れた★ = 対の前提が崩れる"

# (4) ★補正値を焼いておらぬ★ (軍師一号 10:02 の枷 =
#     「ずれは一定でない = boot から離れるほど汚れる」ゆえ定数で引く道は必ず腐る)
age_src = inspect.getsource(irs._oldest_child_age_from_pids)
for bad in ("1937", "1938", "1900", "31 * 60", "1913"):
    assert bad not in age_src, f"★補正値 {bad} を焼いておる★ = ずれは一定でない"
print("OK age is mtime-family, no ps clock, no baked offset")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK age is mtime-family"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-017 (2026-07-27 10:09 の実害・拙者自身が埋めた地雷)★★
# ★齢の口は【引数なしでも】例外を投げてはならぬ★
#
# ★何が起きたか★= 拙者は是正の折 `now_ts is None` の既定に `time.time()` と書いた。
#   ★本 module は `time` を import しておらぬ★ ⇒ ★NameError★。
# ★而して cron は緑を返し続けておった★= 其の枝は
#   ★「stall_min を越えた agent が現れた時」にしか通らぬ★ゆえ =
#   ★★番人が真に働かねばならぬ其の一瞬にだけ落ちる地雷★★であった。
#   (log には 10:06 の scan まで一行の異常も無い = ★沈黙は健全の証にならぬ★)
# ⇒ ★本牙は既定の口を直に踏む★= 呼ばれぬ枝を呼ぶ者を、試験の側に置く。
# ---------------------------------------------------------------------------
@test "T-AGE-017: the age port must not explode when called without now_ts (the NameError landmine)" {
    run "$VENV_PY" - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec); spec.loader.exec_module(irs)
# ★在らぬ agent で良い★= now_ts の既定は subprocess より前に評価されるゆえ、
#   ★実 pane を持たずとも地雷は踏める★ (= 本牙は本番の盤面に依らぬ)。
v = irs.agent_proc_age_sec("no_such_agent_zzz")
assert v is None, f"在らぬ agent の齢が None でない: {v!r}"
# ★既定と明示で同じ道を通る★
import datetime
v2 = irs.agent_proc_age_sec("no_such_agent_zzz", now_ts=datetime.datetime.now().timestamp())
assert v2 is None
print("OK default now_ts does not raise")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK default now_ts does not raise"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-018 (軍師一号 10:02 が数で組んだ【実害の形】をそのまま盤面にする)★★
# ★沈黙 60 分・真の齢 85 分★ の pane:
#   ・★汚れた計器 (ps)★ は齢を 53.7 分 と申す ⇒ 53.7 < 60 ⇒ ★抑止★
#     = ★★齢は現に足りておるのに、真に固着した agent が revive を受けられぬ★★
#   ・★是正後 (mtime)★ は齢を 85 分 と申す ⇒ 85 > 60 ⇒ ★従前どおり撃つ★
# ★本番の閾 45 で撃つ★ (沈黙 60 > 45 ゆえ現に判定へ入る = 盤面が本番に在る)。
# ★両向きを 1 本に収めてある★= 是正が【守りを減らしておらぬ】側 (撃つ) と、
#   【過剰抑止を解いた】側 (撃たれる様になった) が同じ盤面で並ぶ。
# ---------------------------------------------------------------------------
@test "T-AGE-018: the harm shape — a real stall (silence 60min, true age 85min) must fire, though the ps clock would have suppressed it" {
    _write_stuck_task ashigaru91 '60 minutes ago'
    _write_pane_states ashigaru91:idle

    # (1) ★汚れた計器が申す齢 (53.7 分 = 3222 秒)★ → 抑止される = 実害の再現
    FAKE_PROC_AGE=3222 STALL_MIN_UNDER_TEST=45 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    _refute_file "$INBOX_STUB_RECORD" "clear_command"

    # (2) ★是正後の齢 (85 分 = 5100 秒)★ → 従前どおり撃つ
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml"
    FAKE_PROC_AGE=5100 STALL_MIN_UNDER_TEST=45 run _run_main_py
    [ "$status" -eq 0 ]
    _refute_output "ACTION=impossible_claim_suppressed"
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru91"
    echo "$output" | grep -q "OUTCOME=revive_fired AGENT=ashigaru91"
    grep -q "^ashigaru91|clear_command|" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# ★★T-AGE-019 (家老 09:58 の任(2) = 【0 の二義を割る】)★★
#
# ★軍師二号は log の ACTION 1,912 件から `impossible_claim_suppressed` = 0 を示し、
#   「(甲) 条件が成らなんだ / (乙) 成る盤面が来ておらぬ」は ★拙者には割れぬ★ と申した★。
# ★割れなんだ理由は【分母が一度も印字されておらなんだ】ゆえである★ =
#   ★0 だけを見せて母数を見せぬ数は、原理的に読めぬ★。
# ⇒ ★JUDGED / AGE_KNOWN / AGE_UNKNOWN を名乗らせ、0 の三通りを log 単独で割る★:
#     JUDGED=0            … 判定へ入った者が居らぬ            (= 乙)
#     JUDGED>0, KNOWN=0   … 齢を一度も判じられなんだ = 門が盲  (= 丙・軍師が挙げておらぬ third)
#     JUDGED>0, KNOWN>0   … 現に問うて、成らなんだ            (= 甲)
# ★丙を足したのは拙者である★= ★0/N の門は「成らなんだ」と同じ 0 を出す★ゆえ、
#   ★二義でなく【三義】であった★ (之が本牙の産物じゃ)。
# ---------------------------------------------------------------------------
@test "T-AGE-019: a zero suppression count declares its denominator — the three readings of 0 are separable" {
    # (乙) 誰も判定へ入らぬ盤面 = 出力が漸進しておる (沈黙 1 分 < 閾 15)
    _write_stuck_task ashigaru91 '1 minute ago'
    _write_pane_states ashigaru91:idle
    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM 抑止 = 0 体 .*JUDGED=0 AGE_KNOWN=0 AGE_UNKNOWN=0"
    echo "$output" | grep -q "★0 の意味 = 判定へ入った者が居らぬ"

    # (丙) 判定へは入るが齢を判じられぬ = ★門が盲★ (0 が「成らなんだ」と同じ顔で出る)
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml"
    _write_stuck_task ashigaru91 '95 minutes ago'
    FAKE_PROC_AGE=none run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "JUDGED=1 AGE_KNOWN=0 AGE_UNKNOWN=1"
    echo "$output" | grep -q "★0 の意味 = 齢を一度も判じられなんだ (門が盲である)★"

    # (甲) 現に問うて、成らなんだ = 齢が主張を上回る
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml"
    FAKE_PROC_AGE=7200 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "JUDGED=1 AGE_KNOWN=1 AGE_UNKNOWN=0"
    echo "$output" | grep -q "★0 の意味 = 現に問うて、成らなんだ★"

    # ★抑止が現に在る時は註を出さぬ★ (0 でない数に「0 の意味」を添えれば嘘になる)
    rm -f "$INBOX_STUB_RECORD" "$Q/state/clear_log.yaml"
    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "IMPOSSIBLE_CLAIM 抑止 = 1 体 .*JUDGED=1 AGE_KNOWN=1 AGE_UNKNOWN=0"
    _refute_output "★0 の意味"
}
