#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# switch_cli.sh — エージェントのCLIセッションを安全に切り替える
#
# Usage:
#   bash scripts/switch_cli.sh <agent_id> [--type <cli_type>] [--model <model_name>] [--effort <level>] [--variant <variant>]
#
# Examples:
#   # settings.yaml の現在値で再起動（CLI種別/モデル変更なし）
#   bash scripts/switch_cli.sh ashigaru3
#
#   # Codex Spark → Claude Sonnet に切替
#   bash scripts/switch_cli.sh ashigaru3 --type claude --model claude-sonnet-4-6
#
#   # OpenCode で provider/model を直接指定（role 定義は --agent、モデル変更は再起動で反映）
#   bash scripts/switch_cli.sh ashigaru3 --type opencode --model openai/gpt-5.4-mini
#
#   # OpenCode provider-specific reasoning variant
#   bash scripts/switch_cli.sh ashigaru3 --type opencode --model openrouter/minimax/minimax-m2.5 --variant xhigh
#
#   # 同一CLI内でモデルとClaude effortを変更（Sonnet → Opus/max）
#   bash scripts/switch_cli.sh ashigaru3 --model claude-opus-4-8 --effort max
#
#   # 全足軽を一括切替
#   for i in $(seq 1 7); do bash scripts/switch_cli.sh ashigaru$i --type claude --model claude-sonnet-4-6; done
#
# Flow:
#   1. (Optional) settings.yaml を更新
#   2. 現在のCLIに /exit を送信
#   3. シェルプロンプトの復帰を待機
#   4. build_cli_command() で新CLIコマンドを構築
#   5. tmux send-keys で新CLIを起動
#   6. tmux pane metadata を更新（@agent_cli, @model_name）
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.yaml"
LOG_FILE="${PROJECT_ROOT}/logs/switch_cli.log"

# cli_adapter.sh をロード
source "${PROJECT_ROOT}/lib/cli_adapter.sh"
source "${PROJECT_ROOT}/lib/agent_registry.sh"

# ─── ログ ───
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [switch_cli] $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Usage ───
usage() {
    echo "Usage: $0 <agent_id> [--type <cli_type>] [--model <model_name>] [--effort <level>] [--variant <variant>]"
    echo ""
    echo "  agent_id   Agent configured in config/settings.yaml (e.g. karo, ashigaru1, gunshi)"
    echo "  --type     claude | codex | copilot | kimi | opencode | cursor"
    echo "  --model    claude-sonnet-4-6 | claude-opus-4-8 | gpt-5.3-codex | openai/gpt-5.4-mini | etc."
    echo "  --effort   Claude effort level: low | medium | high | xhigh | max"
    echo "  --type     claude | codex | copilot | kimi | opencode | antigravity"
    echo "  --model    claude-sonnet-4-6 | claude-opus-4-6 | gpt-5.3-codex | openai/gpt-5.4-mini | etc."
    echo "  --variant  OpenCode model variant such as xhigh, high, max, minimal"
    echo ""
    echo "If --type/--model omitted, uses current settings.yaml values."
    exit 1
}

# ─── Agent ID → tmux pane 解決 ───
# @agent_id メタデータから動的にペインを検索する（ペイン番号のズレに対応）
# フォールバック: メタデータが見つからない場合は従来の固定マッピングを使用
resolve_pane() {
    local agent_id="$1"

    # Phase 1: @agent_id メタデータから動的検索
    local pane_count
    pane_count=$(tmux list-panes -t "multiagent:agents" 2>/dev/null | wc -l)
    if [[ "$pane_count" -gt 0 ]]; then
        for i in $(seq 0 $((pane_count - 1))); do
            local aid
            aid=$(tmux display-message -t "multiagent:agents.$i" -p '#{@agent_id}' 2>/dev/null)
            if [[ "$aid" == "$agent_id" ]]; then
                echo "multiagent:agents.$i"
                return 0
            fi
        done
        log "WARN: @agent_id=$agent_id not found in any pane. Falling back to fixed mapping."
    fi

    # Phase 2: フォールバック（settings.yaml の編成順から解決）
    local pane_base
    pane_base=$(tmux show-options -t multiagent -v @pane_base 2>/dev/null || echo "0")

    if agent_registry_multiagent_pane_for_agent "$agent_id" "$pane_base"; then
        return 0
    fi

    log "ERROR: Unknown agent_id: $agent_id"
    return 1
}

