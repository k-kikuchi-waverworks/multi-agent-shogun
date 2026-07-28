#!/usr/bin/env bats
# 控えの鮮度を見る検査の試験 (cmd_1439)
#
# 何を確かめるか:
#   陽性 = 記録が古い時に現に鳴ること
#   陰性 = 記録が新しい時に鳴らないこと (陰性を撃たないと、常に鳴る検査でも緑になる)
#   記録が無い時 = 鳴る側へ倒してあること (「無い」を「新しい」と読むと穴が残るため)
#   配線 = gate_nightly が、この検査の結果で現に家老へ知らせる形になっていること
#
# 記録は本番の場所を使わない。すべて一時の場所へ作る (本番の logs/ へは 0 バイト)。

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHECK="$REPO/scripts/backup_freshness_check.sh"
    TMP="$(mktemp -d)"
    # 「今」を固定する。実際の日付で試験すると、日が変わった朝に結果が変わるため。
    export NOW_EPOCH=1785000000        # 2026-07-24 頃
    export BACKUP_STATE_FILE="$TMP/backup.txt"
    export DVCGC_STATE_FILE="$TMP/dvcgc.txt"
    export DVCGC_MIRROR_FILE="$TMP/mirror.txt"
}

teardown() { rm -rf "$TMP"; }

# 与えた日数だけ前の日時を書く
write_stamp() {
    local file="$1" days_ago="$2"
    date -u -d "@$(( NOW_EPOCH - days_ago * 86400 ))" '+%Y-%m-%d %H:%M:%S' > "$file"
}

# 書く側と同じ形で書く = 先頭に UTF-8 BOM を付ける。
#
# ★これを足した理由★: 上の write_stamp は bash が書くので BOM が付かない。
#   だが本番で書くのは Windows PowerShell 5.1 の Set-Content -Encoding UTF8 で、
#   ★この版は必ず BOM を付ける★。ゆえに試験の作り物と本物の形が違っており、
#   試験は全数 緑のまま、本番では初日から読めない状態だった (現に踏んだ)。
#
# BOM の3バイトは推測でなく実測: 本物の書き手に書かせて head -c 6 | xxd で見た結果が
#   ef bb bf 32 30 32 ("...202")。F: の掃除の記録の方は BOM 無しで、
#   ★片方だけ BOM が付くゆえ、掃除の側が緑で控えの側だけ落ちる形だった★。
write_stamp_as_writer_does() {
    local file="$1" days_ago="$2"
    printf '\xef\xbb\xbf' > "$file"
    date -u -d "@$(( NOW_EPOCH - days_ago * 86400 ))" '+%Y-%m-%d %H:%M:%S' >> "$file"
}

@test "陰性: 両方とも新しければ鳴らない" {
    write_stamp "$BACKUP_STATE_FILE" 0
    write_stamp "$DVCGC_STATE_FILE" 1
    run bash "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[BACKUP-OK]"* ]]
    [[ "$output" == *"[DVCGC-OK]"* ]]
    [[ "$output" != *"STALE"* ]]
}

@test "陽性: 控えが古ければ鳴る" {
    write_stamp "$BACKUP_STATE_FILE" 5
    write_stamp "$DVCGC_STATE_FILE" 1
    run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[BACKUP-STALE]"* ]]
    [[ "$output" == *"5 日 前から成功していない"* ]]
}

@test "陽性: 掃除が古ければ鳴る (今の本番と同じ形)" {
    write_stamp "$BACKUP_STATE_FILE" 0
    write_stamp "$DVCGC_STATE_FILE" 74
    run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[DVCGC-STALE]"* ]]
    [[ "$output" == *"74 日 前から成功していない"* ]]
}

@test "記録が無い時は鳴る (「無い」を「新しい」と読まない)" {
    write_stamp "$DVCGC_STATE_FILE" 1
    run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[BACKUP-MISSING]"* ]]
}

@test "掃除の記録が F: にも写しにも無ければ鳴る" {
    write_stamp "$BACKUP_STATE_FILE" 0
    run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[DVCGC-MISSING]"* ]]
}

