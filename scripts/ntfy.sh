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
LOG_FILE="$SCRIPT_DIR/logs/ntfy_send.log"
mkdir -p "$SCRIPT_DIR/logs"

# shellcheck disable=SC2086
if [ -n "$BODY" ]; then
  _http_status=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_ARGS[@]}" -H "Title: $TITLE" -H "Tags: outbound" -d "$BODY" "https://ntfy.sh/$TOPIC" 2>/dev/null)
else
  _http_status=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_ARGS[@]}" -H "Tags: outbound" -d "$TITLE" "https://ntfy.sh/$TOPIC" 2>/dev/null)
fi
echo "[$(date '+%Y-%m-%dT%H:%M:%S')] HTTP=$_http_status title=$(echo "$TITLE" | head -c 80)" >> "$LOG_FILE"
