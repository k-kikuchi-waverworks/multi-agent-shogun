#!/usr/bin/env bats
# test_supervisor_legacy_once.bats — cmd_1339 ③: [LEGACY] log warn-once 化の変異試験.
#
# 欠陥 (2026-07-25 実測): supervisor main loop (5s毎) が旧 instance 検知を毎回 log し
# 54行/5分 ≈ 15.5K行/日 の spam。修正 = marker file による episode 単位 warn-once
# (legacy_note_once / legacy_note_clear)。
#
#   T-LEG-001 (after 実測):  新コード 12周 (60s相当) → [LEGACY] は 1 行のみ
#   T-LEG-002 (before 実測): HEAD (修正前) コード 12周 → 12 行 = spam の再現
#                            → before/after = 12行/分 → 1行/episode の機械実証
#   T-LEG-003 (episode 意味論): 解消 (lock 世代へ移行) 後に再発すれば再び 1 行 log
#   T-LEG-004 (変異): marker 作成を殺すと 12周で 12 行 = T-LEG-001 の検査が
#                     修正の不在を本当に検出する証明
#
# 隔離: SHOGUN_LOCK_DIR / cwd を test tmp へ・pgrep/nohup/proc_lock_is_held は stub。
# 本番 supervisor / ledger_guard には一切触れない (awk 関数抽出 = プロセス非接触)。
# 注: start_watcher_if_missing 側の [LEGACY] も同じ legacy_note_once/clear を使うため
#     ledger_guard 経路の検証で helper 契約は両経路をカバーする。

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUPERVISOR_SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/legacy_once.XXXXXX")"
    export SHOGUN_LOCK_DIR="$TEST_TMPDIR/locks"
    mkdir -p "$SHOGUN_LOCK_DIR" "$TEST_TMPDIR/logs"

    # harness: 対象 script から関数を awk 抽出して N 周呼ぶ (本番プロセス非接触)
    cat > "$TEST_TMPDIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
# usage: harness.sh <src_script> <iterations>
set -uo pipefail
cd "$(dirname "$0")"
sup_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
proc_lock_is_held() { return "${MOCK_LOCK_HELD_RC:-1}"; }
pgrep() { return "${MOCK_PGREP_RC:-0}"; }
nohup() { :; }
src="$1"; iters="$2"
extract() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\)"{p=1} p{print} p&&/^\}$/{exit}' "$src"; }
if grep -q '^legacy_note_once()' "$src"; then
    eval "$(extract legacy_note_once)"
    eval "$(extract legacy_note_clear)"
fi
eval "$(extract start_ledger_guard_if_missing)"
for _ in $(seq 1 "$iters"); do start_ledger_guard_if_missing; done
exit 0
HARNESS
    chmod +x "$TEST_TMPDIR/harness.sh"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_legacy_count() {
    # $1 = stderr file
    grep -c "\[LEGACY\]" "$1" || true
}

@test "T-LEG-001 (after): new code logs [LEGACY] exactly once across 12 iterations (60s worth)" {
    bash "$TEST_TMPDIR/harness.sh" "$SUPERVISOR_SCRIPT" 12 2> "$TEST_TMPDIR/err.log"
    [ "$(_legacy_count "$TEST_TMPDIR/err.log")" -eq 1 ]
    # marker が残っている = 次周も抑止される状態
    [ -e "$SHOGUN_LOCK_DIR/legacy_noted_ledger_guard" ]
}

@test "T-LEG-002 (before): pre-fix implementation logs 12 lines in the same harness = spam reproduced" {
    # 修正前実装の忠実複製 (commit 7493543 の start_ledger_guard_if_missing を byte copy)。
    # git HEAD 参照だと commit 後に before が消えて skip になる (SKIP=FAIL 規律) ため
    # fixture として固定する。同一 harness で回して spam を再現 =
    # before/after 実測: 12行/60s相当 → 1行/episode。
    cat > "$TEST_TMPDIR/old_supervisor.sh" <<'OLD'
start_ledger_guard_if_missing() {
    local start_lock="$SHOGUN_LOCK_DIR/start_ledger_guard.lock"
    (
        flock -n 9 || return 0
        if proc_lock_is_held "ledger_guard"; then
            return 0
        fi
        if pgrep -f "scripts/ledger_guard\.sh" >/dev/null 2>&1; then
            sup_log "[LEGACY] ledger_guard: lifetime lock 無しの旧 instance が生存 — 起動せず"
            return 0
        fi
        nohup bash scripts/ledger_guard.sh >> "logs/ledger_guard.log" 2>&1 9>&- 208>&- &
        sup_log "[START] ledger_guard started PID=$!"
    ) 9>"$start_lock"
}
OLD
    bash "$TEST_TMPDIR/harness.sh" "$TEST_TMPDIR/old_supervisor.sh" 12 \
        2> "$TEST_TMPDIR/err_old.log"
    [ "$(_legacy_count "$TEST_TMPDIR/err_old.log")" -eq 12 ]
}

@test "T-LEG-003: episode semantics — resolved then re-detected legacy logs again (1+1)" {
    # episode 1: 旧 instance 検知 → 1 行
    bash "$TEST_TMPDIR/harness.sh" "$SUPERVISOR_SCRIPT" 3 2> "$TEST_TMPDIR/err1.log"
    [ "$(_legacy_count "$TEST_TMPDIR/err1.log")" -eq 1 ]
    # 解消: 契約 lock 世代が保持 (proc_lock_is_held=0) → marker クリア・log 無し
    MOCK_LOCK_HELD_RC=0 bash "$TEST_TMPDIR/harness.sh" "$SUPERVISOR_SCRIPT" 1 \
        2> "$TEST_TMPDIR/err2.log"
    [ "$(_legacy_count "$TEST_TMPDIR/err2.log")" -eq 0 ]
    [ ! -e "$SHOGUN_LOCK_DIR/legacy_noted_ledger_guard" ]
    # episode 2: 再び旧 instance 検知 → 改めて 1 行 (黙りっぱなしにならない)
    bash "$TEST_TMPDIR/harness.sh" "$SUPERVISOR_SCRIPT" 3 2> "$TEST_TMPDIR/err3.log"
    [ "$(_legacy_count "$TEST_TMPDIR/err3.log")" -eq 1 ]
}

@test "T-LEG-004 (mutation): killing the marker write reverts to 12-line spam = check is load-bearing" {
    sed '/: > "\$marker"/d' "$SUPERVISOR_SCRIPT" > "$TEST_TMPDIR/mutated_supervisor.sh"
    # 変異が実際に当たったことを確認 (空振り変異の防止)
    ! grep -q ': > "\$marker"' "$TEST_TMPDIR/mutated_supervisor.sh"
    bash "$TEST_TMPDIR/harness.sh" "$TEST_TMPDIR/mutated_supervisor.sh" 12 \
        2> "$TEST_TMPDIR/err_mut.log"
    [ "$(_legacy_count "$TEST_TMPDIR/err_mut.log")" -eq 12 ]
}
