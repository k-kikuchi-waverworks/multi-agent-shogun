#!/usr/bin/env bats
# agent_registry.sh / watcher_supervisor dynamic formation tests

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_settings() {
    local path="$1"
    shift
    cat > "$path" << YAML
$*
YAML
}

load_registry_with() {
    export AGENT_REGISTRY_SETTINGS="$1"
    source "$PROJECT_ROOT/lib/agent_registry.sh"
}

join_lines() {
    tr '\n' ' ' | sed 's/ $//'
}

@test "agent_registry: full cli.agents formation preserves configured order" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  default: codex
  agents:
    shogun:
      type: codex
    karo:
      type: codex
    ashigaru2:
      type: codex
    gunshi:
      type: codex
    gunshi2:
      type: codex'

    load_registry_with "$settings"

    result=$(agent_registry_agents | join_lines)
    [ "$result" = "shogun karo ashigaru2 gunshi gunshi2" ]

    result=$(agent_registry_multiagent_agents | join_lines)
    [ "$result" = "karo ashigaru2 gunshi gunshi2" ]
}

@test "agent_registry: partial override config without karo falls back to legacy formation" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  default: claude
  agents:
    ashigaru5: codex
    ashigaru7: copilot'

    load_registry_with "$settings"

    result=$(agent_registry_multiagent_agents | join_lines)
    [ "$result" = "karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7 gunshi" ]
}

@test "agent_registry: pane mapping follows configured order and pane base" {
    local settings="$TEST_TMP/settings.yaml"
    write_settings "$settings" 'cli:
  agents:
    shogun:
      type: codex
    karo:
      type: codex
    ashigaru4:
      type: codex
    gunshi:
      type: codex
    gunshi2:
      type: codex'

    load_registry_with "$settings"

    [ "$(agent_registry_pane_for_agent shogun 1)" = "shogun:main.0" ]
    [ "$(agent_registry_multiagent_pane_for_agent karo 1)" = "multiagent:agents.1" ]
    [ "$(agent_registry_multiagent_pane_for_agent ashigaru4 1)" = "multiagent:agents.2" ]
    [ "$(agent_registry_multiagent_pane_for_agent gunshi2 1)" = "multiagent:agents.4" ]
}

# NOTE (cmd_1170): upstream 2f1ebd0 の「watcher_supervisor: --print-watchers」test は削除。
# merge cde895e で watcher_supervisor.sh は cmd_652 版 (scripts/lib/agent_list.sh 方式) を
# 意図的に retain しており、--print-watchers を持つ upstream registry 版実装はローカル不採用。
# test だけが upstream から残留し、オプション不在の supervisor が無限ループに入って hang していた。
# lib/agent_registry.sh 自体は agent_status.sh / switch_cli.sh で現役ゆえ上記 3 test は維持。
