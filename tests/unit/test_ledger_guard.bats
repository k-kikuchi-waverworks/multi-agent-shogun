#!/usr/bin/env bats
# test_ledger_guard.bats — cmd_1255 台帳parse自己検証gate ユニット+e2eテスト
#
# 設計正本 plans/cmd_1255_ledger_parse_gate_design.md §5 test観点 (1)-(6) を実証:
#   (1) 正常編集→検証PASS→last_good更新・rollback無し (副作用ゼロ)
#   (2) ★事故再現=半角コロン注入→gate発火→rollback→quarantine→karo警告★
#   (3) 空file/空dict上書き→schema検証でcatch
#   (4) debounce=連続書込を吸収 (e2e で実watcher経由)
#   (5) 起動時FAIL→警告のみ (rollbackしない)
#   (6) flock競合=検証中の再編集が失われない (run_guard_check_locked 経由)
#
# ★全て tmp copy harness = 実台帳 queue/shogun_to_karo.yaml には一切触れない★

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ledger_guard.XXXXXX")"
    export TEST_TMPDIR
    export QUEUE_DIR="$TEST_TMPDIR/queue"
    mkdir -p "$QUEUE_DIR/archive"

    # ─── ledger_guard.sh が参照する path を tmp へ注入 (実台帳非接触) ───
    export LEDGER_FILE="$QUEUE_DIR/shogun_to_karo.yaml"
    export LAST_GOOD_FILE="$QUEUE_DIR/.shogun_to_karo.last_good"
    export QUARANTINE_DIR="$QUEUE_DIR/archive"
    export LEDGER_LOCK="$LEDGER_FILE.lock"
    export LEDGER_GUARD_LOG="$TEST_TMPDIR/ledger_guard.log"

    # ─── cmd_1468: lifetime lock も tmp へ隔離する ───
    # cmd_1339 で ledger_guard は proc_lock による二重起動防止を持った。
    # lock の置き場は既定で $HOME/.local/share/multi-agent-shogun/locks = 本番と同じ場所で、
    # ★本番の ledger_guard が常に稼働しているため、テストが起動した instance は
    #   「既に稼働中」と判じて即 退場していた★。
    # 退場した instance は last_good を作らないので、(4) は「守りが壊れた」ではなく
    # 「テストが本番の生きた状態を読んでいた」ために赤くなっていた (2026-07-28 08:43 実測)。
    export SHOGUN_LOCK_DIR="$TEST_TMPDIR/locks"
    mkdir -p "$SHOGUN_LOCK_DIR"
    export LEDGER_VALIDATOR="$PROJECT_ROOT/scripts/ledger_validate.py"
    export SCRIPT_DIR="$PROJECT_ROOT"

    # python: venv優先、無ければsystem
    export LEDGER_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$LEDGER_PYTHON" ] || export LEDGER_PYTHON="python3"

    # ─── karo警告emit shim = 実inbox非接触。呼ばれた引数を記録 ───
    export KARO_WARN_LOG="$TEST_TMPDIR/karo_warn.log"
    cat > "$TEST_TMPDIR/inbox_shim.sh" <<SHIM
#!/usr/bin/env bash
# args: <target> <content> <type> <from>
printf '%s|%s|%s\n' "\$1" "\$3" "\$4" >> "$KARO_WARN_LOG"
SHIM
    chmod +x "$TEST_TMPDIR/inbox_shim.sh"
    export LEDGER_GUARD_INBOX_WRITE="$TEST_TMPDIR/inbox_shim.sh"

    # 関数のみload (main loop skip)
    export __LEDGER_GUARD_TESTING__=1
    # shellcheck source=/dev/null
    source "$PROJECT_ROOT/scripts/ledger_guard.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_valid_ledger() {
    printf 'commands:\n- id: cmd_test1\n  status: pending\n  evidence: |\n    正常な block scalar 自由文\n- id: cmd_test2\n  status: done\n' > "$LEDGER_FILE"
}

