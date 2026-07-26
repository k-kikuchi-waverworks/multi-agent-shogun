#!/usr/bin/env bats
# test_stall_watchdog_redispatch.bats — cmd_1359: 番人へ「呼ぶ者」を配線するにあたり
# 併せて要った ★task_id 再利用の裁定★ と ★alert 疲れの番★ の契約。
#
# 軍師二号の警告 = 本 scan を配線した途端「真の漏れでないのに鳴り続ける」。
# 的 = ★家老が同じ task_id へ新しい手番を載せる癖★。
#
# 裁定 = 運用則で人を縛らず、★task YAML が申告した updated_at で見分ける★。
#   updated_at > report刻 → 再dispatch = 鳴らさぬ (但し【黙った事実】は log に出す)
#   updated_at < report刻 → 真の帳簿漏れ = 鳴る
#   updated_at 不在       → ★見分けられぬゆえ鳴らす側へ倒す★ (握り潰さぬ)
#
# ★mtime を代理に使う道は意図して捨てた★ = task file に触れさえすれば genuine な
# 漏れが黙って消える = 家老が 23:39 に dashboard mtime で誤って死と判定された型の再演。

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # ★複写へ当てる口は【三 suite で 1 つ】である★ (cmd_1394 同族・2026-07-27):
    #   ★片方だけに口を開ける形は、次に来た者が必ず踏む★ — 拙者が現に踏んだ =
    #   ★複写へ当てた変異が此の suite だけ本番を撃ち、緑を返した★。
    #   ⇒ 名を suite ごとに分けず ★根 (scripts/ を持つ木) を 1 つの変数で指す★。
    STALL_SCAN_ROOT="${STALL_SCAN_ROOT:-$REPO}"
    SCAN="$STALL_SCAN_ROOT/scripts/stall_watchdog_scan.py"
    Q="$(mktemp -d)"
    mkdir -p "$Q/tasks" "$Q/reports"
}

teardown() {
    [ -n "${Q:-}" ] && rm -rf "$Q"
}

# $1=task更新刻 (空なら updated_at を書かぬ) / $2=report刻
_fixture() {
    local task_upd="$1" report_ts="$2"
    {
        echo "task:"
        echo "  task_id: subtask_reuse_001"
        echo "  parent_cmd: cmd_1359"
        echo "  status: assigned"
        [ -n "$task_upd" ] && echo "  updated_at: '$task_upd'"
    } > "$Q/tasks/ashigaru3.yaml"
    cat > "$Q/reports/ashigaru3_report.yaml" <<EOF
report:
  task_id: subtask_reuse_001
  status: completed
  timestamp: '$report_ts'
EOF
}

@test "T-RDP-001: updated_at が report より新しい = 再dispatch ゆえ鳴らさぬ" {
    _fixture "2026-07-26T10:00:00" "2026-07-26T08:00:00"
    run python3 "$SCAN" --queue-root "$Q" --threshold-min 30
    [ "$status" -eq 0 ]
    # ★hit 行の署名は ELAPSED_MIN= である★ — 除外 log 行にも AGENT= は載るゆえ
    # そちらで判ずると「黙った事実を log に出す」設計と衝突して偽の緑になる。
    [[ "$output" != *"ELAPSED_MIN="* ]]
    [[ "$output" == *"帳簿漏れ hit なし"* ]]
}

@test "T-RDP-002: ★黙った事実を黙らぬ★ — 再dispatch除外は根拠つきで log へ出る" {
    _fixture "2026-07-26T10:00:00" "2026-07-26T08:00:00"
    run python3 "$SCAN" --queue-root "$Q" --threshold-min 30
    [[ "$output" == *"再dispatchと判定し鳴らさず"* ]]
    [[ "$output" == *"根拠=updated_at"* ]]
    [[ "$output" == *"再dispatch除外=1"* ]]
}

@test "T-RDP-003: updated_at が report より古い = 真の帳簿漏れ ゆえ鳴る" {
    _fixture "2026-07-26T08:00:00" "2026-07-26T10:00:00"
    run python3 "$SCAN" --queue-root "$Q" --threshold-min 30
    # ★hit 行の署名 ELAPSED_MIN= で判ずる★ — AGENT= は【鳴らさなかった】log 行にも
    # 載るゆえ、そちらで判ずると ★握り潰されても緑になる★ (MUT-1359-001 が
    # この穴を実際に暴いた = 台帳が拙者の空虚な test を捕まえた)。
    [[ "$output" == *"ELAPSED_MIN="* ]]
    [[ "$output" == *"TASK_ID=subtask_reuse_001"* ]]
    [[ "$output" != *"再dispatchと判定し鳴らさず"* ]]
}

@test "T-RDP-004: updated_at 不在 = 見分けられぬゆえ ★握り潰さず鳴らす★" {
    _fixture "" "2026-07-26T10:00:00"
    run python3 "$SCAN" --queue-root "$Q" --threshold-min 30
    [[ "$output" == *"ELAPSED_MIN="* ]]
    [[ "$output" != *"再dispatchと判定し鳴らさず"* ]]
}

@test "T-RDP-005: 見分けられなんだ時、alert 本文がその旨を明記する (人が判ずる材料)" {
    run python3 -c "
import sys; sys.path.insert(0, '$REPO/scripts')
import stall_watchdog_scan as s
h = {'agent':'ashigaru3','task_id':'t','parent_cmd':'cmd_1359',
     'elapsed_min':99,'report_status':'completed','redispatch_basis':'none'}
print(s.format_alert_message(h))
"
    [[ "$output" == *"見分けられなんだ"* ]]
    [[ "$output" == *"updated_at"* ]]
}

