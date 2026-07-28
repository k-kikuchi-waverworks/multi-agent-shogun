#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# engine_devserver_morning_check.sh — 朝、engine dev server が落ちておれば殿へ一度だけ鳴らす
#
# 起源: cmd_1393 (2026-07-27 00:45 家老)。
#   ★engine dev server が 2026-07-26 22:54:46 に黙って死んでおり、
#     本朝 07:35 の scheduler 一発試験 (cmd_1379) が 07:15 までに起きておらねば死ぬ★という
#   時限が在ったが、★夜間は ntfy 禁 (殿は御就寝・将軍 cmd_1391 命三)★ゆえ朝まで鳴らせなかった。
#   ⇒ ★殿の起床時刻に依存せず、07:00 前に一度だけ「落ちておる時のみ」鳴らす番★を置く。
#
# 設計:
#   ・★落ちておる時のみ鳴らす★= 生きておれば log に1行残すだけ (静かな空振り)
#   ・★判定は二段★= (1) HTTP 応答 (2) eod-tick-state.json の writtenAt が新しいか
#     ⇒ ★LISTEN だけでは tick が回っておる証にならぬ (cmd_1379/1393 の教訓)★
#   ・★毎朝走ってよい形★= engine dev server は殿の日常道具ゆえ、落ちておる朝は毎朝知りたい
#
# Usage: bash scripts/engine_devserver_morning_check.sh [--dry-run]
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENGINE_ROOT="/mnt/c/Users/k-kikuchi/development/ai-automate-engine"
# ★試験のため差し替えられる形にしておく (己の判定式を壊して色が変わるかを検めるため)★
STATE_JSON="${EDM_STATE_JSON:-${ENGINE_ROOT}/logs/eod-tick-state.json}"
PORT="${EDM_PORT:-38080}"
STALE_MIN=20           # writtenAt が此れ以上 古ければ「tick が止まっておる」と見る (watchdog 間隔 10 分の 2 倍)
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

now_str="$(date '+%Y-%m-%d %H:%M:%S')"

# ★|| echo 000 を付けると curl 自身の "000" と二重になり "000000" となって比較が外れる★
#   = ★家老が 00:41 に己で踏んだ穴 (dry-run の出力で気付いた)★。ゆえに空だけを補い、判定は正規表現で行う。
http_code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:${PORT}/api/execute" 2>/dev/null)"
[ -z "${http_code:-}" ] && http_code="000"
http_alive=0
[[ "$http_code" =~ ^[23][0-9][0-9]$ ]] && http_alive=1   # 2xx/3xx = 応答しておる (405 等は下で扱う)
# ★/api/execute は GET を受けぬ実装であり得る = 4xx でも「server は生きておる」★
[[ "$http_code" =~ ^4[0-9][0-9]$ ]] && http_alive=1

tick_note="writtenAt=未取得"
tick_stale=1
if [ -f "$STATE_JSON" ]; then
  written="$(grep -oE '"writtenAt"[[:space:]]*:[[:space:]]*"[^"]+"' "$STATE_JSON" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')"
  if [ -n "${written:-}" ]; then
    w_epoch="$(date -d "$written" +%s 2>/dev/null || echo 0)"
    if [ "$w_epoch" -gt 0 ]; then
      age_min=$(( ( $(date +%s) - w_epoch ) / 60 ))
      tick_note="writtenAt=${written} (${age_min}分前)"
      [ "$age_min" -le "$STALE_MIN" ] && tick_stale=0
    else
      tick_note="writtenAt=${written} (時刻として読めず)"
    fi
  fi
fi

if [ "$http_alive" -eq 0 ] || [ "$tick_stale" -eq 1 ]; then
  reason="http=${http_code} / ${tick_note}"
  body="engine dev server が起きておりませぬ (${reason})。起こし方=Windows PowerShell で cd C:\\Users\\k-kikuchi\\development\\ai-automate-engine ののち npm run dev (★WSL からは撃てませぬ=native binary を壊すゆえ★)。scheduler の一発試験をなさる朝は 07:15 までに起こしておかれたく。"
  echo "[${now_str}] DOWN — ${reason} — ntfy 送信$([ $DRY_RUN -eq 1 ] && echo ' (dry-run ゆえ撃たず)')"
  if [ "$DRY_RUN" -eq 0 ]; then
    bash "${PROJECT_ROOT}/scripts/ntfy.sh" "🚨 engine dev server が落ちております" "$body"
  fi
else
  echo "[${now_str}] OK — http=${http_code} / ${tick_note} (静かに空振り)"
fi