# ───────────────────────────────────────────────────────────
# (1) 正常編集 → PASS → last_good更新 / rollback無し / 副作用ゼロ
# ───────────────────────────────────────────────────────────
@test "(1) valid ledger: PASS updates last_good, ledger untouched (zero side-effect)" {
    write_valid_ledger
    local before
    before="$(cat "$LEDGER_FILE")"

    run run_guard_check
    assert_success

    # last_good が作られ、台帳と一致
    [ -f "$LAST_GOOD_FILE" ]
    assert_equal "$(cat "$LAST_GOOD_FILE")" "$before"
    # ★台帳は1バイトも変わっていない (正しい編集を消さない)★
    assert_equal "$(cat "$LEDGER_FILE")" "$before"
    # quarantine が作られていない
    run bash -c "ls '$QUARANTINE_DIR'/corrupt_* 2>/dev/null"
    assert_failure
    # karo警告が飛んでいない
    [ ! -s "$KARO_WARN_LOG" ] || [ ! -f "$KARO_WARN_LOG" ]
}

# ───────────────────────────────────────────────────────────
# (2) ★事故再現★ 半角コロン注入 → 発火 → rollback → quarantine → karo警告
# ───────────────────────────────────────────────────────────
@test "(2) accident repro: half-colon injection fires gate, rollback+quarantine+warning" {
    write_valid_ledger
    # まず正常版で last_good を確立
    run run_guard_check
    assert_success
    local good
    good="$(cat "$LAST_GOOD_FILE")"

    # ★事故そのもの=evidence自由文に半角コロン+空白を混入 (YAML mapping誤認→parse失敗)★
    printf 'commands:\n- id: cmd_test1\n  evidence: foo: bar baz\n  status: pending\n' > "$LEDGER_FILE"

    run run_guard_check
    assert_failure

    # 台帳が last_good に巻き戻っている
    assert_equal "$(cat "$LEDGER_FILE")" "$good"
    # 巻き戻った台帳は再検証で PASS する
    run validate_ledger "$LEDGER_FILE"
    assert_success
    # quarantine に破損版が非破壊保存されている (半角コロン混入版が残る)
    run bash -c "ls '$QUARANTINE_DIR'/corrupt_shogun_to_karo_*.yaml"
    assert_success
    run bash -c "grep -l 'evidence: foo: bar baz' '$QUARANTINE_DIR'/corrupt_shogun_to_karo_*.yaml"
    assert_success
    # karo に警告 (type=error, from=ledger_guard) が emit されている
    run grep -F 'karo|error|ledger_guard' "$KARO_WARN_LOG"
    assert_success
}

# ───────────────────────────────────────────────────────────
# (3) 空dict / 空file 上書き → schema検証でcatch → rollback
# ───────────────────────────────────────────────────────────
@test "(3) empty-dict overwrite is caught by schema (safe_load alone would pass)" {
    write_valid_ledger
    run run_guard_check
    assert_success
    local good
    good="$(cat "$LAST_GOOD_FILE")"

    printf '{}\n' > "$LEDGER_FILE"
    run run_guard_check
    assert_failure
    assert_equal "$(cat "$LEDGER_FILE")" "$good"
}

@test "(3b) empty-file overwrite is caught and rolled back" {
    write_valid_ledger
    run run_guard_check
    assert_success
    local good
    good="$(cat "$LAST_GOOD_FILE")"

    : > "$LEDGER_FILE"
    run run_guard_check
    assert_failure
    assert_equal "$(cat "$LEDGER_FILE")" "$good"
}

# ───────────────────────────────────────────────────────────
# (5) 起動時FAIL → 警告のみ・rollbackしない (安全側)
# ───────────────────────────────────────────────────────────
@test "(5) startup FAIL: warn only, NO rollback (never clobber existing)" {
    # last_good 不在の状態で既存破損台帳が在る
    printf 'commands:\n- id: cmd_x\n  evidence: foo: bar baz\n' > "$LEDGER_FILE"
    local corrupt
    corrupt="$(cat "$LEDGER_FILE")"

    run startup_check
    assert_failure

    # ★台帳は起動時に一切変わらない (勝手に古い版へ巻き戻さない)★
    assert_equal "$(cat "$LEDGER_FILE")" "$corrupt"
    # last_good は作られない (PASSしていないため)
    [ ! -f "$LAST_GOOD_FILE" ]
    # 警告のみ emit
    run grep -F 'karo|error|ledger_guard' "$KARO_WARN_LOG"
    assert_success
}

