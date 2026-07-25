#!/usr/bin/env bash
# lib/agent_status.sh — エージェント稼働状態検出の共有ライブラリ
#
# 提供関数:
#   agent_is_busy_check <pane_target>   → 0=busy, 1=idle, 2=pane不在
#   get_pane_state_label <pane_target>  → "稼働中" / "待機中" / "不在"
#
# 使用例:
#   source lib/agent_status.sh
#   agent_is_busy_check "multiagent:agents.0"
#   state=$(get_pane_state_label "multiagent:agents.3")

# agent_is_busy_check <pane_target> [cli_type]
# tmux paneの末尾5行からCLI固有のidle/busyパターンを検出する。
# Returns: 0=busy, 1=idle, 2=pane不在
#
# Detection strategy:
#   1. OpenCode special-case: animated status row (`[■⬝]{8}`) = busy; if that
#      row is absent, fall back to the bottom status line's interrupt hint.
#   2. Status bar check (last non-empty line): 'esc to' only appears in
#      Claude Code's status bar during active processing. This is the most
#      reliable busy signal — immune to old spinner text in scroll-back.
#   3. Live spinner row check (cmd_1280): on narrow panes the status bar is
#      width-truncated ('⏵⏵ bypass permissions on          ·') and 'esc to
#      interrupt' falls off screen, so signal 2 misses busy. Claude Code
#      renders a live spinner row '<glyph> <phrase>… (elapsed · …)' directly
#      above the input box while processing; detect it anchored to the box.
#   4. Idle checks: CLI-specific idle prompts (❯, Codex ? prompt)
#   5. Text-based busy markers: spinner keywords in bottom 5 lines
#
# Why this order matters:
#   - Claude Code shows ❯ prompt even during thinking/working, so idle
#     checks alone cause false-idle (the bug that broke is_busy).
#   - Old spinner text (e.g. "Working on task • esc to interrupt") lingers
#     in scroll-back, so checking all 5 lines for 'esc to' causes false-busy
#     (the bug T-BUSY-008 fixed). Solution: check ONLY the last line for
#     'esc to' — the status bar is always at the bottom. The live spinner
#     check keeps this guarantee by looking ONLY at the first non-blank line
#     directly above the input box top border (never into scroll-back).
agent_is_busy_check() {
    local pane_target="$1"
    local cli_type="${2:-}"
    local pane_tail

    # Pane existence check — independent of capture-pane result.
    # capture-pane on a TUI app (e.g. Claude Code) often returns only trailing
    # blank lines when pane height > visible content, making pane_tail empty
    # even when the pane exists and is healthy. Use display-message instead.
    if ! tmux display-message -t "$pane_target" -p '#{pane_id}' &>/dev/null; then
        return 2  # pane truly absent
    fi

    # capture-pane -p outputs the full pane height including trailing blank lines.
    # Piping directly to `tail -5` captures those blank lines → empty result.
    # Fix: store in a variable first so command-substitution strips trailing newlines,
    # then pipe to tail.
    if [[ -z "$cli_type" ]]; then
        cli_type=$(timeout 2 tmux show-options -v -p -t "$pane_target" @agent_cli 2>/dev/null || true)
    fi

    local full_capture
    full_capture=$(timeout 2 tmux capture-pane -t "$pane_target" -p 2>/dev/null)
    # Only check the bottom 5 lines by default. Old busy markers linger in
    # scroll-back and cause false-busy if we scan too many lines.
    pane_tail=$(echo "$full_capture" | tail -5)

    # OpenCode uses a different layout from Codex/Claude. When the pane is
    # blank, treat it as idle so the watcher can recover instead of holding the
    # agent in permanent busy state after a crash or failed render. When the TUI
    # is visible, prefer the busy animation row and then the interrupt hint.
    if [[ "$cli_type" == "opencode" ]]; then
        local opencode_visible opencode_last_line
        opencode_visible=$(printf '%s\n' "$full_capture" | grep -v '^[[:space:]]*$' || true)
        if [[ -z "$opencode_visible" ]]; then
            return 1
        fi
        if opencode_has_busy_animation "$opencode_visible"; then
            return 0
        fi
        opencode_last_line=$(printf '%s\n' "$opencode_visible" | tail -1)
        if echo "$opencode_last_line" | grep -qiE '(^|[[:space:]])esc([[:space:]]+to)?[[:space:]]+interrupt([[:space:]]|$)'; then
            return 0
        fi
        return 1
    fi

    if [[ "$cli_type" == "cursor" ]]; then
        # Cursor: "ctrl+c to stop" appears in TUI only during active processing
        if echo "$pane_tail" | grep -qiF 'ctrl+c to stop'; then
            return 0  # busy
        fi
        # Idle markers: initial prompt or post-response prompt
        if echo "$pane_tail" | grep -qE '(Plan, search, build anything|Add a follow-up)'; then
            return 1  # idle
        fi
        return 1  # default idle
    fi

    # Pane exists but capture is empty → treat as idle, not absent
    if [[ -z "$pane_tail" ]]; then
        return 1
    fi

    # ── Status bar check (last non-empty line = most reliable) ──
    # Claude Code status bar appends 'esc to interrupt' (or truncated 'esc to…')
    # ONLY during active processing. When idle, this suffix disappears.
    # Checking only the last line avoids false-busy from old spinner text
    # that might still be visible in the bottom 5 lines (T-BUSY-008 scenario).
    local last_line
    last_line=$(echo "$pane_tail" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$last_line" | grep -qiF 'esc to'; then
        return 0  # busy — status bar confirms active processing
    fi

    # ── Queued-messages check (cmd_1339 (d)) ──
    # 入力 queue にメッセージが積まれている間、Claude Code の composer は
    # 『❯ Press up to edit queued messages』を描画し、queued 行 (❯ /clear 等) が
    # 入力 box 境界の直上に並ぶ。★queue が積まれている = 処理中★ (idle なら即
    # 消費される) ゆえ、この文言自体が busy の契約級証拠。
    # 2026-07-25 19:21 実害: 52列 pane では status bar の『esc to interrupt』が
    # 幅で切詰められ (実測『⏵⏵ bypass permissions on … ·』)、上の check が届かず、
    # live spinner check は box 直上の queued 行を見て『spinner でない→idle』と
    # 誤判定。thinking 中の足軽四号へ誤 /clear が 3 連発した。しかも誤 /clear は
    # 自ら queue に積まれてこの誤判定を強化する自己増幅 loop だった。
    # queued 行は composer が in-place 描画するもので、queue 消費後は残らない
    # (scroll-back 残渣で false-busy になる T-BUSY-008 型は起きない)。
    if echo "$pane_tail" | grep -qF 'Press up to edit queued messages'; then
        return 0  # busy — queued messages exist only while the agent is processing
    fi

    # ── Live spinner row check (cmd_1280 narrow-pane fix) ──
    # Panes narrower than ~65 cols truncate the status bar before 'esc to
    # interrupt' ('⏵⏵ bypass permissions on          ·'), so the check above
    # returns false-idle on busy agents. The live spinner row above the input
    # box is width-independent; it is anchored to the box so stale busy text
    # in scroll-back can never match (T-BUSY-008 stays fixed).
    if claude_code_live_spinner_check "$full_capture"; then
        return 0  # busy — live spinner row above the input box
    fi

    # ── Idle checks ──
    # Codex idle prompt
    if echo "$pane_tail" | grep -qE '(\? for shortcuts|context left)'; then
        return 1
    fi
    # Claude Code bare prompt
    if echo "$pane_tail" | grep -qE '^(❯|›)\s*$'; then
        return 1
    fi

    # ── Text-based busy markers (bottom 5 lines) ──
    # These catch non-Claude-Code CLIs and edge cases where status bar
    # isn't present but spinner text indicates active work.
    if echo "$pane_tail" | grep -qiF 'background terminal running'; then
        return 0
    fi
    if echo "$pane_tail" | grep -qiE '(Working|Thinking|Planning|Sending|task is in progress|Compacting conversation|thought for|思考中|考え中|計画中|送信中|処理中|実行中)'; then
        return 0
    fi

    return 1  # idle (default)
}

# claude_code_live_spinner_check <capture_text>
# Claude Code busy中は入力ボックス直上に spinner 行
#   『<glyph> 状態文言… (2m 3s · thinking)』
# が描画される (glyph は · ✢ ✳ ✶ ✻ ✽ * + を巡回)。狭pane では末尾の
# (elapsed …) が幅で切れることがある (実測: 幅31 pane で『✻ 文言…』のみ)。
# Returns: 0 = live spinner row found (busy), 1 = not found.
#
# T-BUSY-008 non-regression design:
#   - Anchor on the input box: locate the composer prompt line (❯/›) and
#     require a box border (─ run) directly above it.
#   - Inspect ONLY the first non-blank line above that border (allowing up
#     to 2 intervening blank rows). Anything further up is scroll-back and
#     is never read, so stale busy text cannot cause false-busy.
#   - The row must start with a spinner glyph + space AND carry busy
#     evidence: an ellipsis '…' or an elapsed-time '(Nh/Nm/Ns'. Response
#     text (● bullets, plain prose) fails the glyph gate.
claude_code_live_spinner_check() {
    local capture_text="$1"
    local -a lines
    mapfile -t lines <<< "$capture_text"
    local n=${#lines[@]}
    (( n < 3 )) && return 1

    # Composer prompt line: search bottom-up, status bar + borders sit below
    # it, so a 10-line window from the bottom is always enough.
    local i prompt_idx=-1 trimmed
    local start=$(( n > 10 ? n - 10 : 0 ))
    for (( i = n - 1; i >= start; i-- )); do
        trimmed="${lines[i]#"${lines[i]%%[![:space:]]*}"}"
        case "$trimmed" in
            '❯'*|'›'*) prompt_idx=$i; break ;;
        esac
    done
    (( prompt_idx < 2 )) && return 1

    # The line directly above the prompt must be the input box top border.
    trimmed="${lines[prompt_idx-1]#"${lines[prompt_idx-1]%%[![:space:]]*}"}"
    case "$trimmed" in
        '───'*) ;;
        *) return 1 ;;
    esac

    # First non-blank line above the border (skip at most 2 blank rows).
    local blanks=0
    for (( i = prompt_idx - 2; i >= 0 && blanks <= 2; i-- )); do
        trimmed="${lines[i]#"${lines[i]%%[![:space:]]*}"}"
        if [[ -z "$trimmed" ]]; then
            blanks=$(( blanks + 1 ))
            continue
        fi
        # Byte-wise prefix match (locale-independent): glyph + space.
        case "$trimmed" in
            '· '*|'✢ '*|'✳ '*|'✶ '*|'✻ '*|'✽ '*|'* '*|'+ '*)
                if printf '%s' "$trimmed" | grep -qE '…|\([0-9]+(h|m|s)'; then
                    return 0
                fi
                ;;
        esac
        return 1  # first non-blank row is not a live spinner → idle region
    done
    return 1
}

