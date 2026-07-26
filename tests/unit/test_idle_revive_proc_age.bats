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

def fake_age(agent):
    v = os.environ.get("FAKE_PROC_AGE_" + agent, os.environ.get("FAKE_PROC_AGE", ""))
    v = v.strip()
    if v in ("", "none", "None"):
        return None
    return int(v)

irs.agent_proc_age_sec = fake_age
argv = ["--queue-root", os.environ["Q"],
        "--pane-state-file", os.environ["TEST_TMPDIR"] + "/pane_state.yaml",
        "--stall-min", "15", "--no-karo-check"] + sys.argv[1:]
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
import importlib.util, os
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec); spec.loader.exec_module(irs)
f = irs._oldest_child_age
assert f("100\n5000\n30\n") == 5000, f("100\n5000\n30\n")   # ★min ならば 30★
assert f("42\n") == 42
assert f("") is None, "子 0 件は None でなければならぬ (齢 0 は全面抑止を招く)"
assert f("\n  \n") is None
assert f("not-a-number\n77\n") == 77                        # ps の雑音は捨てる
print("OK oldest-child + none-when-childless")
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
    _write_stuck_task ashigaru91 '20 minutes ago'
    _write_pane_states ashigaru91:idle

    # 齢 5 分 < 沈黙 20 分 → 抑止 (連続 1)
    FAKE_PROC_AGE=300 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    grep -q "impossible_consecutive: 1" "$Q/state/clear_log.yaml"

    # 齢 40 分 > 沈黙 20 分 → 従来判定へ戻り、現に撃つ
    FAKE_PROC_AGE=2400 run _run_main_py
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