@test "(5b) startup PASS: last_good initialized, no warning" {
    write_valid_ledger
    run startup_check
    assert_success
    [ -f "$LAST_GOOD_FILE" ]
    [ ! -s "$KARO_WARN_LOG" ] || [ ! -f "$KARO_WARN_LOG" ]
}

# no last_good → rollback せず警告のみ (安全側の run_guard_check 経路)
@test "(2b) FAIL with no last_good: no rollback, warn only" {
    printf 'commands:\n- id: cmd_x\n  evidence: foo: bar baz\n' > "$LEDGER_FILE"
    local corrupt
    corrupt="$(cat "$LEDGER_FILE")"
    [ ! -f "$LAST_GOOD_FILE" ]

    run run_guard_check
    assert_failure
    # last_good が無いので rollback されず現状維持 (破損版を消さない=安全側)
    assert_equal "$(cat "$LEDGER_FILE")" "$corrupt"
    run grep -F 'karo|error|ledger_guard' "$KARO_WARN_LOG"
    assert_success
}

# ───────────────────────────────────────────────────────────
# (6) flock wrapper 経由でも同じ挙動 (atomic整合の経路確認)
# ───────────────────────────────────────────────────────────
@test "(6) run_guard_check_locked: flock path produces same rollback behavior" {
    write_valid_ledger
    run run_guard_check_locked
    assert_success
    local good
    good="$(cat "$LAST_GOOD_FILE")"

    printf 'commands:\n- id: cmd_x\n  evidence: foo: bar baz\n' > "$LEDGER_FILE"
    run run_guard_check_locked
    assert_failure
    assert_equal "$(cat "$LEDGER_FILE")" "$good"
}

# ───────────────────────────────────────────────────────────
# validator CLI: 手動検証コマンドとしての exit code 契約
# ───────────────────────────────────────────────────────────
@test "validator CLI: real ledger PASSes (id or legacy cmd_id accepted)" {
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$PROJECT_ROOT/queue/shogun_to_karo.yaml"
    assert_success
}

@test "validator CLI: missing identifier (no id and no cmd_id) FAILs" {
    printf 'commands:\n- status: pending\n' > "$LEDGER_FILE"
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$LEDGER_FILE"
    assert_failure
}

@test "validator CLI: legacy cmd_id-only entry PASSes" {
    printf 'commands:\n- cmd_id: cmd_639\n  type: progress_update\n  status: dispatched\n' > "$LEDGER_FILE"
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$LEDGER_FILE"
    assert_success
}

# ───────────────────────────────────────────────────────────
# cmd_1341: id一意性 + entry内重複key検知
# (★これらのtestは検査を外すと必ずFAILする=検査が空回りしていない恒久証明★)
# ───────────────────────────────────────────────────────────
@test "validator CLI (cmd_1341): duplicate entry id FAILs (B-N1 採番衝突検知)" {
    printf 'commands:\n- id: cmd_a1\n  status: pending\n- id: cmd_a2\n  status: done\n- id: cmd_a1\n  status: done\n' > "$LEDGER_FILE"
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$LEDGER_FILE"
    assert_failure
    assert_output --partial "duplicate entry id"
}

@test "validator CLI (cmd_1341): duplicate mapping key within entry FAILs (後勝ちの黙殺検知)" {
    printf 'commands:\n- id: cmd_a1\n  karo_progress: first\n  karo_progress: second\n' > "$LEDGER_FILE"
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$LEDGER_FILE"
    assert_failure
    assert_output --partial "duplicate mapping key"
}

@test "validator CLI (cmd_1341): duplicate key in NESTED mapping also FAILs" {
    printf 'commands:\n- id: cmd_a1\n  status: pending\n  detail:\n    note: x\n    note: y\n' > "$LEDGER_FILE"
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$LEDGER_FILE"
    assert_failure
    assert_output --partial "duplicate mapping key"
}

