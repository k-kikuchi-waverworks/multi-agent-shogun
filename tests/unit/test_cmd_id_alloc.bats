#!/usr/bin/env bats
# test_cmd_id_alloc.bats — cmd_1341 採番gate硬化の回帰test
#
# 対象: scripts/cmd_id_alloc.sh (cmd_1333/cmd_1336/cmd_1341)
#   (B-N2) rollback 前の quarantine = gate非経由の並行追記を復元不能に消さない
#   (B-N3) 耐久mirror = journal が失われても番号を再払い出ししない
#   正常系回帰 = reserve/claim が従来どおり成立し validate PASS
#   (cmd_1466) repo の外に置く高水位 = 台帳ごと巻き戻された時に番号の二度払い出しを止める
#
# 全部 tmp の使い捨て fixture で走る = 本物の台帳/journal/archive/高水位には一切触れない
# 高水位も ALLOC_HIGHWATER で tmp へ差し替える (既定は $HOME/.local/share/... = repo の外)。

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export PROJECT_ROOT
    TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/cmd_id_alloc.XXXXXX")"
    export TEST_TMPDIR
    mkdir -p "$TEST_TMPDIR/archive"

    export LEDGER_FILE="$TEST_TMPDIR/ledger.yaml"
    export ARCHIVE_DIR="$TEST_TMPDIR/archive"
    export ALLOC_JOURNAL="$TEST_TMPDIR/journal"
    export ALLOC_JOURNAL_MIRROR="$TEST_TMPDIR/archive/alloc_journal_mirror.yaml"
    export LEDGER_VALIDATOR="$PROJECT_ROOT/scripts/ledger_validate.py"
    export LEDGER_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$LEDGER_PYTHON" ] || export LEDGER_PYTHON="python3"

    # cmd_1466: 高水位も使い捨ての場所へ。本物 ($HOME/.local/share/multi-agent-shogun/) には触れない。
    # 「repo の外」という条件を模すため BATS_TMPDIR 配下へ置く。
    export ALLOC_HIGHWATER="$TEST_TMPDIR/outside/cmd_id_highwater"
    mkdir -p "$TEST_TMPDIR/outside"

    printf 'commands:\n- id: cmd_100\n  status: done\n  evidence: |\n    fixture\n' > "$LEDGER_FILE"
    # fixture の最大は cmd_100 ゆえ、高水位も 100 から始める (正常な盤面)
    bash "$PROJECT_ROOT/scripts/cmd_id_alloc.sh" --init-highwater 100 >/dev/null 2>&1
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

alloc() {
    bash "$PROJECT_ROOT/scripts/cmd_id_alloc.sh" "$@"
}

# ───────────────────────────────────────────────────────────
# 正常系回帰 (cmd_1333 契約の非破壊)
# ───────────────────────────────────────────────────────────
@test "reserve: 正常追記 → validate PASS・id払い出し・mirror併記" {
    run alloc --title "試験" --origin karo --project test --priority low --evidence "回帰"
    assert_success
    assert_output --partial "cmd_101"
    # 台帳へ追記され validator も通る
    run "$LEDGER_PYTHON" "$LEDGER_VALIDATOR" "$LEDGER_FILE"
    assert_success
    # journal と mirror の両方に記録される
    run grep -c '^cmd_101' "$ALLOC_JOURNAL"
    assert_output "1"
    run grep -cE '^- id: cmd_101([^0-9]|$)' "$ALLOC_JOURNAL_MIRROR"
    assert_output "1"
}

@test "claim: 番号のみ払い出し (台帳未記帳) + journal/mirror 記録" {
    run alloc --claim --origin karo
    assert_success
    assert_output --partial "cmd_101"
    # 台帳には書かれていない
    run grep -c 'cmd_101' "$LEDGER_FILE"
    assert_output "0"
    run grep -cE '^- id: cmd_101([^0-9]|$)' "$ALLOC_JOURNAL_MIRROR"
    assert_output "1"
}

# ───────────────────────────────────────────────────────────
# (B-N3) 耐久mirror: journal 喪失でも番号を再利用しない
# ───────────────────────────────────────────────────────────
@test "(B-N3) claim → journal削除 → 再claim は同番号を再払い出ししない" {
    run alloc --claim --origin karo
    assert_success
    local first="$output"
    rm -f "$ALLOC_JOURNAL"
    run alloc --claim --origin karo
    assert_success
    [ "${output##*$'\n'}" != "${first##*$'\n'}" ]
    assert_output --partial "cmd_102"
}

