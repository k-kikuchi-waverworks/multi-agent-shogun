#!/usr/bin/env bats
# test_stall_watchdog_ledger_miss.bats — cmd_1459:
# ★「着地した report が在るのに、軍師の帳面に其の cmd を指す任が無い」を捕える★契約。
#
# ■ 何ゆえ cmd_1454 の検めでは足りぬか (軍師一号の実測 2026-07-28 07:10:08)
#   cmd_1454 の検めは「軍師の inbox に未読のまま N 分」を見る。作法は「読んだら即
#   read: true」を命じておる ⇒ ★作法どおりに振る舞う軍師は、其の手で検めの目を閉じる★。
#   ⇒ 残る窓は「軍師が便を読むまで」であって「家老が任を起こすまで」ではない。
#   ⇒ ★今 在る検めが捕えるのは【軍師の停止】であり【家老の起票漏れ】ではない★。
#   現に其の刻、三便が検分を乞うており、軍師の帳面は done のまま、機械は「hit なし」と答えた。
#
# ■ 本 suite が守る物 (条4 = 陽性と陰性の二つを撃つ)
#   (あ) 鳴るべき時に鳴る (T-LM-001) / 鳴らぬべき時に黙る (T-LM-002〜006)
#   (い) ★黙る時も必ず名乗る★ — 承知で退けた物 (T-LM-007/008)・刻が未来の物
#        (T-LM-009)・cmd を拾えなんだ物 (T-LM-013)。★黙って落とす道を作らぬ★
#   (う) ★canary★ (T-LM-011/017) = 「見た上での 0」と「探せておらぬ 0」を分ける
#   (え) ★母数は hit が在っても刷る★ (T-LM-010) = 「1 件 鳴った」と
#        「6 件 中 1 件 鳴った」を log 上で見分けられるようにする (条1)

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # 複写へ当てる口 (変異試験は STALL_SCAN_ROOT に写しを渡して撃つ)。
    STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$REPO}"
    SCAN="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
    Q="$(mktemp -d)"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/inbox"
    # ★己を母数から外す (条C)★ = 試験は必ず mktemp の queue-root を渡す。
    # ★本番の queue/ を一度も読まぬ★ ゆえ、拙者の作り物が番人の数を動かさぬ。
    OLD="2026-07-28T00:00:00"    # 十分に古い刻 (必ず閾値を超える)
    echo "commands: []" > "$Q/shogun_to_karo.yaml"
}

teardown() {
    [ -n "${Q:-}" ] && rm -rf "$Q"
}

# $1=agent $2=task_id $3=parent_cmd(空可) $4=status $5=timestamp
_report() {
    {
        echo "report:"
        echo "  task_id: $2"
        [ -n "$3" ] && echo "  parent_cmd: $3"
        echo "  status: $4"
        echo "  timestamp: '$5'"
    } > "$Q/reports/$1_report.yaml"
}

# $1=帳面の file 名 (gunshi1 等) $2=欄の名 $3=値
_gunshi() {
    cat > "$Q/tasks/$1.yaml" <<EOF
task:
  task_id: subtask_qc_fixture
  $2: $3
  status: assigned
EOF
}

_gunshi_empty() {
    cat > "$Q/tasks/$1.yaml" <<EOF
task:
  task_id: subtask_qc_fixture
  status: assigned
EOF
}

# $1=cmd $2=status
_ledger() {
    cat > "$Q/shogun_to_karo.yaml" <<EOF
commands:
- id: $1
  status: $2
EOF
}

_run() { run python3 "$SCAN" --queue-root "$Q" --no-qc-scan "$@"; }

# ── (あ) 陽性 ────────────────────────────────────────────────────────────
@test "T-LM-001: ★着地した report を帳面が指しておらねば鳴る (陽性)★" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi_empty gunshi1
    _ledger cmd_1457 pending
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"LM_ASHI=ashigaru6"* ]]
    [[ "$output" == *"LM_CMD=cmd_1457"* ]]
    [[ "$output" == *"LM_LEDGER_STATUS=pending"* ]]
}

