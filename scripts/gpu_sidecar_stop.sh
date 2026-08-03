#!/usr/bin/env bash
# gpu_sidecar_stop.sh — 5090 上の実験用 TTS sidecar を【本番を構造的に守りながら】畳む
#
# 背景 (cmd_1331 / 2026-07-25 夜):
#   足軽四号の比較測定 (C0/C1/C4) で qwen3tts_sidecar.py が 4本積み上がり、5090 が 27.4/32.6GiB。
#   測定は完遂済ゆえ実験分3本は不要だが、★port 9100 は恋の本番serving経路★ ゆえ絶対に落とせぬ。
#   素の `kill` は permission 層で拒まれる (agent/家老とも)。ゆえに
#   ★「何を殺してよいか」を機械で検めてから殺す道具★ を置く。迂回ではなく、判定を構造化する。
#
# 安全設計 (D001 系 destructive 規律):
#   1. 対象 pid の cmdline が qwen3tts_sidecar.py でなければ ★拒否★ (無関係 process を守る)
#   2. 対象 pid が ★保護 port (既定 9100) を LISTEN しておれば拒否★
#      = pid 直書きの約束でなく ★実測した port 所有★ で守る (pid が変わっても守りが効く)
#   3. 既定は SIGTERM (graceful)。SIGKILL は --force 明示時のみ
#   4. --dry-run で判定だけ見られる。実行前後で nvidia-smi の VRAM を印字
#
# ★意図的な本番停止の道 (cmd_1354 / 2026-07-26 朝・家老裁定)★:
#   背景 = 本番 9100 が .env より前に起動しており QWEN3TTS_SEED が実機に効いておらぬ
#          (= 恋が毎回違う声のまま)。seed を効かせるには 9100 を落として起こし直すほか無い。
#   ★但し pkill で迂回するのは【黙って通る道】そのものゆえ禁★。
#   ⇒ ★guard を外すのではなく、「意図した操作」としてのみ通る道を足す★。
#      通すには ★3つ全て★ が要る (1つでも欠ければ従来どおり REFUSE):
#        (a) --intentional-production-stop        = 意思の明示 (取り違えでは立たぬ)
#        (b) --reason "<20字以上の理由文>"        = 誰の裁定で何のためかを言語化
#        (c) --ack-protected-port <port>          = ★落とす保護 port を名指しで承認★
#            (実測した LISTEN port と突合。別 port を書けば通らぬ = 取り違え事故を潰す)
#   さらに ★停止を試みる前に journal へ追記する★ (logs/production_stop_journal.log)。
#   = 落ちた後に書くのでは、途中で死んだ時に記録が残らぬ。
#
# 使い方:
#   bash scripts/gpu_sidecar_stop.sh --dry-run 1633118 1755177 1835043
#   bash scripts/gpu_sidecar_stop.sh 1633118 1755177 1835043
#   bash scripts/gpu_sidecar_stop.sh --protect-ports "9100 9101" <pid>...
#   # ★意図的な本番停止★
#   bash scripts/gpu_sidecar_stop.sh --intentional-production-stop \
#        --ack-protected-port 9100 --reason "殿の恋が毎回違う声のままである。…" <pid>

set -uo pipefail

EXPECT_CMD_PATTERN="qwen3tts_sidecar.py"
PROTECT_PORTS="9100"
DRY_RUN=0
FORCE=0
INTENTIONAL=0
REASON=""
ACK_PORTS=""
BY="${AGENT_ID:-unknown}"
REASON_MIN_CHARS=20
JOURNAL="${GPU_SIDECAR_STOP_JOURNAL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs/production_stop_journal.log}"
PIDS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --protect-ports) PROTECT_PORTS="$2"; shift 2 ;;
    --pattern) EXPECT_CMD_PATTERN="$2"; shift 2 ;;
    --intentional-production-stop) INTENTIONAL=1; shift ;;
    --reason) REASON="$2"; shift 2 ;;
    --ack-protected-port) ACK_PORTS="$ACK_PORTS $2"; shift 2 ;;
    --by) BY="$2"; shift 2 ;;
    -h|--help) sed -n '1,46p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) PIDS+=("$1"); shift ;;
  esac
done

[ "${#PIDS[@]}" -gt 0 ] || { echo "usage: $0 [--dry-run] [--force] <pid>..." >&2; exit 2; }

# ★意思表示なしに理由/承認だけ書いても通さぬ (半端な指定は誤操作の徴候ゆえ即座に止める)★
if [ "$INTENTIONAL" = 0 ] && { [ -n "$REASON" ] || [ -n "${ACK_PORTS// /}" ]; }; then
  echo "★REFUSE★: --reason / --ack-protected-port が在るが --intentional-production-stop が無い" >&2
  echo "  = 意図の明示なき本番停止は通さぬ。3つ揃えて撃て。" >&2
  exit 2
fi

# 理由文の実質を検める (「ok」等では通さぬ = 記録が意味を持たねば journal は飾りになる)
reason_len=0
if [ -n "$REASON" ]; then
  reason_len="$(printf '%s' "$REASON" | wc -m | tr -d ' ')"
