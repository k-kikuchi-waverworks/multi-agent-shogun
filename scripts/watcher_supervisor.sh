#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.
#
# cmd_652 (2026-05-16): settings.yaml `cli.agents` 動的読込化 (cmd_645 hard-coded list 廃止)。
# - ashigaru / gunshi 列挙は scripts/lib/agent_list.sh 経由で settings.yaml から動的取得
# - shogun (別 pane shogun:main.0) と karo (multiagent:agents.0) は special、hardcoded retain
# - ashigaru{N} の pane = multiagent:agents.{N} 規則で導出 (番号 = pane index)
# - 軍師の pane は settings.yaml `cli.agents.<gunshi>.pane` field を参照
# - deprecated agent (settings.yaml の deprecated:true) は自動 skip
# - pane がまだ無い時は start_watcher_if_missing の pane_exists guard で skip する

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
        # pgrep は元から ERE。-E はこの環境の procps-ng に無く、付けると常に
        # invalid option で失敗し「既に動いている」を検出できず二重起動になる
        if pgrep -f "scripts/inbox_watcher.sh ${agent} ${pane}( |$)" >/dev/null 2>&1; then
            return 0
        fi

        if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] stale watcher detected for ${agent}; starting watcher for expected pane ${pane}" >&2
        fi

        cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
        # 家老だけ ASW_PHASE=1 (殿の裁 2026-08-03)。理由は shutsujin_departure.sh の家老の行を見よ。
        # ここを落とすと、家老の watcher が1度 落ちた日から黙って 2 (差し込み順) へ戻る。
        local phase_env=""
        [ "$agent" = "karo" ] && phase_env="ASW_PHASE=1"
        nohup env $phase_env bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [START] inbox_watcher started for ${agent} pane=${pane} PID=$!" >&2
    ) 9>"$lockfile"
}

ashigaru_pane() {
    # 命名規約: ashigaru{N} → multiagent:agents.{N}
    local agent="$1"
    local idx="${agent#ashigaru}"
    echo "multiagent:agents.${idx}"
}

while true; do
    # 将軍の watcher はここでは扱わない。shutsujin_departure.sh が安全モード
    # (ASW_DISABLE_ESCALATION=1 / ASW_PROCESS_TIMEOUT=0) 付きで起動しており、
    # ここから素の環境で起動し直すと殿の pane へ /clear を撃つ側に化けるため。
    # start_watcher_if_missing "shogun" "shogun:main.0" "logs/inbox_watcher_shogun.log"
    start_watcher_if_missing "karo" "multiagent:agents.0" "logs/inbox_watcher_karo.log"


    # cmd_652 (2026-05-16): ashigaru list を settings.yaml から動的取得
    while IFS= read -r ash; do
        [ -n "$ash" ] || continue
        start_watcher_if_missing "$ash" "$(ashigaru_pane "$ash")" "logs/inbox_watcher_${ash}.log"
    done < <(get_active_ashigaru_agents)

    # cmd_652 (2026-05-16): active gunshi list を settings.yaml から動的取得 (deprecated 除外)
    while IFS= read -r gun; do
        [ -n "$gun" ] || continue
        local_pane=$(get_agent_pane "$gun")
        [ -n "$local_pane" ] || continue  # pane 未設定 gunshi はスキップ
        start_watcher_if_missing "$gun" "$local_pane" "logs/inbox_watcher_${gun}.log"
    done < <(get_active_gunshi_agents)

    sleep 5
done
