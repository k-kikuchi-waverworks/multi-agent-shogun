#!/usr/bin/env bats
# test_idle_revive_switch_note.bats — cmd_1387: ★我らが撃った切替が crash-loop の顔で映る★
#
# ★何が起きたか (2026-07-27 14:12〜14:21・家老が三例を並べて名指した)★:
#   13:59:53 家老が一斉切替 / 14:12:25 将軍が切替
#   14:12 ashigaru1 = 齢 361→540→721 で restart_loop_alert
#   14:18 ashigaru2 = 齢 715→★164★→344 で restart_loop_alert
#   14:21 ashigaru6 = 齢 875→1055→1235 で restart_loop_alert
#   ⇒ ★三体とも pane は生きて働いておった (家老が実査済)★ = crash-loop ではない。
#
# ★★番人の【判定】は誤っておらぬ★★ = 齢は現に若く、名乗る沈黙は現に長い。
#   誤っておったのは ★読む者へ真因を渡さなんだ事★ = 家老は三通を受けて
#   ★己で pane を実査するまで crash-loop か切替かを割れなんだ★。
# ⇒ ★★ゆえに本層が触れるのは【文字列】だけである★★ (家老 14:21 の裁):
#   ・母数から外さぬ = ★外せば「切替を装えば抑止を逃れる」口が開く★
#   ・抑止・警報・/clear の可否は 1bit も動かさぬ
#
# 契約:
#   T-SW-001 切替が process の誕生と重なる ⇒ ACTION 行と家老の便へ真因が載る
#   T-SW-002 ★★負の対照 = 記録が在ろうと無かろうと【判定】は一字も変わらぬ★★ ← 最も重い1本
#   T-SW-003 記録の源が不在 ⇒ ★沈黙にせず「源が不在」と名乗る★ (「切替は無かった」と読ませぬ)
#   T-SW-004 切替は在るが process は其れより古い ⇒ ★切替のせいにせぬ★ (OLDER)
#   T-SW-005 毎 scan 源を名乗る (抑止 0 の scan でも) = 添え札が出ぬ理由が log 単独で割れる
#   T-SW-006 壊れた行は捨てるが★黙って捨てぬ★ (SWITCH_BAD_LINES)
#   T-SW-007 ★★本物の固着は今も撃たれる★★ = 切替の記録が直前に在っても revive は鳴る
#   T-SW-008 ★書き手の側★ = lib/switch_record.sh の record_switch_ts が現に 1 行 落とす
#   T-SW-009 ★出陣で生まれた体を【切替】と名乗らぬ★ (旧い 4 欄の行は切替のまま)
#   T-SW-010 ★出陣 script が現に呼んでおる★ = 起動点 5 つ すべてに呼び口が在る
#
# ★T-SW-002 / T-SW-007 が要である理由★= 本層の最大の危険は ★添えるつもりで
#   判定を緩めること★ である。他の 6 本は「札が出るか」しか見ておらぬ ⇒
#   ★全部緑でも番人が鈍っておる形が作れる★。
#
# 本番 agent には触れぬ: fixture roster (ashigaru91-94 = 実在せぬ agent 名) +
# pane-state-file 注入 + IDLE_REVIVE_INBOX_WRITE stub + 齢の monkeypatch。
# ★番人は cron で毎3分 走っておるゆえ、変異は SCAN_PY_OVERRIDE の複写へ当てる★。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCAN_PY="${SCAN_PY_OVERRIDE:-$PROJECT_ROOT/scripts/idle_revive_scan.py}"
    export SWITCH_SH="${SWITCH_SH_OVERRIDE:-$PROJECT_ROOT/lib/switch_record.sh}"
    export SHUTSUJIN_SH="${SHUTSUJIN_SH_OVERRIDE:-$PROJECT_ROOT/shutsujin_departure.sh}"
    # ★.venv が無い盤面でも走れる形にする (cmd_1408 の族への手当)★:
    #   変異 runner は ★paths に挙げた file だけ★ を scratch へ写して走らす =
    #   ★.venv は付いて来ぬ★ ⇒ .venv 決め打ちでは ★変異の有無に依らず常に赤★ =
    #   ★牙が「常に赤」なら其の牙は何も証しておらぬ (runner は UNDETERMINED と名乗る)★。
    if [ -x "$PROJECT_ROOT/.venv/bin/python3" ]; then
        export VENV_PY="$PROJECT_ROOT/.venv/bin/python3"
    else
        export VENV_PY="python3"
    fi
    [ -f "$SCAN_PY" ] || return 1
    "$VENV_PY" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/idle_revive_switch.XXXXXX")"
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