# ─── settings.yaml 更新 (Python使用) ───
update_settings_yaml() {
    local agent_id="$1"
    local new_type="${2:-}"
    local new_model="${3:-}"
    local new_variant="${4:-}"
    local new_effort="${5:-}"

    if [[ -z "$new_type" && -z "$new_model" && -z "$new_variant" && -z "$new_effort" ]]; then
        return 0
    fi

    log "Updating settings.yaml: ${agent_id} → type=${new_type:-<unchanged>}, model=${new_model:-<unchanged>}, effort=${new_effort:-<unchanged>}, variant=${new_variant:-<unchanged>}"

    "${PROJECT_ROOT}/.venv/bin/python3" << PYEOF
import yaml, sys, os, datetime

settings_path = "${SETTINGS_FILE}"
agent_id = "${agent_id}"
new_type = "${new_type}" or None
new_model = "${new_model}" or None
new_variant = "${new_variant}" or None
new_effort = "${new_effort}" or None

with open(settings_path, 'r', encoding='utf-8') as f:
    content = f.read()

with open(settings_path, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

cli = data.setdefault('cli', {})
agents = cli.setdefault('agents', {})
agent_cfg = agents.get(agent_id)
if not isinstance(agent_cfg, dict):
    agent_cfg = {}
    agents[agent_id] = agent_cfg

timestamp = datetime.datetime.now().strftime('%Y-%m-%d')
comment = f"# {timestamp}: switch_cli.sh による切替"

if new_type:
    agent_cfg['type'] = new_type
if new_model:
    agent_cfg['model'] = new_model
if new_variant:
    agent_cfg['variant'] = new_variant
if new_effort:
    agent_cfg['effort'] = new_effort

data['cli']['agents'][agent_id] = agent_cfg

# コメント保持のため、対象エージェント行だけsedで置換する方が安全だが
# 完全性のためyaml.dumpを使用。コメントは失われる。
# → 代わりにsed的なアプローチ: 対象ブロックだけ書き換える

# Simple approach: read lines, find agent block, replace
lines = content.split('\n')
new_lines = []
in_agent_block = False
agent_indent = None
skip_until_next = False
agent_block_found = False

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()

    # Detect our agent's block start
    if stripped.startswith(f'{agent_id}:'):
        agent_block_found = True
        in_agent_block = True
        agent_indent = len(line) - len(stripped)
        new_lines.append(line)
        # Write the updated block. Preserve unspecified existing fields so
        # passing --effort alone cannot accidentally drop type/model/thinking.
        inner_indent = ' ' * (agent_indent + 2)
        ordered_keys = ['type', 'model', 'effort', 'thinking', 'variant']
        ordered_keys.extend(k for k in agent_cfg.keys() if k not in ordered_keys)

        def format_scalar(value):
            if isinstance(value, bool):
                return 'true' if value else 'false'
            dumped = yaml.safe_dump(value, allow_unicode=True, default_flow_style=True).strip()
            if dumped.endswith('\n...'):
                dumped = dumped[:-4].strip()
            if dumped == '...':
                dumped = ''
            return dumped

        changed_keys = set()
        if new_type:
            changed_keys.add('type')
        if new_model:
            changed_keys.add('model')
        if new_variant:
            changed_keys.add('variant')
        if new_effort:
            changed_keys.add('effort')

        for key in ordered_keys:
            if key not in agent_cfg:
                continue
            suffix = f'  {comment}' if key in changed_keys else ''
            new_lines.append(f'{inner_indent}{key}: {format_scalar(agent_cfg[key])}{suffix}')
        # Skip old sub-fields
        i += 1
        while i < len(lines):
            next_line = lines[i]
            next_stripped = next_line.lstrip()
            if next_stripped == '' or next_stripped.startswith('#'):
                # Keep blank lines and comments between blocks
                if next_stripped.startswith('#') and len(next_line) - len(next_stripped) > agent_indent:
                    i += 1
                    continue
                break
            next_indent = len(next_line) - len(next_stripped)
            if next_indent <= agent_indent:
                break  # Next agent or section
            i += 1
        in_agent_block = False
        continue
    else:
        new_lines.append(line)
    i += 1

if not agent_block_found:
    # Agent block not found: fall back to yaml.dump (adds new block, comments lost)
    with open(settings_path, 'w', encoding='utf-8') as f:
        yaml.dump(data, f, allow_unicode=True, default_flow_style=False)
else:
    with open(settings_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new_lines))
        if not content.endswith('\n'):
            pass
        else:
            f.write('\n') if not '\n'.join(new_lines).endswith('\n') else None

print("OK")
PYEOF
}

