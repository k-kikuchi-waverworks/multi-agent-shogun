#!/usr/bin/env bats
# test_stall_watchdog_inbox_response.bats — cmd_1459 の後段 (足軽五号・2026-07-28 夕)
#
# ■ 何を守る試験か
#   「軍師の inbox に報告の便が着いてから N 分、その cmd に応答が無い」を捕える契約。
#   芯は一つ = ★read の値を一度も見ない★。
#
# ■ なぜ要るか (実測 2026-07-28 18:0x)
#   cmd_1454 の検め (scan_qc_dispatch) は「未読のまま N 分」を見る。ところが作法は
#   「読んだら即 read: true」を命じている。つまり作法どおりに振る舞う軍師は、
#   その手で検めの目を閉じる。実測 = 軍師の inbox の報告族 5 通は全部 既読、
#   未読の報告族は 0 通で、あの検めは構造として 0 件しか返せない状態だった。
#
#   cmd_1459 前段の突合 (scan_qc_ledger_miss) は read を見ないので上の穴は無い。
#   ただし入口が足軽の report YAML で、この file は上書きされる (追記ではない)。
#   実測 = 三号が 13:14 に軍師へ出した cmd_1349 の報告は、14:36 の cmd_1467 の報告に
#   上書きされ、report YAML 側からは既に消えていた。inbox 側には残っていた。
#   ⇒ 上書きが閾値の内に起きれば、その報告は前段の目に一度も入らない。
#   本検めの入口 (軍師の inbox) は、便ごとに積むので上書きでは消えない。ここが前段との違いである。
#   ★ただし「消えない」わけではない★ = inbox_write.sh は 50 通を超えると既読を
#   末尾 15 通まで切り詰め、残りを queue/archive/ へ移す (2026-07-28 に 30→15 へ下がった)。
#   実測 = gunshi1 は今日 12:56 と 14:15 の二度 切り詰められていた。
#   ゆえに本検めは上限の窓の内にある archive も読む (IR-024)。窓の外は読まない (IR-025)。
#
# ■ 撃つ向きは二つ (条4)
#   陽性 = 応答が無ければ現に鳴る。★read: true でも鳴る (IR-001) = 本任の芯★
#   陰性 = 指していれば黙る / 閾値の内なら黙る / 報告族でない便は数えない
#   黙る時も必ず名乗る = 上限より古い便・台帳が承知の物・二重の物・刻が読めぬ物
#   canary = 「見た上での 0」と「探せていない 0」を分ける
#
# ■ この suite が見ていない範囲 (条G)
#   1. ashigaru4 と ashigaru6 は report_to: karo で軍師の inbox に居ない。
#      この 2 体を覆うのは前段の突合 (report YAML 入口) であり、本検めではない。
#   2. 応答の判定は「軍師の帳面が指すか」だけを見る。検分が済んだかは見ない。
#   3. cron から現に呼ばれているかは本 suite では見ない
#      (配線は test_stall_watchdog_redispatch.bats の T-WIR-002 が見ている)。

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # 複写へ当てる口 (変異試験は STALL_SCAN_ROOT に写しを渡して撃つ)。
    STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$REPO}"
    SCAN="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
    Q="$(mktemp -d)"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/inbox"
    # 己を母数から外す (条C) = 試験は必ず mktemp の queue-root を渡す。
    # 本番の queue/ を一度も読まないので、試験の作り物が番人の数を動かさない。
    #
    # 刻は date で組む。焼き付けた刻では上限 (既定 120 分) の内外が
    # 走らせる日によって変わり、試験の意味が日ごとに変わってしまう。
    LATE="$(date -d '-30 minutes' '+%Y-%m-%dT%H:%M:%S')"    # 閾値の外・上限の内 = 鳴る
    FRESH="$(date -d '-2 minutes' '+%Y-%m-%dT%H:%M:%S')"    # 閾値の内 = 鳴らぬ
    ANCIENT="$(date -d '-300 minutes' '+%Y-%m-%dT%H:%M:%S')" # 上限の外 = 鳴らさず名乗る
    FUTURE="$(date -d '+30 minutes' '+%Y-%m-%dT%H:%M:%S')"  # 刻が未来 = 名乗る
    echo "commands: []" > "$Q/shogun_to_karo.yaml"
}

