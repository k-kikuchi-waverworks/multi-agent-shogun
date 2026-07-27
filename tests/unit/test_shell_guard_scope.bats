#!/usr/bin/env bats
# test_shell_guard_scope.bats — cmd_1414: ★関所は登録された道具しか見ておらなんだ★
#
# ■ 守っている物
#   関所 (scripts/shell_expansion_guard.py) は Bash の command 文字列を全部 見るが、
#   ★中身を検めるのは表 (GUARDED_TOOLS) に載る道具を見つけた時だけ★であった。
#   表に載っておったのは inbox_write.sh と ntfy.sh の 2 つのみ。
#
#   実測 (2026-07-28 06:40:50・直近 3 日の Bash 呼出 35,860 件):
#     現に撃たれた道具 1595 種のうち ★散文を argv で受けた道具 107 種★
#     うち表に載るのは ★2 種★ (inbox_write.sh 966 回 / ntfy.sh 205 回)
#     ⇒ ★表に載らぬまま散文を受けておる道具 105 種・延べ 324 回★ (検算 1495-966-205=324)
#     首位は cmd_id_alloc.sh で 137 回
#
#   ★実害★ 将軍が 07-27 01:21:12 に現に踏まれた:
#     cmd_id_alloc.sh --evidence "… $200 promotional credit …"
#     ⇒ $2 が未定義ゆえ黙って空へ落ち、台帳には「00」だけが残った。
#     ★同じ本文を inbox_write.sh の本文位置へ入れれば関所は DENY を返す★
#     = ★判定の力は元より在り、当てる先が無かっただけである。★
#
# ■ 家老の裁 (06:52) = 二段で当てよ
#   段1 = 誤検知の 1 形 (連番を題に埋める "…#$i") を先に潰せ
#   段2 = 潰れたら DENY で当てよ。潰れなんだら名乗り (WARN) に留めよ
#   ⇒ ★段1 は潰れた★ (実測 = 誤検知 5 件が全て消え、将軍の件は残った) ゆえ DENY で当てておる。
#      当てた後に実データ 36,087 件へ当て直し = DENY 28 件 = 既存 26 + R5 2 (誤検知 0)。
#
# ■ 撃ち方 (陽性と陰性を対で・条4)
#   陽性 = 原本が現に鳴る / 原本が現に黙る (免除が広すぎぬ側)
#   陰性 = 守りを外せば黙る (T-SGS-101/102/103)
#   ★「黙る」だけを主張する試験は門が壊れても緑になる★ (cmd_1399 で己が 4 本 踏んだ形)
#   ゆえに 101 は ★先に原本が鳴ることを確かめてから★ 変異体を撃つ。
#
# ■ 変異の登録案 (台帳へ書くのは六号。拙者は台帳へ 0 byte)
#   MUT-1414-S1: R5 の枝を殺す (scan_unregistered が常に空)   → ^T-SGS-101 赤
#   MUT-1414-S2: R2-a の免除を常に真にする                     → ^T-SGS-102 赤
#   MUT-1414-S3: R4 の据え置きを外し全道具へ広げる             → ^T-SGS-103 赤

setup() {
    REPO="${BATS_TEST_DIRNAME}/../.."
    GUARD="${REPO}/scripts/shell_expansion_guard.py"
    WORK="${BATS_TEST_TMPDIR}"
    # 将軍が現に踏まれた原文の型
    SHOGUN='bash scripts/cmd_id_alloc.sh --title "戦力再配分" --origin shogun --evidence "殿の定額枠が枯渇し $200 promotional credit 運用へ移行=有限の実弾"'
    # 段1 で潰した 1 形 (連番を題に埋める)
    LOOP='for i in $(seq 1 3); do bash scripts/cmd_id_alloc.sh --title "並行試験 N32 #$i" --origin karo; done'
    # 書き手がわざと引用符を外した heredoc (R4 の据え置きが守っておる物)
    HEREDOC='NEW=$(bash scripts/cmd_id_alloc.sh --title "点呼" --origin karo)
python3 - <<PY
s = "parent_cmd: $NEW"
PY'
}