@test "validator CLI (cmd_1341): legacy cmd_id duplicates remain PERMITTED (参照fieldゆえ対象外)" {
    # 実台帳に cmd_640×2 (cmd_id同士) と cmd_611 (id∩cmd_id) が正当に実在する。
    # これを FAIL にすると ledger_guard が false rollback を撃つ (schema緩和根拠と同じ)。
    printf 'commands:\n- id: cmd_640\n  status: done\n- cmd_id: cmd_640\n  type: progress_update\n- cmd_id: cmd_640\n  type: progress_update\n' > "$LEDGER_FILE"
    run "$LEDGER_PYTHON" "$PROJECT_ROOT/scripts/ledger_validate.py" "$LEDGER_FILE"
    assert_success
}

# ───────────────────────────────────────────────────────────
# (4) e2e: 実watcher (inotifywait+debounce+flock) で事故再現
# ───────────────────────────────────────────────────────────
@test "(4) e2e: live watcher detects corruption via inotify+debounce → auto rollback" {
    command -v inotifywait >/dev/null || skip "inotifywait not available"
    write_valid_ledger

    # 実watcher を tmp path 注入で起動 (debounce短縮)
    # ★setup() の __LEDGER_GUARD_TESTING__=1 を解除しないと main_loop がskipされる★
    __LEDGER_GUARD_TESTING__=0 \
    LEDGER_DEBOUNCE_SEC=1 \
    LEDGER_FILE="$LEDGER_FILE" LAST_GOOD_FILE="$LAST_GOOD_FILE" \
    QUARANTINE_DIR="$QUARANTINE_DIR" LEDGER_LOCK="$LEDGER_LOCK" \
    LEDGER_GUARD_LOG="$LEDGER_GUARD_LOG" LEDGER_VALIDATOR="$LEDGER_VALIDATOR" \
    LEDGER_PYTHON="$LEDGER_PYTHON" LEDGER_GUARD_INBOX_WRITE="$LEDGER_GUARD_INBOX_WRITE" \
    SCRIPT_DIR="$PROJECT_ROOT" \
    bash "$PROJECT_ROOT/scripts/ledger_guard.sh" &
    local guard_pid=$!

    # startup_check が last_good を初期化するまで待つ (最大10s)
    local i
    for i in $(seq 1 20); do
        [ -f "$LAST_GOOD_FILE" ] && break
        sleep 0.5
    done
    [ -f "$LAST_GOOD_FILE" ]
    local good
    good="$(cat "$LAST_GOOD_FILE")"

    # ★cmd_1468: last_good の出現を「見張りが立った」の代わりに使わぬ★
    #   main_loop は startup_check (= last_good を作る) の【後】に inotifywait を起動する。
    #   ゆえに last_good だけを待って台帳を壊すと、まだ見張りが立っておらぬ窓へ落ちる。
    #   落ちた事故は 30秒の安全網 (inotifywait -t 30) まで拾われず、此の試験は15秒しか待たぬので
    #   ★守りは正しいのに赤くなる★ (2026-07-28 18:25 実測: 窓は約 0.14 秒。全数走行の負荷で広がる)。
    #   ⇒ ★見張りの process が現に立つまで待つ★。親 pid と process 名で当てるので
    #      此の待ち手が己を拾うことはない (条C)。
    for i in $(seq 1 40); do
        pgrep -P "$guard_pid" -x inotifywait >/dev/null 2>&1 && break
        sleep 0.25
    done
    pgrep -P "$guard_pid" -x inotifywait >/dev/null 2>&1
    # process が立ってから inotify_add_watch が済むまでの僅かな隙を埋める
    sleep 0.5

    # ★半角コロン混入 (atomic rename で書込=Editのidiomに近い)★
    printf 'commands:\n- id: cmd_x\n  evidence: foo: bar baz\n  status: pending\n' > "$LEDGER_FILE.tmp"
    mv "$LEDGER_FILE.tmp" "$LEDGER_FILE"

    # watcher が rollback するまで待つ (quarantine出現で判定・最大15s)
    local recovered=0
    for i in $(seq 1 30); do
        if ls "$QUARANTINE_DIR"/corrupt_shogun_to_karo_*.yaml >/dev/null 2>&1; then
            recovered=1
            break
        fi
        sleep 0.5
    done

    kill "$guard_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true

    [ "$recovered" -eq 1 ]
    # 台帳は自動で last_good に復旧している
    assert_equal "$(cat "$LEDGER_FILE")" "$good"
    run validate_ledger "$LEDGER_FILE"
    assert_success
}

