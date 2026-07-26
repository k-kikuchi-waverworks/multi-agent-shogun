#!/usr/bin/env bash
# night_blackout_guard.sh — 夜間 session 停電 (殿 token 切れ) 中の誤 /clear 封じと復帰 nudge
#
# 背景 (cmd_1346 / 将軍 msg_20260725_232107):
#   crontab の idle_revive_scan は --stall-min 90 で走っており、殿 session が切れて
#   約160分沈黙すると全 agent へ /clear が撃たれる (20:39-20:45 に家老/五号/軍師一号が
#   誤clear され 45分の context を失った事故の再演)。
#   ゆえに停電窓の間だけ閾値を引き上げ、復帰予定時刻に「必ず」元へ戻す。
#
# 設計 (可逆性が命):
#   - arm      : 閾値を退避値へ引上げ + 復旧を【二重】に仕込む
#                  (1) 一発 cron 行 (cron daemon は agent/session と独立に生存 = 主経路)
#                  (2) setsid nohup detached bash (将軍指定形 = 副経路)
#                二重発火は marker file と冪等な crontab 書換で吸収する。
#   - restore  : 閾値を元へ戻す + 一発 cron 行を自去 + 全 agent へ再開 inbox (marker で1回のみ)
#   - status   : 現況表示 (armed か / 現閾値 / 復旧予定)
#
# 使い方:
#   bash scripts/night_blackout_guard.sh arm --at 02:05 [--stall-min 600]
#   bash scripts/night_blackout_guard.sh restore
#   bash scripts/night_blackout_guard.sh status
#   bash scripts/night_blackout_guard.sh disarm     # 手動で即時復旧 (restore と同義)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$ROOT_DIR/logs/night_blackout_guard.log"
STATE_DIR="$ROOT_DIR/logs/night_guard"
LOCK_FILE="$STATE_DIR/arm.lock"
MARKER_RESTORED="$STATE_DIR/restored.marker"
CRON_BACKUP="$STATE_DIR/crontab_before_arm.txt"
STATE_FILE="$STATE_DIR/state.env"

CRON_TAG_IDLE="idle_revive_scan_cmd1154"
CRON_TAG_RESTORE="night_blackout_restore_cmd1346"
NORMAL_STALL_MIN=90

AGENTS=(karo ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 gunshi1 gunshi2)

mkdir -p "$STATE_DIR" "$ROOT_DIR/logs"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

# ---- crontab helpers (冪等・追記のみ / 該当行のみ書換) --------------------

# idle_revive_scan 行の --stall-min を書換える。他行は一切触らない。
set_idle_stall_min() {
  local newval="$1" cur
  cur="$(crontab -l 2>/dev/null)" || cur=""
  if [ -z "$cur" ]; then
    log "ERROR: crontab が空 or 取得失敗。中止する"
    return 1
  fi
  if ! printf '%s\n' "$cur" | grep -q "$CRON_TAG_IDLE"; then
    log "ERROR: crontab に $CRON_TAG_IDLE 行が無い。中止する"
    return 1
  fi
  printf '%s\n' "$cur" \
    | awk -v tag="$CRON_TAG_IDLE" -v v="$newval" '
        $0 ~ tag && $0 !~ /^[[:space:]]*#/ {
          if (!sub(/--stall-min[ ]+[0-9]+/, "--stall-min " v)) {
            # --stall-min 未指定行なら script 直後へ挿入はせず安全側で無改変
            print "# night_blackout_guard: --stall-min 未検出ゆえ無改変 " $0 > "/dev/stderr"
          }
          print; next
        }
        { print }
      ' \
    | crontab -
  local after
  after="$(crontab -l 2>/dev/null | grep "$CRON_TAG_IDLE" | grep -v '^[[:space:]]*#')"
  log "crontab idle 行 (書換後): $after"
  printf '%s' "$after" | grep -q -- "--stall-min $newval"
}

install_restore_cron() {
  local hhmm="$1" hh mm cur
  hh="${hhmm%%:*}"; mm="${hhmm##*:}"
  hh="$((10#$hh))"; mm="$((10#$mm))"
  cur="$(crontab -l 2>/dev/null)" || cur=""
  # 既存の restore 行は取り除いてから入れ直す (冪等)
  cur="$(printf '%s\n' "$cur" | grep -v "$CRON_TAG_RESTORE")"
  printf '%s\n%d %d * * * /bin/bash %s/scripts/night_blackout_guard.sh restore >> %s 2>&1 # %s\n' \
    "$cur" "$mm" "$hh" "$ROOT_DIR" "$LOG_FILE" "$CRON_TAG_RESTORE" | crontab -
  log "復旧 cron を仕込んだ: $(printf '%02d:%02d' "$hh" "$mm") 毎日 (restore が自去する)"
}

remove_restore_cron() {
  local cur
  cur="$(crontab -l 2>/dev/null)" || cur=""
  if printf '%s\n' "$cur" | grep -q "$CRON_TAG_RESTORE"; then
    printf '%s\n' "$cur" | grep -v "$CRON_TAG_RESTORE" | crontab -
    log "復旧 cron 行を自去した"
  fi
}