# ★変異が【1 箇所だけ】に当たったかを確かめる (cmd_1414 で己が踏んだ形への手当て)★
#   当たらねば「変異が届いておらぬのに赤い」/ 広すぎれば「別の物を殺して赤い」。
#   ★どちらも赤の理由が働きでない★ (条5 = 赤の理由を確かめよ)。
assert_mutated_once() {  # assert_mutated_once <原本> <変異体> <目印>
    if cmp -s "$1" "$2"; then
        echo "MUTATION-DID-NOT-APPLY: $3"
        return 1
    fi
    local n
    n=$(grep -c "$3" "$2")
    if [ "$n" -ne 1 ]; then
        echo "MUTATION-TOO-BROAD: $3 が $n 箇所へ当たった (1 でなければならぬ)"
        return 1
    fi
}

verdict() {  # verdict <guard_path> <command>
    python3 "$1" --command "$2" >/dev/null 2>&1
    echo "$?"      # 0 = ALLOW / 2 = DENY
}

# ── 陽性: 原本が現に鳴る ──────────────────────────────────────────────

@test "T-SGS-001: 表に載らぬ道具の散文へ紛れた位置引数を名指す (将軍の型)" {
    run bash -c "python3 '$GUARD' --command '$SHOGUN' 2>&1"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cmd_id_alloc.sh"* ]]
    [[ "$output" == *'$2'* ]]
}

@test "T-SGS-002: 道具の側の逃げ道 (--evidence-file) は通る" {
    run bash -c "python3 '$GUARD' --command 'bash scripts/cmd_id_alloc.sh --title x --evidence-file /tmp/e.txt' 2>&1"
    [ "$status" -eq 0 ]
}

@test "T-SGS-003: 道具でない物は巻き込まぬ (負の対照)" {
    run bash -c "python3 '$GUARD' --command 'echo \"採取の刻 = \$(date)\"' 2>&1"
    [ "$status" -eq 0 ]
}

@test "T-SGS-004: 展開も backtick も無い普通の散文は通る (負の対照)" {
    run bash -c "python3 '$GUARD' --command 'bash scripts/foo.sh \"軍師の検分は PASS であった\"' 2>&1"
    [ "$status" -eq 0 ]
}

# ── 陽性: 段1 で潰した 1 形が現に黙る / 免除が広すぎぬ ────────────────────

@test "T-SGS-010: for で定義された連番は黙る (段1 で潰した 1 形)" {
    run bash -c "python3 '$GUARD' --command '$LOOP' 2>&1"
    [ "$status" -eq 0 ]
}

@test "T-SGS-011: 同じ綴りでも定義が無ければ鳴る (免除が広すぎぬ証)" {
    run bash -c "python3 '$GUARD' --command 'bash scripts/cmd_id_alloc.sh --title \"並行試験 N32 #\$i\" --origin karo' 2>&1"
    [ "$status" -eq 2 ]
}

@test "T-SGS-012: 定義済でも backtick が在れば鳴る (R1 は免除されぬ)" {
    run bash -c "python3 '$GUARD' --command 'for i in 1 2; do bash scripts/foo.sh \"残 \`wc -l < f\` 行 #\$i\"; done' 2>&1"
    [ "$status" -eq 2 ]
}

@test "T-SGS-013: 定義済に \$(…) が混ざれば鳴る (免除を理由より広く取らぬ)" {
    run bash -c "python3 '$GUARD' --command 'for i in 1 2; do bash scripts/foo.sh \"件数 \$(wc -l < f) 本 #\$i\"; done' 2>&1"
    [ "$status" -eq 2 ]
}

@test "T-SGS-014: R4 の据え置き — 表の道具が居らぬ heredoc は鳴らさぬ" {
    run bash -c "python3 '$GUARD' --command '$HEREDOC' 2>&1"
    [ "$status" -eq 0 ]
}