# ───────────────────────────────────────────────────────────
# (4b) cmd_1468: 陰性側 — lock が既に取られていれば watcher は退場する
# ───────────────────────────────────────────────────────────
# (4) の赤は「守りが壊れた」ではなく「テストが本番の lock を読んでいた」ためだった。
# 上の setup で lock を tmp へ隔離したが、★隔離しただけでは
# 「lock が効いているから緑なのか、lock を一度も見ていないから緑なのか」が区別できない★。
# そこで陰性側を隣へ置く = lock を先に握った状態で起動し、退場することを撃つ。
# これが赤くなる時は、二重起動防止そのものが死んでいる。
@test "(4b) e2e: lifetime lock already held → guard exits without touching last_good" {
    command -v inotifywait >/dev/null || skip "inotifywait not available"
    write_valid_ledger

    # 一体目 = 本物の ledger_guard を起動して lock を握らせる
    __LEDGER_GUARD_TESTING__=0 \
    LEDGER_DEBOUNCE_SEC=1 \
    LEDGER_FILE="$LEDGER_FILE" LAST_GOOD_FILE="$LAST_GOOD_FILE" \
    QUARANTINE_DIR="$QUARANTINE_DIR" LEDGER_LOCK="$LEDGER_LOCK" \
    LEDGER_GUARD_LOG="$LEDGER_GUARD_LOG" LEDGER_VALIDATOR="$LEDGER_VALIDATOR" \
    LEDGER_PYTHON="$LEDGER_PYTHON" LEDGER_GUARD_INBOX_WRITE="$LEDGER_GUARD_INBOX_WRITE" \
    SCRIPT_DIR="$PROJECT_ROOT" SHOGUN_LOCK_DIR="$SHOGUN_LOCK_DIR" \
    bash "$PROJECT_ROOT/scripts/ledger_guard.sh" >/dev/null 2>&1 &
    local holder_pid=$!

    # ★lock が実際に握られたことを確かめてから二体目を撃つ★
    # 握られる前に撃つと、二体目は普通に起動して緑になり、陰性側が意味を失う。
    # shellcheck source=lib/proc_lock.sh
    source "$PROJECT_ROOT/scripts/lib/proc_lock.sh"
    local i held=0
    for i in $(seq 1 40); do
        if proc_lock_is_held "ledger_guard"; then held=1; break; fi
        sleep 0.25
    done
    [ "$held" -eq 1 ]

    # 二体目が退場する所を見たいので、last_good は一体目が作った物を消しておく
    rm -f "$LAST_GOOD_FILE"

    __LEDGER_GUARD_TESTING__=0 \
    LEDGER_DEBOUNCE_SEC=1 \
    LEDGER_FILE="$LEDGER_FILE" LAST_GOOD_FILE="$LAST_GOOD_FILE" \
    QUARANTINE_DIR="$QUARANTINE_DIR" LEDGER_LOCK="$LEDGER_LOCK" \
    LEDGER_GUARD_LOG="$LEDGER_GUARD_LOG" LEDGER_VALIDATOR="$LEDGER_VALIDATOR" \
    LEDGER_PYTHON="$LEDGER_PYTHON" LEDGER_GUARD_INBOX_WRITE="$LEDGER_GUARD_INBOX_WRITE" \
    SCRIPT_DIR="$PROJECT_ROOT" SHOGUN_LOCK_DIR="$SHOGUN_LOCK_DIR" \
    run bash "$PROJECT_ROOT/scripts/ledger_guard.sh"

    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true

    assert_success                        # 退場は正常終了 (rc=0)
    assert_output --partial "DUPLICATE"   # 退場したと名乗っている
    [ ! -f "$LAST_GOOD_FILE" ]            # 退場した instance は last_good を作らない
}