teardown() {
    [ -n "${Q:-}" ] && rm -rf "$Q"
}

# $1=inbox名 (gunshi1 等)
_inbox() { echo "messages: []" > "$Q/inbox/$1.yaml"; }

# $1=inbox名 $2=差出人 $3=type $4=read $5=刻 $6=本文
_msg() {
    cat >> "$Q/inbox/$1.yaml" <<EOF
- id: msg_${2}_${4}_$(echo "$5" | tr -dc '0-9')
  from: $2
  type: $3
  read: $4
  timestamp: '$5'
  content: |
    $6
EOF
    # messages: [] の空 list の後ろへ足せぬゆえ、初回に頭を差し替える。
    sed -i 's/^messages: \[\]$/messages:/' "$Q/inbox/$1.yaml"
}

# $1=帳面の file 名 $2=欄の名 $3=値
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

# 前段の突合と 10 分規律の検めは外して撃つ (本検めだけを主張するため)。
_run() { run python3 "$SCAN" --queue-root "$Q" --no-qc-scan --no-qc-ledger-scan "$@"; }

# ── 陽性 ─────────────────────────────────────────────────────────────────
@test "IR-001: ★便が既読 (read: true) でも応答が無ければ鳴る★ = 本任の芯" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _ledger cmd_1465 in_progress
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"IR_ASHI=ashigaru5"* ]]
    [[ "$output" == *"IR_CMD=cmd_1465"* ]]
    [[ "$output" == *"IR_READ=True"* ]]
    [[ "$output" == *"IR_LEDGER_STATUS=in_progress"* ]]
}

@test "IR-002: 未読の便でも同じく鳴る (read の値で判定を変えぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru3 report false "$LATE" "cmd_1349 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [ "$status" -eq 0 ]
    [[ "$output" == *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"IR_CMD=cmd_1349"* ]]
    [[ "$output" == *"IR_READ=False"* ]]
}

@test "IR-003: 型が task_completed / report_received でも報告族として拾う" {
    _inbox gunshi1
    _msg gunshi1 ashigaru2 task_completed true "$LATE" "cmd_1290 が畢わった"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"IR_CMD=cmd_1290"* ]]
}

# ── 陰性 = 負の対照 ──────────────────────────────────────────────────────
@test "IR-004: ★帳面が parent_cmd で指しておれば黙る★ (負の対照)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi gunshi1 parent_cmd cmd_1465
    _run
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"応答済=1"* ]]
}

@test "IR-005: covers_cmds で指しておっても黙る" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi gunshi1 covers_cmds "'cmd_1465, cmd_1467'"
    _run
    [[ "$output" != *"QC_INBOX_NO_RESPONSE "* ]]
}

@test "IR-006: 閾値の内なら鳴らぬ (家老に配る間が在る)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$FRESH" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [[ "$output" != *"QC_INBOX_NO_RESPONSE"* ]]
}

@test "IR-007: 差出人が足軽でない便は報告族に数えぬ (負の対照)" {
    _inbox gunshi1
    _msg gunshi1 karo task_assigned true "$LATE" "cmd_1465 を検分せよ"
    _gunshi_empty gunshi1
    _run
    [[ "$output" != *"QC_INBOX_NO_RESPONSE"* ]]
    [[ "$output" == *"報告族=0"* ]]
}

@test "IR-008: 報告族でない型 (task_assigned) は数えぬ (負の対照)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 task_assigned true "$LATE" "cmd_1465 を承った"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"報告族=0"* ]]
}

# ── 黙る時も必ず名乗る ───────────────────────────────────────────────────
@test "IR-009: ★上限より古い便は鳴らさず、必ず名乗る★" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$ANCIENT" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [[ "$output" != *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"QC_INBOX_NO_RESPONSE_QUIET"* ]]
    [[ "$output" == *"上限120分より古い"* ]]
}

@test "IR-010: 台帳が deferred なら鳴らさず名乗る (承知の遅れ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _ledger cmd_1465 deferred
    _run
    [[ "$output" != *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"QC_INBOX_NO_RESPONSE_QUIET"* ]]
    [[ "$output" == *"台帳がdeferred"* ]]
}