@test "T-LM-012: parent_cmd 欄が無くとも task_id から cmd を拾うて鳴る" {
    _report ashigaru3 subtask_1414_guard_scope "" done "$OLD"
    _gunshi_empty gunshi1
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"LM_CMD=cmd_1414"* ]]
    [[ "$output" == *"LM_CMD_SOURCE=task_id"* ]]
}

# ── (い) 陰性 = 負の対照 (鳴らぬべき時に黙る) ────────────────────────────
@test "T-LM-002: ★帳面が parent_cmd で指しておれば黙る (負の対照)★" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi gunshi1 parent_cmd cmd_1457
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"起票漏れ hit なし"* ]]
}

@test "T-LM-003: 帳面の prev_parent_cmd_* (履歴の欄) で指しておっても黙る" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi gunshi1 prev_parent_cmd_c00 cmd_1457
    _run
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
}

@test "T-LM-004: 帳面の covers_cmds (束ねの欄) で指しておっても黙る" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi gunshi1 covers_cmds "[cmd_1457, cmd_1400]"
    _run
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
}

@test "T-LM-005: ★註の散文に cmd が在るだけでは【指した】と数えぬ (鳴る)★" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    cat > "$Q/tasks/gunshi1.yaml" <<'EOF'
# cmd_1457 は本任の外である (註の散文ゆえ指しておらぬ)
task:
  task_id: subtask_qc_fixture
  note: 'cmd_1457 の話も出たが、任は起こしておらぬ'
  status: assigned
EOF
    _run
    [[ "$output" == *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"LM_CMD=cmd_1457"* ]]
}

@test "T-LM-006: 閾値の内なら鳴らぬ (家老に配る間が在る)" {
    NOW_ISO="$(date '+%Y-%m-%dT%H:%M:%S')"
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$NOW_ISO"
    _gunshi_empty gunshi1
    _run --qc-ledger-threshold-min 10
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
}

@test "T-LM-015: 着地しておらぬ report (status=in_progress) は鳴らぬ" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 in_progress "$OLD"
    _gunshi_empty gunshi1
    _run
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"着地=0"* ]]
}

# ── (い-2) 黙る時も名乗る ───────────────────────────────────────────────
@test "T-LM-007: ★台帳が deferred なら鳴らさぬが必ず名乗る (承知の遅れ)★" {
    _report ashigaru5 subtask_1446_gc subtask_none done "$OLD"
    _report ashigaru5 subtask_1446_gc cmd_1446 done "$OLD"
    _gunshi_empty gunshi1
    _ledger cmd_1446 deferred
    _run
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"QC_LEDGER_MISS_QUIET"* ]]
    [[ "$output" == *"LM_LEDGER_STATUS=deferred"* ]]
    [[ "$output" == *"鳴らさず名乗った分=1"* ]]
}

@test "T-LM-008: ★台帳が done でも【黙って消さぬ】= 名乗る★ (畳めば無かった事にはせぬ)" {
    _report ashigaru1 subtask_1452_check cmd_1452 done "$OLD"
    _gunshi_empty gunshi1
    _ledger cmd_1452 done
    _run
    [[ "$output" != *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"QC_LEDGER_MISS_QUIET"* ]]
    [[ "$output" == *"LM_CMD=cmd_1452"* ]]
}

@test "T-LM-009: ★刻が未来の report を名乗る★ (経過が負ゆえ永久に閾値を超えぬ)" {
    FUT="$(date -d '+45 minutes' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '2099-01-01T00:00:00')"
    _report ashigaru1 subtask_1455_census cmd_1455 done "$FUT"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"ACTION=report_future_dated"* ]]
    [[ "$output" == *"LM_ASHI=ashigaru1"* ]]
    [[ "$output" == *"刻が未来=1"* ]]
}