_write_stuck_task() {
    local agent="$1" age="${2:-2 hours ago}"
    cat > "$Q/tasks/${agent}.yaml" <<EOF
task:
  task_id: subtask_switch_${agent}
  parent_cmd: cmd_1387
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

# $1=agent $2=何秒前に生まれたか $3=事由 (既定 switch・省けば【欄そのものを書かぬ】= 旧い行の形)
_write_switch_record() {
    local agent="$1" ago="$2" event="${3:-}" epoch line
    epoch=$(( $(date '+%s') - ago ))
    line="$(printf '%s\t%s\t%s\t%s' "$epoch" "$(date -d "@${epoch}" '+%Y-%m-%dT%H:%M:%S')" \
        "$agent" "claude/claude-opus-5")"
    [ -n "$event" ] && line="$(printf '%s\t%s' "$line" "$event")"
    printf '%s\n' "$line" >> "$Q/state/switch_history.tsv"
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

# ★判定だけを抜き出す★ (T-SW-002 の物差し): ACTION= と OUTCOME= の行から
# ★添え札 (SWITCH=...) を除いた決定の骨★ を取り出す。
_decision_skeleton() {
    echo "$output" \
        | grep -E '^(ACTION=|\[idle_revive\] OUTCOME=)' \
        | sed -E 's/ SWITCH=[^ ]*//; s/ — .*$//'
}

_run_main_py() {
    "$VENV_PY" - "$@" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("irs", os.environ["SCAN_PY"])
irs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(irs)
irs.probe_agent_state = lambda agent: os.environ.get("FAKE_PROBE_STATE", "idle")
irs.pane_upstream_text = lambda agent: os.environ.get("FAKE_PANE_TEXT", "")

def fake_age(agent, now_ts=None):
    v = os.environ.get("FAKE_PROC_AGE_" + agent, os.environ.get("FAKE_PROC_AGE", ""))
    v = v.strip()
    if v in ("", "none", "None"):
        return None
    return int(v)

irs.agent_proc_age_sec = fake_age
argv = ["--queue-root", os.environ["Q"],
        "--pane-state-file", os.environ["TEST_TMPDIR"] + "/pane_state.yaml",
        "--stall-min", os.environ.get("STALL_MIN_UNDER_TEST", "15"),
        "--no-karo-check"] + sys.argv[1:]
rc = irs.main(argv)
print(f"MAIN_RC={rc}")
PY
}

# ---------------------------------------------------------------------------
# T-SW-001: ★14:21 の盤面そのもの★ — 齢 6.5 分の process・5 分前に切替。
# ⇒ 抑止行と家老への便の【両方】に真因が載る。
#   ★便へ載せる事が芯である★= 家老が読むのは log でなく inbox ゆえ、
#   log にだけ載せれば ★三通を受けた家老は今日と同じく己で pane を実査する★。
# ---------------------------------------------------------------------------
@test "T-SW-001: a switch that overlaps the process birth is named in BOTH the log line and the karo message" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle
    # ★実測の形へ寄せた (2026-07-27 17:0x・現に走る 8 体)★= ★誕生 − launch = +0.4〜1.3 秒★
    #   ⇒ 見本も「切替の直後に生まれた process」= 齢 390 秒・切替 395 秒前 とする。
    #   ★初版は切替 300 秒前 = 誕生の 90 秒 前であった★= ★猶予 120 秒に寄り掛かった見本★ =
    #   ★実測に照らせば起こらぬ形を見本にしておった★ (家老 17:00 の第七条で撃ち直した)。
    _write_switch_record ashigaru91 395

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=impossible_claim_suppressed AGENT=ashigaru91"
    echo "$output" | grep -qE "SWITCH=[0-9.]+m_ago_EXPLAINS"

    # 連続 3 回で警報 ⇒ 家老の便に真因が同梱される
    FAKE_PROC_AGE=400 run _run_main_py
    FAKE_PROC_AGE=410 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=restart_loop_alert AGENT=ashigaru91"
    echo "$output" | grep -qE "^ACTION=restart_loop_alert .*SWITCH=[0-9.]+m_ago_EXPLAINS"
    [ "$(_count_record '^karo|warning|')" -eq 1 ]
    grep -q "直前に切替が在った" "$INBOX_STUB_RECORD"
    grep -q "crash-loop ではない" "$INBOX_STUB_RECORD"
    # ★門は己の射程も名乗る★ = 「真因の申し送りであって判定ではない」
    grep -q "判定" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-SW-002 ★★負の対照 = 判定は 1bit も動かぬ★★
# 同じ盤面を「記録あり」「記録なし」で二度 撃ち、★決定の骨が完全に一致する★事を
# 見る。★之が破れる形 = 添えるつもりで母数から外す★ =
#   「切替を装えば抑止を逃れる」口が開く (家老が明示に退けた道)。
# ---------------------------------------------------------------------------
@test "T-SW-002: the annotation changes the WORDS only — the decisions are identical with and without the record" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    local without
    without="$(_decision_skeleton)"

    # state を捨て、同じ盤面を【記録あり】で撃ち直す
    rm -f "$Q/state/clear_log.yaml"
    _write_switch_record ashigaru91 395
    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    local with
    with="$(_decision_skeleton)"

    [ -n "$without" ]
    if [ "$without" != "$with" ]; then
        echo "★判定が動いた★" >&2
        echo "--- 記録なし ---" >&2; echo "$without" >&2
        echo "--- 記録あり ---" >&2; echo "$with" >&2
        return 1
    fi
    # ★而して文字列は現に変わっておる★ (試験が「何も起きておらぬ」を緑にせぬ)
    echo "$output" | grep -q "SWITCH="
}

# ---------------------------------------------------------------------------
# T-SW-003: 記録の源が不在 ⇒ ★沈黙にせぬ★。
# ★沈黙にすれば読む者は「切替は無かった」と読む★ = 我らが証しておらぬ事を
# 読ませる形 = 本日ずっと狩ってきた病 (0 の三義) の本層における顔。
# ---------------------------------------------------------------------------
@test "T-SW-003: with no history file the line says 'no source' — never silence (which reads as 'no switch')" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle
    [ ! -f "$Q/state/switch_history.tsv" ]

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SWITCH=no_source"
    _refute_output "SWITCH=[0-9]"
}

