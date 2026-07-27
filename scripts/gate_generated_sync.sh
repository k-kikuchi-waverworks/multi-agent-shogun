#!/usr/bin/env bash
# gate_generated_sync.sh — cmd_1435 (2026-07-28 足軽四号)
#   cmd_1437 で3箇所 直した（軍師一号の検分）。
#     ・出口の一覧が門の中に二度 手書きで在った → 1箇所へ寄せた
#     ・新しい生成物が増えた日を、出口 5 口のうち 3 口で数えなんだ → 数える形へ替えた
#     ・「作り直しが作った物」を機械で数えるようにした（手書きの find を消した）
#
# ■ 何を見る門か
#   CLAUDE.md などの正本から scripts/build_instructions.sh が作る生成物が、
#   正本に追いついているかを commit の直前に検める。
#
#   起源: 2026-07-27 に CLAUDE.md が 10:40 と 17:36 の2度 変わったが、写しは1度も
#   追いつかなかった。作業ツリーに残っていた写しは 02:17 版で、10:40 に「言い過ぎ」
#   として訂正された記述を持っていた。そのまま commit すれば、訂正前の版だけが
#   Codex / Copilot / 既定エージェントへ配られる所であった。
#   気づけたのは、たまたま未 commit として git に見えていたからである。
#   02:17 に commit されていれば、写しは古いまま緑になり、誰も気づかなかった。
#
# ■ 探し方（なぜこの形か）
#   一時の場所へ index の中身だけで作り直し、index の生成物と1バイト単位で比べる。
#   生成物は毎回 作り直せば必ず一致するため、差分がそのまま「追いついていない証」になる。
#   mtime やコミット時刻では比べない。時刻は「誰が書いたか」を答えないため。
#   比べる相手を作業ツリーではなく index にしたのは、commit されようとしている中身
#   そのものを測るためである（CLAUDE.md だけを stage して生成物を stage し忘れた形も捕える）。
#
# ■ 返り値
#   0 = 一致、または今回の commit に関わりが無い（黙る）
#   1 = ずれている → commit を止める
#   2 = 判じられぬ → 大声で警告して通す（作り直しが走らなかった等）
#
#   ★拒む側に倒した理由★: 生成物は1行で作り直せるゆえ書き手を止める費えが小さい。
#   一方これは全エージェントへ配られる規そのものであり、古い版が commit されると
#   訂正前の規に従って動く者が出る。費えが小さく害が大きいゆえ拒む。
#
# ■ 使い方
#   bash scripts/gate_generated_sync.sh           # commit 対象に関わる時だけ検める
#   bash scripts/gate_generated_sync.sh --all     # stage の絞りを外して全数を検める
#   bash scripts/gate_generated_sync.sh --scope   # 母数と、この門が見ない範囲を印字して終わる
#
# ■ この門が見ない範囲（緑の射程）は --scope で印字する。docs も参照:
#   plans/cmd_1435_generated_sync_gate.md

set -uo pipefail

PASS=0
FAIL=1
UNDETERMINED=2

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# ── 母数の宣言 ────────────────────────────────────────────────────────
# 触れば作り直しが要る物（入口）
SOURCES=(
    CLAUDE.md
    instructions/shogun.md
    instructions/karo.md
    instructions/ashigaru.md
    instructions/gunshi.md
    instructions/common
    instructions/cli_specific
    config/opencode-permissions.yaml
    scripts/build_instructions.sh
)

# 作られる物の置き場（出口）。「追跡されているのに作られなくなった物」を見るための母数。
# ★cmd_1437: この一覧は門の中でここ1箇所だけに在る。★
#   以前は extra 検知の find にも同じ一覧が手で書いてあり、置き場を足す日に片方だけ直せば
#   比べる側は見て extra 側は見ぬ片肺になる形であった（軍師一号の指摘3）。
#   今は「砂場で作り直した物」を撃つ前後の差で機械に数えさせるため、第二の写しが要らない。
OUTPUT_ROOTS=(
    AGENTS.md
    .github/copilot-instructions.md
    agents/default
    instructions/generated
    .opencode/agents
)

