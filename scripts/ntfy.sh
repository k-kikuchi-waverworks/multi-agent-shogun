#!/usr/bin/env bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
# FR-066: ntfy認証対応 (Bearer token / Basic auth)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml" >&2
  exit 1
fi

# 認証引数を取得（設定がなければ空 = 後方互換）
AUTH_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

TITLE="${1:-}"
BODY="${2:-}"

# ── cmd_1363: shell に食われぬ本文の受け口 (inbox_write.sh と同じ綴り) ──────
# ★家老が 2026-07-26 に本 script で同型を踏んだ★ = 本文の backtick を shell が先に
#   評価し、送信そのものが失敗した。綴りは scripts/shell_expansion_guard.py の
#   BODY_SENTINELS と一致させること (関所が認めた逃げ道を道具が受け取らねば意味がない)。
#   例: bash scripts/ntfy.sh "🚨 要対応" --body-stdin <<'EOF'
case "$BODY" in
    --stdin|--body-stdin|-)
        BODY="$(cat)"
        ;;
    --content-file=*|--body-file=*)
        _BF="${BODY#*=}"
        [ -f "$_BF" ] || { echo "[ntfy] FATAL: 本文 file が読めぬ: $_BF" >&2; exit 1; }
        BODY="$(cat "$_BF")"
        ;;
    --content-file|--body-file)
        _BF="${3:-}"
        [ -f "$_BF" ] || { echo "[ntfy] FATAL: 本文 file が読めぬ: $_BF" >&2; exit 1; }
        BODY="$(cat "$_BF")"
        ;;
esac
LOG_FILE="$SCRIPT_DIR/logs/ntfy_send.log"
mkdir -p "$SCRIPT_DIR/logs"

# shellcheck disable=SC2086
if [ -n "$BODY" ]; then
  _http_status=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_ARGS[@]}" -H "Title: $TITLE" -H "Tags: outbound" -d "$BODY" "https://ntfy.sh/$TOPIC" 2>/dev/null)
else
  _http_status=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_ARGS[@]}" -H "Tags: outbound" -d "$TITLE" "https://ntfy.sh/$TOPIC" 2>/dev/null)
fi
echo "[$(date '+%Y-%m-%dT%H:%M:%S')] HTTP=$_http_status title=$(echo "$TITLE" | head -c 80)" >> "$LOG_FILE"

# ★cmd_1363: 送信の失敗を【黙って】飲まぬ★
#   旧版は HTTP status を log へ書くだけで ★何が起きても exit 0★ であった =
#   ★「撃ったこと」を成功の証拠にしており、「届いたこと」を見ておらぬ★
#   (五号の教訓 = 解放は「撃った」でなく「VRAM が戻った」で確かめよ、の通知版)。
#   家老が本日 ntfy の送信失敗に気付けなんだのは、この沈黙が理由である。
case "$_http_status" in
    2??) ;;  # 届いた
    *)
        echo "[ntfy] FAILED: HTTP=$_http_status — ★通知は届いておらぬ★ (title=$(echo "$TITLE" | head -c 60))" >&2
        exit 1
        ;;
esac