# ─── OpenCode runtime agent frontmatter 同期 ───
# OpenCode TUI は `opencode run` と違って --variant を受け付けない。
# provider固有variantは git-ignored の .opencode/agents/<agent>-runtime.md に同期する。
sync_opencode_agent_frontmatter() {
    local agent_id="$1"
    local model="${2:-}"
    local variant="${3:-}"
    local base_file="${PROJECT_ROOT}/.opencode/agents/${agent_id}.md"
    local runtime_file="${PROJECT_ROOT}/.opencode/agents/${agent_id}-runtime.md"
    local normalized_model

    [[ -f "$base_file" ]] || return 0

    normalized_model="$(normalize_opencode_model "$model")"

    if [[ -z "$variant" ]]; then
        rm -f "$runtime_file"
        return 0
    fi

    log "Syncing OpenCode runtime agent: ${agent_id}-runtime → model=${normalized_model:-<unset>}, variant=${variant}"

    "${PROJECT_ROOT}/.venv/bin/python3" - "$base_file" "$runtime_file" "$normalized_model" "$variant" <<'PYEOF'
import sys
from pathlib import Path

import yaml

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
model = sys.argv[3] or None
variant = sys.argv[4] or None

text = source.read_text(encoding="utf-8")
if not text.startswith("---\n"):
    raise SystemExit(0)

parts = text.split("---", 2)
if len(parts) < 3:
    raise SystemExit(0)

body = parts[2]
route = {}
if model:
    route["model"] = model
if variant:
    route["variant"] = variant
route_lines = yaml.safe_dump(route, allow_unicode=True, sort_keys=False).splitlines() if route else []

frontmatter_lines = parts[1].lstrip("\n").splitlines()
new_lines = []
inserted = False
for line in frontmatter_lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if indent == 0 and (stripped.startswith("model:") or stripped.startswith("variant:")):
        continue
    if not inserted and indent == 0 and stripped.startswith("permission:"):
        new_lines.extend(route_lines)
        inserted = True
    new_lines.append(line)

if not inserted:
    new_lines.extend(route_lines)

frontmatter_text = "\n".join(new_lines).rstrip()

dest.write_text(f"---\n{frontmatter_text}\n---{body}", encoding="utf-8")
PYEOF
}

# ─── 現在のCLI種別を取得（tmux metadata） ───
get_current_pane_cli() {
    local pane="$1"
    tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null | tr -d '[:space:]' || echo "claude"
}

# ─── /exit送信 ───
send_exit() {
    local pane="$1"
    local current_cli="$2"

    log "Sending exit command to ${pane} (current CLI: ${current_cli})"

    case "$current_cli" in
        codex)
            # Codex: suggestion UI dismissal → Ctrl-C → /exit
            tmux send-keys -t "$pane" Escape 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" C-c 2>/dev/null || true
            sleep 0.5
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
        claude)
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
        copilot|kimi|antigravity)
            tmux send-keys -t "$pane" C-c 2>/dev/null || true
            sleep 0.5
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
        cursor)
            tmux send-keys -t "$pane" "/quit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" "" Enter 2>/dev/null || true
            ;;
        *)
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
    esac
}

# ─── シェルへ戻るのを待つ（最大30秒） ───
# cmd_2057: 前は画面の字 (❯ や exit) で判定していた。Claude Code の入力欄も ❯ で、
# 打ち込んだ "/exit" も exit に当たるため、古い CLI が終わる前に「戻った」と判定し、
# 起動のコマンドが終わりかけの CLI に食われて新しい CLI が起動しないことがあった
# (2026-10-13 19:47〜48 の足軽3・6・7号。SessionStart hook が一度も走っていない)。
# 今は tmux の pane_current_command がシェルになったかで判定する。
is_shell_command() {
    case "$1" in
        bash|zsh|sh|dash|fish|-bash|-zsh|-sh) return 0 ;;
        *) return 1 ;;
    esac
}

pane_command() {
    tmux display-message -t "$1" -p '#{pane_current_command}' 2>/dev/null || true
}

wait_for_shell() {
    local pane="$1"
    local max_wait=30
    local waited=0
    local cmd

    log "Waiting for shell on ${pane}..."
    while [ "$waited" -lt "$max_wait" ]; do
        sleep 1
        waited=$((waited + 1))
        cmd=$(pane_command "$pane")
        if is_shell_command "$cmd"; then
            sleep 1  # プロンプトが出るまでの間
            log "Shell detected after ${waited}s (pane_current_command=${cmd})"
            return 0
        fi
    done
    log "ERROR: still not a shell after ${max_wait}s (pane_current_command=${cmd})"
    return 1
}

