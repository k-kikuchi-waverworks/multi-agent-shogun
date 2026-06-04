---
name: discord-ch-state-verify
description: |
  Discord ch操作(削除/read-only化/権限overwrite)後に、bot API(discord.py不要・urllib標準ライブラリ)でlive server状態を独立読取し、期待状態を検証するスキル。
  削除確認(ch消滅)/保護ch無傷/read-only(@everyone SEND deny+VIEW維持)/bot SEND allow/AI投稿smoke testの5項目を自動検証。EXIT0=全PASS。
  「Discord ch検証」「read-only確認」「ch状態verify」「discord-ch-state-verify」で起動。
  認証情報はbackend/.envのDISCORD_TOKEN/DISCORD_GUILD_IDを参照(ハードコード禁止)。
  Do NOT use for: Discord ch一覧取得のみ(discord_channel_inventory.sh)・ch作成/削除/変更操作(それは別タスク)。
---

# discord-ch-state-verify — Discord ch操作後 独立live検証

## North Star

Discord ch操作(削除/read-only化/権限設定)を実施した後、**bot APIで独立に**live server状態を読み取り、自己申告でなく実データとして期待状態を確認する。cmd_873で確立した検証手順を汎用化したスキル。

## When to Use

- Discord ch削除後: 対象chが本当に消えたかを確認したい
- read-only化後: @everyone SEND deny + VIEW維持 + bot SEND allow が正しく設定されているか確認
- 保護chが無傷かを確認したい(削除/権限操作で誤って触れていないか)
- AI(bot)投稿経路が維持されているか smoke test したい
- cmd_873 / cmd_873系操作の検証を再実行したい

## 入力仕様

スキル起動後、以下を聞くか、`$ARGUMENTS` として渡す:

| パラメータ | 説明 | 例 |
|-----------|------|-----|
| 削除確認ch | 削除済みのはずのch id/name list | `1234,5678` |
| 保護chカテゴリ | 無傷のはずのカテゴリ/ch list | `[共通] [恋] [STAFF]` |
| read-only ch | @everyone SEND deny を確認するch id list | `9999,8888` |
| bot投稿smokeテストch | botがSENDできるか確認するch id (任意) | `1111` |

引数なしで起動した場合 → scripts/discord_ch_state_verify.py の DEFAULT_CONFIG を使用。

## 実行手順

### Step 1: 環境確認

```bash
# backend/.env 確認 (DISCORD_TOKEN と DISCORD_GUILD_ID が必要)
grep -E "^(DISCORD_TOKEN|DISCORD_GUILD_ID)=" \
  /home/k-kikuchi/aituber-project/backend/.env 2>/dev/null || \
grep -E "^(DISCORD_TOKEN|DISCORD_GUILD_ID)=" \
  /mnt/c/Users/k-kikuchi/development/aituber-project/backend/.env
```

### Step 2: 検証スクリプト実行

引数なし (DEFAULT_CONFIG使用):
```bash
python3 /mnt/c/tools/multi-agent-shogun/skills/discord-ch-state-verify/scripts/discord_ch_state_verify.py
```

引数あり (個別指定):
```bash
python3 /mnt/c/tools/multi-agent-shogun/skills/discord-ch-state-verify/scripts/discord_ch_state_verify.py \
  --deleted-ids "1234567890,9876543210" \
  --protected-names "[共通],[恋],[STAFF]" \
  --readonly-ids "1111111111,2222222222" \
  --smoke-ch-id "3333333333"
```

### Step 3: 結果確認

スクリプトは以下を出力:

```
[VERIFY] 削除確認: 一般-ja (id=...) → PASS (ch消滅確認)
[VERIFY] 保護ch: welcome-ja (id=...) → PASS (存在確認)
[VERIFY] read-only: chat-ja (id=...) → PASS (@everyone SEND=deny, VIEW=維持)
[VERIFY] bot SEND allow: ai-chat (id=...) → PASS
[SMOKE]  bot投稿test: ai-chat → PASS (msg_id=...)
---
結果: 5/5 PASS  EXIT=0
```

失敗時:
```
[FAIL] read-only: chat-en (id=...) → FAIL (@everyone SEND not denied: allow=0, deny=0)
---
結果: 4/5 PASS  EXIT=1
```

## 検証ロジック詳細

### 削除確認
- Guild全ch listを取得 (`GET /guilds/{id}/channels`)
- 削除済みidがlistに存在しないことを確認

### 保護ch無傷確認
- 指定カテゴリ名/ch名がlistに存在することを確認
- 存在しない場合はFAIL (誤削除の可能性)

### read-only確認 (permission_overwrites解析)
- 各chの `permission_overwrites` を取得
- `@everyone` (type=0, id=guild_id) のエントリを探す
- `deny` に `SEND_MESSAGES` (bit 11 = 2048) が含まれることを確認
- `deny` に `VIEW_CHANNEL` (bit 10 = 1024) が**含まれない**ことを確認

### bot SEND allow確認
- Bot役割のoverwriteが `allow` に `SEND_MESSAGES` (2048) を持つことを確認
- または `@everyone` の deny が bot には適用されていないことを確認

### smoke test (任意)
- 指定chにbot名義でテストメッセージをPOST
- 成功したら即DELETE (痕跡を残さない)

## 認証情報

`DISCORD_TOKEN` と `DISCORD_GUILD_ID` は必ず `backend/.env` から読み込む。
**スクリプト内にハードコードしない。**

探索順:
1. `/home/k-kikuchi/aituber-project/backend/.env` (WSL canonical)
2. `/mnt/c/Users/k-kikuchi/development/aituber-project/backend/.env` (Windows フォールバック)

## 制約

- **GET専用** (削除/権限確認)。smoke test時のみ POST+DELETE (自浄)
- 既存chの削除・権限変更は行わない (read-only設計)
- push禁止 = 殿手番
