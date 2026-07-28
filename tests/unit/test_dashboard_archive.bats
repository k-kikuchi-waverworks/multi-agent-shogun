#!/usr/bin/env bats
#
# cmd_1470 — 殿の頁の、印より下を控えへ移す道具の試験
#
# 撃つのは陽性と陰性の両方である。
#   陽性 = 印が在れば現に移る・印より上が 1 バイトも変わらない
#   陰性 = 印が無い / 2 本在る / 頭に在る時に、1 バイトも動かない
#
# ★試験は現物の dashboard.md へ 1 バイトも書かない。★ --file で写しへ差し替える。
# 但し「既定の対象が現物を指しているか」の配線だけは、空撃ちで 1 本 撃つ
# (入力を差し替えて撃つ試験は、入力を読む口を試験しない = cmd_1450・足軽六号)。

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/dash_archive.XXXXXX")"
    export DASH="$TEST_TMPDIR/dashboard.md"
    export ARC="$TEST_TMPDIR/archive"
    mkdir -p "$ARC"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

run_cut() {
    bash "$PROJECT_ROOT/scripts/dashboard_archive.sh" --file "$DASH" --archive-dir "$ARC" "$@"
}

# 頁の写しを作る。頭 60 行 + 印 + 下 40 行。
# 印は頭から 61 行目に置く (守り「頭 50 行以内なら止まる」に当たらない位置)。
make_page() {
    local marker="${1:-yes}"
    : > "$DASH"
    printf '# 🏯 殿の頁 (試験用)\n' >> "$DASH"
    local i
    for i in $(seq 2 60); do printf '生きている記録 %s\n' "$i" >> "$DASH"; done
    if [ "$marker" = yes ]; then
        printf '<!-- KARO_CUT_HERE  置いた者=karo  刻=2026-07-28T18:10 -->\n' >> "$DASH"
    elif [ "$marker" = twice ]; then
        printf '<!-- KARO_CUT_HERE  1本目 -->\n' >> "$DASH"
    else
        printf '<!-- ここに印は無い -->\n' >> "$DASH"
    fi
    printf '## 🚨 古い要対応 (これは移る側に在る)\n' >> "$DASH"
    for i in $(seq 1 38); do printf '畢わった記録 %s\n' "$i" >> "$DASH"; done
    if [ "$marker" = twice ]; then
        printf '<!-- KARO_CUT_HERE  2本目 -->\n' >> "$DASH"
    fi
}

head_sha() {
    /usr/bin/head -n 60 "$DASH" | /usr/bin/sha256sum | /usr/bin/cut -d' ' -f1
}

# ── 陽性 ───────────────────────────────────────────────────────────

@test "cmd_1470: 印が在れば、印より下が控えへ移る" {
    make_page yes
    run run_cut --apply
    assert_success
    assert_output --partial "★移した★"
    [ -f "$ARC/dashboard_archive_$(date +%Y%m%d).md" ]
    run /usr/bin/grep -c '畢わった記録' "$ARC/dashboard_archive_$(date +%Y%m%d).md"
    assert_output "38"
}

@test "cmd_1470: 印より上は 1 バイトも変わらない" {
    make_page yes
    local before; before="$(head_sha)"
    run run_cut --apply
    assert_success
    [ "$(head_sha)" = "$before" ]
}

@test "cmd_1470: 移した後の頁は、印より上 + 指し先の 1 行だけになる" {
    make_page yes
    run run_cut --apply
    assert_success
    run /usr/bin/wc -l < "$DASH"
    assert_output "61"
    run /usr/bin/tail -n 1 "$DASH"
    assert_output --partial "これより古い記録は"
    # 印そのものは移す側に入る (残すと次の走行が同じ所で空撃ちを繰り返すため)
    run /usr/bin/grep -c 'KARO_CUT_HERE' "$DASH"
    assert_output "0"
}

