#!/usr/bin/env bats
# test_pane_cli_liveness.bats — cmd_1418
#
# 何を守る試験か:
#   pane で CLI プロセスが現に動いているかを判定する口 (lib/pane_cli_liveness.sh)。
#   2026-07-27 12:25、足軽五号の claude が落ちて pane が素の bash に戻った。
#   そこへ nudge が送られ、bash がそれをコマンドとして食った。
#   点呼は「claude 稼働中」と緑を返していた。実体を見る口が一つも無かった。
#
# 試験は本物の tmux セッションを使う。使い捨ての名前で建て、必ず畳む。
# 稼働中の multiagent セッションには一切 触れない。
#
# 試験 ID:
#   T-PCL-001  素の bash だけの pane            → dead (rc=1)   ← 本件の穴
#   T-PCL-002  pane 自身が CLI に化けた形        → alive (rc=0)
#   T-PCL-003  子として CLI が居る形             → alive (rc=0)
#   T-PCL-004  孫として CLI が居る形             → alive (rc=0)
#   T-PCL-005  CLI は居るが札と違う              → mismatch (rc=3)
#   T-PCL-006  無い pane                         → no_pane (rc=2)
#   T-PCL-007  無い pane を「現在の pane」で誤魔化さない (退行防止)
#   T-PCL-008  実行ファイル名の取り出し (純関数)
#   T-PCL-009  CLI ごとの実行ファイル名の対応表
#   T-PCL-010  判定語 → 表示ラベル

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export LIB="$PROJECT_ROOT/lib/pane_cli_liveness.sh"
    [ -f "$LIB" ] || return 1
    command -v tmux >/dev/null || return 1
}

setup() {
    SESSION="pcl_$$_${BATS_TEST_NUMBER}"
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    tmux new-session -d -s "$SESSION" -n w bash
    PANE="$SESSION:w.0"
    # pane の shell が上がるまで待つ
    _wait_for_verdict "$PANE" dead 50
}

teardown() {
    [ -n "${SESSION:-}" ] && tmux kill-session -t "$SESSION" 2>/dev/null
    return 0
}

# _verdict <pane> [expected_cli] → 判定語のみ
_verdict() {
    bash -c "source '$LIB'; pane_cli_liveness_detail '$1' '${2:-}'" 2>/dev/null | cut -f1
}

# _rc <pane> [expected_cli] → 終了コード
_rc() {
    bash -c "source '$LIB'; pane_cli_liveness_detail '$1' '${2:-}' >/dev/null"
    echo $?
}

# _wait_for_verdict <pane> <verdict> <tries> — 100ms 刻みで待つ
_wait_for_verdict() {
    local pane="$1" want="$2" tries="${3:-50}" i
    for (( i = 0; i < tries; i++ )); do
        [ "$(_verdict "$pane")" = "$want" ] && return 0
        command sleep 0.1
    done
    return 1
}

# --- T-PCL-001: 本件の穴そのもの ---

@test "T-PCL-001: 素の bash だけの pane は dead" {
    run _verdict "$PANE"
    [ "$output" = "dead" ]
    run _rc "$PANE"
    [ "$output" = "1" ]
}

@test "T-PCL-001b: dead の時は証拠として pane の第一プロセスの argv を出す" {
    run bash -c "source '$LIB'; pane_cli_liveness_detail '$PANE'"
    [[ "$output" == *"bash"* ]]
}

# --- T-PCL-002〜004: CLI が居る三つの形 ---

@test "T-PCL-002: pane 自身が CLI に化けた形は alive" {
    tmux send-keys -t "$PANE" 'exec -a claude /bin/sleep 300' Enter
    _wait_for_verdict "$PANE" alive 50
    run _verdict "$PANE"
    [ "$output" = "alive" ]
    run _rc "$PANE"
    [ "$output" = "0" ]
}

@test "T-PCL-003: 子として CLI が居る形は alive" {
    tmux send-keys -t "$PANE" 'bash -c "exec -a claude /bin/sleep 300; true"' Enter
    _wait_for_verdict "$PANE" alive 50
    run _verdict "$PANE"
    [ "$output" = "alive" ]
}