# ---------------------------------------------------------------------------
# T-SW-004: 切替は在るが ★process は其れより古い★ ⇒ 切替のせいにせぬ。
# ★之が無ければ札は「近頃 切替が在ったか」しか見ておらぬ★ =
#   一斉切替の日は ★全ての警報に真因の札が付く★ = 札が意味を失う。
# ---------------------------------------------------------------------------
@test "T-SW-004: a switch AFTER the process was born does not get blamed (OLDER, not EXPLAINS)" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle
    _write_switch_record ashigaru91 60

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "SWITCH=[0-9.]+m_ago_OLDER"
    _refute_output "EXPLAINS"
}

# ---------------------------------------------------------------------------
# T-SW-005: ★毎 scan 源を名乗る (抑止 0 の scan でも)★。
# 之が無ければ ★札が一つも出ぬ日★ に「切替が無かった」と「源が死んでおる」を
# 割れぬ = 母数を印字せよ (五号 09:54) の本層における顔。
# ---------------------------------------------------------------------------
@test "T-SW-005: every scan declares the source of the annotation, even when nothing was suppressed" {
    _write_pane_states ashigaru91:busy

    run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SWITCH_SRC="
    echo "$output" | grep -q "SWITCH_RECORDS="
}

# ---------------------------------------------------------------------------
# T-SW-006: 壊れた行は捨てるが ★黙って捨てぬ★。
# ★黙って捨てれば「記録が無い」と「記録を捨てた」が同じ顔になる★。
# ---------------------------------------------------------------------------
@test "T-SW-006: malformed history lines are dropped but COUNTED (never silently)" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle
    printf 'これは壊れた行\n' >> "$Q/state/switch_history.tsv"
    printf 'not_a_number\tiso\tashigaru91\tx\n' >> "$Q/state/switch_history.tsv"
    _write_switch_record ashigaru91 395

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SWITCH_BAD_LINES=2"
    echo "$output" | grep -q "SWITCH_RECORDS=1"
    # ★壊れた行が在っても生きた記録は現に効く★
    echo "$output" | grep -qE "SWITCH=[0-9.]+m_ago_EXPLAINS"
}

# ---------------------------------------------------------------------------
# T-SW-007 ★★本物の固着は今も撃たれる★★
# 直前に切替が在り、且つ ★process は沈黙より古い★ (= 真の固着) 盤面。
# ★添え札の実装が判定へ漏れておれば此処が黙る★ = 番人が死ぬ向き。
# ---------------------------------------------------------------------------
@test "T-SW-007: a REAL stall still fires the revive even though a switch was recorded moments ago" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle
    _write_switch_record ashigaru91 30

    # 齢 85 分 > 沈黙 (task mtime 2 時間だが stall_min 15 分で判ずる) ⇒ 矛盾せぬ
    FAKE_PROC_AGE=99999 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "^ACTION=revive AGENT=ashigaru91"
    _refute_output "ACTION=impossible_claim_suppressed"
    grep -q "clear_command" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-SW-008 ★書き手の側★ = lib/switch_record.sh の record_switch_ts が現に 1 行 落とす。
