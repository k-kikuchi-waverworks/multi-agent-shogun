#!/usr/bin/env bats
# test_cmd_id_alloc.bats — cmd_1341 採番gate硬化の回帰test
#
# 対象: scripts/cmd_id_alloc.sh (cmd_1333/cmd_1336/cmd_1341)
#   (B-N2) rollback 前の quarantine = gate非経由の並行追記を復元不能に消さない
#   (B-N3) 耐久mirror = journal が失われても番号を再払い出ししない
#   正常系回帰 = reserve/claim が従来どおり成立し validate PASS
#
# ★全て tmp fixture harness = 実台帳/実journal/実archiveには一切触れない★

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

    printf 'commands:\n- id: cmd_100\n  status: done\n  evidence: |\n    fixture\n' > "$LEDGER_FILE"
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
    # ★quarantine に消えたはずの並行追記 (cmd_7777) が保全されている★
    run bash -c "grep -lE '^- id: cmd_7777' '$ARCHIVE_DIR'/corrupt_shogun_to_karo_*.yaml"
    assert_success
}