@test "中身が読めない時は、古いとも新しいとも言わずに測れなんだと言う" {
    write_stamp "$BACKUP_STATE_FILE" 0
    echo "これは日時ではない" > "$DVCGC_STATE_FILE"
    run bash "$CHECK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"[DVCGC-UNREADABLE]"* ]]
}

@test "F: の記録が読めた時は、C: 側へ写しを残す (F: が飛んだ後に答えられるように)" {
    write_stamp "$BACKUP_STATE_FILE" 0
    write_stamp "$DVCGC_STATE_FILE" 1
    [ ! -f "$DVCGC_MIRROR_FILE" ]
    run bash "$CHECK"
    [ -f "$DVCGC_MIRROR_FILE" ]
    [ "$(cat "$DVCGC_MIRROR_FILE")" = "$(cat "$DVCGC_STATE_FILE")" ]
}

@test "F: の記録が無くても、C: 側の写しが在れば判じられる" {
    write_stamp "$BACKUP_STATE_FILE" 0
    write_stamp "$DVCGC_MIRROR_FILE" 74
    run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[DVCGC-SOURCE]"* ]]
    [[ "$output" == *"[DVCGC-STALE]"* ]]
}

@test "緑の時も、見ていない範囲を名乗る" {
    write_stamp "$BACKUP_STATE_FILE" 0
    write_stamp "$DVCGC_STATE_FILE" 1
    run bash "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[射程]"* ]]
    [[ "$output" == *"中身が正しいかは見ていない"* ]]
}

# ── 配線の試験 ────────────────────────────────────────────────────────────
# 判定が正しくても、gate_nightly がその結果を見ていなければ家老へ届かない。
# 今朝ずっと出ていた「判定は試験され、配線は試験されていない」形を、ここで塞ぐ。

@test "本物の書き手が書いた形 (BOM つき) を、現に読めること" {
    write_stamp_as_writer_does "$BACKUP_STATE_FILE" 0
    write_stamp "$DVCGC_STATE_FILE" 1
    run bash "$CHECK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[BACKUP-OK]"* ]]
    [[ "$output" != *"UNREADABLE"* ]]
}

@test "本物の書き手が書いた形でも、古ければ現に鳴る" {
    write_stamp_as_writer_does "$BACKUP_STATE_FILE" 5
    write_stamp "$DVCGC_STATE_FILE" 1
    run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[BACKUP-STALE]"* ]]
    # ★「読めない」で 落ちたのでは陽性の証にならない★ = 日数を現に数えた上で鳴ったことを見る
    [[ "$output" == *"5 日 前から成功していない"* ]]
}

@test "配線: gate_nightly が この検査を現に呼んでいる" {
    grep -q 'backup_freshness_check.sh' "$REPO/scripts/gate_nightly.sh"
}

@test "配線: 他が全部 緑でも、この検査だけで家老への警告が出る形になっている" {
    # 家老へ知らせる if の条件に freshness_rc が入っていなければ、
    # 控えが古い朝でも、他が緑なら警告は 1 通も出ない。
    run grep -c 'if \[ "\$freshness_rc" -ne 0 \] ||' "$REPO/scripts/gate_nightly.sh"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "配線: 警告の本文に、この検査の所見が載る" {
    grep -q 'freshnote' "$REPO/scripts/gate_nightly.sh"
    grep -q '${freshnote}所見=' "$REPO/scripts/gate_nightly.sh"
}

@test "控えの script が、成功した日時を F: の外へ書く形になっている" {
    local ps1=/mnt/f/aituber-project-ml/scripts/backup/backup_f_to_d.ps1
    if [ ! -f "$ps1" ]; then skip "F: が見えない環境"; fi
    grep -q 'StateFile' "$ps1"
    # 置き場が F: でも D: でもないこと (答えるべき事故で一緒に消えないため)
    run grep -E '^\s*\[string\]\$StateFile' "$ps1"
    [ "$status" -eq 0 ]
    [[ "$output" != *'F:\'* ]]
    [[ "$output" != *'D:\'* ]]
}