# ─── 起動を送り、CLI が立ち上がったかを確かめる（cmd_2057） ───
# 起動を送った後、pane_current_command がシェル以外になり、5秒後もそのままなら成功。
# claude の時は pane_current_command が claude であることまで見る。
# 立ち上がらなければ、シェルに居る事を確かめてから撃ち直す（全部で3回まで）。
launch_and_confirm() {
    local pane="$1"
    local cmd_line="$2"
    local cli_type="$3"
    local attempt waited cur

    for attempt in 1 2 3; do
        log "Launching new CLI (attempt ${attempt}/3): ${cmd_line}"
        tmux send-keys -t "$pane" "$cmd_line" 2>/dev/null || true
        sleep 0.3
        tmux send-keys -t "$pane" Enter 2>/dev/null || true

        waited=0
        while [ "$waited" -lt 20 ]; do
            sleep 1
            waited=$((waited + 1))
            cur=$(pane_command "$pane")
            if ! is_shell_command "$cur"; then
                break
            fi
        done

        if ! is_shell_command "$cur"; then
            sleep 5
            cur=$(pane_command "$pane")
            local up=0
            if [[ "$cli_type" == "claude" ]]; then
                [[ "$cur" == "claude" ]] && up=1
            elif ! is_shell_command "$cur"; then
                up=1
            fi
            if [ "$up" -eq 1 ]; then
                log "CLI is up after attempt ${attempt} (pane_current_command=${cur})"
                return 0
            fi
        fi
        log "WARN: CLI not up after attempt ${attempt} (pane_current_command=${cur})"
        if ! wait_for_shell "$pane"; then
            return 1
        fi
    done
    return 1
}

notify_karo_failure() {
    local msg="$1"
    if [[ "$AGENT_ID" != "karo" && -x "${PROJECT_ROOT}/scripts/inbox_write.sh" ]]; then
        bash "${PROJECT_ROOT}/scripts/inbox_write.sh" karo "switch_cli: ${AGENT_ID} の切替に失敗。${msg} 画面を確かめよ。" switch_failed switch_cli \
            >/dev/null 2>&1 || true
    fi
}

# ─── モデル表示名の正規化（cli_adapter.sh の get_model_display_name を使用） ───
# get_model_display_name は cli_adapter.sh から source 済み

# ─── tmux pane metadata 更新 ───
update_pane_metadata() {
    local pane="$1"
    local new_cli_type="$2"
    local display_name="$3"

    log "Updating pane metadata: @agent_cli=${new_cli_type}, @model_name=${display_name}"

    tmux set-option -p -t "$pane" @agent_cli "$new_cli_type" 2>/dev/null || true
    tmux set-option -p -t "$pane" @model_name "$display_name" 2>/dev/null || true
    tmux select-pane -t "$pane" -T "$display_name" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# メイン処理
# ═══════════════════════════════════════════════════════════════

# 引数パース
if [ $# -lt 1 ]; then
    usage
fi

# --help が第1引数の場合
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

AGENT_ID="$1"
shift

NEW_TYPE=""
NEW_MODEL=""
NEW_VARIANT=""
NEW_EFFORT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type)
            NEW_TYPE="$2"
            shift 2
            ;;
        --model)
            NEW_MODEL="$2"
            shift 2
            ;;
        --effort)
            NEW_EFFORT="$2"
            shift 2
            ;;
        --variant)
            NEW_VARIANT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# バリデーション
if [[ -n "$NEW_TYPE" ]] && ! _cli_adapter_is_valid_cli "$NEW_TYPE"; then
    log "ERROR: Invalid CLI type: ${NEW_TYPE}. Allowed: ${CLI_ADAPTER_ALLOWED_CLIS}"
    exit 1
fi
if [[ -n "$NEW_TYPE" ]]; then
    NEW_TYPE=$(_cli_adapter_normalize_cli_type "$NEW_TYPE")
fi