@test "T-RDP-006: 根拠が updated_at の hit は alert に余計な但し書きを付けぬ" {
    run python3 -c "
import sys; sys.path.insert(0, '$REPO/scripts')
import stall_watchdog_scan as s
h = {'agent':'ashigaru3','task_id':'t','parent_cmd':'cmd_1359',
     'elapsed_min':99,'report_status':'completed','redispatch_basis':'updated_at'}
print(s.format_alert_message(h))
"
    [[ "$output" != *"見分けられなんだ"* ]]
}

# ── alert 疲れの番 (★常に赤い検知は無視されて死ぬ = 沈黙と同じ結末★) ──

@test "T-CD-001: 同一 (agent, task_id) は cooldown 内なら再警報せぬ" {
    run python3 -c "
import sys, datetime, pathlib, tempfile
sys.path.insert(0, '$REPO/scripts')
import stall_watchdog_scan as s
s.ALERT_STATE = pathlib.Path(tempfile.mkdtemp()) / 'st.yaml'
now = datetime.datetime(2026, 7, 26, 12, 0, 0)
h = {'agent':'ashigaru3','task_id':'t1'}
st = {s.alert_key(h): {'last_alert': (now - datetime.timedelta(minutes=10)).isoformat()}}
print('cooldown内:', s.in_cooldown(h, st, 360, now))
print('cooldown明け:', s.in_cooldown(h, st, 5, now))
"
    [[ "$output" == *"cooldown内: True"* ]]
    [[ "$output" == *"cooldown明け: False"* ]]
}

@test "T-CD-002: 別の task_id は cooldown に巻き込まれず即座に鳴る" {
    run python3 -c "
import sys, datetime, pathlib, tempfile
sys.path.insert(0, '$REPO/scripts')
import stall_watchdog_scan as s
s.ALERT_STATE = pathlib.Path(tempfile.mkdtemp()) / 'st.yaml'
now = datetime.datetime(2026, 7, 26, 12, 0, 0)
old = {'agent':'ashigaru3','task_id':'t1'}
new = {'agent':'ashigaru3','task_id':'t2'}
st = {s.alert_key(old): {'last_alert': now.isoformat()}}
print('別task:', s.in_cooldown(new, st, 360, now))
"
    [[ "$output" == *"別task: False"* ]]
}

# ── ★配線消失検知 (cmd_1359 の核心)★ ──────────────────────────────────
# 本 cmd の病 = 「番人は書かれたが【呼ぶ者が居らぬ】」。3ヶ月 発報0件であった。
# ゆえに ★配線が消えたら気付ける★ ことまでを契約にする (gate_nightly が毎朝検める)。
#
# 検分対象は ★実 file から機械抽出した当の行★ = 手写しの写しを検めても意味が無い
# (fixture が実体と乖離する罠は本日繰り返し見た)。

_extract_wiring_check() {
    sed -n '/配線消失検知 (cmd_1359)/,/^fi$/p' "$REPO/scripts/gate_nightly.sh" \
        > "$Q/wiring_check.sh"
    echo 'echo "配線=$([ "$wiring_rc" -eq 0 ] && echo OK || echo MISSING)"' >> "$Q/wiring_check.sh"
    # 抽出できておらぬのに緑にせぬ (空を緑と読む型の防止)
    [ "$(wc -l < "$Q/wiring_check.sh")" -ge 5 ]
}

@test "T-WIR-001: cron 配線が在れば OK" {
    _extract_wiring_check
    mkdir -p "$Q/stub"
    printf '#!/bin/sh\necho "*/15 * * * * x # stall_watchdog_cmd1359"\n' > "$Q/stub/crontab"
    chmod +x "$Q/stub/crontab"
    run env PATH="$Q/stub:$PATH" bash "$Q/wiring_check.sh"
    [[ "$output" == *"配線=OK"* ]]
}

@test "T-WIR-002: ★cron 配線が消えたら名指しで MISSING★ (番人が誰にも呼ばれておらぬ)" {
    _extract_wiring_check
    mkdir -p "$Q/stub"
    printf '#!/bin/sh\necho "*/3 * * * * x # idle_revive_scan_cmd1154"\n' > "$Q/stub/crontab"
    chmod +x "$Q/stub/crontab"
    run env PATH="$Q/stub:$PATH" bash "$Q/wiring_check.sh"
    [[ "$output" == *"配線=MISSING"* ]]
    [[ "$output" == *"誰にも呼ばれておらぬ"* ]]
}

@test "T-WIR-003: crontab 自体が見えぬ時は UNDETERMINED 側へ倒す (緑にせぬ)" {
    _extract_wiring_check
    mkdir -p "$Q/minbin"
    for t in bash grep sed cat echo; do ln -sf "$(command -v $t)" "$Q/minbin/$t" 2>/dev/null; done
    run env PATH="$Q/minbin" bash "$Q/wiring_check.sh"
    [[ "$output" == *"配線=MISSING"* ]]
    [[ "$output" == *"検分できぬ"* ]]
}

@test "T-CD-003: state が壊れておっても番人は死なず鳴る側へ倒れる (fail-LOUD)" {
    run python3 -c "
import sys, datetime, pathlib, tempfile
sys.path.insert(0, '$REPO/scripts')
import stall_watchdog_scan as s
d = pathlib.Path(tempfile.mkdtemp()); p = d / 'st.yaml'
p.write_text('{{{ not yaml', encoding='utf-8')
s.ALERT_STATE = p
st = s._load_alert_state()
print('壊れたstate:', st)
print('cooldown:', s.in_cooldown({'agent':'a','task_id':'t'}, st, 360, datetime.datetime.now()))
"
    [[ "$output" == *"壊れたstate: {}"* ]]
    [[ "$output" == *"cooldown: False"* ]]
}