# ── 陰性 (変異): 守りを外せば黙る ────────────────────────────────────
#   ★どの変異も、先に原本が現に鳴ることを確かめてから撃つ★
#   = 「黙る」だけを主張すれば、門が丸ごと壊れても緑になるゆえ (cmd_1399 の教訓)。

@test "T-SGS-101: R5 の枝を殺すと将軍の型を見逃す" {
    # ① 原本が現に鳴ることを先に確かめる (陽性)
    [ "$(verdict "$GUARD" "$SHOGUN")" -eq 2 ]

    # ② 変異を当てる: scan_unregistered を常に空へ
    M="$WORK/mut_s1.py"
    # ★綴りは scan_unregistered の中だけに在る 1 行を選ぶ★
    #   初版は `findings: list[dict] = []` を撃っており ★analyze() にも当たって門を丸ごと殺しておった★
    #   = R5 でなく「門が壊れた」を測っていた (cmd_1399 で己が名指した形を、己で踏んだ)。
    sed 's/^    offset = 0$/    return findings  # MUTANT-S1\n    offset = 0/' "$GUARD" > "$M"
    assert_mutated_once "$GUARD" "$M" MUTANT-S1

    # ③ 変異体は黙る = R5 が現に効いておった
    [ "$(verdict "$M" "$SHOGUN")" -eq 0 ]
}

@test "T-SGS-102: R2-a の免除を常に真にすると、定義の無い連番まで見逃す" {
    # ① 原本が現に鳴ることを先に確かめる (陽性)
    NOLOOP='bash scripts/cmd_id_alloc.sh --title "並行試験 N32 #$i" --origin karo'
    [ "$(verdict "$GUARD" "$NOLOOP")" -eq 2 ]

    # ② 変異を当てる: r2a_exempt が常に真
    M="$WORK/mut_s2.py"
    sed 's/^    spans = _EXPANSION_RE.findall(raw_unsafe)$/    return True  # MUTANT-S2\n    spans = _EXPANSION_RE.findall(raw_unsafe)/' \
        "$GUARD" > "$M"
    assert_mutated_once "$GUARD" "$M" MUTANT-S2

    # ③ 変異体は黙る = 免除の絞りが現に効いておった
    [ "$(verdict "$M" "$NOLOOP")" -eq 0 ]
}

@test "T-SGS-103: R4 の据え置きを外すと、関係の無い heredoc まで止める" {
    # ① 原本は現に黙る (据え置きが効いておる = 陽性の逆向き)
    [ "$(verdict "$GUARD" "$HEREDOC")" -eq 0 ]

    # ② 変異を当てる: R4 の「表の道具が居るか」の条件を常に真へ
    M="$WORK/mut_s3.py"
    sed 's/^    if any($/    if True or any(  # MUTANT-S3/' "$GUARD" > "$M"
    assert_mutated_once "$GUARD" "$M" MUTANT-S3

    # ③ 変異体は止める = 据え置きが現に守っておった
    [ "$(verdict "$M" "$HEREDOC")" -eq 2 ]
}

# ── 門そのものの自己試験 ────────────────────────────────────────────

@test "T-SGS-200: selftest が全数 PASS (SKIP=FAIL)" {
    run bash -c "python3 '$GUARD' --selftest 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" != *"NG "* ]]
}

@test "T-SGS-201: 外す一覧 (UNGUARDED_TOOLS) が現に効く" {
    # ① 原本は鳴る
    [ "$(verdict "$GUARD" "$SHOGUN")" -eq 2 ]

    # ② cmd_id_alloc.sh を外す一覧へ入れる
    M="$WORK/mut_waiver.py"
    sed 's/^UNGUARDED_TOOLS: dict\[str, str\] = {}$/UNGUARDED_TOOLS: dict[str, str] = {"cmd_id_alloc.sh": "試験 (until: 2026-08-31)"}  # MUTANT-W/' \
        "$GUARD" > "$M"
    assert_mutated_once "$GUARD" "$M" MUTANT-W

    # ③ 外した道具は黙る = 一覧が現に効く (黙って外す道でなく、書けば外れる道である)
    [ "$(verdict "$M" "$SHOGUN")" -eq 0 ]
}
