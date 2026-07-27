#!/usr/bin/env bash
# tests/mutation_cmd1418_pane_cli_liveness.sh — cmd_1418
#
# 問い: test_pane_cli_liveness.bats は「緑になる試験」か、「壊せば落ちる試験」か。
#
# やり方: lib/pane_cli_liveness.sh をわざと壊し、狙った試験が現に落ちるかを見る。
# 判定は二段で出す (本日の全軍規 第五条)。
#   ① 壊した後の md5 が原本と違うか  … 違わなければ「変異が当たっていない」
#   ② 狙った試験が現に落ちたか        … 落ちなければ「試験が意味に届いていない」
# ①だけで緑と読まない。
#
# 負の対照 (NC) を1本 置く: 註釈を1行 足すだけの変異。md5 は動くが試験は全緑のはず。
# これが赤くなるなら、試験が中身でなく file の同一性を見ていることになる。
#
# 安全 (本日の全軍規 第六条):
#   ・原本は撃つ前に控え、trap で必ず書き戻す。
#   ・書き戻した後に md5 を原本と照合し、違えば HALT する。
#   ・稼働中の multiagent セッションには触れない。試験は使い捨てセッションを建てて畳む。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SUT="lib/pane_cli_liveness.sh"
BATS_FILE="tests/unit/test_pane_cli_liveness.bats"

[[ -f "$SUT" ]] || { echo "被検体が無い: $SUT" >&2; exit 2; }
[[ -f "$BATS_FILE" ]] || { echo "試験が無い: $BATS_FILE" >&2; exit 2; }
command -v bats >/dev/null || { echo "bats が無い" >&2; exit 2; }

TMP="$(mktemp -d)"
BACKUP="$TMP/orig.sh"
cp "$SUT" "$BACKUP"
# 撃つ直前に控えた原本の md5 (事後に「今の原本」と較べない — 第二条)
ORIG_MD5="$(md5sum < "$BACKUP" | awk '{print $1}')"

restore_and_verify() {
    cp "$BACKUP" "$SUT"
    local now
    now="$(md5sum < "$SUT" | awk '{print $1}')"
    if [[ "$now" != "$ORIG_MD5" ]]; then
        echo ""
        echo "HALT: 書き戻しに失敗した。原本 md5=$ORIG_MD5 / 現在 md5=$now"
        echo "      控えは $BACKUP に在る (この dir は消さない)"
        return 1
    fi
    rm -rf "$TMP"
    return 0
}
trap 'restore_and_verify || exit 3' EXIT

# ─── 変異の定義 ───
# 各行: 名前 | 説明 | 期待 (red=狙った試験が落ちる / green=全緑のまま) | 試験の絞り
declare -a NAMES=() DESCS=() EXPECTS=() FILTERS=()

add_mut() { NAMES+=("$1"); DESCS+=("$2"); EXPECTS+=("$3"); FILTERS+=("$4"); }

add_mut MUT-A "pane の存在確認 (list-panes) を外す" red "T-PCL-00[67]"
add_mut MUT-B "常に alive を返す"                    red "T-PCL-001"
add_mut MUT-C "木を辿らず pane_pid だけ見る"          red "T-PCL-00[34]"
add_mut MUT-D "node 噛ませの分岐を外す"               red "T-PCL-008"
add_mut MUT-E "mismatch を dead へ倒す"               red "T-PCL-005"
add_mut NC    "註釈を1行 足すだけ (負の対照)"          green "T-PCL-"

apply_mut() {
    case "$1" in
        MUT-A)
            python3 - "$SUT" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "    if ! timeout 2 tmux list-panes -t \"$pane_target\" -F '#{pane_id}' >/dev/null 2>&1; then\n        printf 'no_pane\\t-\\t-\\n'; return 2\n    fi\n",
    "")
open(p, "w").write(s)
PY
            ;;
        MUT-B)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "pane_cli_liveness_detail() {\n    local pane_target=\"$1\"",
    "pane_cli_liveness_detail() {\n    printf 'alive\\t0\\tmutated\\n'; return 0\n    local pane_target=\"$1\"")
open(p, "w").write(s)
PY
            ;;
        MUT-C)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '    while IFS= read -r p; do pids+=("$p"); done < <(_pcl_process_tree "$pane_pid")',
    '    pids=("$pane_pid")')
open(p, "w").write(s)
PY
            ;;
        MUT-D)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("        node|nodejs|bun|deno|python|python3|env)",
              "        __never_matches_after_mutation__)")
open(p, "w").write(s)
PY
            ;;
        MUT-E)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("        printf 'mismatch\\t%s\\t%s\\n' \"$other_pid\" \"$other_argv\"\n        return 3",
              "        printf 'dead\\t%s\\t%s\\n' \"$other_pid\" \"$other_argv\"\n        return 1")
open(p, "w").write(s)
PY
            ;;
        NC)
            printf '\n# 負の対照のために足した註釈 (中身に効かない)\n' >> "$SUT"
            ;;
        *) return 2 ;;
    esac
}

# ─── 実行 ───
echo "═══ cmd_1418 変異テスト ═══"
echo "被検体: $SUT"
echo "試験  : $BATS_FILE"
echo "原本 md5: $ORIG_MD5"
echo ""

FAIL=0
for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"; desc="${DESCS[$i]}"; expect="${EXPECTS[$i]}"; filt="${FILTERS[$i]}"

    cp "$BACKUP" "$SUT"
    apply_mut "$name" || { echo "$name: 変異の当て方が判らぬ"; FAIL=$((FAIL+1)); continue; }

    mut_md5="$(md5sum < "$SUT" | awk '{print $1}')"

    # ① md5 が動いたか
    if [[ "$mut_md5" == "$ORIG_MD5" ]]; then
        printf '%-6s %-34s ① md5 差 0 → 当たっていない = 赤\n' "$name" "$desc"
        FAIL=$((FAIL+1))
        continue
    fi

    # ② 狙った試験が現に落ちたか
    out="$(bats -f "$filt" "$BATS_FILE" 2>&1)"
    rc=$?
    nfail=$(grep -c '^not ok' <<< "$out" || true)
    nok=$(grep -c '^ok ' <<< "$out" || true)

    if [[ "$expect" == "red" ]]; then
        if (( nfail > 0 )); then
            printf '%-6s %-34s ①md5差 有 ②落ちた (not ok %s / ok %s) → 良し\n' \
                "$name" "$desc" "$nfail" "$nok"
        else
            printf '%-6s %-34s ①md5差 有 ②落ちなかった → 試験が意味に届いていない\n' \
                "$name" "$desc"
            echo "$out" | sed 's/^/        /' | head -20
            FAIL=$((FAIL+1))
        fi
    else
        if (( nfail == 0 )) && (( nok > 0 )); then
            printf '%-6s %-34s ①md5差 有 ②全緑 (ok %s) → 良し (md5 差は当たりの証にならぬ)\n' \
                "$name" "$desc" "$nok"
        else
            printf '%-6s %-34s ①md5差 有 ②落ちた → 試験が中身でなく file の同一性を見ている\n' \
                "$name" "$desc"
            echo "$out" | sed 's/^/        /' | head -20
            FAIL=$((FAIL+1))
        fi
    fi
done

cp "$BACKUP" "$SUT"

echo ""
if (( FAIL == 0 )); then
    echo "結果: 変異 ${#NAMES[@]} 本すべて期待どおり (赤 5 / 負の対照 1)"
    exit 0
fi
echo "結果: ${#NAMES[@]} 本中 ${FAIL} 本が期待どおりでない"
exit 1