# build が作るが、意図して git へ載せぬ物。★ここに書いた物だけが「増えても黙る」★
#   cmd_1437: 以前は git check-ignore で握り潰していた。だがこの repo の .gitignore は
#   白名簿（既定で全て無視）ゆえ、★新しい生成物はどこに増えても「無視される」と読まれ、
#   門は黙った★。軍師一号の実測では出口 5 口のうち 3 口が盲であった
#   （agents/default 直下・.github 直下・repo 直下）。
#   ゆえに「無視されるか」でなく「あらかじめ宣言したか」で黙らせる形へ替えた。
UNTRACKED_BY_DESIGN=(
    'agents/default/agent.yaml'        # 中身は CLAUDE.md に依らぬ固定文（heredoc）ゆえ正本とずれる形が無い
    '.opencode/agents/*-runtime.md'    # git 管理外の config/settings.yaml に依り機械ごとに変わる
)

untracked_by_design() {
    local p="$1" pat
    for pat in "${UNTRACKED_BY_DESIGN[@]}"; do
        # shellcheck disable=SC2254
        case "$p" in $pat) return 0 ;; esac
    done
    return 1
}

# ── 引数 ──────────────────────────────────────────────────────────────
MODE=staged
case "${1:-}" in
    --all)   MODE=all ;;
    --scope) MODE=scope ;;
    "")      ;;
    *) echo "[gate-5] 知らぬ引数: $1 (--all / --scope のみ)" >&2; exit "$UNDETERMINED" ;;
esac

cd "$ROOT" 2>/dev/null || { echo "[gate-5] repo root へ移れぬ: $ROOT" >&2; exit "$UNDETERMINED"; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "[gate-5] git repo でない" >&2; exit "$UNDETERMINED"; }

