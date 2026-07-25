#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.
#
# cmd_652 (2026-05-16): settings.yaml `cli.agents` 動的読込化 (cmd_645 hard-coded list 廃止)。
# - ashigaru / gunshi 列挙は scripts/lib/agent_list.sh 経由で settings.yaml から動的取得
# - shogun (別 pane shogun:main.0) と karo (multiagent:agents.0) は special、hardcoded retain
# - ashigaru{N} の pane = multiagent:agents.{N} 規則で導出 (番号 = pane index)
# - gunshi{N} の pane は settings.yaml `cli.agents.<gunshi>.pane` field を参照
# - deprecated agent (settings.yaml の deprecated:true) は自動 skip
# - pane 不在時 (例: gunshi2 の pane 0.9 殿手動起動前) は start_watcher_if_missing 内 pane_exists guard で skip

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=lib/agent_list.sh
. "$SCRIPT_DIR/scripts/lib/agent_list.sh"

mkdir -p logs queue/inbox

get_multiagent_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli
    local lockfile="/tmp/shogun_watcher_start_${agent}.lock"

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    (
        flock -n 9 || return 0
        if pgrep -Ef "scripts/inbox_watcher.sh ${agent} ${pane}( |$)" >/dev/null 2>&1; then
            return 0
        fi

        if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher detected for ${agent}; starting watcher for expected pane ${pane}" >&2
        fi

        cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
        nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] inbox_watcher started for ${agent} pane=${pane} PID=$!" >&2
    ) 9>"$lockfile"
}

resolve_pane_by_agent_id() {
    # ★cmd_1339 (2026-07-25) 起源=@agent_id を pane 解決の第一正本にする★
    # 背景: 実 pane 配置が 0.6=gunshi1 / 0.7=ashigaru6 とずれた状態で、
    #       「ashigaru{N} → agents.{N}」の命名規約 hardcode により watcher が交差配達した。
    #       plain nudge は「起こす相手が違うだけ(各agentは自分のinboxを読む)」ゆえ軽症だが、
    #       ★clear_command は /clear + 指示文を pane へ直接送るため、別agentのsessionを吹き飛ばし
    #       他人の task 指示を渡す★ (2026-07-25 18:19/18:20 に軍師一号と足軽六号で実発生)。
    # ⇒ 各 CLI session は SessionStart hook が読む @agent_id で自己識別するゆえ、@agent_id が正本。
    #    見つからねば従来規約へ fallback (回帰非破壊)。
    local agent="$1"
    local found=""
    found=$(tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index} #{@agent_id}" 2>/dev/null \
        | awk -v a="$agent" '$2 == a { print $1; exit }' || true)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
}

ashigaru_pane() {
    # ★@agent_id 優先 → 見つからねば命名規約 ashigaru{N} → multiagent:agents.{N} へ fallback★
    local agent="$1"
    local resolved=""
    if resolved=$(resolve_pane_by_agent_id "$agent"); then
        echo "$resolved"
        return 0
    fi
    local idx="${agent#ashigaru}"
    echo "multiagent:agents.${idx}"
}

gunshi_pane_resolved() {
    # ★gunshi も @agent_id 優先。settings.yaml の pane: field は fallback★
    # (settings.yaml は 2026-07-25 時点で gunshi1=agents.7 と記載されていたが実体は agents.6 であった)
    local agent="$1"
    local resolved=""
    if resolved=$(resolve_pane_by_agent_id "$agent"); then
        echo "$resolved"
        return 0
    fi
    get_agent_pane "$agent"
}

# cmd_1255 (2026-07-11): 台帳(shogun_to_karo.yaml)parse自己検証gate=ledger_guard watcher。
# per-agent inbox watcher と異なり pane 非依存の singleton(台帳file監視)。
# 未起動時のみ nohup 起動(pgrep で重複防止・inbox watcher の start_watcher_if_missing と同型)。
start_ledger_guard_if_missing() {
    local lockfile="/tmp/shogun_ledger_guard_start.lock"
    (
        flock -n 9 || return 0
        if pgrep -Ef "scripts/ledger_guard.sh" >/dev/null 2>&1; then
            return 0
        fi
        nohup bash scripts/ledger_guard.sh >> "logs/ledger_guard.log" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] ledger_guard started PID=$!" >&2
    ) 9>"$lockfile"
}

while true; do
    start_watcher_if_missing "shogun" "shogun:main.0" "logs/inbox_watcher_shogun.log"
    start_watcher_if_missing "karo" "multiagent:agents.0" "logs/inbox_watcher_karo.log"

    # cmd_1255: 台帳parse自己検証gate(singleton・pane非依存)
    start_ledger_guard_if_missing

    # cmd_652 (2026-05-16): ashigaru list を settings.yaml から動的取得
    while IFS= read -r ash; do
        [ -n "$ash" ] || continue
        start_watcher_if_missing "$ash" "$(ashigaru_pane "$ash")" "logs/inbox_watcher_${ash}.log"
    done < <(get_active_ashigaru_agents)

    # cmd_652 (2026-05-16): active gunshi list を settings.yaml から動的取得 (deprecated 除外)
    while IFS= read -r gun; do
        [ -n "$gun" ] || continue
        local_pane=$(gunshi_pane_resolved "$gun")   # cmd_1339: @agent_id 優先・settings.yaml は fallback
        [ -n "$local_pane" ] || continue  # pane 未設定 gunshi はスキップ
        start_watcher_if_missing "$gun" "$local_pane" "logs/inbox_watcher_${gun}.log"
    done < <(get_active_gunshi_agents)

    sleep 5
done
