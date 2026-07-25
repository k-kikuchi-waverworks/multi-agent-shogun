#!/usr/bin/env bash
# scripts/lib/proc_lock.sh — 常駐プロセスの lifetime lock 契約 (cmd_1339)
#
# 背景 (2026-07-25 交差配達事故 RCA):
#   watcher_supervisor の dedup は `pgrep -Ef` だったが、この環境の pgrep
#   (procps-ng 4.0.4) に -E オプションは存在せず常に rc=2 = ★dedup は
#   2026-06-06 (commit 1666034) 以来ずっと死にコード★だった。それでも普段
#   二重起動しなかったのは、start_watcher_if_missing の subshell `9>lockfile`
#   の fd 9 を nohup 起動された watcher が【偶然相続】し、per-agent start lock
#   を watcher の生涯保持していたため。★出陣 (shutsujin) 直撃の watcher は
#   この経路を通らず lock を持たぬゆえ、supervisor 再起動で全 agent 二重起動
#   した (2026-07-25 18:52:57 実測・10体)★。
#
# 本 lib は「偶然」を「契約」に変える:
#   常駐プロセス自身が起動時に自分の名前の lock を明示的に取得し、生涯保持する。
#   誰が起動しても (shutsujin / supervisor / 手動)、二重起動側は取得失敗で
#   自主退場する。判定は flock のみに依存 = pgrep の可視性 (PID namespace /
#   cmdline 自己一致) に依存しない。
#
# 提供関数:
#   proc_lock_acquire <name> <fd> [meta]  → 0=取得(生涯保持) / 1=他プロセス保持中
#   proc_lock_is_held <name>              → 0=生きたプロセスが保持中 / 1=誰も保持せず
#   proc_lock_read_meta <name>            → 保持者が書いた metadata を出力
#   proc_lock_write_meta <name> <meta>    → metadata を書き換え (保持者専用)
#
# lock の置き場は Linux FS (ext4) 固定 (default: ~/.local/share/multi-agent-shogun/locks)。
# /mnt/c (DrvFS) は flock/inotify が不安定ゆえ避ける (queue/inbox symlink と同じ理由)。

SHOGUN_LOCK_DIR="${SHOGUN_LOCK_DIR:-$HOME/.local/share/multi-agent-shogun/locks}"

proc_lock_acquire() {
    local name="$1"
    local fd="$2"
    local meta="${3:-pid=$$}"
    local file="$SHOGUN_LOCK_DIR/${name}.lock"

    mkdir -p "$SHOGUN_LOCK_DIR" 2>/dev/null || return 1

    # append open (>>): 取得失敗時に保持者の metadata を truncate しないため。
    eval "exec ${fd}>>\"\$file\"" || return 1
    if ! flock -n "$fd"; then
        eval "exec ${fd}>&-" 2>/dev/null || true
        return 1
    fi
    # 取得成功 → metadata を書く。別 fd の truncate 書込は自分の flock に影響しない
    # (flock は open file description 単位。新規 open/close は別 description)。
    printf 'pid=%s started=%s %s\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S')" "$meta" > "$file" 2>/dev/null || true
    return 0
}

proc_lock_is_held() {
    local file="$SHOGUN_LOCK_DIR/${1}.lock"
    [ -e "$file" ] || return 1
    # flock が取れる=保持者なし (subshell 終了で即解放・保持者の妨害はしない)。
    if ( flock -n 9 ) 9>>"$file" 2>/dev/null; then
        return 1
    fi
    return 0
}

proc_lock_read_meta() {
    local file="$SHOGUN_LOCK_DIR/${1}.lock"
    head -1 "$file" 2>/dev/null
}

proc_lock_write_meta() {
    local file="$SHOGUN_LOCK_DIR/${1}.lock"
    printf '%s\n' "$2" > "$file" 2>/dev/null
}
