#!/usr/bin/env bash
# lib/pane_cli_liveness.sh — pane で CLI プロセスが現に動いているかを判定する (cmd_1418)
#
# 何を解く物か:
#   既存の agent_is_busy_check (lib/agent_status.sh) は pane に描かれた文字だけを見る。
#   pane の metadata (@agent_cli) も「何を起動するはずか」を書いた札にすぎない。
#   どちらも「その pane で CLI プロセスが現に生きているか」は見ていない。
#   2026-07-27 12:25 に足軽五号の claude が落ち、pane が素の bash に戻った。
#   そこへ nudge が送られ、bash がそれをコマンドとして食った (command not found が9回)。
#   点呼は「claude 稼働中」と緑を返していた。計器に実体を見る口が無かった。
#   (落ちた原因は本稿では扱わない。判っていない。)
#
# 何を見るか:
#   tmux の pane_pid から子プロセスを辿り、各プロセスの argv (/proc/<pid>/cmdline) を読む。
#   argv の先頭が期待する CLI の実行ファイル名なら「生存」。
#   pane_pid 自身も候補に含める (CLI を直に pane の第一プロセスとして起動した形に備える)。
#
# 提供関数:
#   pane_cli_liveness_detail <pane_target> [expected_cli]
#       → "verdict<TAB>pid<TAB>argv" を印字。rc は下表。
#   pane_cli_liveness_check <pane_target> [expected_cli]
#       → verdict 語のみを印字。rc は下表。
#   pane_cli_liveness_label <verdict> [ja|en]
#       → 人が読む短い語を印字。
#   pane_cli_expected_binaries <cli_type>
#       → その CLI が名乗るはずの実行ファイル名を空白区切りで印字。
#
# verdict と rc:
#   alive     0  期待した CLI のプロセスが現に居る
#   dead      1  CLI のプロセスが一つも居ない (pane は shell だけ) ← 本件の穴
#   no_pane   2  pane が無い
#   mismatch  3  CLI は居るが期待した物と違う (札と実体の食い違い)
#   unknown   4  見られなかった (pane_pid が取れぬ / /proc が読めぬ)
#
# 枷: 判定は読むだけで行う。プロセスへ signal を送らない。pane を殺さない。

# ─── CLI ごとの実行ファイル名 ───
# lib/cli_adapter.sh の build_cli_command が組み立てる先頭語と対で保つこと。
pane_cli_expected_binaries() {
    case "${1:-}" in
        claude)      echo "claude" ;;
        codex)       echo "codex" ;;
        copilot)     echo "copilot" ;;
        kimi)        echo "kimi" ;;
        opencode)    echo "opencode" ;;
        cursor)      echo "cursor-agent agent" ;;
        antigravity) echo "agy" ;;
        *)           echo "" ;;
    esac
}

# 既知の CLI 実行ファイル名すべて (mismatch 判定に使う)
_pcl_all_binaries() {
    echo "claude codex copilot kimi opencode cursor-agent agy"
}

# _pcl_argv <pid> → argv を空白区切りで印字 (読めなければ rc=1)
_pcl_argv() {
    local pid="$1" raw
    [[ -r "/proc/${pid}/cmdline" ]] || return 1
    raw=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null) || return 1
    # 末尾の空白を落とす
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -z "$raw" ]] && return 1
    printf '%s' "$raw"
}

# _pcl_binary_name <argv> → 判定に使う実行ファイル名を印字
# node/bun 等の噛ませが先頭に来る形 (`node /path/to/claude.js`) にも当たるよう、
# 先頭が runtime なら次の語を見る。
_pcl_binary_name() {
    local argv="$1" first second base
    first="${argv%% *}"
    base="${first##*/}"
    base="${base%.exe}"
    case "$base" in
        node|nodejs|bun|deno|python|python3|env)
            second="${argv#* }"
            [[ "$second" == "$argv" ]] && { printf '%s' "$base"; return 0; }
            second="${second%% *}"
            base="${second##*/}"
            base="${base%.exe}"
            base="${base%.js}"
            ;;
    esac
    printf '%s' "$base"
}

# ─── 親子表 (/proc の一巡) ───
# 既定では判定のたびに /proc を読み直す (常に今の姿を見る)。
# 多数の pane を続けて見る時は pane_cli_liveness_snapshot で一度だけ読み、
# 全 pane を同じ瞬間の姿で判ずる。
declare -gA _PCL_KIDS=()
_PCL_SNAPSHOT=0

_pcl_build_kids() {
    _PCL_KIDS=()
    [[ -d /proc ]] || return 1
    local d pid line rest ppid
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [[ -r "$d/stat" ]] || continue
        IFS= read -r line < "$d/stat" 2>/dev/null || continue
        # stat の第2欄 (comm) は括弧で囲まれ空白を含みうる。最後の ") " まで捨てる。
        rest="${line##*") "}"
        [[ "$rest" == "$line" ]] && continue
        ppid="${rest#* }"
        ppid="${ppid%% *}"
        [[ "$ppid" =~ ^[0-9]+$ ]] || continue
        _PCL_KIDS[$ppid]+=" $pid"
    done
    return 0
}