# opencode_has_busy_animation <capture_text>
# OpenCode paneの busy animation (`[■⬝]{8}`) を検出する。
opencode_has_busy_animation() {
    local capture_text="$1"

    if command -v python3 &>/dev/null; then
        OPENCODE_CAPTURE_TEXT="$capture_text" python3 - <<'PY'
import os
import sys

text = os.environ.get("OPENCODE_CAPTURE_TEXT", "")
for line in text.splitlines():
    glyphs = "".join(ch for ch in line if ch in "■⬝")
    if len(glyphs) >= 8:
        sys.exit(0)
sys.exit(1)
PY
        return $?
    fi

    local line
    while IFS= read -r line; do
        # Python is preferred for Unicode handling.  This shell fallback keeps
        # the same contract: any OpenCode spinner line with at least eight
        # busy-animation glyphs is busy, regardless of the current frame.
        if [[ "$line" =~ ([■⬝].*){8} ]]; then
            return 0
        fi
    done <<< "$capture_text"
    return 1
}

# get_pane_state_label <pane_target>
# 人間が読めるラベルを返す。
get_pane_state_label() {
    local pane_target="$1"
    agent_is_busy_check "$pane_target"
    local rc=$?
    case $rc in
        0) echo "稼働中" ;;
        1) echo "待機中" ;;
        2) echo "不在" ;;
    esac
}
