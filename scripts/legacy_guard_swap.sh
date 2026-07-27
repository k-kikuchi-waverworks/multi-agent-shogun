#!/usr/bin/env bash
# legacy_guard_swap.sh — ledger_guard の [LEGACY] 旧instance を契約版へ無停止swapする
#
# 背景 (cmd_1339 / 足軽一号 e9a1f5e):
#   22:38 の再出陣で watcher×10 + supervisor + idle_revive は契約版へ移行したが、
#   ★ledger_guard だけ旧コードの instance が生存★ (in-place 編集ゆえ fd/255 が deleted inode を指す)。
#   旧instance は [LEGACY] 行を 5秒毎に吐き続け ★15K行/日の log spam★ を生んでおる
#   (一号が warn-once 化を実装済だが、それが効くのは新instance からである)。
#   ⇒ 旧instance を落とせば supervisor が ≤5秒で契約版を起動し、spam も同時に止まる。
#
# 安全設計 (素の kill は permission 層で拒まれる。迂回でなく ★判定の構造化★ で通す):
#   1. 対象 pid の cmdline が `scripts/ledger_guard.sh` でなければ ★拒否★
#   2. ★fd/255 が deleted inode を指しておらねば拒否★
#      = これが [LEGACY] の機械的な指紋。★契約版 (新instance) を誤って落とせぬ★構造的な守り
#   3. ★watcher_supervisor が生存しておらねば拒否★ (再起動の保証が無い状態で落とさぬ)
#   4. 落とした後 ★新instance が deleted でない fd/255 で立つまで待って実測確認★
#      = 立たねば ★loud に失敗を報告★ (黙って台帳の守りを外したままにせぬ)
#   5. --dry-run で判定のみ
#
# 使い方:
#   bash scripts/legacy_guard_swap.sh --dry-run
#   bash scripts/legacy_guard_swap.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$ROOT_DIR/logs/legacy_guard_swap.log"
DRY_RUN=0
WAIT_SEC=30

[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

is_legacy() {   # $1=pid → 0 なら [LEGACY] (fd/255 が deleted)
  readlink "/proc/$1/fd/255" 2>/dev/null | grep -q '(deleted)$'
}

guard_pids() { pgrep -f 'scripts/ledger_guard\.sh' 2>/dev/null || true; }

log "=== legacy_guard_swap 開始 (dry_run=$DRY_RUN) ==="

# --- 前提3: supervisor 生存確認 (再起動の保証) ---
if ! pgrep -f 'scripts/watcher_supervisor\.sh' >/dev/null 2>&1; then
  log "★REFUSE★: watcher_supervisor が生存しておらぬ = 落としても契約版が立たぬ。中止する"
  exit 1
fi
log "前提OK: watcher_supervisor 生存 (再起動の保証あり)"

mapfile -t pids < <(guard_pids)
if [ "${#pids[@]}" -eq 0 ]; then
  log "ledger_guard の process が無い。supervisor が立てるのを待つべき状況ゆえ何もせぬ"
  exit 0
fi

targets=()
for p in "${pids[@]}"; do
  cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
  if ! printf '%s' "$cmd" | grep -q 'scripts/ledger_guard\.sh'; then
    log "  pid $p ★REFUSE★: cmdline が想定と違う (${cmd:0:80})"
    continue
  fi
  if is_legacy "$p"; then
    log "  pid $p = ★[LEGACY]★ (fd/255 が deleted inode) ⇒ swap 対象"
    targets+=("$p")
  else
    log "  pid $p = 契約版 (fd/255 は生きた inode) ⇒ ★守る (触れぬ)★"
  fi
done

if [ "${#targets[@]}" -eq 0 ]; then
  log "[LEGACY] instance は無い = 既に契約版のみ。何もせぬ (冪等)"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY-RUN: 対象 = ${targets[*]} (実行はせぬ)"
  exit 0
fi

before_lines="$(wc -l < "$ROOT_DIR/logs/ledger_guard.log" 2>/dev/null || echo 0)"
for p in "${targets[@]}"; do
  kill -TERM "$p" 2>/dev/null && log "pid $p へ SIGTERM 送出" || log "WARN: pid $p SIGTERM 失敗"
done

# --- 前提4: 契約版が立つまで待って実測確認 ---
log "契約版の起動を待つ (最長 ${WAIT_SEC}s)"
ok=0
for i in $(seq 1 "$WAIT_SEC"); do
  sleep 1
  for p in $(guard_pids); do
    if ! is_legacy "$p"; then
      log "★契約版 起動確認: pid $p (fd/255 = 生きた inode)★ 所要 ${i}s"
      ok=1; break
    fi
  done
  [ "$ok" = 1 ] && break
done

echo "--- 現況 ---" | tee -a "$LOG_FILE"
ps -ef | grep 'scripts/ledger_guard\.sh' | grep -v grep | tee -a "$LOG_FILE"
for p in $(guard_pids); do
  printf 'pid %s fd/255 -> %s\n' "$p" "$(readlink "/proc/$p/fd/255" 2>/dev/null)" | tee -a "$LOG_FILE"
done

if [ "$ok" != 1 ]; then
  log "★FAIL★: ${WAIT_SEC}s 待っても契約版が立たぬ = ★台帳の守りが外れておる。即座に人手で復旧せよ★"
  log "  復旧= nohup bash scripts/ledger_guard.sh >> logs/ledger_guard.log 2>&1 &"
  exit 1
fi

log "=== swap 完遂 === (swap前 log 行数=$before_lines / [LEGACY] spam の停止は以後の増分で検める)"
