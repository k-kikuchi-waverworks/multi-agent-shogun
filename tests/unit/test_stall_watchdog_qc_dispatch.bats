#!/usr/bin/env bats
# test_stall_watchdog_qc_dispatch.bats — cmd_1454: ★10 分規律を撃つ機械★ の契約。
#
# 規の出所 = instructions/karo.md「🚨 MANDATORY: Ash Report Receipt → Karo MUST
# Dispatch QC Task Explicitly」節の **Rule** (絶対遵守)「… within ≤10 min of arrival」。
# ★行番号で引かぬ★ = 06:40〜06:44 の間に現に動いた (四号が同 file を編集中・1400→1376)。
# 之を撃つ機械が本 script に無かった。同 file の Watchdog 節 (B) に python の一節は在るが、
#   ・queue/inbox/gunshi.yaml を読む (現物の messages は 0 件)
#   ・type は report_received だけを見る
#     (現の型は report 18 件・task_completed 4 件・report_received 1 件)
# ⇒ ★file 名と型の二重の食い違いゆえ、走らせても必ず 0 を返す =「見ておらぬ 0」★。
#
# ★本 suite が守るのは二つ★
#   (あ) 鳴るべき時に鳴り、鳴らぬべき時に黙る (両方向・条4)
#   (い) ★canary★ = 報告族が既読も含めて 0 通なら「探し方が当たっておらぬ疑い」と名乗る。
#        ★之が無ければ、上の食い違いが二度と静かに起きる★ (家老 06:36 の下命)。

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # 複写へ当てる口は三 suite で 1 つ (test_stall_watchdog_redispatch.bats と同型)。
    STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$REPO}"
    SCAN="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
    Q="$(mktemp -d)"
    mkdir -p "$Q/tasks" "$Q/reports" "$Q/inbox"
    # ★己を母数から外す (条C)★: 試験は必ず mktemp の queue-root を渡す =
    # ★本番の queue/ を一度も読まぬ★ ゆえ、拙者の作り物が番人の数を動かさぬ。
    OLD="2026-07-28T00:00:00"   # 十分に古い刻 (必ず閾値を超える)
}

teardown() {
    [ -n "${Q:-}" ] && rm -rf "$Q"
}

# $1=inbox名 $2=from $3=type $4=read $5=timestamp
_msg() {
    cat >> "$Q/inbox/$1.yaml" <<EOF
- content: 'fixture'
  from: $2
  id: msg_fixture_$1_$3_$4
  read: $4
  timestamp: '$5'
  type: $3
EOF
}

_inbox() { echo "messages:" > "$Q/inbox/$1.yaml"; }

@test "T-QC-001: 未読の報告が閾値を超えて居れば鳴る (陽性)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"QC_DISPATCH_LATE"* ]]
    [[ "$output" == *"FROM=ashigaru5"* ]]
    [[ "$output" == *"MSG_TYPE=report"* ]]
}

@test "T-QC-002: ★型は report_received だけではない★ — report_received も task_completed も鳴る" {
    _inbox gunshi1
    _msg gunshi1 ashigaru1 report_received false "$OLD"
    _msg gunshi1 ashigaru3 task_completed false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"MSG_TYPE=report_received"* ]]
    [[ "$output" == *"MSG_TYPE=task_completed"* ]]
}

@test "T-QC-003: ★gunshi.yaml だけを見る形では落ちる物★ — gunshi1/gunshi2 も走査される" {
    _inbox gunshi.yaml_dummy_unused 2>/dev/null || true
    _inbox gunshi
    _inbox gunshi2
    _msg gunshi2 ashigaru7 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"INBOX=gunshi2.yaml"* ]]
}

@test "T-QC-004: 閾値内なら黙る (陰性)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report false "$(date '+%Y-%m-%dT%H:%M:%S')"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    [[ "$output" == *"QC dispatch 漏れ hit なし"* ]]
}

@test "T-QC-005: 既読は鳴らぬ (陰性) — だが母数と canary には載る" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    [[ "$output" == *"canary 緑"* ]]
    [[ "$output" == *"報告族 1 通"* ]]
}

@test "T-QC-006: ★canary 赤★ — 報告族が既読も含めて 0 通なら『探し方が当たっておらぬ疑い』と名乗る" {
    # ★之が karo.md の一節が陥っておった形そのもの★ =
    #   家老の便しか居らぬ inbox を見て「漏れ 0」と返す。
    _inbox gunshi1
    _msg gunshi1 karo task_assigned false "$OLD"
    _msg gunshi1 inbox_watcher note false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    [[ "$output" == *"canary 赤"* ]]
    [[ "$output" == *"此の 0 を『漏れ無し』と読むな"* ]]
}

@test "T-QC-007: 家老/inbox_watcher の便は鳴らさぬ (足軽の報告だけが的)" {
    _inbox gunshi1
    _msg gunshi1 karo task_assigned false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
}

