#!/usr/bin/env bats
# test_watcher_supervisor.bats — start_watcher_if_missing unit tests
#
# ── cmd_1468 (2026-07-28): 3本が赤だったのを直した。守りは壊れていない ──
#
# 赤の理由は本体ではなくテストの側にあった。cmd_1339 で契約が2つ変わっている。
#
#   (a) start lock の置き場   /tmp/shogun_watcher_start_{agent}.lock
#                           → $SHOGUN_LOCK_DIR/start_{agent}.lock  (scripts/lib/proc_lock.sh)
#   (b) 二重起動の判じ方       pgrep で cmdline を見る
#                           → proc_lock_is_held で watcher 自身の lifetime lock を見る
#                              (pgrep は旧世代 watcher 向けの移行期 fallback へ格下げ)
#
# 旧テストは (a)(b) のどちらも知らなかったので:
#   T-WS-002/004 = SHOGUN_LOCK_DIR が未定義のまま `9>"/start_ashigaru1.lock"` を撃ち、
#                  Permission denied で落ちていた (本体の働きは一度も試されていない)
#   T-WS-003     = 旧 lockfile の綴りを grep しており、綴りが変わった時点で赤になった
#                  ＝ 綴りに釘付けした試験。今は「実際に其の path へ lock が出来るか」を撃つ。
#
# テスト観点:
#   T-WS-001: pane 不在 → rc=0・watcher を起動しない
#   T-WS-002: lifetime lock 保持者あり → 二重起動しない (今の契約)
#   T-WS-003: start lock は $SHOGUN_LOCK_DIR/start_{agent}.lock に出来る
#   T-WS-004: 保持者なし → inbox_watcher が起動される
#   T-WS-005: 旧世代 watcher (lock 無し・pgrep のみ当たる) → 起動しない (移行期 fallback)

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
# WS_SUPERVISOR_SCRIPT = 変異させた写しを撃つための差し込み口。
# 「無い物を確かめる」形の試験 (T-WS-002/005 は launch log が【無い】ことを見る) は、
# 何も走らなくても緑になる。守りを外した写しで撃って赤くなることを確かめられる形にしておく。
#   例: sed '/proc_lock_is_held/,+3d;/pgrep -f/,+3d' scripts/watcher_supervisor.sh > /tmp/mut.sh
#       WS_SUPERVISOR_SCRIPT=/tmp/mut.sh bats tests/unit/test_watcher_supervisor.bats
SUPERVISOR_SCRIPT="${WS_SUPERVISOR_SCRIPT:-$PROJECT_ROOT/scripts/watcher_supervisor.sh}"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/logs"

    # ★lock を本番と同じ場所へ置かない★ = 稼働中の watcher の lock を読んでしまうため。
    # 既定は $HOME/.local/share/multi-agent-shogun/locks で、そこには本物が居る。
    export SHOGUN_LOCK_DIR="$TEST_TMP/locks"
    mkdir -p "$SHOGUN_LOCK_DIR"

    LAUNCH_LOG="$TEST_TMP/watcher_launched.log"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# start_watcher_if_missing の定義だけを取り出して eval する。
# script 末尾の無限 loop を走らせないため、丸ごと source はしない。
# 依存する周辺関数は呼び手側で先に stub しておくこと。
eval_start_fn() {
    eval "$(
        awk '/^start_watcher_if_missing\(\)/{p=1} p{print} /^\}$/{if(p){p=0}}' \
            "$SUPERVISOR_SCRIPT"
    )"
}

# 本体が呼ぶ周辺を、テストが持ち物として持てる形へ差し替える。
stub_common() {
    ensure_inbox_file() { touch "$TEST_TMP/queue/inbox/${1}.yaml"; }
    sup_log() { echo "$*" >> "$TEST_TMP/sup.log"; }
    legacy_note_once() { :; }
    legacy_note_clear() { :; }
    tmux() { echo "codex"; }
    nohup() { echo "launched: $*" >> "$LAUNCH_LOG"; }
}