@test "IR-011: 台帳が done でも鳴らさず名乗る (畳めば無かったことにはせぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _ledger cmd_1465 done
    _run
    [[ "$output" == *"QC_INBOX_NO_RESPONSE_QUIET"* ]]
    [[ "$output" == *"台帳がdone"* ]]
}

@test "IR-012: ★前段の突合が同じ走行で鳴らした cmd は二重に鳴らさぬ (名乗りは残す)★" {
    # 前段 (report YAML 入口) と本検め (inbox 入口) が同じ cmd で同時に鳴る形。
    # 家老の inbox へ二通 飛ばさぬ。ただし黙って消さず、名乗りは残す。
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _ledger cmd_1465 in_progress
    {
        echo "report:"
        echo "  task_id: subtask_1465_watch_seven"
        echo "  parent_cmd: cmd_1465"
        echo "  status: done"
        echo "  timestamp: '$LATE'"
    } > "$Q/reports/ashigaru5_report.yaml"
    # 前段を外さずに撃つ = 前段が先に鳴る
    run python3 "$SCAN" --queue-root "$Q" --no-qc-scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"QC_LEDGER_MISS "* ]]                   # 前段は鳴る
    [[ "$output" != *"QC_INBOX_NO_RESPONSE "* ]]             # 本検めは鳴らぬ
    [[ "$output" == *"前段の突合が同じ走行で既に鳴らした"* ]]  # 而して名乗る
}

@test "IR-013: 本文に cmd 番号が無い便を名乗る (黙って落とさぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "畢わった。詳しくは稿を見よ"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"ACTION=inbox_response_cmd_undetermined"* ]]
    [[ "$output" == *"cmd不明除外=1"* ]]
}

@test "IR-014: 刻が未来の便を名乗る (経過が負で閾値を永久に超えぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$FUTURE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"ACTION=inbox_response_future_dated"* ]]
    [[ "$output" == *"刻が未来ゆえ除外=1"* ]]
}

@test "IR-015: 刻が読めぬ便を名乗る" {
    cat > "$Q/inbox/gunshi1.yaml" <<'EOF'
messages:
- id: msg_broken_ts
  from: ashigaru5
  type: report
  read: true
  timestamp: 'いつだったか忘れた'
  content: |
    cmd_1465 の検分を乞う
EOF
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"ACTION=inbox_response_undated"* ]]
    [[ "$output" == *"刻の読めぬ便除外=1"* ]]
}

@test "IR-016: 読めぬ inbox を名乗る (健全側へ混ぜぬ)" {
    printf 'messages:\n  - [broken\n' > "$Q/inbox/gunshi1.yaml"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"ACTION=inbox_response_unreadable"* ]]
    [[ "$output" == *"健全と読むな"* ]]
}

# ── canary と母数 ────────────────────────────────────────────────────────
@test "IR-017: ★canary 赤 = 報告族が 1 通も無い時、0 を『漏れ無し』と読ませぬ★" {
    _inbox gunshi1
    _gunshi gunshi1 parent_cmd cmd_1465
    _run
    [[ "$output" == *"canary 赤"* ]]
    [[ "$output" == *"報告族が 1 通も無い"* ]]
}

@test "IR-018: canary 赤 = 帳面が指す cmd が 1 件も無い時" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$FRESH" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"canary 赤"* ]]
    [[ "$output" == *"帳面が指す cmd が 1 件も無い"* ]]
}

@test "IR-019: ★母数は hit が在っても刷る★ (条1)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi gunshi1 parent_cmd cmd_9999
    _run
    [[ "$output" == *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"応答なき報告 hit=1 件"* ]]
    [[ "$output" == *"報告族=1"* ]]
    [[ "$output" == *"走査file=1"* ]]
    [[ "$output" == *"canary 緑"* ]]
}

# ── 口 と 構造 ───────────────────────────────────────────────────────────
@test "IR-020: --no-qc-inbox-scan で外せる (外した時は一行も出ぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    run python3 "$SCAN" --queue-root "$Q" --no-qc-scan --no-qc-ledger-scan --no-qc-inbox-scan
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_INBOX_NO_RESPONSE"* ]]
    [[ "$output" != *"応答なき報告"* ]]
}

