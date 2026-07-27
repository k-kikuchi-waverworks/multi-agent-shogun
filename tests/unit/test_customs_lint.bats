#!/usr/bin/env bats
# test_customs_lint.bats — cmd_1330: 本日できた作法を、機械で守れる分だけテストにする。
#
# 何を試すか:
#   scripts/customs_lint.py は判定で落とさない (終了コードは常に 0)。
#   よってテストが見るのは出力の中身である。「落ちたか」ではなく「名指したか」を検める。
#
# テストの構成 (memory feedback_green_tests_that_prove_nothing の三類型を避ける形):
#   ・検出する例   = 作法を破った文書を撃って名指す (T-CL-002 / T-CL-004)
#   ・検出しない例 = 作法を守った文書や無関係な書き換えでは名指さない (T-CL-003 / T-CL-005 / T-CL-006)
#   ・射程の確認   = 道具が自分の限界を自分で名乗る (T-CL-001 / T-CL-007)
#
# 変異テストの登録案 (台帳の書き手は六号一人なので、登録は報告経由):
#   MUT-1330-CL1: MEASURED_RE から「測定」を外す        → T-CL-003 が赤 (守った文書を名指す)
#   MUT-1330-CL2: SUBJ_RE から「については」を外す      → T-CL-005 が赤
#   MUT-1330-CL3: 表の行の分別 (c2_undecidable) を撤去  → T-CL-006 が赤 (判定できない物を名指す)
#   MUT-1330-CL4: 終了コードを 1 に変える (ゲート化)     → T-CL-002 ほかが赤

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export LINT="$PROJECT_ROOT/scripts/customs_lint.py"
    [ -f "$LINT" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/customs.XXXXXX")"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_py() {
    if [ -x "$PROJECT_ROOT/.venv/bin/python3" ]; then "$PROJECT_ROOT/.venv/bin/python3" "$@";
    else python3 "$@"; fi
}

# ---------------------------------------------------------------------------
# T-CL-001: 道具が自分の射程を自分で名乗る (「守れない物を守った顔にしない」の機械側)
# ---------------------------------------------------------------------------
@test "T-CL-001: the tool declares its own scope — what it sees, what it does not, and that it never fails" {
    run _py "$LINT" --scope
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "見る"
    echo "$output" | grep -q "見ない"
    echo "$output" | grep -q "落とさない"
}

# ---------------------------------------------------------------------------
# T-CL-002: 検出する例 (C1)。ps 由来の時刻に測定時刻の併記がない行を名指す。
# かつ終了コードは 0 のまま。「名指すところで止め、落とさない」をテストで固定する。
# ---------------------------------------------------------------------------
@test "T-CL-002: a ps-derived clock written without its measurement time is named (and still rc=0)" {
    printf '%s\n' \
        'evidence: |' \
        '  家老の起動は ps -o lstart= で Mon Jul 27 01:06:29 であった' \
        > "$TEST_TMPDIR/r.yaml"
    run _py "$LINT" --name "$TEST_TMPDIR/r.yaml"
    [ "$status" -eq 0 ]                                   # 判定で落とす道具ではない
    echo "$output" | grep -q "C1 .*r.yaml:2"
    echo "$output" | grep -q "母数 1 行"                   # 母数を先に出す (0/0 と 0/8 は別物)
}

# ---------------------------------------------------------------------------
# T-CL-003: 検出しない例 (C1)。測定時刻を併記した行は名指さない。
# これがないと、何でも赤くするチェックでも T-CL-002 は緑になってしまう。
# ---------------------------------------------------------------------------
@test "T-CL-003: the same clock WITH a measurement time is not named (the net is not over-broad)" {
    printf '%s\n' \
        'evidence: |' \
        '  家老の起動は ps -o lstart= で Mon Jul 27 01:06:29 (測定刻 17:14 JST) であった' \
        > "$TEST_TMPDIR/r.yaml"
    run _py "$LINT" --name "$TEST_TMPDIR/r.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "母数 1 行 → 測定時刻の併記なし 0 行"
    if echo "$output" | grep -q "C1 .*r.yaml:2"; then return 1; fi
}

# ---------------------------------------------------------------------------
# T-CL-004: 検出する例 (C2)。第七条の札に「何の判定について」の一語がない形を名指す。
# 由来: 同じ一つの「言えない」が、問いを替えると別の札になる (二号 17:14 の表)。
# ---------------------------------------------------------------------------
@test "T-CL-004: a bare seventh-article tag with no stated subject of judgement is named" {
    printf '%s\n' \
        'cannot_say:' \
        '  - 筆の別か effort の別か分かれぬ ⑦-c' \
        > "$TEST_TMPDIR/r.yaml"
    run _py "$LINT" --name "$TEST_TMPDIR/r.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C2 .*r.yaml:2"
}

# ---------------------------------------------------------------------------
# T-CL-005: 検出しない例 (C2)。「b16 の採否については ⑦-c」の形は名指さない。
# ---------------------------------------------------------------------------
@test "T-CL-005: the same tag prefixed with what it judges is not named" {
    # 2 行書く理由: 1 行目は「の採否」でも「については」でも通るので、語を一つ抜いても緑のままだった
    #   (2026-07-27 の MUT-1330-CL2 実射で判明)。2 行目は「については」だけが支える形にしてある。
    #   これがないと、このテストは「壊しても落ちない緑」だった。
    printf '%s\n' \
        'cannot_say:' \
        '  - b16 の採否については ⑦-c (当たらぬ)' \
        '  - cmd_1416 については ⑦-b (Opus/high 一冊で割れる)' \
        > "$TEST_TMPDIR/r.yaml"
    run _py "$LINT" --name "$TEST_TMPDIR/r.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "判定対象の一語なし 0 箇所"
}

# ---------------------------------------------------------------------------
# T-CL-006: 判定できない物は名指さない。表の行は判定対象が別の列にあり得るため。
# 出所: 17:14 に自分が書いた表が実際にその形で、守れている物を機械が違反と言った。
# そこで名指さず、別の数として持つことにした。
# ---------------------------------------------------------------------------
@test "T-CL-006: a table row is counted as undecidable, not named (its subject may live in a column header)" {
    printf '%s\n' \
        '| 項 | b16 の採否 | cmd_1416 |' \
        '| 筆の別か effort の別か | ⑦-c 当たらぬ | ⑦-b 高い |' \
        > "$TEST_TMPDIR/p.md"
    run _py "$LINT" --name "$TEST_TMPDIR/p.md"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "判定できない (表の行)」 2 箇所"
    if echo "$output" | grep -q "C2 .*p.md:2"; then return 1; fi
}

# ---------------------------------------------------------------------------
# T-CL-007: 無関係な書き換えでは数が動かない。作法に触れない文をいくら足しても名指しは 0 のまま。
# 何でも赤くするチェックなら、ここが赤くなる。
# ---------------------------------------------------------------------------
@test "T-CL-007: an unrelated rewrite leaves the tool silent (no finding is invented)" {
    printf '%s\n' \
        'progress: |' \
        '  b16 の 30 対を著述し、門 9 本を撃った。SKIP は 0 であった。' \
        '  出来ておらぬ物を出来たとは書かぬ。' \
        > "$TEST_TMPDIR/r.yaml"
    run _py "$LINT" --name "$TEST_TMPDIR/r.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C1 ps由来の時刻: 母数 0 行 → 測定時刻の併記なし 0 行"
    echo "$output" | grep -q "C2 第七条の札 : 母数 0 箇所 → 判定対象の一語なし 0 箇所"
    # 0 を報せる前の確認。道具が実際にファイルを読んでいること (走査 0 file の緑を排す)
    echo "$output" | grep -q "走査 1 file"
}

# ---------------------------------------------------------------------------
# T-CL-008: 道具の名 (ファイル名) を時刻と取り違えない。
# tests/unit/test_idle_revive_proc_age.bats のような行は ps 由来の時刻ではない。
# 2026-07-27 の実測では、語頭の境界を課さないと 16 行を取り違えていた。
# ---------------------------------------------------------------------------
@test "T-CL-008: a tool/file name containing proc_age is not mistaken for a ps-derived clock" {
    printf '%s\n' \
        'note: tests/unit/test_idle_revive_proc_age.bats を撃った' \
        > "$TEST_TMPDIR/r.yaml"
    run _py "$LINT" --name "$TEST_TMPDIR/r.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "C1 ps由来の時刻: 母数 0 行"
}
