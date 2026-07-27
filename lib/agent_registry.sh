#!/usr/bin/env bash
# Shared agent formation helpers.
#
# `cli.agents` historically served both as per-agent CLI overrides and as the
# runtime formation list. To keep old partial override configs working, a parsed
# list is treated as a formation only when it contains `karo`.

AGENT_REGISTRY_PROJECT_ROOT="${AGENT_REGISTRY_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AGENT_REGISTRY_SETTINGS="${AGENT_REGISTRY_SETTINGS:-${SHOGUN_SETTINGS_FILE:-${AGENT_REGISTRY_PROJECT_ROOT}/config/settings.yaml}}"

agent_registry_default_agents() {
    printf '%s\n' \
        shogun \
        karo \
        ashigaru1 \
        ashigaru2 \
        ashigaru3 \
        ashigaru4 \
        ashigaru5 \
        ashigaru6 \
        ashigaru7 \
        gunshi
}

agent_registry_read_agents_from_settings() {
    local settings="${1:-$AGENT_REGISTRY_SETTINGS}"
    [ -f "$settings" ] || return 0

    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }

        /^cli:[[:space:]]*$/ {
            in_cli = 1
            in_agents = 0
            next
        }

        in_cli && /^[^[:space:]]/ {
            in_cli = 0
            in_agents = 0
        }

        in_cli && /^[[:space:]]{2}agents:[[:space:]]*$/ {
            in_agents = 1
            next
        }

        in_agents {
            if ($0 !~ /^[[:space:]]{4}/) {
                exit
            }
            if ($0 ~ /^[[:space:]]{4}[A-Za-z0-9_-]+:[[:space:]]*/) {
                line = $0
                sub(/^[[:space:]]*/, "", line)
                sub(/:.*/, "", line)
                print line
            }
        }
    ' "$settings"
}

# 廃止済みのエージェントを 1 行ずつ印字する (cmd_1418)。
#
# settings.yaml の `cli.agents.<name>.deprecated: true` を見る。
# 廃止済みでも定義は残してある (cmd_645 の gunshi_a / gunshi_b が現物)。
# pane は元より無いので、点呼では「不在」でも「待機中」でもなく
# 「廃止済」と別に名乗らせる。一覧から黙って除くと、後から読む者が
# 「居たものが消えた」と誤る。
agent_registry_deprecated_agents() {
    local settings="${1:-$AGENT_REGISTRY_SETTINGS}"
    [ -f "$settings" ] || return 0

    awk '
        /^cli:[[:space:]]*$/ {
            in_cli = 1
            in_agents = 0
            next
        }

        in_cli && /^[^[:space:]#]/ {
            in_cli = 0
            in_agents = 0
        }

        in_cli && /^[[:space:]]{2}agents:[[:space:]]*$/ {
            in_agents = 1
            next
        }

        in_agents {
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { next }
            if ($0 !~ /^[[:space:]]{4}/) { exit }
            if ($0 ~ /^[[:space:]]{4}[A-Za-z0-9_-]+:[[:space:]]*/) {
                line = $0
                sub(/^[[:space:]]*/, "", line)
                sub(/:.*/, "", line)
                agent = line
                next
            }
            if (agent != "" && $0 ~ /^[[:space:]]{6}deprecated:[[:space:]]*true([[:space:]]|$)/) {
                print agent
                agent = ""
            }
        }
    ' "$settings"
}

# agent_registry_is_deprecated <agent> [settings] → 廃止済みなら rc=0
agent_registry_is_deprecated() {
    local wanted="$1" settings="${2:-$AGENT_REGISTRY_SETTINGS}" agent
    while IFS= read -r agent; do
        [ "$agent" = "$wanted" ] && return 0
    done < <(agent_registry_deprecated_agents "$settings")
    return 1
}

agent_registry_has_agent() {
    local wanted="$1"
    shift || true
    local agent
    for agent in "$@"; do
        [ "$agent" = "$wanted" ] && return 0
    done
    return 1
}

agent_registry_agents() {
    local parsed=()
    local agent

    while IFS= read -r agent; do
        [ -n "$agent" ] && parsed+=("$agent")
    done < <(agent_registry_read_agents_from_settings "$AGENT_REGISTRY_SETTINGS")

    if [ "${#parsed[@]}" -eq 0 ] || ! agent_registry_has_agent "karo" "${parsed[@]}"; then
        agent_registry_default_agents
        return 0
    fi

    if ! agent_registry_has_agent "shogun" "${parsed[@]}"; then
        printf '%s\n' shogun
    fi
    printf '%s\n' "${parsed[@]}"
}

agent_registry_multiagent_agents() {
    local agent
    while IFS= read -r agent; do
        [ "$agent" = "shogun" ] && continue
        printf '%s\n' "$agent"
    done < <(agent_registry_agents)
}

agent_registry_multiagent_pane_for_agent() {
    local wanted="$1"
    local pane_base="${2:-0}"

    # cmd_1339 (g): ★@agent_id を第一正本に格上げ★。settings 順序による index 導出は
    # 実 pane 配置がずれた瞬間に沈黙して壊れる (2026-07-25 交差配達事故 / idle_revive の
    # busy probe が別 pane を読み thinking 中の agent へ誤 /clear した事故の共通根)。
    # index 規約は @agent_id 不在環境 (旧構成) の fallback に格下げ。
    # scripts/lib/pane_gate.sh pane_gate_resolve_by_agent_id と同一 idiom。
    local found=""
    found=$(tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index} #{@agent_id}" 2>/dev/null \
        | awk -v a="$wanted" '$2 == a { print $1; exit }') || true
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi

    local idx=0
    local agent

    while IFS= read -r agent; do
        if [ "$agent" = "$wanted" ]; then
            printf 'multiagent:agents.%s\n' "$((pane_base + idx))"
            return 0
        fi
        idx=$((idx + 1))
    done < <(agent_registry_multiagent_agents)

    return 1
}

agent_registry_pane_for_agent() {
    local agent="$1"
    local pane_base="${2:-0}"

    if [ "$agent" = "shogun" ]; then
        printf '%s\n' "shogun:main.0"
        return 0
    fi

    agent_registry_multiagent_pane_for_agent "$agent" "$pane_base"
}