fi
if [ "$INTENTIONAL" = 1 ]; then
  if [ "$reason_len" -lt "$REASON_MIN_CHARS" ]; then
    echo "★REFUSE★: --intentional-production-stop には ${REASON_MIN_CHARS}字以上の --reason が要る (現在 ${reason_len}字)" >&2
    echo "  = 「何の裁定で何のために本番を落としたか」を後から言えぬ停止は許さぬ。" >&2
    exit 2
  fi
  if [ -z "${ACK_PORTS// /}" ]; then
    echo "★REFUSE★: --intentional-production-stop には --ack-protected-port <port> が要る" >&2
    echo "  = ★落とす保護 port を名指しで承認せよ★ (取り違えで別の本番を落とさぬための鍵)。" >&2
    exit 2
  fi
fi

journal_append() {
  # $1 = event, $2 = 詳細1行
  mkdir -p "$(dirname "$JOURNAL")" 2>/dev/null
  {
    printf '%s\t%s\tby=%s\t%s\n' "$(date -Iseconds)" "$1" "$BY" "$2"
  } >> "$JOURNAL" 2>/dev/null || true
}

vram() {
  nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader 2>/dev/null \
    || echo "(nvidia-smi 取得失敗)"
}

# pid が LISTEN している port 一覧
ports_of() {
  ss -ltnp 2>/dev/null | grep -oE "[0-9.]+:[0-9]+ .*pid=$1," | grep -oE ":[0-9]+ " | tr -d ': ' || true
}

echo "=== 実行前 VRAM ==="; vram
echo

rc=0
for pid in "${PIDS[@]}"; do
  echo "--- pid $pid"
  if [ ! -d "/proc/$pid" ]; then
    echo "    SKIP: process が存在せぬ (既に終了)"
    continue
  fi
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  if ! printf '%s' "$cmd" | grep -q -- "$EXPECT_CMD_PATTERN"; then
    echo "    ★REFUSE★: cmdline が想定 ($EXPECT_CMD_PATTERN) と違う = 無関係 process ゆえ触れぬ"
    echo "      cmdline: ${cmd:0:160}"
    rc=1; continue
  fi
  owned="$(ports_of "$pid" | tr '\n' ' ')"
  echo "    cmdline OK / LISTEN ports: ${owned:-'(なし)'}"
  guarded=0
  overridden_ports=""
  for p in $PROTECT_PORTS; do
    if printf ' %s ' "$owned" | grep -q " $p "; then
      # ★意図的停止の道★ = 意思表示 + 理由 + ★当該 port の名指し承認★ が揃った時のみ通す
      if [ "$INTENTIONAL" = 1 ] && printf ' %s ' "$ACK_PORTS" | grep -q " $p "; then
        echo "    ★意図的停止★: 保護 port $p を LISTEN しておるが、名指し承認 (--ack-protected-port $p) が在る"
        echo "      理由: $REASON"
        overridden_ports="$overridden_ports $p"
      else
        echo "    ★REFUSE★: 保護 port $p を LISTEN しておる = 本番経路ゆえ絶対に落とさぬ"
        if [ "$INTENTIONAL" = 1 ]; then
          echo "      (--intentional-production-stop は在るが port $p の名指し承認が無い = 取り違えの疑い)"
        fi
        guarded=1
      fi
    fi
  done
  if [ "$guarded" = 1 ]; then rc=1; continue; fi

  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "${overridden_ports// /}" ]; then
      echo "    DRY-RUN: ★意図的停止として★ 落とす対象と判定 (実行はせぬ / 保護port:${overridden_ports})"
    else
      echo "    DRY-RUN: 落とす対象と判定 (実行はせぬ)"
    fi
    continue
  fi

  # ★停止を試みる【前に】記録する★ = 途中で死んでも「誰が何のために落としたか」は残る
  if [ -n "${overridden_ports// /}" ]; then
    journal_append "INTENTIONAL_PRODUCTION_STOP_ATTEMPT" \
      "pid=$pid ports=${overridden_ports# } cmd=${cmd:0:80} reason=$REASON"
  fi

  if kill -TERM "$pid" 2>/dev/null; then
    echo "    SIGTERM 送出"
  else
    echo "    WARN: SIGTERM 送出失敗"
  fi
  for _ in $(seq 1 20); do
    [ -d "/proc/$pid" ] || break
    sleep 0.5
  done
  if [ -d "/proc/$pid" ]; then
    if [ "$FORCE" = 1 ]; then
      kill -KILL "$pid" 2>/dev/null && echo "    SIGKILL 送出 (--force)"
      sleep 1
    fi
    if [ -d "/proc/$pid" ]; then
      echo "    ★残存★: 落ちておらぬ (--force 未指定 or 効かず)"
      [ -n "${overridden_ports// /}" ] && journal_append "INTENTIONAL_PRODUCTION_STOP_FAILED" "pid=$pid 残存"
      rc=1
    else
      echo "    停止確認"
      [ -n "${overridden_ports// /}" ] && journal_append "INTENTIONAL_PRODUCTION_STOP_DONE" "pid=$pid 停止確認 (SIGKILL)"
    fi
  else
    echo "    停止確認"
    [ -n "${overridden_ports// /}" ] && journal_append "INTENTIONAL_PRODUCTION_STOP_DONE" "pid=$pid 停止確認 (SIGTERM)"
  fi
done

echo
echo "=== 実行後 VRAM ==="; vram
echo "=== 残存 sidecar ==="
ss -ltnp 2>/dev/null | grep -E "91[0-9]0" || echo "(9x x0 port の LISTEN なし)"
exit $rc