# ---------------------------------------------------------------------------
# T-WS-001: pane が無ければ rc=0 で、watcher を起動しない
# ---------------------------------------------------------------------------
@test "T-WS-001: pane does not exist returns 0 and does not start watcher" {
    (
        stub_common
        pane_exists() { return 1; }
        proc_lock_is_held() { return 1; }
        pgrep() { return 1; }

        eval_start_fn
        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "$TEST_TMP/logs/ws001.log"
        result=$?

        [ "$result" -eq 0 ]
        [ ! -f "$LAUNCH_LOG" ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-002: lifetime lock を持つ watcher が居れば、二重に起動しない
# ---------------------------------------------------------------------------
@test "T-WS-002: watcher already holding lifetime lock does not start duplicate" {
    (
        stub_common
        pane_exists() { return 0; }
        # ★今の契約はこれ★ = watcher 自身が持つ lock を見る
        proc_lock_is_held() { [ "$1" = "inbox_watcher_ashigaru1" ]; }
        # pgrep は当たらない = lock だけで止まったことを示す
        pgrep() { return 1; }

        eval_start_fn
        start_watcher_if_missing "ashigaru1" "multiagent:agents.1" "$TEST_TMP/logs/ws002.log"

        [ ! -f "$LAUNCH_LOG" ]
    )
}

# ---------------------------------------------------------------------------
# T-WS-003: start lock は $SHOGUN_LOCK_DIR/start_{agent}.lock に出来る
# ---------------------------------------------------------------------------
# 旧テストは script 本文の綴りを grep していた。綴りが変われば、働きが正しくても赤くなる。
# ここでは「呼んだ結果その path に lock file が現れるか」を撃つ。
# 陰性側も併せて撃つ = 他の agent 名の lock は出来ない (path が agent 名で分かれている証)。
@test "T-WS-003: start lock is created under SHOGUN_LOCK_DIR per agent" {
    (
        stub_common
        pane_exists() { return 0; }
        proc_lock_is_held() { return 0; }   # 早期 return させる (lock file は其の前に出来る)
        pgrep() { return 1; }

        eval_start_fn
        start_watcher_if_missing "ashigaru3" "multiagent:agents.3" "$TEST_TMP/logs/ws003.log"
    )

    [ -f "$SHOGUN_LOCK_DIR/start_ashigaru3.lock" ]
    [ ! -e "$SHOGUN_LOCK_DIR/start_ashigaru9.lock" ]
}

# ---------------------------------------------------------------------------
# T-WS-004: 保持者が居なければ inbox_watcher を起動する
# ---------------------------------------------------------------------------
@test "T-WS-004: no existing watcher causes inbox_watcher to be launched" {
    (
        stub_common
        pane_exists() { return 0; }
        proc_lock_is_held() { return 1; }   # lock 保持者なし
        pgrep() { return 1; }               # 旧世代も居ない

        eval_start_fn
        start_watcher_if_missing "ashigaru4" "multiagent:agents.4" "$TEST_TMP/logs/ws004.log"
    )

    [ -f "$LAUNCH_LOG" ]
    grep -q "launched:" "$LAUNCH_LOG"
    grep -q "scripts/inbox_watcher.sh ashigaru4 multiagent:agents.4" "$LAUNCH_LOG"
}

# ---------------------------------------------------------------------------
# T-WS-005: 旧世代 watcher (lock 無し・pgrep のみ当たる) でも起動しない
# ---------------------------------------------------------------------------
# cmd_1339 以前のコードで起動した watcher は lifetime lock を持たない。
# 契約は lock だが、移行期の網として pgrep も残っている。この網が外れると二重起動する。
@test "T-WS-005: legacy watcher without lifetime lock still blocks a duplicate start" {
    (
        stub_common
        pane_exists() { return 0; }
        proc_lock_is_held() { return 1; }   # lock は持っていない (旧世代)
        pgrep() { return 0; }               # cmdline には居る

        eval_start_fn
        start_watcher_if_missing "ashigaru5" "multiagent:agents.5" "$TEST_TMP/logs/ws005.log"
    )

    [ ! -f "$LAUNCH_LOG" ]
}