@test "T-LM-013: cmd を拾えなんだ時は黙って落とさず名乗る" {
    _report ashigaru2 no_digits_here "" done "$OLD"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"ACTION=ledger_miss_cmd_undetermined"* ]]
    [[ "$output" == *"cmd不明除外=1"* ]]
}

# ── (う) canary ─────────────────────────────────────────────────────────
@test "T-LM-011: ★canary 赤★ = 帳面が 1 件も指さぬ時は『漏れ無し』と読ませぬ" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi gunshi1 parent_cmd cmd_1457
    # 帳面は指しておるゆえ hit は 0。而して pointer が 0 件になる形を作って canary を撃つ:
    _gunshi_empty gunshi1
    _report ashigaru6 subtask_1457_head_check cmd_1457 in_progress "$OLD"
    _run
    [[ "$output" == *"canary 赤"* ]]
}

@test "T-LM-017: 台帳が読めぬ時は canary が名乗る (承知の遅れを分けられぬ)" {
    # ★初版はここを status=in_progress で組み、着地 0 件の canary が先に鳴って落ちた★
    # = ★赤の理由が「働きが壊れた」でなく「己の撃ち方」であった (条5)★。
    # 台帳の canary を撃つには ★着地も帳面も健全で、台帳だけが壊れておる★ 盤面が要る。
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi gunshi1 parent_cmd cmd_1457
    printf 'commands: [\n' > "$Q/shogun_to_karo.yaml"   # 壊れた YAML
    _run
    [[ "$output" == *"台帳が読めなんだ"* ]]
}

# ── (え) 母数と口 ───────────────────────────────────────────────────────
@test "T-LM-010: ★母数は hit が在っても刷る★ (条1)" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"QC_LEDGER_MISS "* ]]
    [[ "$output" == *"起票漏れ hit=1 件"* ]]
    [[ "$output" == *"report file=1"* ]]
    [[ "$output" == *"着地=1"* ]]
}

@test "T-LM-014: --no-qc-ledger-scan で外せる (外した時は一行も出ぬ)" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi_empty gunshi1
    run python3 "$SCAN" --queue-root "$Q" --no-qc-scan --no-qc-ledger-scan
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_LEDGER_MISS"* ]]
    [[ "$output" != *"起票漏れ"* ]]
}

@test "T-LM-016: ★json の口でも起票漏れを落とさぬ★ (同じ穴が口を変えて戻らぬ)" {
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi_empty gunshi1
    _run --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"qc_ledger_miss"* ]]
    [[ "$output" == *"cmd_1457"* ]]
    [[ "$output" == *"qc_ledger_miss_stats"* ]]
}

@test "T-LM-018: ★本検めの出力は既存の検めの【否定の主張】と衝突せぬ★ (構造の側の守り)" {
    # ★何ゆえ此の試験が要るか — 拙者が現に踏んだゆえである (2026-07-28 07:3x)。★
    # 既存 4 suite の否定の主張 22 件のうち 5 件は
    #   [[ "$output" != *"AGENT="* ]] / [[ "$output" != *"ELAPSED_MIN="* ]]
    # の形で「此の走行に hit 行が一つも無い」を主張しておる。
    # ★本検めが素の AGENT= を刷ると、其の 5 本が赤くなる。★
    # 初版は LM_ を冠して避けたつもりであったが ★LM_AGENT= は AGENT= を含む★ ゆえ
    # 直っておらなんだ (部分一致である)。★「避けたつもり」を機械で留める。★
    _report ashigaru6 subtask_1457_head_check cmd_1457 done "$OLD"
    _gunshi_empty gunshi1
    _ledger cmd_1457 pending
    _run
    [[ "$output" == *"QC_LEDGER_MISS "* ]]        # 現に鳴っておる上で、
    [[ "$output" != *"AGENT="* ]]                 # ★此の二つを含まぬ★
    [[ "$output" != *"ELAPSED_MIN="* ]]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
}
