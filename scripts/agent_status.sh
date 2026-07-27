#!/usr/bin/env bash
# scripts/agent_status.sh — Show busy/idle status of all agents in tmux panes
#
# Usage:
#   bash scripts/agent_status.sh                    # Auto-detect from config
#   bash scripts/agent_status.sh --session myses    # Specify tmux session
#   bash scripts/agent_status.sh --panes 0,1,2,3    # Specify pane indices
#   bash scripts/agent_status.sh --lang en          # English labels
#
# Works in two modes:
#   1. Project mode (default): Reads agent list from config/settings.yaml
#      and shows task YAML + inbox status alongside pane state.
#   2. Standalone mode (--session/--panes): Just shows tmux pane busy/idle
#      state without project-specific data. Works anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Defaults ───
LANG_MODE="ja"
SESSION_NAME=""
MANUAL_PANES=""
STANDALONE=false

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lang)    LANG_MODE="$2"; shift 2 ;;
        --session) SESSION_NAME="$2"; STANDALONE=true; shift 2 ;;
        --panes)   MANUAL_PANES="$2"; STANDALONE=true; shift 2 ;;
        --help|-h)
            echo "Usage: agent_status.sh [--session NAME] [--panes 0,1,2] [--lang en|ja]"
            echo ""
            echo "Options:"
            echo "  --session NAME   Tmux session to scan (default: auto-detect)"
            echo "  --panes N,N,N    Comma-separated pane indices to check"
            echo "  --lang en|ja     Output language (default: ja)"
            echo ""
            echo "Without options, reads config/settings.yaml for agent definitions."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Load shared library ───
source "$SCRIPT_DIR/lib/agent_status.sh"

# ─── Load pane CLI liveness library (cmd_1418) ───
# 「pane に何が描かれているか」ではなく「pane で CLI プロセスが現に動いているか」を見る。
# 無くても既存の表示は動く (実体欄が '不明' になるだけ)。
PCL_AVAILABLE=false
if [[ -f "$SCRIPT_DIR/lib/pane_cli_liveness.sh" ]]; then
    source "$SCRIPT_DIR/lib/pane_cli_liveness.sh"
    PCL_AVAILABLE=true
fi

# 実体欄の値を返す。ライブラリが無い時は '不明' / 'UNKNOWN'。
proc_state_label() {
    local pane_target="$1" expected_cli="${2:-}"
    if ! $PCL_AVAILABLE; then
        pane_cli_liveness_label_fallback "$LANG_MODE"
        return
    fi
    local verdict
    verdict=$(pane_cli_liveness_check "$pane_target" "$expected_cli") || true
    pane_cli_liveness_label "$verdict" "$LANG_MODE"
}

pane_cli_liveness_label_fallback() {
    [[ "${1:-ja}" == "en" ]] && echo "UNKNOWN" || echo "不明"
}

# ─── Label functions ───
state_label() {
    local rc="$1"
    if [[ "$LANG_MODE" == "en" ]]; then
        case $rc in
            0) echo "BUSY" ;;
            1) echo "IDLE" ;;
            2) echo "N/A" ;;
        esac
    else
        case $rc in
            0) echo "稼働中" ;;
            1) echo "待機中" ;;
            2) echo "不在" ;;
        esac
    fi
}