if [[ -n "$NEW_EFFORT" && ! "$NEW_EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]]; then
    log "ERROR: Invalid effort: ${NEW_EFFORT}. Allowed: low, medium, high, xhigh, max"
    exit 1
fi

# Step 0: pane解決
PANE_TARGET=$(resolve_pane "$AGENT_ID")
if [ -z "$PANE_TARGET" ]; then
    exit 1
fi
log "=== Starting CLI switch for ${AGENT_ID} (pane: ${PANE_TARGET}) ==="

# Step 0.5: --model指定時に--type未指定なら、CLI種別を安全に補完する
if [[ -n "$NEW_MODEL" && -z "$NEW_TYPE" ]]; then
    case "$NEW_MODEL" in
        gpt-5.3-codex*|gpt-5-codex*)
            NEW_TYPE="codex"
            log "Auto-inferred type=codex from model=${NEW_MODEL}"
            ;;
        */*)
            if [[ "$(get_cli_type "$AGENT_ID")" == "opencode" ]]; then
                NEW_TYPE="opencode"
                log "Preserving type=opencode for provider-qualified model=${NEW_MODEL}"
            else
                log "ERROR: provider-qualified model IDs are ambiguous without --type; use --type opencode --model ${NEW_MODEL}"
                exit 1
            fi
            ;;
        claude-*)
            NEW_TYPE="claude"
            log "Auto-inferred type=claude from model=${NEW_MODEL}"
            ;;
    esac
fi

# Step 0.7: 作業中なら切り替えない (cmd_2057)。最大2分、区切りを待つ。
# 作業中に /exit を送ると仕事が切れる。待っても作業中なら settings.yaml も触らずに止める。
source "${PROJECT_ROOT}/lib/agent_status.sh"
busy_waited=0
while agent_is_busy_check "$PANE_TARGET" "$(get_current_pane_cli "$PANE_TARGET")"; do
    if [ "$busy_waited" -ge 120 ]; then
        log "ERROR: ${AGENT_ID} is still working after 120s. Not switching."
        echo "BUSY: ${AGENT_ID} は作業中なので切り替えなかった。区切りの後に撃ち直すこと。" >&2
        exit 3
    fi
    [ "$busy_waited" -eq 0 ] && log "${AGENT_ID} is working. Waiting for it to finish (max 120s)..."
    sleep 5
    busy_waited=$((busy_waited + 5))
done

# Step 1: settings.yaml 更新（--type/--model/--variant 指定時のみ）
if [[ -n "$NEW_TYPE" || -n "$NEW_MODEL" || -n "$NEW_VARIANT" || -n "$NEW_EFFORT" ]]; then
    update_settings_yaml "$AGENT_ID" "$NEW_TYPE" "$NEW_MODEL" "$NEW_VARIANT" "$NEW_EFFORT"
fi

# Step 2: 切替後のCLI情報を取得（settings.yaml反映後）
TARGET_CLI_TYPE=$(get_cli_type "$AGENT_ID")
TARGET_MODEL=$(get_agent_model "$AGENT_ID")
TARGET_EFFORT=$(get_agent_effort "$AGENT_ID")
TARGET_VARIANT=$(_cli_adapter_read_yaml "cli.agents.${AGENT_ID}.variant" "")
if [[ "$TARGET_CLI_TYPE" == "opencode" ]]; then
    sync_opencode_agent_frontmatter "$AGENT_ID" "$TARGET_MODEL" "$TARGET_VARIANT"
fi
TARGET_CMD=$(build_cli_command "$AGENT_ID")

log "Target: cli=${TARGET_CLI_TYPE}, model=${TARGET_MODEL}, effort=${TARGET_EFFORT:-<unset>}, cmd=${TARGET_CMD}"

# Step 3: 現在のCLIを /exit で終了
CURRENT_CLI=$(get_current_pane_cli "$PANE_TARGET")
log "Current CLI: ${CURRENT_CLI}"
send_exit "$PANE_TARGET" "$CURRENT_CLI"

# Step 4: シェルへ戻るのを待つ (戻らなければ起動を送らない)
if ! wait_for_shell "$PANE_TARGET"; then
    notify_karo_failure "古い CLI が30秒で終わらなかったので、新しい CLI を送っていない。"
    echo "FAIL: ${AGENT_ID} の古い CLI が終わらない" >&2
    exit 4
fi

# Step 5: 新しいCLIコマンドを送信し、立ち上がったかを確かめる
if ! launch_and_confirm "$PANE_TARGET" "$TARGET_CMD" "$TARGET_CLI_TYPE"; then
    notify_karo_failure "新しい CLI が3回撃っても立ち上がらない (${TARGET_CMD})。"
    echo "FAIL: ${AGENT_ID} の新しい CLI が立ち上がらない" >&2
    exit 5
fi

# Step 6: tmux pane metadata 更新
DISPLAY_NAME=$(get_model_display_name "$AGENT_ID")
update_pane_metadata "$PANE_TARGET" "$TARGET_CLI_TYPE" "$DISPLAY_NAME"

log "=== CLI switch complete: ${AGENT_ID} → ${TARGET_CLI_TYPE}/${TARGET_MODEL} (${DISPLAY_NAME}) ==="
echo "OK: ${AGENT_ID} → ${TARGET_CLI_TYPE}/${TARGET_MODEL}"