@test "(B-N3) mirror 追記不能なら払い出さない (fail-closed)" {
    : > "$ALLOC_JOURNAL_MIRROR"
    chmod 444 "$ALLOC_JOURNAL_MIRROR"
    run alloc --claim --origin karo
    assert_failure
    assert_output --partial "mirror"
    # journal には焼却記録が残る (安全側) が、台帳は無変化
    run grep -c 'cmd_101' "$LEDGER_FILE"
    assert_output "0"
}

# ───────────────────────────────────────────────────────────
# (B-N2) rollback 前 quarantine: 並行追記を復元不能に消さない
# ───────────────────────────────────────────────────────────
@test "(B-N2) validate FAIL rollback は quarantine を先に取り、並行追記が復元できる" {
    # 悪魔validator = 検証の窓で gate非経由の書き手 (家老のEdit) が cmd_7777 を
    # 追記した状況を模擬し、FAIL を返す (軍師二号の B-N2 実証手法と同型)
    cat > "$TEST_TMPDIR/evil_validator.py" <<EOF
import sys
with open("$LEDGER_FILE", "a", encoding="utf-8") as f:
    f.write("- id: cmd_7777\n  status: pending\n  evidence: |\n    gate非経由の並行追記模擬\n")
sys.exit(1)
EOF
    local before
    before="$(cat "$LEDGER_FILE")"

    LEDGER_VALIDATOR="$TEST_TMPDIR/evil_validator.py" \
        run alloc --title "quarantine試験" --origin karo --project test --priority low --evidence "B-N2"
    assert_failure
    assert_output --partial "quarantine"

    # 台帳は snapshot へ復元されている (rollback 自体は従来どおり)
    assert_equal "$(cat "$LEDGER_FILE")" "$before"
    # 消えたはずの並行追記 (cmd_7777) が quarantine に残っている
    run bash -c "grep -lE '^- id: cmd_7777' '$ARCHIVE_DIR'/corrupt_shogun_to_karo_*.yaml"
    assert_success
}

# ───────────────────────────────────────────────────────────
# (cmd_1466) repo の外の高水位 — 台帳ごと巻き戻された時に止める
#
# 陽性/陰性を対で撃つ (CLAUDE.md「数の検め方」条4)。
#   陰性側 = 正常な盤面では止まらないこと
#   陽性側 = 古い控えから戻した盤面で現に止まること
# ───────────────────────────────────────────────────────────

# repo の中の4点 (台帳・archive・journal・mirror) を git clean -xd 後の状態にし、
# 台帳だけを古い控えから戻す = cmd_1466 で実測した危ない形の再現。
rewind_tree() {
    rm -f "$ALLOC_JOURNAL"
    rm -rf "$ARCHIVE_DIR"
    mkdir -p "$ARCHIVE_DIR"   # 人が ERROR を見て mkdir -p を実行する手順まで含めて再現する
    printf 'commands:\n- id: cmd_100\n  status: done\n  evidence: |\n    古い控え\n' > "$LEDGER_FILE"
}

@test "(cmd_1466 陰性側) 正常な盤面では止まらず、高水位が払い出しに追随する" {
    run alloc --claim --origin karo
    assert_success
    assert_output --partial "cmd_101"
    # 高水位が 100 → 101 へ上がっている
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "101"

    run alloc --claim --origin karo
    assert_success
    assert_output --partial "cmd_102"
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "102"
}

@test "(cmd_1466 陽性側) 台帳を古い控えから戻すと巻き戻りを検知して止まる" {
    # まず正常に払い出して高水位を進める (cmd_101〜103 が焼却される)
    alloc --claim --origin karo >/dev/null
    alloc --claim --origin karo >/dev/null
    run alloc --claim --origin karo
    assert_success
    assert_output --partial "cmd_103"

    rewind_tree

    # ここが本題。高水位が無ければ cmd_101 を平然ともう一度 払い出す状態である
    run alloc --claim --origin karo
    assert_failure
    assert_output --partial "巻き戻"
    assert_output --partial "cmd_101"
    # 焼却済みの番号は出ていない
    refute_output --partial "claimed:"
    # 高水位は下がっていない
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "103"
}

