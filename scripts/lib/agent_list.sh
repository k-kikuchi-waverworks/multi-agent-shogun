#!/usr/bin/env bash
# scripts/lib/agent_list.sh
# cmd_652 (2026-05-16): settings.yaml `cli.agents` 動的読込 helper (yq 不在ゆえ python3 + PyYAML 採用)
#
# 提供関数:
#   - get_active_agents          : settings.yaml の cli.agents から deprecated:true を除外したキー列挙
#   - get_active_ashigaru_agents : 上記から ashigaru* のみ抽出
#   - get_active_gunshi_agents   : 上記から gunshi* のみ抽出 (gunshi_a/b deprecated 除外)
#   - get_command_layer_agents   : shogun + karo + 全 active gunshi (ashigaru 除外)
#   - is_command_layer_agent <name> : 0=true, 1=false
#   - is_deprecated_agent <name>    : 0=true (deprecated:true 設定あり), 1=false
#   - get_agent_pane <name>      : settings.yaml の pane: field を返却 (gunshi1/2 用)、なければ空
#
# 使い方:
#   source scripts/lib/agent_list.sh
#   for agent in $(get_active_agents); do ...; done

# このファイルが置かれたディレクトリの 2 階層上 = リポジトリルート
_AGENT_LIST_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_AGENT_LIST_SETTINGS_FILE="${_AGENT_LIST_REPO_ROOT}/config/settings.yaml"

_agent_list_dispatch() {
    local mode="$1"
    shift || true
    python3 - "$mode" "$@" "${_AGENT_LIST_SETTINGS_FILE}" <<'PYEOF'
import sys
import yaml

argv = sys.argv[1:]
if not argv:
    sys.exit(2)
mode = argv[0]
settings_file = argv[-1]
extras = argv[1:-1]
target = extras[0] if extras else None

try:
    with open(settings_file, "r") as f:
        data = yaml.safe_load(f)
except FileNotFoundError:
    sys.exit(0)

agents = (data or {}).get("cli", {}).get("agents", {}) or {}

def is_deprecated(cfg):
    return bool((cfg or {}).get("deprecated", False))

def active_keys():
    return [k for k, v in agents.items() if not is_deprecated(v)]

if mode == "active":
    print("\n".join(active_keys()))
elif mode == "active_ashigaru":
    print("\n".join(k for k in active_keys() if k.startswith("ashigaru")))
elif mode == "active_gunshi":
    print("\n".join(k for k in active_keys() if k.startswith("gunshi")))
elif mode == "all_gunshi":
    # active + deprecated 全 gunshi* (cmd_645 retain 用)
    print("\n".join(k for k in agents.keys() if k.startswith("gunshi")))
elif mode == "is_deprecated":
    cfg = agents.get(target, {})
    sys.exit(0 if is_deprecated(cfg) else 1)
elif mode == "pane":
    cfg = agents.get(target, {}) or {}
    print(cfg.get("pane", ""))
else:
    sys.exit(2)
PYEOF
}

get_active_agents() {
    _agent_list_dispatch active
}

get_active_ashigaru_agents() {
    _agent_list_dispatch active_ashigaru
}

get_active_gunshi_agents() {
    _agent_list_dispatch active_gunshi
}

# active + deprecated を含む全 gunshi*。shutsujin_departure.sh の queue/inbox 初期化等で
# cmd_645 由来の deprecated agent (gunshi_a/b) も file 初期化対象に保つために使う。
# legacy 'gunshi' (settings.yaml に存在しないが backward compat retain) は呼出側で追加。
get_all_gunshi_agents() {
    _agent_list_dispatch all_gunshi
}

# shogun + karo + active gunshi (ashigaru は除外)。command-layer agent 判定用。
get_command_layer_agents() {
    {
        echo shogun
        echo karo
        get_active_gunshi_agents
    } | awk 'NF'
}

is_command_layer_agent() {
    # 命名規約ベース判定 (settings.yaml 状態に依存しない、deprecated gunshi も command-layer 扱いで
    # watcher 抑制を維持)。新 agent class 追加時は本関数の case 文を更新せよ。
    local target="$1"
    case "$target" in
        shogun|karo) return 0 ;;
        gunshi*)     return 0 ;;  # gunshi1/gunshi2/gunshi_a/gunshi_b/gunshi (legacy) 全て command-layer
        *)           return 1 ;;
    esac
}

is_deprecated_agent() {
    local target="$1"
    [ -z "$target" ] && return 1
    _agent_list_dispatch is_deprecated "$target"
}

get_agent_pane() {
    local target="$1"
    [ -z "$target" ] && return 1
    _agent_list_dispatch pane "$target"
}
