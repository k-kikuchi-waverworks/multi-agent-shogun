#!/usr/bin/env bats
# test_bats_negation_guard.bats — cmd_1401: ★負の主張が刃を持たぬ形で書かれるのを門で止める★
#
# ★何を止めるか★:
#   bats の test 本文に書いた `! cmd` は ★bash の set -e から明示的に免除される★
#   ("the command's return value is being inverted with !") =
#   ★grep が当たっても (= 出てはならぬ物が現に出ておっても) test は緑のまま★。
#   ★牙が折れたのではない。牙が最初から刃を持っておらなんだ★ — 据えた者も読む者も緑を見て安心する。
#
# ★実測 (2026-07-27・bats 1.13.0)★:
#   NEG-A: `! echo "WARN=x" | grep -q "WARN=x"` を test の途中に置く → ★ok (緑)★
#   NEG-B: 同じ判定を `if …; then return 1; fi` で書く              → ★not ok (赤)★
#   ★repo 全数 (find|xargs で 73 file) に 94 箇所・うち中途 52 箇所が無効であった★。
#   配達層に 50 本 集中 = ★「撃ってはならぬ時に撃っておらぬ」を守る側の主張が丸ごと無効★。
#
# ★末尾に在る 42 本も倒した理由★:
#   末尾の `! cmd` は test の戻り値そのものゆえ【今は】効く。★但し明日 1 行 足された瞬間に死ぬ★=
#   ★死ぬ時に音がせぬ★ (緑のまま)。⇒ 「末尾なら良い」を覚えておける者は居らぬゆえ、形を一つに倒した。
#
# ★正しい書き方★= `if <cmd>; then return 1; fi`
#   (bats が失敗行をそのまま印字するゆえ、診断の言葉を足さずとも何処が落ちたか判る)
#
# 変異登録案 (牙 台帳の単独書き手=六号ゆえ登録は報告経由):
#   MUT-1401-G1: 走査から tests/unit を外す      → T-NEG-001 が【見落とす】= 赤にならぬ形の的
#   MUT-1401-G2: 判定を「末尾は許す」へ緩める    → T-NEG-003 赤

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export SCANNER="$PROJECT_ROOT/scripts/gate_bats_negation.py"
    [ -f "$SCANNER" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/negguard.XXXXXX")"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_py() {
    if [ -x "$PROJECT_ROOT/.venv/bin/python3" ]; then "$PROJECT_ROOT/.venv/bin/python3" "$@";
    else python3 "$@"; fi
}

# ---------------------------------------------------------------------------
# T-NEG-001: ★repo の現況が緑★ = 94 箇所を倒した後の状態を門が是と読む。
# 之が赤くなる時 = 誰かが新しく `! cmd` を書いた時 (本門の主目的)。
# ---------------------------------------------------------------------------
@test "T-NEG-001: the repository currently has zero toothless negations" {
    run _py "$SCANNER" "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK: 刃を持たぬ負の主張は 0 箇所"
    # ★0 を報ずる前の canary★ = 門が現に .bats を読んでおること (走査 0 file の緑を排す)
    echo "$output" | grep -Eq "走査 [1-9][0-9]* file"
}

# ---------------------------------------------------------------------------
# T-NEG-002: ★新しく書けば落ちる★ (書き手の側で落ちる形)。
# ★之が本門の存在理由★ — 規律 (家老 02:12) の機械側の顔。
# ---------------------------------------------------------------------------
@test "T-NEG-002: a newly written mid-body '! cmd' is caught and named with file:line" {
    mkdir -p "$TEST_TMPDIR/tests"
    # ★heredoc を使わぬ★= 行頭 @test を bats 自身が拾うて本 file が其処で切れる (実測)
    printf '%s\n' \
        '@test "someone writes a fresh toothless negation" {' \
        '    output="boom"' \
        '    ! echo "$output" | grep -q "boom"' \
        '    echo "done"' \
        '}' > "$TEST_TMPDIR/tests/offender.bats"
    run _py "$SCANNER" "$TEST_TMPDIR"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "offender.bats:3"
    echo "$output" | grep -q "if .*; then return 1; fi"   # 直し方まで名乗る
}

# ---------------------------------------------------------------------------
# T-NEG-003: ★末尾に書いても落ちる★ = 「末尾なら生きておるゆえ良い」を許さぬ。
# 理由 = ★明日 1 行 足された瞬間に、音もなく死ぬ★ (本夜 52 本が現に其の姿であった)。
# ---------------------------------------------------------------------------
@test "T-NEG-003: a trailing '! cmd' is caught too (today it works, tomorrow it dies silently)" {
    mkdir -p "$TEST_TMPDIR/tests"
    printf '%s\n' \
        '@test "trailing negation — alive today, dead tomorrow" {' \
        '    output="boom"' \
        '    ! echo "$output" | grep -q "boom"' \
        '}' > "$TEST_TMPDIR/tests/trailing.bats"
    run _py "$SCANNER" "$TEST_TMPDIR"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "trailing.bats:3"
}

# ---------------------------------------------------------------------------
# T-NEG-004: ★過剰に締めておらぬ★ (逆向き)。
# `[ ! -f x ]` (test 組込みの否定) と `if cmd; then return 1; fi` は ★現に効く★ゆえ許す。
# 之が無ければ「何でも赤にする門」でも T-NEG-002/003 は緑になる。
# ---------------------------------------------------------------------------
@test "T-NEG-004: '[ ! -f x ]' and the if/return-1 form are NOT flagged (the net is not over-broad)" {
    mkdir -p "$TEST_TMPDIR/tests"
    printf '%s\n' \
        '@test "legit forms" {' \
        '    [ ! -f "/no/such/file" ]' \
        '    [ ! -e "/no/such/dir" ]' \
        '    if echo "x" | grep -q "y"; then return 1; fi' \
        '    echo "ok"' \
        '}' > "$TEST_TMPDIR/tests/legit.bats"
    run _py "$SCANNER" "$TEST_TMPDIR"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK: 刃を持たぬ負の主張は 0 箇所"
}

# ---------------------------------------------------------------------------
# T-NEG-005: ★行の途中の否定 (`A || ! B`) も捕える★。
# 本夜 実測: 此の形も set e の免除に掛かり ★当たっても緑★ であった
# (tests/unit/test_stop_hook.bats:130 が現に其の形で在った)。
# ---------------------------------------------------------------------------
@test "T-NEG-005: inline negation after || is caught (measured to be toothless as well)" {
    mkdir -p "$TEST_TMPDIR/tests"
    # ★否定記号を変数で組む★= 本 file の中に literal を残さぬ (門が己を名指すのを避ける)。
    # ★門は quote の中身を判じられぬ★= 引用符の中の fixture text も同じ形に見えるゆえ
    # (門の限界は scripts/gate_bats_negation.py の注記に明記した)。
    local bang='!'
    printf '%s\n' \
        '@test "inline negation" {' \
        '    output="block"' \
        "    [ -z \"\$output\" ] || $bang echo \"\$output\" | grep -q \"block\"" \
        '    echo "done"' \
        '}' > "$TEST_TMPDIR/tests/inline.bats"
    run _py "$SCANNER" "$TEST_TMPDIR"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "inline.bats:3"
}

# ---------------------------------------------------------------------------
# T-NEG-006: ★第三者の物 (vendored bats-assert/bats-support) は走査せぬ★。
# 彼らは他所の規律で書かれており、我らの門で赤にする筋が無い (CLAUDE.md の線)。
# ---------------------------------------------------------------------------
@test "T-NEG-006: vendored test_helper/bats-* trees are excluded from the sweep" {
    mkdir -p "$TEST_TMPDIR/tests/test_helper/bats-assert/test"
    printf '%s\n' \
        '@test "vendored suite uses its own conventions" {' \
        '    ! true' \
        '    echo "done"' \
        '}' > "$TEST_TMPDIR/tests/test_helper/bats-assert/test/vendor.bats"
    run _py "$SCANNER" "$TEST_TMPDIR"
    [ "$status" -eq 0 ]
}
