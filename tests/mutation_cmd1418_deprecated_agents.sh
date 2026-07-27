#!/usr/bin/env bash
# tests/mutation_cmd1418_deprecated_agents.sh — cmd_1418 (追加分)
#
# 問い: test_agent_registry_deprecated.bats は「緑になる試験」か、「壊せば落ちる試験」か。
#
# 被検体は lib/agent_registry.sh に足した口 (settings.yaml の deprecated: true を読む)。
# これを壊し、狙った試験が現に落ちるかを見る。
#
# 判定は二段で出す (全軍規 第五条)。
#   ① 壊した後の md5 が原本と違うか … 違わなければ「変異が当たっていない」
#   ② 狙った試験が現に落ちたか       … 落ちなければ「試験が意味に届いていない」
#
# 負の対照 (NC) を1本 置く。註釈を1行 足すだけ。md5 は動くが試験は全緑のはず。
#
# 安全 (全軍規 第六条): 原本は撃つ前に控え、trap で必ず書き戻し、
# 書き戻した後に md5 を照合して不一致なら HALT する。
# settings.yaml も pane も一切 触らない。試験は見本 (tmpdir) だけを読む。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SUT="lib/agent_registry.sh"
BATS_FILE="tests/unit/test_agent_registry_deprecated.bats"

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

declare -a NAMES=() DESCS=() EXPECTS=() FILTERS=()
add_mut() { NAMES+=("$1"); DESCS+=("$2"); EXPECTS+=("$3"); FILTERS+=("$4"); }

add_mut MUT-P "flag を見ずに全件 廃止済と読む"   red   "T-ARD-00[14]"
add_mut MUT-Q "名前の直書き (gunshi_a/b) へ置換" red   "T-ARD-00[123]"
add_mut MUT-R "deprecated: false も拾う"          red   "T-ARD-004"
add_mut MUT-S "cli 節の外も拾う"                  red   "T-ARD-006"
add_mut MUT-T "可否判定を常に真にする"            red   "T-ARD-005"
add_mut NC    "註釈を1行 足すだけ (負の対照)"     green "T-ARD-"

apply_mut() {
    case "$1" in
        MUT-P)
            # flag を見ず、agents 節の全件を印字する
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '''            if (agent != "" && $0 ~ /^[[:space:]]{6}deprecated:[[:space:]]*true([[:space:]]|$)/) {
                print agent
                agent = ""
            }''',
    '''            if (agent != "") {
                print agent
                agent = ""
            }''')
open(p, "w").write(s)
PY
            ;;
        MUT-Q)
            # settings.yaml を読まず、現物の名前を直書きで返す
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '''agent_registry_deprecated_agents() {
    local settings="${1:-$AGENT_REGISTRY_SETTINGS}"''',
    '''agent_registry_deprecated_agents() {
    printf '%s\\n' gunshi_a gunshi_b; return 0
    local settings="${1:-$AGENT_REGISTRY_SETTINGS}"''')
open(p, "w").write(s)
PY
            ;;
        MUT-R)
            # true の縛りを外し、deprecated 欄が在るだけで拾う
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '$0 ~ /^[[:space:]]{6}deprecated:[[:space:]]*true([[:space:]]|$)/',
    '$0 ~ /^[[:space:]]{6}deprecated:/')
open(p, "w").write(s)
PY
            ;;
        MUT-S)
            # cli 節を抜けた印を消す (節の外の deprecated まで拾う)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '''        in_cli && /^[^[:space:]#]/ {
            in_cli = 0
            in_agents = 0
        }

        in_cli && /^[[:space:]]{2}agents:[[:space:]]*$/ {
            in_agents = 1
            next
        }

        in_agents {
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { next }
            if ($0 !~ /^[[:space:]]{4}/) { exit }''',
    '''        in_cli && /^[[:space:]]{2}agents:[[:space:]]*$/ {
            in_agents = 1
            next
        }

        in_agents {
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { next }''')
open(p, "w").write(s)
PY
            ;;
        MUT-T)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    '''agent_registry_is_deprecated() {
    local wanted="$1"''',
    '''agent_registry_is_deprecated() {
    return 0
    local wanted="$1"''')
open(p, "w").write(s)
PY
            ;;
        NC)
            python3 - "$SUT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "agent_registry_deprecated_agents() {",
    "# 負の対照のために足した註釈 (意味は変えない)\nagent_registry_deprecated_agents() {")
open(p, "w").write(s)
PY
            ;;
    esac
}

FAIL=0
echo "被検体: $SUT (原本 md5=$ORIG_MD5)"
echo "試験  : $BATS_FILE"
echo ""

for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"; desc="${DESCS[$i]}"
    expect="${EXPECTS[$i]}"; filt="${FILTERS[$i]}"

    cp "$BACKUP" "$SUT"
    apply_mut "$name"

    # ① md5 が動いたか
    mut_md5="$(md5sum < "$SUT" | awk '{print $1}')"
    if [[ "$mut_md5" == "$ORIG_MD5" ]]; then
        printf '%-6s %-34s ①md5差 無 → 変異が当たっていない\n' "$name" "$desc"
        FAIL=$((FAIL+1))
        continue
    fi

    # ② 狙った試験が現に落ちたか
    out="$(bats -f "$filt" "$BATS_FILE" 2>&1)"
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
