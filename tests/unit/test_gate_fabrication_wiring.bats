#!/usr/bin/env bats
# test_gate_fabrication_wiring.bats — ★捏造の門 (K-17) に与えた【呼ぶ者】を機械が縛る★ (cmd_1413 (c))
#
# ★何ゆえ此の試験が在るか (軍師二号 12:26 実測)★:
#   ★.git/hooks 0 本 / GHA で eval を呼ぶ物 0 本 / fabrication_probe の綴りを持つ file 5 本は
#   牙台帳 2 + 対応表 1 + 稿 = ★★走らせる script 0 本★★★
#   = ★条文は在るが走っておらぬ = 「門が在る」と読ませておった★
#   ⇒ 呼び口を朝の門へ据えた。★而して「据えた」だけでは、明日 消えても音がせぬ★
#   ⇒ ★ゆえに配線そのものへ牙を立てる★ (cmd_1382 の census 配線と同じ作法)。
#
# ★作法 (本日の族を悉く当てる)★:
#   (a)★梯子を書き写さぬ★= 判定の実体は ★gate_nightly.sh から現物を抜いて eval する★
#   (b)★canary を先に撃つ★= 抜き出しが空でない・越境しておらぬ事を T-FB-000 が縛る
#   (c)★bare `!` を使わぬ★ (cmd_1401) = 判定は `if <cmd>; then return 1; fi` の形
#   (d)★現物の probe は撃たぬ★= 此処で測るのは【配線】ゆえ、rc と札を選べる偽の道具で撃つ
#
# 契約:
#   T-FB-000 canary : FAB block と run_reporter が現物から抜ける (越境も見る)
#   T-FB-001 : ★corpus が 1 束も見えぬ★ → rc=2 + 「撃てなんだ」と名乗る (★黙って飛ばさぬ★)
#   T-FB-002 : ★札 [射程] を出さぬ道具★ → rc=2 (★rc=0 でも緑にせぬ★)
#   T-FB-003 : ★札つき rc=1 (RED)★ → fab_rc=1 かつ ★fab_gate=0 (既定は門へ入れぬ)★ + 警報へ載せる旨を刷る
#   T-FB-004 : ★GATE_FAB_STRICT=1★ → fab_gate=1 (号令が下れば門へ入る)
#   T-FB-005 : ★母数を刷る★= 走査した束の数を毎朝 名乗る (0 束と N 束を分ける)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_nightly.sh"
    [ -f "$GATE" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/fabwire.XXXXXX")"
    export CORPUS_DIR="$TEST_TMPDIR/corpus"
    mkdir -p "$CORPUS_DIR"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ★現物から抜く★ — 書き写さぬ。抜けねば空が返り、T-FB-000 が之を赤で名指す。
fn_run_reporter() { sed -n '/^run_reporter() {/,/^}/p' "$GATE"; }
fab_block()       { sed -n '/^FAB_STRICT=/,/^verdict() {/p' "$GATE" | sed '$d'; }

# ★札と rc を選べる偽の道具★ (現物の probe は撃たぬ = 此処で測るのは配線ゆえ)
make_tool() { # $1=path $2=banner $3=rc
    printf '#!/usr/bin/env python3\nimport sys\nprint("%s ここに名乗りが出る")\nsys.exit(%s)\n' "$2" "$3" > "$1"
    chmod +x "$1"
}

# 現物の block を、偽の道具と偽の corpus の上で走らせる
run_block() { # env は呼び手が渡す
    bash -c "set -u
$(fn_run_reporter)
$(fab_block)
echo \"FAB_RC=\$fab_rc FAB_GATE=\$fab_gate\"" 2>&1
}

@test "T-FB-000 canary: FAB block と run_reporter が現物から抜ける (越境も見る)" {
    run fn_run_reporter
    [ "$status" -eq 0 ]
    if [ "$(printf '%s\n' "$output" | wc -l)" -lt 5 ]; then return 1; fi
    printf '%s' "$output" | grep -qF 'UNDETERMINED'

    run fab_block
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'FAB_STRICT'
    printf '%s' "$output" | grep -qF '[射程]'
    printf '%s' "$output" | grep -qF 'fab_gate'
    # ★越境の証★= verdict() の中身や inbox_write が混ざっておらぬこと
    if printf '%s' "$output" | grep -qF 'inbox_write'; then return 1; fi
    if printf '%s' "$output" | grep -qF 'echo PASS'; then return 1; fi
}

@test "T-FB-001: corpus が 1 束も見えぬ → rc=2 + 「撃てなんだ」と名乗る" {
    make_tool "$TEST_TMPDIR/probe.py" "[射程]" 0
    export GATE_FAB_PROBE="$TEST_TMPDIR/probe.py"
    export GATE_FAB_CORPUS_DIR="$TEST_TMPDIR/no_such_dir"
    run run_block
    printf '%s' "$output" | grep -qF 'FAB_RC=2'
    printf '%s' "$output" | grep -qF '撃てなんだ'
    # ★測れなんだ朝も門は落とさぬ (既定)★
    printf '%s' "$output" | grep -qF 'FAB_GATE=0'
}

@test "T-FB-002: 札 [射程] を出さぬ道具 → rc=2 (rc=0 でも緑にせぬ)" {
    make_tool "$TEST_TMPDIR/probe.py" "[別の綴り]" 0
    : > "$CORPUS_DIR/koi_core_batch1.jsonl"
    export GATE_FAB_PROBE="$TEST_TMPDIR/probe.py"
    export GATE_FAB_CORPUS_DIR="$CORPUS_DIR"
    run run_block
    printf '%s' "$output" | grep -qF 'FAB_RC=2'
    printf '%s' "$output" | grep -qF '1行も出さなんだ'
}

@test "T-FB-003: 札つき rc=1 (RED) → fab_rc=1 だが既定では門へ入れぬ" {
    make_tool "$TEST_TMPDIR/probe.py" "[射程]" 1
    : > "$CORPUS_DIR/koi_core_batch1.jsonl"
    export GATE_FAB_PROBE="$TEST_TMPDIR/probe.py"
    export GATE_FAB_CORPUS_DIR="$CORPUS_DIR"
    run run_block
    printf '%s' "$output" | grep -qF 'FAB_RC=1'
    printf '%s' "$output" | grep -qF 'FAB_GATE=0'
    # ★門は落とさぬが黙らぬ★= 家老の警報へ載せる旨を其の場で申す
    printf '%s' "$output" | grep -qF '家老への警報には載せる'
}

@test "T-FB-004: GATE_FAB_STRICT=1 → 門へ入る (号令が下った時のみ)" {
    make_tool "$TEST_TMPDIR/probe.py" "[射程]" 1
    : > "$CORPUS_DIR/koi_core_batch1.jsonl"
    export GATE_FAB_PROBE="$TEST_TMPDIR/probe.py"
    export GATE_FAB_CORPUS_DIR="$CORPUS_DIR"
    export GATE_FAB_STRICT=1
    run run_block
    printf '%s' "$output" | grep -qF 'FAB_RC=1'
    printf '%s' "$output" | grep -qF 'FAB_GATE=1'
}

@test "T-FB-005: 母数を刷る (0 束と N 束を分ける)" {
    make_tool "$TEST_TMPDIR/probe.py" "[射程]" 0
    : > "$CORPUS_DIR/koi_core_batch1.jsonl"
    : > "$CORPUS_DIR/koi_core_batch2.jsonl"
    export GATE_FAB_PROBE="$TEST_TMPDIR/probe.py"
    export GATE_FAB_CORPUS_DIR="$CORPUS_DIR"
    run run_block
    printf '%s' "$output" | grep -qF '走査 2 束'
    printf '%s' "$output" | grep -qF 'FAB_RC=0'
}