@test "cmd_1470: 移した物を消さない — 控えが元と同じ大きさで残る" {
    make_page yes
    local before; before="$(/usr/bin/stat -c '%s' "$DASH")"
    run run_cut --apply
    assert_success
    local backup; backup="$(/usr/bin/find "$ARC" -name 'dashboard_backup_*.md' | /usr/bin/head -1)"
    [ -n "$backup" ]
    [ "$(/usr/bin/stat -c '%s' "$backup")" -eq "$before" ]
}

@test "cmd_1470: 1 行も落とさない — 元の全文が、頁と控えのどちらかに在る" {
    # 「移した物を消すな」を、行数ではなく現物の突き合わせで撃つ。
    # 印の行そのものが、残りもせず控えにも入らずに消える形を、これで捕える
    # (変異試験で現に生き残った穴である)。
    make_page yes
    local orig="$TEST_TMPDIR/orig.md"
    /usr/bin/cp "$DASH" "$orig"
    run run_cut --apply
    assert_success
    local arcfile="$ARC/dashboard_archive_$(date +%Y%m%d).md"
    # 頁に残った分 = 指し先の 1 行を除く全部
    local kept; kept=$(( $(/usr/bin/wc -l < "$DASH") - 1 ))
    local rebuilt="$TEST_TMPDIR/rebuilt.md"
    /usr/bin/head -n "$kept" "$DASH" > "$rebuilt"
    # 控えに移った分 = 追記の見出し (<!-- ===== ... ===== -->) より下
    local sep; sep=$(/usr/bin/grep -n 'に dashboard.md から移した' "$arcfile" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
    /usr/bin/tail -n +"$((sep + 1))" "$arcfile" >> "$rebuilt"
    run /usr/bin/diff "$orig" "$rebuilt"
    assert_success
}

@test "cmd_1470: 控えは追記である — 既に在る控えを上書きしない" {
    local arcfile="$ARC/dashboard_archive_$(date +%Y%m%d).md"
    printf '前から在った記録 XYZ\n' > "$arcfile"
    make_page yes
    run run_cut --apply
    assert_success
    run /usr/bin/grep -c '前から在った記録 XYZ' "$arcfile"
    assert_output "1"
    run /usr/bin/grep -c '畢わった記録' "$arcfile"
    assert_output "38"
}

@test "cmd_1470: 最終書込の刻を戻す (番人が「今さっき働いた」と誤読しないため)" {
    make_page yes
    /usr/bin/touch -d '2020-01-02 03:04:05' "$DASH"
    run run_cut --apply
    assert_success
    run /usr/bin/stat -c '%y' "$DASH"
    assert_output --partial "2020-01-02 03:04:05"
}

@test "cmd_1470: inode を替えない (見張りが古い inode に取り残されないため)" {
    make_page yes
    local before; before="$(/usr/bin/stat -c '%i' "$DASH")"
    run run_cut --apply
    assert_success
    [ "$(/usr/bin/stat -c '%i' "$DASH")" = "$before" ]
}

@test "cmd_1470: 移す 🚨 の本数を黙って呑まず、必ず名乗る" {
    make_page yes
    run run_cut --apply
    assert_success
    assert_output --partial "🚨 を含む見出し 1 本"
}

# ── 陰性 ───────────────────────────────────────────────────────────

@test "cmd_1470/陰性: 印が無ければ 1 バイトも動かない" {
    make_page no
    local before; before="$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)"
    run run_cut --apply
    assert_success
    assert_output --partial "1 バイトも移さぬ"
    [ "$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)" = "$before" ]
    # ★黙って緑にしない★ = 印の置き方まで刷る
    assert_output --partial "KARO_CUT_HERE"
    # 控えも控え先も作らない
    run /usr/bin/find "$ARC" -type f
    assert_output ""
}

@test "cmd_1470/陰性: 印が 2 本 在れば止まり、1 バイトも動かない" {
    make_page twice
    local before; before="$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)"
    run run_cut --apply
    assert_failure 3
    assert_output --partial "止まる"
    [ "$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)" = "$before" ]
    run /usr/bin/find "$ARC" -type f
    assert_output ""
}

@test "cmd_1470/陰性: 印が頁の頭に在れば止まる (頁を丸ごと移す事故)" {
    printf '# 🏯 殿の頁\n<!-- KARO_CUT_HERE -->\n' > "$DASH"
    local i; for i in $(seq 1 40); do printf '記録 %s\n' "$i" >> "$DASH"; done
    local before; before="$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)"
    run run_cut --apply
    assert_failure 4
    [ "$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)" = "$before" ]
}

@test "cmd_1470/陰性: 印より下に中身が無ければ、控えを作らない" {
    : > "$DASH"
    local i; for i in $(seq 1 60); do printf '記録 %s\n' "$i" >> "$DASH"; done
    printf '<!-- KARO_CUT_HERE -->\n\n\n' >> "$DASH"
    run run_cut --apply
    assert_success
    assert_output --partial "1 バイトも移さぬ"
    run /usr/bin/find "$ARC" -type f
    assert_output ""
}

@test "cmd_1470/陰性: 空撃ちは 1 バイトも書かない" {
    make_page yes
    local before; before="$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)"
    run run_cut
    assert_success
    assert_output --partial "★空撃ちである"
    [ "$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)" = "$before" ]
    run /usr/bin/find "$ARC" -type f
    assert_output ""
}

@test "cmd_1470/陰性: 対象が無ければ止まる" {
    run run_cut --apply
    assert_failure 2
    assert_output --partial "対象が無い"
}

# ── canary (探し方が生きている証) ──────────────────────────────────

@test "cmd_1470: canary は陽性と陰性の両方を撃つ" {
    make_page yes
    run run_cut --canary
    assert_success
    assert_output --partial "陽性"
    assert_output --partial "陰性"
    assert_output --partial "印 (KARO_CUT_HERE) の本数              : 1 件"
}

@test "cmd_1470: canary は走査が死んでいれば赤になる" {
    # 陽性の綴りを 1 つも持たない頁 = 走査が死んでいる形と同じ顔
    printf 'ここには目印が無い\n' > "$DASH"
    run run_cut --canary
    assert_failure
    assert_output --partial "走査が死んでいる公算"
}

# ── 配線 (既定の対象が現物を指しているか) ─────────────────────────

@test "cmd_1470/配線: 既定の対象は現物の dashboard.md である" {
    # 入力を差し替えて撃つ試験は、入力を読む口を試験しない (cmd_1450)。
    # ここだけ --file を渡さず、既定の path が現物を指していることを撃つ。
    #
    # ★--show-target を使う。空撃ち (--dry-run) では撃たない。★
    # 理由 = 2026-07-28 18:17 に現に踏んだ。変異試験で空撃ちの守りを 1 つ外した時、
    # この試験だけが現物の dashboard.md を対象にしていたため、★試験が殿の頁を現に切った★
    # (897,623 → 98,389 byte)。控えから戻したので失った物は無いが、
    # ★「守りが 1 つ壊れた時に、現物へ届く道が試験の側に在った」★ のが誤りである。
    # --show-target は書く道の手前で畢わるので、道具のどこが壊れていても現物へ届かない。
    local before; before="$(/usr/bin/sha256sum "$PROJECT_ROOT/dashboard.md" | /usr/bin/cut -d' ' -f1)"
    run bash "$PROJECT_ROOT/scripts/dashboard_archive.sh" --show-target
    assert_success
    assert_output --partial "対象   = $PROJECT_ROOT/dashboard.md"
    assert_output --partial "控え先 = $PROJECT_ROOT/archive"
    [ "$(/usr/bin/sha256sum "$PROJECT_ROOT/dashboard.md" | /usr/bin/cut -d' ' -f1)" = "$before" ]
}

@test "cmd_1470/配線: --show-target は 1 バイトも書かない (守りが壊れていても)" {
    # 上の配線の試験が、現物へ届かないことを別に撃つ。
    make_page yes
    local before; before="$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)"
    run run_cut --show-target --apply
    assert_success
    [ "$(/usr/bin/sha256sum "$DASH" | /usr/bin/cut -d' ' -f1)" = "$before" ]
    run /usr/bin/find "$ARC" -type f
    assert_output ""
}
