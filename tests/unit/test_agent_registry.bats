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

# cmd_1468: この2本は tmux を stub して撃つ。
#
# cmd_1339 で agent_registry_multiagent_pane_for_agent は
# ★settings の並び順ではなく、生きた tmux pane の @agent_id を第一正本にした★。
# ところがテストは settings の fixture だけ差し替えて撃っていたので、
# 実際には ★本番の pane 配置★ を読んでいた (karo は現に multiagent:agents.0 に居るため、
# fixture が何と言おうと .0 が返る)。2026-07-28 08:43 に赤で露見。
#
# ゆえに二方向を分けて撃つ:
#   下の「fallback」= @agent_id が引けない時に settings 順が効くこと (旧来の契約)
#   下の「@agent_id 優先」= 引ける時は settings 順を無視して pane を採ること (今の契約)
# 片方だけでは、どちらの実装でも緑になってしまう。
stub_tmux_absent() {
    # @agent_id を一つも返さない tmux = 旧構成 / tmux 不在に相当
    tmux() { return 1; }
}

@test "agent_registry: pane mapping falls back to configured order when @agent_id is absent" {
    stub_tmux_absent
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

@test "agent_registry: live @agent_id wins over configured order" {
    # 同じ settings を使い、tmux だけ「settings 順とは違う席」を返す stub にする。
    # settings 順なら karo=.1 / ashigaru4=.2 になるが、@agent_id が引ける以上
    # そちらが正本ゆえ .7 / .3 が返らねばならない。
    tmux() {
        printf '%s\n' \
            'multiagent:agents.7 karo' \
            'multiagent:agents.3 ashigaru4'
    }

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

    [ "$(agent_registry_multiagent_pane_for_agent karo 1)" = "multiagent:agents.7" ]
    [ "$(agent_registry_multiagent_pane_for_agent ashigaru4 1)" = "multiagent:agents.3" ]
    # @agent_id に居ない者は従来どおり settings 順の fallback へ落ちる
    [ "$(agent_registry_multiagent_pane_for_agent gunshi2 1)" = "multiagent:agents.4" ]
}

# NOTE (cmd_1170): upstream 2f1ebd0 の「watcher_supervisor: --print-watchers」test は削除。
# merge cde895e で watcher_supervisor.sh は cmd_652 版 (scripts/lib/agent_list.sh 方式) を
# 意図的に retain しており、--print-watchers を持つ upstream registry 版実装はローカル不採用。
# test だけが upstream から残留し、オプション不在の supervisor が無限ループに入って hang していた。
# lib/agent_registry.sh 自体は agent_status.sh / switch_cli.sh で現役ゆえ上記 3 test は維持。