@test "T-PCL-004: 孫として CLI が居る形も alive (子だけ見る実装では落ちる)" {
    tmux send-keys -t "$PANE" 'bash -c "bash -c \"exec -a claude /bin/sleep 300\"; true"' Enter
    _wait_for_verdict "$PANE" alive 50
    run _verdict "$PANE"
    [ "$output" = "alive" ]
    # 本当に孫であることを確かめる (子だとこの試験は T-PCL-003 の重複になる)
    local pane_pid child
    pane_pid=$(tmux display-message -t "$PANE" -p '#{pane_pid}')
    child=$(pgrep -P "$pane_pid" | head -1)
    run pgrep -P "$child"
    [ "$status" -eq 0 ]
}

# --- T-PCL-005: 札と実体の食い違い ---

@test "T-PCL-005: claude が居る pane を codex 期待で見ると mismatch" {
    tmux send-keys -t "$PANE" 'exec -a claude /bin/sleep 300' Enter
    _wait_for_verdict "$PANE" alive 50
    run _verdict "$PANE" codex
    [ "$output" = "mismatch" ]
    run _rc "$PANE" codex
    [ "$output" = "3" ]
}

# --- T-PCL-006/007: 無い pane ---

@test "T-PCL-006: 無い pane は no_pane" {
    run _verdict "$SESSION:w.99"
    [ "$output" = "no_pane" ]
    run _rc "$SESSION:w.99"
    [ "$output" = "2" ]
}

@test "T-PCL-007: 無い pane を現在の pane で誤魔化さない (退行防止)" {
    # tmux display-message は宛先が無い時に黙って現在の pane へ落ちる。
    # 存在確認を list-panes で行わないと、無い pane が alive を返す。
    run _verdict "nosuchsession_pcl:0"
    [ "$output" = "no_pane" ]
}

# --- T-PCL-008: 実行ファイル名の取り出し (プロセス不要の純関数) ---

@test "T-PCL-008: 実行ファイル名の取り出し" {
    run bash -c "source '$LIB'; _pcl_binary_name '/usr/bin/claude --model x'"
    [ "$output" = "claude" ]

    run bash -c "source '$LIB'; _pcl_binary_name 'claude'"
    [ "$output" = "claude" ]

    # node 噛ませ (node /path/to/claude.js …) も claude と読む
    run bash -c "source '$LIB'; _pcl_binary_name '/usr/bin/node /opt/n/claude.js --model x'"
    [ "$output" = "claude" ]

    run bash -c "source '$LIB'; _pcl_binary_name 'node.exe C:/x/codex --search'"
    [ "$output" = "codex" ]

    run bash -c "source '$LIB'; _pcl_binary_name '-bash'"
    [ "$output" = "-bash" ]
}

# --- T-PCL-009: 対応表 ---

@test "T-PCL-009: CLI ごとの実行ファイル名" {
    run bash -c "source '$LIB'; pane_cli_expected_binaries claude"
    [ "$output" = "claude" ]
    run bash -c "source '$LIB'; pane_cli_expected_binaries cursor"
    [ "$output" = "cursor-agent agent" ]
    run bash -c "source '$LIB'; pane_cli_expected_binaries antigravity"
    [ "$output" = "agy" ]
    # 知らぬ CLI は空 (= 何にも当たらぬ ⇒ dead 側へ倒れる)
    run bash -c "source '$LIB'; pane_cli_expected_binaries nosuchcli"
    [ "$output" = "" ]
}

# --- T-PCL-010: 表示ラベル ---

@test "T-PCL-010: 判定語から表示ラベル" {
    run bash -c "source '$LIB'; pane_cli_liveness_label alive"
    [ "$output" = "生存" ]
    run bash -c "source '$LIB'; pane_cli_liveness_label dead"
    [ "$output" = "落ち" ]
    run bash -c "source '$LIB'; pane_cli_liveness_label mismatch"
    [ "$output" = "別CLI" ]
    run bash -c "source '$LIB'; pane_cli_liveness_label no_pane en"
    [ "$output" = "NO-PANE" ]
}

# --- T-PCL-011: 一巡だけ読む形でも同じ答えになる ---

@test "T-PCL-011: snapshot on でも判定は変わらない" {
    tmux send-keys -t "$PANE" 'exec -a claude /bin/sleep 300' Enter
    _wait_for_verdict "$PANE" alive 50
    run bash -c "source '$LIB'; pane_cli_liveness_snapshot on; pane_cli_liveness_check '$PANE'"
    [ "$output" = "alive" ]
}