# ---- arm ----------------------------------------------------------------

cmd_arm() {
  local at="02:05" stall="600"
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) at="$2"; shift 2 ;;
      --stall-min) stall="$2"; shift 2 ;;
      *) log "unknown arg: $1"; return 2 ;;
    esac
  done

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "既に arm 実行中 (lock) ゆえ自主退場"
    return 0
  fi

  crontab -l > "$CRON_BACKUP" 2>/dev/null || true
  log "=== ARM 開始 === 退避先 --stall-min=$stall / 復旧予定=$at / crontab backup=$CRON_BACKUP"

  if ! set_idle_stall_min "$stall"; then
    log "ERROR: 閾値引上げに失敗。crontab を backup から復旧して中止"
    [ -s "$CRON_BACKUP" ] && crontab "$CRON_BACKUP"
    return 1
  fi

  install_restore_cron "$at"

  rm -f "$MARKER_RESTORED"
  {
    echo "ARMED_AT=$(date '+%Y-%m-%dT%H:%M:%S')"
    echo "RESTORE_AT=$at"
    echo "STALL_MIN_ARMED=$stall"
    echo "STALL_MIN_NORMAL=$NORMAL_STALL_MIN"
  } > "$STATE_FILE"

  # 副経路: detached bash (session が死んでも生き残る)
  local wait_sec
  wait_sec="$(python3 - "$at" <<'PY'
import sys, datetime
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now()
tgt = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if tgt <= now:
    tgt += datetime.timedelta(days=1)
print(int((tgt - now).total_seconds()))
PY
)"
  log "detached watcher を起動する (待機 ${wait_sec}s = 復旧予定 $at)"
  setsid nohup bash -c "sleep $wait_sec; /bin/bash '$ROOT_DIR/scripts/night_blackout_guard.sh' restore" \
    >> "$LOG_FILE" 2>&1 < /dev/null &
  disown || true
  log "=== ARM 完遂 === 復旧は cron(主) + detached bash(副) の二重。marker で1回のみ発火"
  cmd_status
}

# ---- restore ------------------------------------------------------------

cmd_restore() {
  exec 8>"$STATE_DIR/restore.lock"
  flock 8

  if [ -f "$MARKER_RESTORED" ]; then
    log "restore は既に完遂済 (marker) ゆえ何もせぬ"
    remove_restore_cron
    return 0
  fi

  log "=== RESTORE 開始 ==="
  if set_idle_stall_min "$NORMAL_STALL_MIN"; then
    log "idle_revive_scan の閾値を $NORMAL_STALL_MIN 分へ復旧した"
  else
    log "ERROR: 閾値復旧に失敗。backup からの全戻しを試みる"
    [ -s "$CRON_BACKUP" ] && crontab "$CRON_BACKUP" && log "crontab を backup から全戻しした"
  fi
  remove_restore_cron
  : > "$MARKER_RESTORED"

  local msg
  msg='【夜間停電より復帰=再開せよ】殿のsession token切れで全agentのsessionが落ちておった。★貴殿に非は無い★。/clear Recovery 手順に従い、queue/tasks/{自分のid}.yaml を唯一の正として再開せよ (status: assigned なら即着手・done なら待機)。中間所見は30-40分毎に queue/reports/ 配下の自分のreport YAMLへ落とせ (ディスクに落ちておらぬ所見は次の停電で消える)。詳細は queue/inbox/{自分のid}.yaml を読め。(night_blackout_guard cmd_1346)'
  local a
  for a in "${AGENTS[@]}"; do
    if bash "$ROOT_DIR/scripts/inbox_write.sh" "$a" "$msg" task_assigned night_blackout_guard >/dev/null 2>&1; then
      log "再開inbox 投函: $a"
    else
      log "WARN: 再開inbox 投函失敗: $a"
    fi
  done
  log "=== RESTORE 完遂 === 全 ${#AGENTS[@]} 体へ再開inbox投函 + 閾値復旧"
}

# ---- status -------------------------------------------------------------

cmd_status() {
  echo "--- night_blackout_guard status ---"
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE"
  echo "restored_marker : $([ -f "$MARKER_RESTORED" ] && echo yes || echo no)"
  echo "cron idle line  : $(crontab -l 2>/dev/null | grep "$CRON_TAG_IDLE" | grep -v '^[[:space:]]*#')"
  echo "cron restore    : $(crontab -l 2>/dev/null | grep "$CRON_TAG_RESTORE" || echo '(なし)')"
  echo "detached watcher: $(pgrep -af "night_blackout_guard.sh' restore" 2>/dev/null | head -3 || true)"
}

case "${1:-status}" in
  arm)     shift; cmd_arm "$@" ;;
  restore) shift; cmd_restore ;;
  disarm)  shift; cmd_restore ;;
  status)  shift; cmd_status ;;
  *) echo "usage: $0 {arm [--at HH:MM] [--stall-min N]|restore|disarm|status}" >&2; exit 2 ;;
esac
