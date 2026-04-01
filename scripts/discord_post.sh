#!/usr/bin/env bash
# discord_post.sh — #shogun-reports チャンネルへメッセージを投稿する
#
# 使い方:
#   bash scripts/discord_post.sh "メッセージ内容"
#   bash scripts/discord_post.sh --file path/to/report.md
#
# 依存:
#   - curl, python3
#   - DISCORD_TOKEN, DISCORD_GUILD_ID が backend/.env に設定済みであること

set -euo pipefail

# ---------------------------------------------------------------------------
# .env から DISCORD_TOKEN / DISCORD_GUILD_ID を読み込む
# ---------------------------------------------------------------------------
BACKEND_ENV="/mnt/c/Users/k-kikuchi/development/aituber-project/backend/.env"
if [[ ! -f "$BACKEND_ENV" ]]; then
  echo "[ERROR] .env が見つかりません: $BACKEND_ENV" >&2
  exit 1
fi

DISCORD_TOKEN=""
DISCORD_GUILD_ID=""

while IFS='=' read -r key value; do
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
  key="${key%%[[:space:]]*}"
  value="${value%%[[:space:]]*}"
  case "$key" in
    DISCORD_TOKEN)    DISCORD_TOKEN="$value" ;;
    DISCORD_GUILD_ID) DISCORD_GUILD_ID="$value" ;;
  esac
done < "$BACKEND_ENV"

if [[ -z "$DISCORD_TOKEN" ]]; then
  echo "[ERROR] DISCORD_TOKEN が .env に設定されていません" >&2
  exit 1
fi
if [[ -z "$DISCORD_GUILD_ID" ]]; then
  echo "[ERROR] DISCORD_GUILD_ID が .env に設定されていません" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 引数パース
# ---------------------------------------------------------------------------
CONTENT=""
if [[ "${1:-}" == "--file" ]]; then
  FILE_PATH="${2:?'--file には対象ファイルパスが必要です'}"
  if [[ ! -f "$FILE_PATH" ]]; then
    echo "[ERROR] ファイルが見つかりません: $FILE_PATH" >&2
    exit 1
  fi
  CONTENT="$(cat "$FILE_PATH")"
else
  CONTENT="${1:?'使い方: discord_post.sh "メッセージ" または discord_post.sh --file path'}"
fi

# ---------------------------------------------------------------------------
# JSON ユーティリティ（python3 使用）
# ---------------------------------------------------------------------------
json_get() {
  # json_get <json_str> <key> — 指定キーの文字列値を抽出
  python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2],''))" "$1" "$2"
}

json_array_find() {
  # json_array_find <json_str> <name_key> <name_val> <type_key> <type_val> <id_key>
  # → name_key==name_val かつ type_key==type_val の要素の id_key 値を返す
  python3 -c "
import sys, json
arr = json.loads(sys.argv[1])
name_key, name_val, type_key, type_val, id_key = sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
for item in arr:
    if item.get(name_key) == name_val and item.get(type_key) == type_val:
        print(item.get(id_key, ''))
        break
" "$1" "$2" "$3" "$4" "$5" "$6"
}

json_encode() {
  # json_encode <str> → JSON 文字列（ダブルクォート付き）
  python3 -c "import sys, json; print(json.dumps(sys.argv[1]))" "$1"
}

json_build_message() {
  python3 -c "import sys, json; print(json.dumps({'content': sys.argv[1]}))" "$1"
}

json_build_channel() {
  python3 -c "
import sys, json
name, cat_id, bot_id, owner_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
payload = {
  'name': name,
  'type': 0,
  'parent_id': cat_id,
  'topic': 'multi-agent-shogun 運用レポート専用チャンネル',
  'permission_overwrites': [
    {'id': '0', 'type': 0, 'deny': '1024'},
    {'id': bot_id, 'type': 1, 'allow': '52224'},
    {'id': owner_id, 'type': 1, 'allow': '1024'},
  ]
}
print(json.dumps(payload))
" "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
# #shogun-reports チャンネルを検索 or 作成
# ---------------------------------------------------------------------------
CHANNEL_NAME="shogun-reports"
API_BASE="https://discord.com/api/v10"
AUTH_HEADER="Authorization: Bot ${DISCORD_TOKEN}"

CHANNELS_JSON="$(curl -sSf -H "$AUTH_HEADER" "${API_BASE}/guilds/${DISCORD_GUILD_ID}/channels")"

CHANNEL_ID="$(json_array_find "$CHANNELS_JSON" "name" "$CHANNEL_NAME" "type" "0" "id")"

if [[ -z "$CHANNEL_ID" ]]; then
  echo "[INFO] #${CHANNEL_NAME} チャンネルが見つかりません。作成します..."

  CATEGORY_ID="$(json_array_find "$CHANNELS_JSON" "name" "Bot Internal" "type" "4" "id")"

  if [[ -z "$CATEGORY_ID" ]]; then
    echo "[INFO] カテゴリ 'Bot Internal' を作成します..."
    CAT_PAYLOAD='{"name":"Bot Internal","type":4}'
    CATEGORY_JSON="$(curl -sSf -X POST -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -d "$CAT_PAYLOAD" \
      "${API_BASE}/guilds/${DISCORD_GUILD_ID}/channels")"
    CATEGORY_ID="$(json_get "$CATEGORY_JSON" "id")"
    echo "[OK] カテゴリ作成: $CATEGORY_ID"
  fi

  GUILD_JSON="$(curl -sSf -H "$AUTH_HEADER" "${API_BASE}/guilds/${DISCORD_GUILD_ID}")"
  OWNER_ID="$(json_get "$GUILD_JSON" "owner_id")"

  BOT_USER_JSON="$(curl -sSf -H "$AUTH_HEADER" "${API_BASE}/users/@me")"
  BOT_ID="$(json_get "$BOT_USER_JSON" "id")"

  CREATE_PAYLOAD="$(json_build_channel "$CHANNEL_NAME" "$CATEGORY_ID" "$BOT_ID" "$OWNER_ID")"
  CH_CREATED="$(curl -sSf -X POST -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$CREATE_PAYLOAD" \
    "${API_BASE}/guilds/${DISCORD_GUILD_ID}/channels")"
  CHANNEL_ID="$(json_get "$CH_CREATED" "id")"
  echo "[OK] #${CHANNEL_NAME} チャンネル作成: $CHANNEL_ID"
fi

# ---------------------------------------------------------------------------
# メッセージを2000文字ずつ分割して投稿
# ---------------------------------------------------------------------------
MAX_LEN=2000
TOTAL_LEN="${#CONTENT}"
OFFSET=0
SENT=0

while [[ $OFFSET -lt $TOTAL_LEN ]]; do
  CHUNK="${CONTENT:$OFFSET:$MAX_LEN}"
  OFFSET=$((OFFSET + MAX_LEN))

  MSG_PAYLOAD="$(json_build_message "$CHUNK")"
  RESP="$(curl -sSf -X POST -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$MSG_PAYLOAD" \
    "${API_BASE}/channels/${CHANNEL_ID}/messages")"

  MSG_ID="$(json_get "$RESP" "id")"
  echo "[OK] 投稿成功 (msg_id=$MSG_ID, chunk=$((SENT+1)))"
  SENT=$((SENT + 1))
done

echo "[DONE] ${SENT} チャンク投稿完了 → #${CHANNEL_NAME}"