# ── 母数と射程の印字 ──────────────────────────────────────────────────
print_scope() {
    local tracked
    tracked="$(git ls-files -- "${OUTPUT_ROOTS[@]}" | wc -l)"
    echo "=== gate_generated_sync — 母数と射程 (cmd_1435 / cmd_1437 で盲点3件を直した) ==="
    echo
    echo "[入口] 触れば作り直しが要る物 ${#SOURCES[@]} 口:"
    printf '  %s\n' "${SOURCES[@]}"
    echo
    echo "[出口] 検分する生成物 = 下の置き場の git 追跡ファイル ${tracked} 本:"
    local r n
    for r in "${OUTPUT_ROOTS[@]}"; do
        n="$(git ls-files -- "$r" | wc -l)"
        echo "  $r  … ${n} 本"
    done
    echo
    echo "[増えても黙る物 — 宣言した ${#UNTRACKED_BY_DESIGN[@]} 口だけ]"
    printf '  %s\n' "${UNTRACKED_BY_DESIGN[@]}"
    echo
    echo "[この門が見ない範囲 — 緑と同じ大きさで書く]"
    cat <<'EOS'
  1. agents/default/agent.yaml — build が作るが、上のとおり宣言して黙らせてある。
     中身は CLAUDE.md に依らぬ固定文（heredoc）ゆえ、正本とずれる形が無い。
     ★宣言した以上、この1本が壊れても門は何も言わぬ。★
  2. .opencode/agents/*-runtime.md — 同じく宣言して黙らせてある。
     git 管理外の config/settings.yaml に依るため機械ごとに中身が変わる。
     検分の砂場へは settings.yaml を渡さぬゆえ、この門は1本も作らず、1本も見ない。
  3. git add していない変更 — この門は index を見る。作業ツリーだけの変更は見えぬ。
     （commit されぬ物は配られぬゆえ、これは意図した射程である）
  4. --no-verify で越えた commit / SHOGUN_GATE_SKIP=1 — hook そのものが走らぬ。
  5. 出口の置き場が増えた時（cmd_1437 で狭めた）—
     ★新しい置き場へ生成物が増えた事自体は検知する★（作り直しが作った物を機械で数え、
     追跡下にも宣言にも無ければ名指す）。残る盲点は2つだけである。
       (a) staged の絞り: 新しい置き場の file だけを stage し、入口にも既存の出口にも
           触れぬ commit では、この門は発火せぬ（--all なら見る）。
           ただし置き場が増えるには build_instructions.sh を触る要があり、それは入口ゆえ普通は発火する。
       (b) 新しい置き場の物が「作られなくなった」形は見えぬ。OUTPUT_ROOTS に無いためである。
  6. 他の repo（engine 等）— この門はこの repo の中だけを見る。
  7. 生成物が「正しいか」は見ない。見るのは「正本から作り直した物と同じか」だけである。
  8. build_instructions.sh が毎回 同じ物を作ることを前提にしている。
     時刻や乱数を混ぜる作りに変われば、この門は毎回 赤くなる（其の時は門でなく build を疑え）。
  9. path に改行を含む生成物は数えぬ（作り直した物の一覧を行で数えるため）。
     今は1本も無い。
EOS
}

if [ "$MODE" = scope ]; then
    print_scope
    exit "$PASS"
fi

# ── 今回の commit に関わりが有るか ────────────────────────────────────
in_scope() {
    local p="$1" e
    for e in "${SOURCES[@]}" "${OUTPUT_ROOTS[@]}"; do
        [ "$p" = "$e" ] && return 0
        case "$p" in "$e"/*) return 0 ;; esac
    done
    return 1
}

if [ "$MODE" = staged ]; then
    hit=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if in_scope "$p"; then hit=1; break; fi
    done < <(git diff --cached --name-only --diff-filter=ACMRD 2>/dev/null)
    # 関わりが無ければ黙る。CLAUDE.md にも生成物にも触れぬ commit で鳴らさぬため。
    [ "$hit" -eq 1 ] || exit "$PASS"
fi

# ── 砂場で作り直す ────────────────────────────────────────────────────
TMPROOT="$(mktemp -d)" || { echo "[gate-5] 一時の場所を作れぬ" >&2; exit "$UNDETERMINED"; }
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT
SB="$TMPROOT/build"      # 作り直した物
SB_IDX="$TMPROOT/index"  # index に在る物
mkdir -p "$SB" "$SB_IDX"

# 入口を index から取り出す（作業ツリーではなく、commit されようとしている中身）。
if ! git ls-files -z -- "${SOURCES[@]}" | git checkout-index --prefix="$SB/" -f -z --stdin 2>"$TMPROOT/co.err"; then
    echo "[gate-5] ⚠ index から入口を取り出せなんだ:"
    sed 's/^/    /' "$TMPROOT/co.err" >&2
    exit "$UNDETERMINED"
fi

if [ ! -f "$SB/scripts/build_instructions.sh" ]; then
    echo "[gate-5] ⚠ index に scripts/build_instructions.sh が無い。判じられぬ。" >&2
    exit "$UNDETERMINED"
fi

# PyYAML を持つ python が要る。repo の .venv が在れば読ませる（読むだけ）。
[ -d "$ROOT/.venv" ] && ln -s "$ROOT/.venv" "$SB/.venv" 2>/dev/null

# ★作り直す前の姿を控える★ — 撃つ前と後の差が、そのまま「build が作った物」になる。
# 一覧を手で書かぬのはこのためである（置き場を足す日に片方だけ直す形を無くす）。
list_sandbox() { ( cd "$SB" && find . \( -type f -o -type l \) -printf '%P\n' | sort ); }
list_sandbox > "$TMPROOT/sb_before"

# config/settings.yaml は渡さない。git 管理外で機械ごとに変わり、
# *-runtime.md（これも git 管理外）だけを左右するためである。
if ! bash "$SB/scripts/build_instructions.sh" >"$TMPROOT/build.log" 2>&1; then
    echo "[gate-5] ⚠ 作り直しが走らなんだ（ずれの有無は判じられぬ）:"
    tail -15 "$TMPROOT/build.log" | sed 's/^/    /'
    exit "$UNDETERMINED"
fi

list_sandbox > "$TMPROOT/sb_after"
comm -13 "$TMPROOT/sb_before" "$TMPROOT/sb_after" > "$TMPROOT/produced"
n_produced="$(grep -c . "$TMPROOT/produced")"

# 作り直しが1本も作らなんだ時に「ずれ 0 本」と読ませぬため。
if [ "${n_produced:-0}" -eq 0 ]; then
    echo "[gate-5] ⚠ 作り直しが生成物を1本も作らなんだ。門が当たっておらぬ疑い。" >&2
    exit "$UNDETERMINED"
fi

# ── index の生成物と1バイト単位で比べる ──────────────────────────────
stale=()   # 中身がずれている
missing=() # index に在るが作り直しでは出来なかった
extra=()   # 作り直しでは出来るが index に無く、宣言もされておらぬ

# 追跡下の全 file。★出口の一覧に依らずに突き合わせるため★ =
# 新しい置き場が増えて commit された日も、中身のずれは見える。
tracked_all="$TMPROOT/tracked_all"
git ls-files > "$tracked_all"

# 出口として宣言した置き場の追跡 file。「作られなくなった物」を見るための母数。
tracked_list="$TMPROOT/tracked"
git ls-files -- "${OUTPUT_ROOTS[@]}" > "$tracked_list"

# 母数が 0 なら「見ていない」を「0件」と読ませぬため判じられぬとする。
if [ "$(grep -c . "$tracked_list")" -eq 0 ]; then
    echo "[gate-5] ⚠ 検分すべき生成物が index に1本も無い。門が当たっておらぬ疑い。" >&2
    exit "$UNDETERMINED"
fi

# 作り直した物を3つへ分ける: 追跡下 / 宣言して黙らせる物 / それ以外（＝ extra）
to_check=()
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if grep -Fxq "$p" "$tracked_all"; then
        to_check+=("$p")
    elif untracked_by_design "$p"; then
        :
    else
        extra+=("$p")
    fi
done < "$TMPROOT/produced"

# 比べる相手（index の生成物）も同じ口から出す。
# ★片側だけ git の改行変換を通る形にせぬため★ — 今日は .md に変換が掛からぬが、
# 明日 .gitattributes が1行 増えた時に、この門が静かに誤り出す形を作らない。
if [ "${#to_check[@]}" -gt 0 ]; then
    if ! printf '%s\0' "${to_check[@]}" | git checkout-index --prefix="$SB_IDX/" -f -z --stdin 2>"$TMPROOT/co2.err"; then
        echo "[gate-5] ⚠ index から生成物を取り出せなんだ:"
        sed 's/^/    /' "$TMPROOT/co2.err" >&2
        exit "$UNDETERMINED"
    fi
fi

total=0
for p in ${to_check[@]+"${to_check[@]}"}; do
    total=$((total + 1))
    if ! cmp -s "$SB_IDX/$p" "$SB/$p"; then
        stale+=("$p")
    fi
done

# 追跡されておるのに、作り直しでは出来なくなった物
while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -Fxq "$p" "$TMPROOT/produced" || missing+=("$p")
done < "$tracked_list"

n_bad=$(( ${#stale[@]} + ${#missing[@]} + ${#extra[@]} ))

if [ "$n_bad" -eq 0 ]; then
    echo "[gate-5] PASS: 生成物 ${total} 本すべて正本と一致 (作り直して1バイト単位で比較)"
    exit "$PASS"
fi

echo "════════════════════════════════════════════════════════════════"
echo "[gate-5] ★FAIL — 生成物が正本に追いついておらぬ★ (cmd_1435)"
echo "  検分 ${total} 本 / ずれ ${n_bad} 本"
[ ${#stale[@]} -gt 0 ] && { echo "  ── 中身がずれている (${#stale[@]} 本):"; printf '     %s\n' "${stale[@]}"; }
[ ${#missing[@]} -gt 0 ] && { echo "  ── 作り直しでは出来なかった (${#missing[@]} 本):"; printf '     %s\n' "${missing[@]}"; }
[ ${#extra[@]} -gt 0 ] && { echo "  ── 作り直しでは出来るが commit 対象に無い (${#extra[@]} 本):"; printf '     %s\n' "${extra[@]}"; }
echo
echo "  直し方 (この2行で済む):"
echo "    bash scripts/build_instructions.sh"
echo "    git add ${OUTPUT_ROOTS[*]}"
echo
echo "  ★正本を1行 直して生成物を古いまま commit すると、訂正前の規が"
echo "    Codex / Copilot / 既定エージェントへ配られる。2026-07-27 に現に起きかけた形である。★"
echo "  この門が見ない範囲: bash scripts/gate_generated_sync.sh --scope"
echo "  緊急回避 (理由必須): SHOGUN_GATE_SKIP=1 git commit ..."
echo "════════════════════════════════════════════════════════════════"
exit "$FAIL"
