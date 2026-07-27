#!/usr/bin/env bash
# scripts/pane_cli_liveness.sh — pane で CLI プロセスが現に動いているかを見る (cmd_1418)
#
# 使い方:
#   bash scripts/pane_cli_liveness.sh                      # 全エージェントを見る
#   bash scripts/pane_cli_liveness.sh --pane multiagent:agents.5
#   bash scripts/pane_cli_liveness.sh --pane multiagent:agents.5 --expect claude
#   bash scripts/pane_cli_liveness.sh --quiet              # 落ちている pane だけ出す
#
# 判定の意味 (lib/pane_cli_liveness.sh):
#   生存 alive     期待した CLI のプロセスが現に居る
#   落ち dead      CLI が一つも居ない (pane は shell だけ)
#   別CLI mismatch CLI は居るが札と違う
#   不在 no_pane   pane が無い
#   不明 unknown   見られなかった
#   廃止済         settings.yaml に deprecated: true と書かれている (プロセスは見ない)
#
# 廃止済みの扱い (cmd_1418):
#   gunshi_a / gunshi_b は cmd_645 で廃止され、定義だけ settings.yaml に残っている。
#   pane は元より無いので「不在」と出るが、それは異常ではない。
#   一覧から黙って除くと「居たものが消えた」と誤読されるため、除かずに
#   「廃止済」と別に名乗らせ、件数を必ず末尾に出す。生存判定の対象からは外す。
#
# 終了コード:
#   0 = 見た pane すべてが生存 (廃止済みは数に入れない)
#   1 = 落ち / 別CLI / 不在 / 不明 が1つ以上あった
#   2 = 使い方の誤り
#
# 枷: 読むだけ。プロセスへ signal を送らない。pane を殺さない。
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PANE_TARGET=""
EXPECT_CLI=""
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pane)   PANE_TARGET="$2"; shift 2 ;;
        --expect) EXPECT_CLI="$2"; shift 2 ;;
        --quiet)  QUIET=true; shift ;;
        --help|-h)
            sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

source "$PROJECT_ROOT/lib/pane_cli_liveness.sh"

report_one() {
    local pane_target="$1" expected="$2" agent="$3"
    local detail verdict pid argv label
    detail=$(pane_cli_liveness_detail "$pane_target" "$expected") || true
    IFS=$'\t' read -r verdict pid argv <<< "$detail"
    label=$(pane_cli_liveness_label "$verdict")

    if [[ "$verdict" == "alive" ]]; then
        $QUIET && return 0
    fi

    printf '%-24s %-12s %-6s pid=%-8s %s\n' "$pane_target" "$agent" "$label" "$pid" "$argv"
    [[ "$verdict" == "alive" ]]
}

# ─── 単一 pane ───
if [[ -n "$PANE_TARGET" ]]; then
    report_one "$PANE_TARGET" "$EXPECT_CLI" "-" && exit 0 || exit 1
fi

# ─── 全エージェント ───
if [[ -f "$PROJECT_ROOT/lib/cli_adapter.sh" ]]; then
    source "$PROJECT_ROOT/lib/cli_adapter.sh"
fi
if [[ -f "$PROJECT_ROOT/lib/agent_registry.sh" ]]; then
    source "$PROJECT_ROOT/lib/agent_registry.sh"
fi

AGENTS=()
if declare -f agent_registry_multiagent_agents >/dev/null 2>&1; then
    while IFS= read -r _a; do [[ -n "$_a" ]] && AGENTS+=("$_a"); done \
        < <(agent_registry_multiagent_agents)
fi
if [[ "${#AGENTS[@]}" -eq 0 ]]; then
    AGENTS=(karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi)
fi

PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

# 廃止済み (settings.yaml の deprecated: true) を先に控える
DEPRECATED=()
if declare -f agent_registry_deprecated_agents >/dev/null 2>&1; then
    while IFS= read -r _d; do [[ -n "$_d" ]] && DEPRECATED+=("$_d"); done \
        < <(agent_registry_deprecated_agents)
fi
_is_deprecated() {
    local a
    for a in ${DEPRECATED[@]+"${DEPRECATED[@]}"}; do
        [[ "$a" == "$1" ]] && return 0
    done
    return 1
}

# 全 pane を同じ瞬間のプロセス表で判ずる
pane_cli_liveness_snapshot on

bad=0
retired=0
for i in "${!AGENTS[@]}"; do
    agent="${AGENTS[$i]}"
    pane_target="multiagent:agents.$((PANE_BASE + i))"

    # 廃止済みはプロセスを見ない。除かずに札だけ替えて出す。
    if _is_deprecated "$agent"; then
        retired=$((retired + 1))
        $QUIET || printf '%-24s %-12s %-6s pid=%-8s %s\n' \
            "$pane_target" "$agent" "$(pane_cli_liveness_label deprecated)" "-" \
            "settings.yaml に deprecated: true"
        continue
    fi

    expected=""
    if declare -f get_cli_type >/dev/null 2>&1; then
        expected=$(get_cli_type "$agent" 2>/dev/null || true)
    fi
    report_one "$pane_target" "$expected" "$agent" || bad=$((bad + 1))
done

live=$(( ${#AGENTS[@]} - retired ))

# 母数の内訳は常に出す (静かな時も廃止済みの件数を黙って落とさない)
echo ""
echo "母数 ${#AGENTS[@]} 件 = 現役 ${live} 件 + 廃止済み ${retired} 件"

if (( bad > 0 )); then
    echo "生存でない pane: ${bad} 件 (現役 ${live} 件のうち)"
    exit 1
fi
echo "現役 ${live} 件 すべて生存"
exit 0