# ★読み手だけを試験すれば「誰も書かぬ file を読む番人」が全部緑になる★ =
#   本日 狩ってきた「登録した ≠ 壊せば落ちる」の、二層に跨る顔。
# ★production の本文を其のまま source して走らせる★ (複写を試験せぬ)。
# ---------------------------------------------------------------------------
@test "T-SW-008: the shared recorder actually appends one machine-readable line" {
    run bash -c "
        set -euo pipefail
        SWITCH_HISTORY_FILE='$Q/state/switch_history.tsv'
        source '$SWITCH_SH'
        record_switch_ts ashigaru91 claude claude-opus-5
    "
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$Q/state/switch_history.tsv")" -eq 1 ]
    # ★epoch(数) TAB iso TAB agent TAB cli/model TAB 事由★ = 番人が読む形
    run awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/ && $3 == "ashigaru91" && $5 == "switch" {print "SHAPE_OK"}' \
        "$Q/state/switch_history.tsv"
    echo "$output" | grep -q "SHAPE_OK"
}

# ---------------------------------------------------------------------------
# T-SW-009 ★出陣で生まれた体を【切替】と名乗らぬ★ (家老 17:31 の裁(甲))
#   ★出陣の朝に「直前に切替が在った」と書けば、読む者は★在りもせぬ切替を探す★。
#   ★事由の欄が無い旧い行は【切替】と読む★= 本欄が生まれる前の行は悉く切替であったゆえ。
# ---------------------------------------------------------------------------
@test "T-SW-009: a boot record is named 出陣, not 切替 (and legacy 4-column rows stay 切替)" {
    _write_stuck_task ashigaru91
    _write_pane_states ashigaru91:idle
    _write_switch_record ashigaru91 395 boot

    FAKE_PROC_AGE=390 run _run_main_py
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "SWITCH=[0-9.]+m_ago_EXPLAINS"
    FAKE_PROC_AGE=400 run _run_main_py
    FAKE_PROC_AGE=410 run _run_main_py
    grep -q "直前に出陣 (初回起動)が在った" "$INBOX_STUB_RECORD"
    _refute_file "$INBOX_STUB_RECORD" "直前に切替が在った"

    # ★事由の欄を持たぬ旧い行は【切替】のまま★
    rm -f "$Q/state/switch_history.tsv" "$Q/state/clear_log.yaml" "$INBOX_STUB_RECORD"
    _write_switch_record ashigaru91 395
    FAKE_PROC_AGE=390 run _run_main_py
    FAKE_PROC_AGE=400 run _run_main_py
    FAKE_PROC_AGE=410 run _run_main_py
    grep -q "直前に切替が在った" "$INBOX_STUB_RECORD"
}

# ---------------------------------------------------------------------------
# T-SW-010 ★出陣 script が【現に呼んでおる】★ (紙 → 契約 → 現物 の現物側)
#   ★lib に函数が在っても、出陣が呼ばねば出陣で生まれた体は永久に漏れる★ =
#   ★之が cmd_1387 で埋めた当の漏れ口である★。
#   ★数で縛る★= 起動点は 5 つ (将軍 / 家老 / 足軽 決戦 / 足軽 平時 / 軍師) ⇒
#   ★呼び口が減れば赤★ (どれか一族が黙って漏れ戻るのを捕える)。
# ---------------------------------------------------------------------------
@test "T-SW-010: the departure script sources the recorder AND calls it at every launch site" {
    grep -q 'source "$SCRIPT_DIR/lib/switch_record.sh"' "$SHUTSUJIN_SH"
    # ★fail-open の代物が在る★= 源が無くとも出陣を止めぬ (家老 17:31 の枷②)
    grep -qE 'record_switch_ts\(\) \{ return 0; \}' "$SHUTSUJIN_SH"
    # ★起動点ごとの呼び口★= boot と名乗って呼ぶ行が 5 本
    local n
    n="$(grep -c 'record_switch_ts .* "boot"' "$SHUTSUJIN_SH")"
    [ "$n" -eq 5 ]
    # ★呼び口は必ず Enter (起動) の後に在る★= 生年より前に刻を落とさぬ
    run bash -c "grep -n 'send-keys.*Enter\|record_switch_ts .* \"boot\"' '$SHUTSUJIN_SH' | grep -A1 'Enter' | grep -c 'record_switch_ts'"
    [ "$output" -ge 5 ]
}
