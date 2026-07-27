#!/usr/bin/env bats
# test_pointer_into_ignored_ledger.bats
#   追跡外のファイルを「◯◯:行番号」の形で根拠として指していないかを見るテスト。
#
# 何を守るテストか (cmd_1450・2026-07-28):
#   scripts/idle_revive_scan.py の2箇所が、週次上限 banner を検知する pattern の根拠として
#   dashboard の行と足軽四号の report YAML の行を、行番号つきで指していた。
#   report YAML はその後 上書きされ、指していた行番号はとうに範囲外になっていた。
#
#   問題は行番号がずれたことではない。指し先の性質である。
#     ・どちらも .gitignore で追跡外なので、上書きされた時点で git からも復元できない。
#     ・2026-07-28 に確認した実測 = この banner の literal を含む commit は
#       40cdde0 の1本だけで、dashboard と report YAML の側には1つも無い。
#     ⇒ 行番号を書き直しても、次の上書きでまた同じことが起きる。
#
#   ゆえに根拠は git に残る物 (commit) を指す形へ替えた。このテストは、
#   同じ形が戻ってこないように縛る。
#
# このテストが見ない範囲 (緑でも言えないこと):
#   1. 追跡されているファイルへの行番号の指しは見ない。そちらは git で復元できるので、
#      壊れても読み返す道が残る。害の大きさが違う。
#   2. 「今 斯く書いてある」と指す形と「昔 斯う書いてあった」と引く形を区別できない。
#      引用のつもりで綴りをそのまま書けば、このテストは指しと同じように鳴る。
#      実際、直している最中に筆者自身が古い綴りをそのまま註へ書き写して鳴らした。
#      鳴った側が正しい。綴りを書かない形へ直した。
#   3. 見るのは下の TARGETS に挙げたファイルだけである。他のスクリプトは見ていない。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    # 直す前の版。陽性の対照に使う (この版では現に2件 見つかるはず)
    export BEFORE_REV="70c6bb0"
    export TARGETS="scripts/idle_revive_scan.py"
}

# 引数のファイルを読み、追跡外のファイルへの「path:行番号」を1行ずつ出す
find_bad_pointers() {
    grep -oE "[A-Za-z0-9_][A-Za-z0-9_./-]*\.(md|yaml|yml|txt):[0-9]+" "$1" \
    | sort -u \
    | while IFS= read -r hit; do
        p="${hit%:*}"
        # 実在して、かつ git が無視するファイルだけを拾う
        if [ -e "$PROJECT_ROOT/$p" ] && \
           git -C "$PROJECT_ROOT" check-ignore -q "$p" 2>/dev/null; then
            echo "$hit"
        fi
    done
}

@test "T-PTR-001 陽性の対照: 直す前の版では現に見つかる (探し方が生きている証)" {
    before="$BATS_TEST_TMPDIR/before.py"
    git -C "$PROJECT_ROOT" show "${BEFORE_REV}:scripts/idle_revive_scan.py" > "$before"
    run find_bad_pointers "$before"
    [ "$status" -eq 0 ]
    # この2件が cmd_1450 で見つかった当の物である。
    # 0件になったらテストが死んでいる。壊れていないのではなく、探せていない。
    [[ "$output" == *"dashboard.md:462"* ]]
    [[ "$output" == *"queue/reports/ashigaru4_report.yaml:2778"* ]]
    [ "$(echo "$output" | grep -c .)" -eq 2 ]
}

@test "T-PTR-002 今の版には1件も無い" {
    for f in $TARGETS; do
        run find_bad_pointers "$PROJECT_ROOT/$f"
        [ "$status" -eq 0 ]
        if [ -n "$output" ]; then
            echo "追跡外のファイルを行番号で指している: $f"
            echo "$output"
            return 1
        fi
    done
}

@test "T-PTR-003 変異: 新しく1件 足したら鳴る" {
    tmp="$BATS_TEST_TMPDIR/mutated.py"
    cp "$PROJECT_ROOT/scripts/idle_revive_scan.py" "$tmp"
    # 追跡外のファイルへの指しを1件 足す
    echo '# 根拠 = dashboard.md:999' >> "$tmp"
    run find_bad_pointers "$tmp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dashboard.md:999"* ]]
}

@test "T-PTR-004 負の対照: 追跡されているファイルへの指しでは鳴らない" {
    tmp="$BATS_TEST_TMPDIR/tracked.py"
    # CLAUDE.md は git が追跡している。行番号で指しても、このテストの対象外である
    # (害の大きさが違うため。射程は冒頭に書いてある)
    echo '# 参考 = CLAUDE.md:1' > "$tmp"
    run find_bad_pointers "$tmp"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-PTR-005 前提: 対照に使う版が現に読める" {
    # BEFORE_REV が gc や rebase で消えると T-PTR-001 が「見つからない」で黙って通りうる。
    # ここで先に落としておく。
    run git -C "$PROJECT_ROOT" cat-file -e "${BEFORE_REV}:scripts/idle_revive_scan.py"
    [ "$status" -eq 0 ]
}