# ─── CJK-aware padding ───
# printf doesn't account for double-width CJK characters.
# This function prints a field with correct visual alignment.
print_padded() {
    local text="$1" width="$2"
    # Calculate display width: byte length minus char count gives extra bytes from multibyte chars
    local byte_len char_len extra_bytes display_width pad
    byte_len=$(echo -n "$text" | wc -c)
    char_len=${#text}
    # Each CJK char is 3 bytes in UTF-8 and 2 display columns.
    # extra_bytes = byte_len - char_len = (3-1)*cjk_count = 2*cjk_count
    # display_width = char_len + cjk_count = char_len + extra_bytes/2
    extra_bytes=$((byte_len - char_len))
    display_width=$((char_len + extra_bytes / 2))
    pad=$((width - display_width))
    if (( pad < 0 )); then pad=0; fi
    printf "%s%*s" "$text" "$pad" ""
}

# ═══════════════════════════════════════════
# Standalone mode: just scan tmux panes
# ═══════════════════════════════════════════
if $STANDALONE; then
    # Determine session
    if [[ -z "$SESSION_NAME" ]]; then
        SESSION_NAME=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
        if [[ -z "$SESSION_NAME" ]]; then
            echo "Error: not inside a tmux session and --session not specified" >&2
            exit 1
        fi
    fi

    # Determine panes — collect all window:pane pairs across the session
    declare -a PANE_TARGETS=()
    if [[ -n "$MANUAL_PANES" ]]; then
        IFS=',' read -ra _indices <<< "$MANUAL_PANES"
        for pidx in "${_indices[@]}"; do
            PANE_TARGETS+=("${SESSION_NAME}:${pidx}")
        done
    else
        # List all panes across all windows in the session
        while IFS= read -r line; do PANE_TARGETS+=("$line"); done < <(tmux list-panes -s -t "$SESSION_NAME" -F '#{session_name}:#{window_name}.#{pane_index}' 2>/dev/null)
    fi

    # 全 pane を同じ瞬間のプロセス表で判ずる (cmd_1418)
    $PCL_AVAILABLE && pane_cli_liveness_snapshot on

    # Header
    printf "\n"
    if [[ "$LANG_MODE" == "en" ]]; then
        printf "%-30s %-10s %-9s %s\n" "Pane" "State" "Process" "Agent ID"
        printf "%-30s %-10s %-9s %s\n" "------------------------------" "----------" "---------" "----------"
    else
        printf "%-30s %-10s %-9s %s\n" "Pane" "状態" "実体" "Agent ID"
        printf "%-30s %-10s %-9s %s\n" "------------------------------" "----------" "---------" "----------"
    fi

    for pane_target in "${PANE_TARGETS[@]}"; do
        # Try reading @agent_id from the pane
        agent_id=$(timeout 2 tmux display-message -t "$pane_target" -p '#{@agent_id}' 2>/dev/null || echo "---")
        [[ -z "$agent_id" ]] && agent_id="---"

        agent_is_busy_check "$pane_target" && rc=0 || rc=$?
        label=$(state_label "$rc")
        proc_label=$(proc_state_label "$pane_target")

        print_padded "$pane_target" 30
        printf " "
        print_padded "$label" 10
        printf " "
        print_padded "$proc_label" 9
        printf " %s\n" "$agent_id"
    done
    printf "\n"
    exit 0
fi

# ═══════════════════════════════════════════
# Project mode: full status with task/inbox
# ═══════════════════════════════════════════
cd "$SCRIPT_DIR"

# Load cli_adapter if available (for get_cli_type)
CLI_ADAPTER_AVAILABLE=false
if [[ -f "$SCRIPT_DIR/lib/cli_adapter.sh" ]]; then
    source "$SCRIPT_DIR/lib/cli_adapter.sh"
    CLI_ADAPTER_AVAILABLE=true
fi

if [[ -f "$SCRIPT_DIR/lib/agent_registry.sh" ]]; then
    source "$SCRIPT_DIR/lib/agent_registry.sh"
fi

# Python (PyYAML)
PYTHON="${SCRIPT_DIR}/.venv/bin/python3"
PYTHON_AVAILABLE=false
if [[ -x "$PYTHON" ]]; then
    PYTHON_AVAILABLE=true
fi

# Agent definitions (from settings.yaml formation; legacy partial configs fall back)
AGENTS=()
if declare -f agent_registry_multiagent_agents >/dev/null 2>&1; then
    while IFS= read -r _agent; do
        [ -n "$_agent" ] && AGENTS+=("$_agent")
    done < <(agent_registry_multiagent_agents)
fi
if [ "${#AGENTS[@]}" -eq 0 ]; then
    # 最後の手段。settings.yaml が読めない時だけ使う旧構成 (OSS 素の陣容) の名前で、
    # 今の盤の陣容ではない。今の盤は pane 0-8 = karo + ashigaru1-6 + gunshi1(pane 7)
    # + gunshi2(pane 8) (2026-07-27 実測。ashigaru7 と 名無しの gunshi は居ない)。
    # 旧構成の盤でも点呼が落ちないよう、この一覧そのものは減らさない。
    AGENTS=("karo" "ashigaru1" "ashigaru2" "ashigaru3" "ashigaru4" "ashigaru5" "ashigaru6" "ashigaru7" "gunshi")
fi

# pane-base-index
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

# ─── Helper: task info from YAML ───
get_task_info() {
    local agent_id="$1"
    local yaml_file="$SCRIPT_DIR/queue/tasks/${agent_id}.yaml"
    if [[ ! -f "$yaml_file" ]] || ! $PYTHON_AVAILABLE; then
        echo "--- ---"
        return
    fi
    "$PYTHON" -c "
import yaml, sys
try:
    with open('${yaml_file}') as f:
        data = yaml.safe_load(f) or {}
    task = data.get('task', data)
    tid = task.get('task_id', '---')
    status = task.get('status', '---')
    print(f'{tid} {status}')
except Exception:
    print('--- ---')
" 2>/dev/null || echo "--- ---"
}

# ─── Helper: unread inbox count ───
get_unread_count() {
    local agent_id="$1"
    local inbox_file="$SCRIPT_DIR/queue/inbox/${agent_id}.yaml"
    if [[ ! -f "$inbox_file" ]] || ! $PYTHON_AVAILABLE; then
        echo "-"
        return
    fi
    "$PYTHON" -c "
import yaml, sys
try:
    with open('${inbox_file}') as f:
        data = yaml.safe_load(f) or {}
    msgs = data.get('messages', [])
    unread = sum(1 for m in msgs if not m.get('read', False))
    print(unread)
except Exception:
    print('?')
" 2>/dev/null || echo "?"
}

# ─── 廃止済みのエージェント (cmd_1418) ───
# settings.yaml に deprecated: true と書かれた定義 (cmd_645 の gunshi_a / gunshi_b)。
# pane は元より無いため、既存の点呼はこれを「待機中」と出していた = 誤り。
# 一覧から除くと「居たものが黙って消える」形になるので、除かずに札を替える。
DEPRECATED_AGENTS=()
if declare -f agent_registry_deprecated_agents >/dev/null 2>&1; then
    while IFS= read -r _d; do
        [ -n "$_d" ] && DEPRECATED_AGENTS+=("$_d")
    done < <(agent_registry_deprecated_agents)
fi
is_deprecated_agent() {
    local a
    for a in ${DEPRECATED_AGENTS[@]+"${DEPRECATED_AGENTS[@]}"}; do
        [[ "$a" == "$1" ]] && return 0
    done
    return 1
}
deprecated_label() {
    if $PCL_AVAILABLE; then
        pane_cli_liveness_label deprecated "$LANG_MODE"
    else
        [[ "$LANG_MODE" == "en" ]] && echo "RETIRED" || echo "廃止済"
    fi
}

# 全 pane を同じ瞬間のプロセス表で判ずる (cmd_1418)
$PCL_AVAILABLE && pane_cli_liveness_snapshot on

# ─── Output ───
printf "\n"
if [[ "$LANG_MODE" == "en" ]]; then
    printf "%-10s %-7s %-9s %-9s %-42s %-10s %s\n" "Agent" "CLI" "State" "Process" "Task ID" "Status" "Inbox"
    printf "%-10s %-7s %-9s %-9s %-42s %-10s %s\n" "----------" "-------" "---------" "---------" "------------------------------------------" "----------" "-----"
else
    printf "%-10s %-7s %-9s %-9s %-42s %-10s %s\n" "Agent" "CLI" "Pane" "実体" "Task ID" "Status" "Inbox"
    printf "%-10s %-7s %-9s %-9s %-42s %-10s %s\n" "----------" "-------" "---------" "---------" "------------------------------------------" "----------" "-----"
fi

retired_count=0
for i in "${!AGENTS[@]}"; do
    agent="${AGENTS[$i]}"
    pane_idx=$((PANE_BASE + i))
    pane_target="multiagent:agents.${pane_idx}"

    # CLI type
    if $CLI_ADAPTER_AVAILABLE; then
        cli_type=$(get_cli_type "$agent" 2>/dev/null || echo "?")
    else
        cli_type="?"
    fi

    if is_deprecated_agent "$agent"; then
        # 廃止済み — pane は無い。生死を問う対象ではないので判定しない。
        retired_count=$((retired_count + 1))
        pane_state=$(deprecated_label)
        proc_state="-"
    else
        # Pane state
        agent_is_busy_check "$pane_target" "$cli_type" && rc=0 || rc=$?
        pane_state=$(state_label "$rc")

        # 実体 (pane で CLI プロセスが現に動いているか) — cmd_1418
        # metadata (CLI 欄) が緑でも実体が落ちている形を、ここで名指す。
        proc_state=$(proc_state_label "$pane_target" "$cli_type")
    fi

    # Task info
    task_info=$(get_task_info "$agent")
    task_id=$(echo "$task_info" | awk '{print $1}')
    task_status=$(echo "$task_info" | awk '{$1=""; print $0}' | sed 's/^ //')

    # Unread inbox
    unread=$(get_unread_count "$agent")

    # Print with CJK padding
    printf "%-10s %-7s " "$agent" "$cli_type"
    print_padded "$pane_state" 9
    printf " "
    print_padded "$proc_state" 9
    printf " %-42s %-10s %s\n" "$task_id" "$task_status" "$unread"
done

printf "\n"

# 母数の内訳を必ず出す (cmd_1418)。廃止済みを黙って除かない・黙って混ぜない。
active_count=$(( ${#AGENTS[@]} - retired_count ))
retired_names=""
if (( retired_count > 0 )); then
    retired_names=" ($(IFS=,; echo "${DEPRECATED_AGENTS[*]}"))"
fi
if [[ "$LANG_MODE" == "en" ]]; then
    printf "Total %d = active %d + retired %d%s\n" \
        "${#AGENTS[@]}" "$active_count" "$retired_count" "$retired_names"
    if (( retired_count > 0 )); then
        printf "Retired entries have no pane; liveness is not judged for them.\n"
    fi
else
    printf "母数 %d 件 = 現役 %d 件 + 廃止済み %d 件%s\n" \
        "${#AGENTS[@]}" "$active_count" "$retired_count" "$retired_names"
    if (( retired_count > 0 )); then
        printf "廃止済みは pane が無い。生死の判定は行わない (実体欄は -)。\n"
    fi
fi
printf "\n"