@test "T-QC-008: ★己を母数から外す (条C)★ — 番人自身の便は報告族に数えぬ" {
    # ★之が効く機序は【差出人の prefix 絞り】ただ一つである★ =
    #   番人が名乗る from は "stall_watchdog" ゆえ ashigaru の prefix を通らぬ。
    #   ★元は QC_SELF_SENDERS という第二の錠も置いておったが、変異試験 (06:41) で
    #   【落としても赤が 1 本も出ぬ】= 二つの錠が互いを隠しておると判り、外した。★
    #   ⇒ 今は T-QC-014 が prefix 絞りそのものを留めておる (単独で赤になる)。
    _inbox gunshi1
    _msg gunshi1 stall_watchdog report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    [[ "$output" == *"canary 赤"* ]]   # 報告族 0 通 = 之は当然 canary が鳴る側
}

@test "T-QC-014: ★差出人の絞りを留める★ — 軍師発の report は鳴らさぬ (的は足軽の報告のみ)" {
    # ★本試験が無ければ prefix 絞りは【どの変異でも赤にならぬ】= 何も証さぬ緑であった
    #   (2026-07-28 06:42 実測 M7 = prefix を潰しても赤 0 本)。★
    #   型の絞りが karo/inbox_watcher を先に落としてしまい、prefix 側が試されておらなんだ。
    #   ゆえに ★型の絞りを通り、prefix だけで落ちる便★ を的に据える。
    _inbox gunshi1
    _msg gunshi1 gunshi2 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
}

@test "T-QC-009: 刻の読めぬ便は【黙って落とさず】名乗る" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report false "刻が壊れておる"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACTION=gunshi_msg_undated"* ]]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
}

@test "T-QC-010: 読めぬ inbox は【健全と読ませぬ】" {
    printf 'messages:\n  - [broken\n' > "$Q/inbox/gunshi1.yaml"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACTION=gunshi_inbox_unreadable"* ]]
    [[ "$output" == *"健全と読むな"* ]]
}

@test "T-QC-011: 母数を必ず印字する (0 の時も『何を見た上での 0 か』が読める)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report true "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [[ "$output" == *"走査file="* ]]
    [[ "$output" == *"便="* ]]
    [[ "$output" == *"未読="* ]]
}

@test "T-QC-012: --no-qc-scan で検めを外せる (外した時は一行も出ぬ)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --no-qc-scan
    [ "$status" -eq 0 ]
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    [[ "$output" != *"QC dispatch 漏れ hit なし"* ]]
}

@test "T-QC-013: json の口でも 10 分規律を落とさぬ" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10 --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"qc_dispatch_late"* ]]
    [[ "$output" == *"ashigaru5"* ]]
}

# ── 刻が未来の便 (cmd_1450 丙・家老 07:21 の裁・三号 07:17 の実測) ──────────
# ★機序★= 経過で切る検めは、刻が未来の便を ★永久に拾わぬ★ (経過が負ゆえ閾値を超えぬ)。
#   実測 = ashigaru1_report.yaml の record が 07:45 (file の mtime は 07:08) ⇒ 経過 -28 分。
#   ★黙って skip すれば、其の報告は検めから消えたまま誰も気付かぬ。★
#   ⇒ hit にはせぬ (経過が閾値を超えておらぬのは事実) が、★必ず名乗らせる★。

@test "T-QC-015: 刻が未来の便は【黙って落とさず】名乗る (陽性)" {
    _inbox gunshi1
    # now より確実に先の刻を作る (試験の刻に依らぬよう相対で作る)
    FUTURE="$(python3 -c 'import datetime;print((datetime.datetime.now()+datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%S"))')"
    _msg gunshi1 ashigaru5 report false "$FUTURE"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACTION=gunshi_msg_future_dated"* ]]
    [[ "$output" == *"AHEAD_MIN="* ]]
    # ★hit には載せぬ★ = 経過が閾値を超えておらぬのは事実である
    [[ "$output" != *"QC_DISPATCH_LATE"* ]]
    # ★母数にも数が出る★ = 「見た上で落とした」が読める
    [[ "$output" == *"刻が未来ゆえ除外=1"* ]]
}

@test "T-QC-016: 刻が過去の便では未来の名乗りは出ぬ (負の対照)" {
    _inbox gunshi1
    _msg gunshi1 ashigaru5 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" != *"ACTION=gunshi_msg_future_dated"* ]]
    [[ "$output" == *"QC_DISPATCH_LATE"* ]]
}

@test "T-QC-017: 未来の便が在っても、同居する古い便は現に鳴る (未来が他を隠さぬ)" {
    _inbox gunshi1
    FUTURE="$(python3 -c 'import datetime;print((datetime.datetime.now()+datetime.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%S"))')"
    _msg gunshi1 ashigaru5 report false "$FUTURE"
    _msg gunshi1 ashigaru6 report false "$OLD"
    run python3 "$SCAN" --queue-root "$Q" --qc-threshold-min 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACTION=gunshi_msg_future_dated"* ]]
    [[ "$output" == *"QC_DISPATCH_LATE"* ]]
    [[ "$output" == *"ashigaru6"* ]]
}