# pane_cli_liveness_snapshot [on|off]
# on にすると親子表を一度だけ作って以降 使い回す。
pane_cli_liveness_snapshot() {
    case "${1:-on}" in
        on)  _pcl_build_kids || return 1; _PCL_SNAPSHOT=1 ;;
        off) _PCL_SNAPSHOT=0; _PCL_KIDS=() ;;
        *)   return 2 ;;
    esac
    return 0
}

# _pcl_process_tree <root_pid> → root とその子孫の pid を 1 行ずつ印字
_pcl_process_tree() {
    local root="$1"
    [[ -d /proc ]] || return 1
    if (( _PCL_SNAPSHOT == 0 )); then
        _pcl_build_kids || return 1
    fi
    local -n kids=_PCL_KIDS

    local -a queue=("$root")
    local -A seen=()
    local depth=0 cur next_pid
    while ((${#queue[@]} > 0)) && ((depth < 32)); do
        local -a nextq=()
        for cur in "${queue[@]}"; do
            [[ -n "${seen[$cur]:-}" ]] && continue
            seen[$cur]=1
            printf '%s\n' "$cur"
            for next_pid in ${kids[$cur]:-}; do
                nextq+=("$next_pid")
            done
        done
        queue=("${nextq[@]}")
        depth=$((depth + 1))
    done
    return 0
}

# pane_cli_liveness_detail <pane_target> [expected_cli]
pane_cli_liveness_detail() {
    local pane_target="$1"
    local expected_cli="${2:-}"

    # pane の存在確認は list-panes で行う。
    # display-message は宛先が無い時に黙って現在の pane へ落ちるため、単独では
    # 「無い pane」を「在る pane」として答えてしまう (実測 2026-07-27)。
    if ! timeout 2 tmux list-panes -t "$pane_target" -F '#{pane_id}' >/dev/null 2>&1; then
        printf 'no_pane\t-\t-\n'; return 2
    fi

    local pane_pid
    pane_pid=$(timeout 2 tmux display-message -t "$pane_target" -p '#{pane_pid}' 2>/dev/null) || {
        printf 'no_pane\t-\t-\n'; return 2
    }
    if [[ -z "$pane_pid" || ! "$pane_pid" =~ ^[0-9]+$ ]]; then
        printf 'no_pane\t-\t-\n'; return 2
    fi

    if [[ -z "$expected_cli" ]]; then
        expected_cli=$(timeout 2 tmux show-options -v -p -t "$pane_target" @agent_cli 2>/dev/null || true)
    fi
    [[ -z "$expected_cli" ]] && expected_cli="claude"

    if [[ ! -d /proc ]]; then
        printf 'unknown\t%s\t/proc が無い\n' "$pane_pid"; return 4
    fi

    local -a pids=()
    while IFS= read -r p; do pids+=("$p"); done < <(_pcl_process_tree "$pane_pid")
    if ((${#pids[@]} == 0)); then
        printf 'unknown\t%s\tプロセス表が読めぬ\n' "$pane_pid"; return 4
    fi

    local expected_bins other_bins
    expected_bins=" $(pane_cli_expected_binaries "$expected_cli") "
    other_bins=" $(_pcl_all_binaries) "

    local pid argv base
    local other_pid="" other_argv=""
    for pid in "${pids[@]}"; do
        argv=$(_pcl_argv "$pid") || continue
        base=$(_pcl_binary_name "$argv")
        [[ -z "$base" ]] && continue
        if [[ "$expected_bins" == *" $base "* ]]; then
            printf 'alive\t%s\t%s\n' "$pid" "$argv"
            return 0
        fi
        if [[ -z "$other_pid" && "$other_bins" == *" $base "* ]]; then
            other_pid="$pid"; other_argv="$argv"
        fi
    done

    if [[ -n "$other_pid" ]]; then
        printf 'mismatch\t%s\t%s\n' "$other_pid" "$other_argv"
        return 3
    fi

    # CLI が一つも居ない。pane の第一プロセス (たいてい shell) を証拠として添える。
    local root_argv
    root_argv=$(_pcl_argv "$pane_pid") || root_argv="-"
    printf 'dead\t%s\t%s\n' "$pane_pid" "$root_argv"
    return 1
}

# pane_cli_liveness_check <pane_target> [expected_cli]
pane_cli_liveness_check() {
    local detail rc
    detail=$(pane_cli_liveness_detail "$@") && rc=0 || rc=$?
    printf '%s\n' "${detail%%$'\t'*}"
    return $rc
}

# pane_cli_liveness_label <verdict> [ja|en]
pane_cli_liveness_label() {
    local verdict="$1" lang="${2:-ja}"
    if [[ "$lang" == "en" ]]; then
        case "$verdict" in
            alive)    echo "ALIVE" ;;
            dead)     echo "DEAD" ;;
            no_pane)  echo "NO-PANE" ;;
            mismatch) echo "OTHER-CLI" ;;
            *)        echo "UNKNOWN" ;;
        esac
    else
        case "$verdict" in
            alive)    echo "生存" ;;
            dead)     echo "落ち" ;;
            no_pane)  echo "不在" ;;
            mismatch) echo "別CLI" ;;
            *)        echo "不明" ;;
        esac
    fi
}
