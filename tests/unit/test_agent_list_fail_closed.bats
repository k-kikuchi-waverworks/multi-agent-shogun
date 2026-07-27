#!/usr/bin/env bats
# test_agent_list_fail_closed.bats — cmd_1405 (2026-07-27)
#
# ★何を守る牙か★:
#   scripts/lib/agent_list.sh は settings.yaml を読めぬ時、旧実装で
#   ★rc=0 + 空出力★ を返した (`except FileNotFoundError: sys.exit(0)`)。
#   ★之は「active な agent が 0 人である」と byte 単位で同一★ゆえ、
#   watcher_supervisor は ★誰も見張らぬまま 5 秒 loop を回し、上位は「見張っておる」と読んだ★。
#   = 「我らの木を新しい機へ写しても動かぬ。而して【動かぬ】とも申さぬ」の実物。
#
# ★両方向で撃つ★ (片側だけでは守りを減らした改悪と区別が付かぬ):
#   (A) 隠せば ★名乗って落ちる★ (rc=3 + stderr 1行)
#   (B) 在れば ★従前どおり返す★ (件数・deprecated 除外・pane 解決)
#   (C) ★真に 0 件 (cli.agents: {}) は 0 のまま★ = 空を赤に混ぜぬ (混ぜれば毎晩鳴る門=外される)
#
# ★書き方の枷★= 判定に `! cmd` を使わぬ (cmd_1401: bats の `!` は set -e 免除ゆえ刃を持たぬ)。
#   負の主張は `if <cmd>; then return 1; fi` で書く。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export AGENT_LIST_LIB="$PROJECT_ROOT/scripts/lib/agent_list.sh"
    [ -f "$AGENT_LIST_LIB" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/agentlist.XXXXXX")"
    export FIXTURE="$TEST_TMPDIR/settings.yaml"
    cat > "$FIXTURE" << 'YAML'
cli:
  agents:
    shogun:
      cli: claude
    karo:
      cli: claude
    ashigaru1:
      cli: claude
    ashigaru2:
      cli: claude
    gunshi1:
      cli: claude
      pane: multiagent:agents.7
    gunshi_a:
      cli: claude
      deprecated: true
YAML
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fixture を差した状態で agent_list の関数を1つ呼ぶ (stdout のみ・rc は run が拾う)
_al() {
    local settings="$1"; shift
    run env AGENT_LIST_TEST_SETTINGS="$settings" bash -c '
        . "'"$AGENT_LIST_LIB"'"
        _AGENT_LIST_SETTINGS_FILE="$AGENT_LIST_TEST_SETTINGS"
        "$@"
    ' _ "$@"
}

# ─────────────────────────────────────────────────────────────
# (B) 在る盤面 = 従前どおり返す (守りを減らしておらぬ証)
# ─────────────────────────────────────────────────────────────

@test "T-AL-001: 在る盤面 → active ashigaru を従前どおり列挙 (rc=0)" {
    _al "$FIXTURE" get_active_ashigaru_agents
    [ "$status" -eq 0 ]
    [ "$output" = "ashigaru1
ashigaru2" ]
}

@test "T-AL-002: 在る盤面 → deprecated gunshi は従前どおり除外" {
    _al "$FIXTURE" get_active_gunshi_agents
    [ "$status" -eq 0 ]
    [ "$output" = "gunshi1" ]
    # deprecated を含む全列挙は従前どおり両方返す
    _al "$FIXTURE" get_all_gunshi_agents
    [ "$status" -eq 0 ]
    [ "$output" = "gunshi1
gunshi_a" ]
}

@test "T-AL-003: 在る盤面 → pane / deprecated 判定が従前どおり" {
    _al "$FIXTURE" get_agent_pane gunshi1
    [ "$status" -eq 0 ]
    [ "$output" = "multiagent:agents.7" ]

    _al "$FIXTURE" is_deprecated_agent gunshi_a
    [ "$status" -eq 0 ]      # 0 = deprecated

    _al "$FIXTURE" is_deprecated_agent ashigaru1
    [ "$status" -eq 1 ]      # 1 = deprecated でない
}

@test "T-AL-004: canary = 本番 config/settings.yaml は現に読めて 1 件以上返す" {
    # ★0 を報ずる前に canary★= fixture だけで緑になる試験は、本番 config の腐りを見逃す。
    _al "$PROJECT_ROOT/config/settings.yaml" get_active_ashigaru_agents
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ─────────────────────────────────────────────────────────────
# (A) 読めぬ盤面 = 名乗って落ちる
# ─────────────────────────────────────────────────────────────

@test "T-AL-005: settings.yaml 不在 → rc=3 かつ UNREADABLE を名乗る (★旧実装は rc=0+空★)" {
    _al "$TEST_TMPDIR/does_not_exist.yaml" get_active_ashigaru_agents
    [ "$status" -eq 3 ]
    if echo "$output" | grep -q "UNREADABLE"; then :; else return 1; fi
    if echo "$output" | grep -q "settings.yaml が無い"; then :; else return 1; fi
    # ★agent 名を1つでも刷ったなら「読めた」と偽っておる★
    if echo "$output" | grep -q "ashigaru1"; then return 1; fi
}

@test "T-AL-006: 壊れた YAML → rc=3 (traceback でなく名乗りで落ちる)" {
    printf 'cli:\n  agents:\n   - [broken\n' > "$TEST_TMPDIR/broken.yaml"
    _al "$TEST_TMPDIR/broken.yaml" get_active_ashigaru_agents
    [ "$status" -eq 3 ]
    if echo "$output" | grep -q "YAML として壊れておる"; then :; else return 1; fi
    if echo "$output" | grep -q "Traceback"; then return 1; fi
}

@test "T-AL-007: cli.agents 節ごと欠落 → rc=3 (★0 件と読んではならぬ★)" {
    printf 'other: 1\n' > "$TEST_TMPDIR/nocli.yaml"
    _al "$TEST_TMPDIR/nocli.yaml" get_active_ashigaru_agents
    [ "$status" -eq 3 ]
    if echo "$output" | grep -q "cli.agents 節が無い"; then :; else return 1; fi
}

@test "T-AL-008: 空 file → rc=3" {
    : > "$TEST_TMPDIR/blank.yaml"
    _al "$TEST_TMPDIR/blank.yaml" get_active_ashigaru_agents
    [ "$status" -eq 3 ]
}

@test "T-AL-009: 読めぬ時は全ての口が rc=3 を通す (pipeline に食わせぬ)" {
    local missing="$TEST_TMPDIR/does_not_exist.yaml"
    for fn in get_active_agents get_active_ashigaru_agents get_active_gunshi_agents \
              get_all_gunshi_agents get_command_layer_agents; do
        _al "$missing" "$fn"
        [ "$status" -eq 3 ]
    done
    # ★get_command_layer_agents は awk への pipeline★= 旧形なら rc が awk の 0 に化けた
    _al "$missing" get_command_layer_agents
    if echo "$output" | grep -q "^shogun$"; then return 1; fi

    _al "$missing" get_agent_pane gunshi1
    [ "$status" -eq 3 ]
    _al "$missing" is_deprecated_agent gunshi_a
    [ "$status" -eq 3 ]
}

# ─────────────────────────────────────────────────────────────
# (C) 真の 0 件は 0 のまま = 空を赤に混ぜぬ
# ─────────────────────────────────────────────────────────────

@test "T-AL-010: cli.agents: {} → rc=0 かつ空出力 (★真の空を赤に混ぜぬ★)" {
    printf 'cli:\n  agents: {}\n' > "$TEST_TMPDIR/empty.yaml"
    _al "$TEST_TMPDIR/empty.yaml" get_active_ashigaru_agents
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ─────────────────────────────────────────────────────────────
# 上位 (watcher_supervisor) が其の落ちを現に刷るか
# ★名乗ったのに上位が黙るなら直っておらぬ★
# ─────────────────────────────────────────────────────────────

_sup() {
    run env SHOGUN_LOCK_DIR="$TEST_TMPDIR/locks" \
            WATCHER_AGENT_LIST_RENOTE_SEC="${RENOTE:-3600}" \
            __WATCHER_SUPERVISOR_TESTING__=1 \
            bash -c '
        . "'"$PROJECT_ROOT"'/scripts/watcher_supervisor.sh" 2>/dev/null
        eval "$1"
    ' _ "$1" 2>&1
}

@test "T-AL-011: 上位は落ちを [UNREADABLE] として刷り、回復を [RECOVERED] として刷る" {
    _sup 'agent_list_fail_note ashigaru 3 "理由XYZ"; agent_list_fail_clear'
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q "\[UNREADABLE\] ashigaru"; then :; else return 1; fi
    if echo "$output" | grep -q "rc=3"; then :; else return 1; fi
    if echo "$output" | grep -q "理由XYZ"; then :; else return 1; fi
    if echo "$output" | grep -q "\[RECOVERED\]"; then :; else return 1; fi
}

@test "T-AL-012: 同一状態の再掲は throttle される (5 秒毎に 17K行/日 の spam にせぬ)" {
    _sup 'agent_list_fail_note ashigaru 3 "理由A"; agent_list_fail_note ashigaru 3 "理由A"; agent_list_fail_note ashigaru 3 "理由A"'
    [ "$status" -eq 0 ]
    local n
    n=$(echo "$output" | grep -c "\[UNREADABLE\]")
    [ "$n" -eq 1 ]
}

@test "T-AL-013: throttle は scope 別 = ashigaru と gunshi の両方が名乗る" {
    _sup 'agent_list_fail_note ashigaru 3 "理由A"; agent_list_fail_note gunshi 3 "理由B"'
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q "\[UNREADABLE\] ashigaru"; then :; else return 1; fi
    if echo "$output" | grep -q "\[UNREADABLE\] gunshi"; then :; else return 1; fi
}

@test "T-AL-014: 落ちが無い周回で agent_list_fail_clear は黙る (回復を偽らぬ)" {
    _sup 'agent_list_fail_clear'
    [ "$status" -eq 0 ]
    if echo "$output" | grep -q "\[RECOVERED\]"; then return 1; fi
}

# ─────────────────────────────────────────────────────────────
# ★契約の値を【宣言して production と突合する】検★ (家老 03:54 の訂正表・第三の形)
#
# ★之を置く前、上の 14 本は【全て path を引数で上書きして】撃っておった★=
#   ★試験は production の既定値を一度も見ておらなんだ★。
# ★実測 (03:56:34)★= 既定 path を config/settings.yaml → config/settings_TYPO.yaml へ
#   動かす変異 (MUT-DEFAULT) を当てても ★14/14 緑・赤 0★ =
#   ★本番が己の config を一切見つけられぬ状態で、suite は全て緑であった★。
# ⇒ ★「本数」は守りの量を示さぬ★ (五号の 32/32 と同型)。
#
# ★作法★= declared を此処へ書き、production の既定と突き合わせる。
#   ★意図して動かす日は declared も直せ★= 其の一行が【意図の記録】になる
#   (「黙って動いた」と「意図して動かした」を分ける唯一の場所)。
# ─────────────────────────────────────────────────────────────

@test "T-AL-015: 契約 = 既定の settings path。宣言と production を突合する (上書きせぬ)" {
    # ★declared = 我らが決めた約束★
    local declared="config/settings.yaml"

    # ★AGENT_LIST_SETTINGS_FILE を明示的に剥いで source する★
    # = production が己で決める既定値を、其のまま見る
    run env -u AGENT_LIST_SETTINGS_FILE bash -c '
        . "'"$AGENT_LIST_LIB"'"
        printf "%s\n" "$_AGENT_LIST_SETTINGS_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_ROOT/$declared" ]

    # ★宣言と一致するだけでなく、其の path が現に在ること★
    # (宣言も実装も揃って間違うておる形を、盤面で捕える)
    [ -f "$output" ]
}

@test "T-AL-016: 契約 = 再掲の間隔 60 秒。宣言と production を突合する (上書きせぬ)" {
    # ★declared★= 5 秒毎の spam (実測 17K行/日) を避けるために我らが決めた値。
    # ★上の T-AL-012/013 は RENOTE=3600 で上書きして撃っておる★= 既定は其の射程の外。
    local declared=60

    # ─── cmd_1418 (2026-07-27): 標準エラーと値が混ざって落ちた件の手当て ───
    # 真因: cmd_1408 で watcher_supervisor.sh に EXIT trap が入り、抜ける時に
    # 「watcher_supervisor ENDED …」を★標準エラーへ★刷るようになった
    # (watcher_supervisor.sh:37 の sup_log が >&2)。
    # 下の 2>/dev/null は読み込みの間だけ掛かっており、後始末は抜ける時に鳴るゆえ効かぬ。
    # bats の run は既定で標準出力と標準エラーを1つに入れるゆえ、値と後始末が混ざって落ちた。
    #
    # 手当ては2段。片方だけでは足りない (2026-07-27 実測)。
    #   (a) --separate-stderr で標準エラーを $stderr へ分ける。捨ててはいない。
    #   (b) 値は最後に刷るゆえ、標準出力の★最終行★だけを見る。
    #       読み込みの途中で標準出力へ何か増えても、この検めは壊れない。
    # ※ (b) だけでは足りぬ理由: 実測では併合時の並びが「値 → 後始末」であり、
    #    最終行は後始末の行になる。標準エラーを分けて初めて最終行が値になる。
    bats_require_minimum_version 1.5.0
    run --separate-stderr env -u WATCHER_AGENT_LIST_RENOTE_SEC \
            __WATCHER_SUPERVISOR_TESTING__=1 \
            SHOGUN_LOCK_DIR="$TEST_TMPDIR/locks" \
            bash -c '
        . "'"$PROJECT_ROOT"'/scripts/watcher_supervisor.sh" 2>/dev/null
        printf "%s\n" "$AGENT_LIST_RENOTE_SEC"
    '
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "$declared" ]
}

# ─────────────────────────────────────────────────────────────
# ★loop 本体 (配線そのもの) を実射する検★
#
# ★T-AL-011〜014 は助手 (agent_list_fail_note / _clear) を直に呼んでおるだけ★=
#   ★「rc を受けて助手を呼ぶ」配線は 1 度も走っておらなんだ★
#   (`__WATCHER_SUPERVISOR_TESTING__=1` は while loop の【手前】で return するゆえ)。
# = ★軍師一号の T21 と同型の真空 PASS★ (助手は緑・配線は射程の外)。
# ⇒ WATCHER_SUPERVISOR_MAX_CYCLES で回数を切り、★loop 本体を 1 周 実射する★。
#
# ★process を一切生まぬための枷★= tmux / nohup を stub し、lock dir を temp へ、
#   drift は間隔を極大にし inbox_write を /bin/true へ倒す
#   (★試験が家老へ偽の drift 警告を送る形を潰す★)。
# ─────────────────────────────────────────────────────────────

@test "T-AL-018: loop 本体 = 読めぬ時に [UNREADABLE] を刷り、watcher を一体も起動せぬ" {
    local stub="$TEST_TMPDIR/stub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/tmux";   chmod +x "$stub/tmux"
    printf '#!/bin/sh\nexit 0\n' > "$stub/nohup";  chmod +x "$stub/nohup"
    # ★lock dir は本番では proc_lock_acquire が掘る★= 其の段は TESTING=1 で飛ぶゆえ、
    # ★試験の側で本番と同じ状態を作る★ (掘らねば start_lock の 9> が set -e で落ち、
    #  「配線の検」が【盤面の不備】で赤くなり、何を検めておるのか判らなくなる)。
    mkdir -p "$TEST_TMPDIR/locks"

    run env PATH="$stub:$PATH" \
            AGENT_LIST_SETTINGS_FILE="$TEST_TMPDIR/does_not_exist.yaml" \
            SHOGUN_LOCK_DIR="$TEST_TMPDIR/locks" \
            WATCHER_DRIFT_EVERY_SEC=999999 \
            DRIFT_INBOX_WRITE=/bin/true \
            WATCHER_SUPERVISOR_MAX_CYCLES=1 \
            __WATCHER_SUPERVISOR_TESTING__=1 \
            timeout 60 bash "$PROJECT_ROOT/scripts/watcher_supervisor.sh"
    [ "$status" -eq 0 ]

    # ★ashigaru と gunshi の両方が名乗ること★
    if echo "$output" | grep -q "\[UNREADABLE\] ashigaru"; then :; else return 1; fi
    if echo "$output" | grep -q "\[UNREADABLE\] gunshi"; then :; else return 1; fi
    # ★rc が 0 件へ化けておらぬこと★= 理由行が畳まれて届いておる
    if echo "$output" | grep -q "agent_list rc=3"; then :; else return 1; fi
    # ★読めぬのに「回復した」と刷る形は偽り★
    if echo "$output" | grep -q "\[RECOVERED\]"; then return 1; fi
    # ★watcher を起動した顔をしておらぬこと★
    if echo "$output" | grep -q "\[START\] inbox_watcher started"; then return 1; fi
}

@test "T-AL-019: loop 本体 = 在る盤面では黙り、従前どおり全 agent を辿る" {
    local stub="$TEST_TMPDIR/stub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/tmux";   chmod +x "$stub/tmux"
    printf '#!/bin/sh\nexit 0\n' > "$stub/nohup";  chmod +x "$stub/nohup"
    mkdir -p "$TEST_TMPDIR/locks2"   # 同上 (本番では proc_lock_acquire が掘る段に当たる)

    run env PATH="$stub:$PATH" \
            AGENT_LIST_SETTINGS_FILE="$FIXTURE" \
            SHOGUN_LOCK_DIR="$TEST_TMPDIR/locks2" \
            WATCHER_DRIFT_EVERY_SEC=999999 \
            DRIFT_INBOX_WRITE=/bin/true \
            WATCHER_SUPERVISOR_MAX_CYCLES=1 \
            __WATCHER_SUPERVISOR_TESTING__=1 \
            timeout 60 bash "$PROJECT_ROOT/scripts/watcher_supervisor.sh"
    [ "$status" -eq 0 ]
    # ★読めておる時に赤を刷るな★= 静かな夜に毎回鳴る門は外される
    if echo "$output" | grep -q "\[UNREADABLE\]"; then return 1; fi
}

@test "T-AL-017: 契約 = rc 3。shell の名札と python の実挙動が割れておらぬこと" {
    # ★rc=3 は二箇所に別々に書かれておる★=
    #   shell 側 `AGENT_LIST_RC_UNREADABLE=3` (呼び手が読む名札) と
    #   python 側 `RC_UNREADABLE = 3` (実際に返る値)。
    # ★片方だけ動かせば、名札と実挙動が黙って割れる★ゆえ、両方を declared と突合する。
    local declared=3

    run env -u AGENT_LIST_SETTINGS_FILE bash -c '
        . "'"$AGENT_LIST_LIB"'"
        printf "%s\n" "$AGENT_LIST_RC_UNREADABLE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$declared" ]      # shell の名札

    # python 側が現に返す値 (読めぬ盤面を撃って観測する)
    _al "$TEST_TMPDIR/does_not_exist.yaml" get_active_ashigaru_agents
    [ "$status" -eq "$declared" ]    # 実挙動
}