@test "(cmd_1466 陽性側) 高水位が無ければ再払い出しは現に起きる (この試験が守っている物の実証)" {
    alloc --claim --origin karo >/dev/null   # cmd_101
    rewind_tree
    # 高水位を外した時だけ、同じ番号がもう一度 出ることを示す
    ALLOC_HIGHWATER="$TEST_TMPDIR/outside/none" run bash -c \
        "ALLOC_HIGHWATER='$TEST_TMPDIR/outside/bootstrap' bash '$PROJECT_ROOT/scripts/cmd_id_alloc.sh' --init-highwater 1 >/dev/null 2>&1
         ALLOC_HIGHWATER='$TEST_TMPDIR/outside/bootstrap' bash '$PROJECT_ROOT/scripts/cmd_id_alloc.sh' --claim --origin karo"
    assert_success
    assert_output --partial "cmd_101"   # 二度目の cmd_101 = 検査が無い時に起きること
}

@test "(cmd_1466) peek も巻き戻った盤面で「次の空き番号」を答えない" {
    alloc --claim --origin karo >/dev/null   # cmd_101
    rewind_tree
    run alloc --peek
    assert_failure
    assert_output --partial "巻き戻"
}

@test "(cmd_1466) 高水位 file が無ければ止まる (fail-closed)" {
    rm -f "$ALLOC_HIGHWATER"
    run alloc --claim --origin karo
    assert_failure
    assert_output --partial "高水位 file が無い"
    assert_output --partial "--init-highwater"
    # 番号は出ていない
    refute_output --partial "claimed:"
}

@test "(cmd_1466) 空 file / 数でない中身を0扱いしない (archive dir と同じ穴を作らない)" {
    : > "$ALLOC_HIGHWATER"
    run alloc --claim --origin karo
    assert_failure
    assert_output --partial "読めぬ"

    printf 'not_a_number\n' > "$ALLOC_HIGHWATER"
    run alloc --claim --origin karo
    assert_failure
    assert_output --partial "読めぬ"
}

@test "(cmd_1466) 高水位を書けねば番号を払い出さない (fail-closed)" {
    chmod 500 "$TEST_TMPDIR/outside"
    run alloc --claim --origin karo
    chmod 700 "$TEST_TMPDIR/outside"
    assert_failure
    assert_output --partial "高水位を書けぬ"
}

@test "(cmd_1466) --init-highwater は値を明示させ、下げる方向へは動かない" {
    # 値の明示が要る (導出しない)
    run alloc --init-highwater
    assert_failure
    assert_output --partial "整数で明示"

    run alloc --init-highwater 500
    assert_success
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "500"

    # 上げるのは通る
    run alloc --init-highwater 600
    assert_success
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "600"

    # 下げる方向は通らない
    run alloc --init-highwater 400
    assert_failure
    assert_output --partial "下げ"
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "600"
}

@test "(cmd_1466) --init-highwater は台帳/archive が消えていても撃てる" {
    # 据え直しが要るのは、まさに台帳も archive も消えた後だからである
    rm -f "$LEDGER_FILE" "$ALLOC_HIGHWATER"
    rm -rf "$ARCHIVE_DIR"
    run alloc --init-highwater 1467
    assert_success
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "1467"
}

@test "(cmd_1466) 既定の置き場は repo の外に解決される" {
    # 上の試験は全て ALLOC_HIGHWATER を使い捨ての場所へ差し替えている = 既定の path を一度も通らない
    # (足軽六号が cmd_1450 で踏んだ形 = 入力を差し替える試験は、入力を読む口を試験しない)。
    # 既定が repo の中へ解決されると検査が丸ごと無意味になるので、既定の解決だけを別に確かめる。
    local fake_home="$TEST_TMPDIR/home"
    mkdir -p "$fake_home"
    run env -u ALLOC_HIGHWATER -u XDG_DATA_HOME HOME="$fake_home" \
        bash "$PROJECT_ROOT/scripts/cmd_id_alloc.sh" --init-highwater 1
    assert_success
    [ -f "$fake_home/.local/share/multi-agent-shogun/cmd_id_highwater" ]
    # 本物の $HOME も repo の下ではないこと (既定が repo の中なら git clean -xd で消える)
    case "$HOME/" in
        "$PROJECT_ROOT"/*) fail "\$HOME が repo の下にある = 既定の置き場が git clean -xd で消える範囲に入る" ;;
    esac
}

@test "(cmd_1466) reserve も高水位を上げる (claim だけの守りにしない)" {
    run alloc --title "高水位試験" --origin karo --project test --priority low --evidence "cmd_1466"
    assert_success
    assert_output --partial "cmd_101"
    run bash -c "cut -f1 '$ALLOC_HIGHWATER'"
    assert_output "101"
}
