#!/usr/bin/env bash
# scripts/lib/pane_gate.sh — pane 解決・検証の単一正本 (cmd_1339)
#
# ★pane番号の hardcode / 命名規約導出は、実配置がずれた瞬間に沈黙して壊れる★
# (2026-07-25: 0.6=gunshi1 / 0.7=ashigaru6 とずれた状態で watcher が交差配達し、
#  clear_command が別 agent の session を吹き飛ばした。同日 19:25 には pane
#  再作成で再度ずれた)。
#
# ⇒ 各 CLI session は SessionStart hook が読む tmux pane option @agent_id で
#   自己識別する。★@agent_id が pane 解決の唯一の正本★であり、番号規約は
#   @agent_id 不在環境 (旧構成 / OSS 素の環境) の fallback に格下げする。
#
# 提供関数:
#   pane_gate_resolve_by_agent_id <agent> → pane target (session:window.index) / rc=1
#   pane_gate_agent_id_of <pane_target>   → その pane の @agent_id / rc=1 (未設定)
#   pane_gate_verify <agent> <pane>       → 0 = pane の実体 (@agent_id) が agent 本人
#   pane_gate_pane_id <pane_target>       → tmux 一意 pane id (%N)。別名表記の同一性判定用
#   pane_gate_in_use                      → 0 = この tmux server で @agent_id 運用が有効
#
# 送信系 (send-keys / clear) は必ず配達直前に pane_gate_verify を通すこと。
# ★不一致なら送らず警告が正 — 誤爆で session を吹き飛ばすより止まる方がまし (将軍明示)★。

pane_gate_resolve_by_agent_id() {
    local agent="$1"
    local found=""
    found=$(tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index} #{@agent_id}" 2>/dev/null \
        | awk -v a="$agent" '$2 == a { print $1; exit }') || true
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
}

pane_gate_agent_id_of() {
    local v=""
    v=$(timeout 2 tmux show-options -p -t "$1" -v @agent_id 2>/dev/null | tr -d '[:space:]') || true
    if [ -n "$v" ]; then
        echo "$v"
        return 0
    fi
    return 1
}

pane_gate_verify() {
    local agent="$1"
    local pane="$2"
    [ "$(pane_gate_agent_id_of "$pane" 2>/dev/null)" = "$agent" ]
}

pane_gate_pane_id() {
    timeout 2 tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null
}

# @agent_id が一つも設定されていない tmux server では gate を開放する
# (OSS 素の環境 / 手動 tmux 構成の後方互換。設定済み環境では常に検証)。
pane_gate_in_use() {
    tmux list-panes -a -F '#{@agent_id}' 2>/dev/null | grep -q .
}