@test "IR-021: json の口でも落とさぬ (同じ穴が口を変えて戻らぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _run --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"qc_inbox_no_response"* ]]
    [[ "$output" == *"qc_inbox_no_response_stats"* ]]
    [[ "$output" == *"cmd_1465"* ]]
}

@test "IR-022: ★本検めの出力は既存の検めの【否定の主張】と衝突せぬ★" {
    # なぜ要るか = 三号が cmd_1459 前段で現に踏んだ (2026-07-28 07:3x に他人の試験 5 本が赤くなった)。
    # 既存 4 suite の否定の主張は「この走行に AGENT= / ELAPSED_MIN= /
    # QC_DISPATCH_LATE / QC_LEDGER_MISS / 起票漏れ が一つも無い」の形で書かれている。
    # 部分一致で当たる点に注意 = LM_AGENT= は AGENT= を含む (三号の一度目の直しは効いていなかった)。
    # 「避けたつもり」を機械の側で留める。
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$LATE" "cmd_1465 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"QC_INBOX_NO_RESPONSE "* ]]   # 現に鳴っておる上で、
    [[ "$output" != *"AGENT="* ]]                  # この 5 つを含まぬ
    [[ "$output" != *"ELAPSED_MIN="* ]]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    [[ "$output" != *"QC_LEDGER_MISS"* ]]
    [[ "$output" != *"起票漏れ"* ]]
}

@test "IR-023: 便が 2 通 在れば 2 通 とも見る (先の便が後の便に隠れぬ)" {
    # 前段の突合が見られない形そのもの = report YAML なら先の 1 件が上書きで消える。
    # inbox は追記式ゆえ 2 通 とも残る。ここが本検めの存在理由である。
    _inbox gunshi1
    _msg gunshi1 ashigaru3 report true "$LATE" "cmd_1349 の検分を乞う"
    _msg gunshi1 ashigaru3 report true "$LATE" "cmd_1467 の検分を乞う"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"IR_CMD=cmd_1349"* ]]
    [[ "$output" == *"IR_CMD=cmd_1467"* ]]
    [[ "$output" == *"報告族=2"* ]]
}

# ── 入口が切り詰められても見えるか (2026-07-28 夕に前提が崩れると分かった分) ──
@test "IR-024: ★切り詰めで控えへ移った便も、上限の窓の内なら見る★" {
    # inbox_write.sh は 50 通を超えると既読を末尾 15 通まで切り詰め、
    # 残りを queue/archive/inbox_<agent>_<刻>_overflow.yaml へ移す。
    # 移った先を見なければ、この検めは時間差で同じ穴に落ちる。
    _inbox gunshi1
    mkdir -p "$Q/archive"
    cat > "$Q/archive/inbox_gunshi1_20260728_overflow.yaml" <<EOF2
messages:
- id: msg_moved
  from: ashigaru3
  type: report
  read: true
  timestamp: '$LATE'
  content: |
    cmd_1349 の検分を乞う
EOF2
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"QC_INBOX_NO_RESPONSE "* ]]
    [[ "$output" == *"IR_CMD=cmd_1349"* ]]
    [[ "$output" == *"うち控え=1"* ]]
}

@test "IR-025: 上限より古い控えは読まぬ (窓の外は名乗りも出ぬ = 射程として明示)" {
    _inbox gunshi1
    mkdir -p "$Q/archive"
    cat > "$Q/archive/inbox_gunshi1_old_overflow.yaml" <<EOF2
messages:
- id: msg_ancient
  from: ashigaru3
  type: report
  read: true
  timestamp: '$ANCIENT'
  content: |
    cmd_1349 の検分を乞う
EOF2
    touch -d '-300 minutes' "$Q/archive/inbox_gunshi1_old_overflow.yaml"
    _gunshi_empty gunshi1
    _run
    [[ "$output" == *"うち控え=0"* ]]
    [[ "$output" != *"IR_CMD=cmd_1349"* ]]
}
