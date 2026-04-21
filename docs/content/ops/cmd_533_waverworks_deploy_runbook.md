# WaverWorks テーマデプロイ 運用 Runbook

**スキル**: `waverworks-deploy-theme`
**対象**: WaverWorks WordPress テーマ (waverworks-base-for-wp) の WPMUDEV 環境デプロイ
**対象者**: 殿本人が実施する運用作業
**作成**: cmd_533 (2026-04-21)

---

## 1. 概要

`waverworks-deploy-theme` スキルは、WaverWorks WordPress テーマを WPMUDEV の
Staging / Production 環境に SSH 経由で自動デプロイする。

| 項目 | 内容 |
|---|---|
| デプロイ方式 | SSH + rsync + WP-CLI |
| 所要時間 | 手動 15-30 分 → スクリプト 30-60 秒 |
| 対応環境 | Staging / Production 切り替え |
| 誤デプロイ防止 | Production は `yes` 完全一致確認 + Snapshot fail-fast |
| ロールバック | tar.gz 10 世代保持、1 コマンド復元 |

**殿運用方針（2026-04-21 確定）**: テーマ変更（PHP/CSS/JS 更新）発生時に
本 runbook を参照して実施する。cmd_533 として集中実施せず、次回テーマ更新時に
テストがてら実運用に吸収する。

**スクリプトパス（PowerShell）**:
```
C:\tools\multi-agent-shogun\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1
```

**スクリプトパス（WSL2 Bash）**:
```
./skills/waverworks-deploy-theme/scripts/deploy-theme.sh
```

---

## 2. 前提条件

### 2-1. SSH 鍵の準備（初回のみ）

1 組の ed25519 鍵ペアを Staging / Production 共用で使用する（殿決裁 2026-04-20）。

```powershell
# Windows PowerShell で生成
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\waverworks-web\waverworks"
```

生成後、WPMUDEV 管理画面 (Hub) で Staging / Production 両環境に公開鍵を登録する。

### 2-2. .env ファイルの設定（初回のみ）

```powershell
# multi-agent-shogun リポルートで実行
Copy-Item .\skills\waverworks-deploy-theme\.env.sample `
         .\skills\waverworks-deploy-theme\.env
```

`.env` を開き、下記 **必須 8 変数** に実値を記入する（`.env` は git-ignored、絶対に commit しない）。

| # | 変数名 | 用途 | 備考 |
|---|--------|------|------|
| 1 | `WAVERWORKS_SSH_HOST` | WPMUDEV SSH ホスト | Staging / Production 共用 |
| 2 | `WAVERWORKS_SSH_USER_STG` | Staging SSH ユーザ | |
| 3 | `WAVERWORKS_SSH_USER_PRD` | Production SSH ユーザ | |
| 4 | `WAVERWORKS_SSH_KEY_STG` | Staging 秘密鍵絶対パス (Windows) | 1 組共用時は PRD と同値 |
| 5 | `WAVERWORKS_SSH_KEY_PRD` | Production 秘密鍵絶対パス (Windows) | 1 組共用時は STG と同値 |
| 6 | `WAVERWORKS_THEME_PATH_STG` | Staging テーマ絶対パス（リモートサーバー側） | |
| 7 | `WAVERWORKS_THEME_PATH_PRD` | Production テーマ絶対パス（リモートサーバー側） | Production デプロイ時必須 |
| 8 | `WAVERWORKS_WP_ROOT` | WP root 絶対パス (WP-CLI 用、共通) | |

> **注記**: 殿が 2026-04-20 に設定済みの 7 変数（`WAVERWORKS_THEME_PATH_PRD` は
> 別途確認要）。SSH 鍵は 1 組共用ゆえ `WAVERWORKS_SSH_KEY_STG` / `WAVERWORKS_SSH_KEY_PRD`
> 両変数に同値を記入（設計書 §2.6 準拠）。

### 2-3. 実行環境確認

- Windows 11 + PowerShell 5.1 以上（推奨）
- または WSL2 Ubuntu（deploy-theme.sh wrapper 経由）
- WPMUDEV サーバへの SSH 接続可能なネットワーク

---

## 3. Staging デプロイ手順

### 3-1. DryRun（初回・変更後は必須）

```powershell
cd C:\tools\multi-agent-shogun\skills\waverworks-deploy-theme\scripts
.\deploy-theme.ps1 -Environment Staging -DryRun
```

DryRun では実際の転送・展開を行わず、接続確認とコマンドのログ出力のみ行う。
エラーがないことを確認してから本番デプロイへ進む。

### 3-2. 本番デプロイ

```powershell
.\deploy-theme.ps1 -Environment Staging
```

内部で以下の手順を自動実行する:

| ステップ | 内容 |
|----------|------|
| Step 4 | SSH 接続テスト |
| Step 5 | Pre-flight チェック（必須変数確認） |
| Step 8 | ZIP 作成（ローカルテーマ圧縮） |
| Step 9 | リモートバックアップ（既存テーマを tar.gz 保存） |
| Step 10 | ZIP 転送（rsync / SCP） |
| Step 11 | リモート展開 + 権限設定 |
| Step 12 | WP-CLI テーマアクティベート |
| Step 13 | HTTP 疎通確認 |

### 3-3. Staging 成功判定

- [ ] スクリプトが `exit 0` で終了する
- [ ] `backups/` 配下にタイムスタンプ付き snapshot が生成されている
- [ ] Staging サイト（ログイン画面またはトップページ）の表示確認

---

## 4. Production デプロイ手順

> ⚠️ **Staging 動作確認が完了してから実施すること。**

### 4-1. DryRun（強く推奨）

```powershell
cd C:\tools\multi-agent-shogun\skills\waverworks-deploy-theme\scripts
.\deploy-theme.ps1 -Environment Production -DryRun
```

### 4-2. 本番デプロイ

```powershell
.\deploy-theme.ps1 -Environment Production
```

Production デプロイには以下の追加ステップが実行される:

| ステップ | 内容 |
|----------|------|
| Step 6 | 対話的確認プロンプト（`yes` の完全一致入力が必要） |
| Step 7 | Snapshot 自動取得（fail-fast、下記参照） |

**Snapshot 取得フロー（Step 7）**:

1. Phase 1: WPMUDEV Hub API で Snapshot 要求（`WAVERWORKS_WPMUDEV_API_KEY` 設定時）
2. Phase 2: WP-CLI snapshot package 経由（Phase 1 失敗時のフォールバック）
3. Phase 3: 手動確認プロンプト（Phase 1/2 両方失敗時）

Snapshot が取得できない場合はデプロイが停止する（fail-fast 設計）。

### 4-3. Production 成功判定

- [ ] スクリプトが `exit 0` で終了する
- [ ] `backups/` 配下にタイムスタンプ付き snapshot が生成されている
- [ ] Production サイト表示確認

---

## 5. Snapshot + ロールバック

### 5-1. バックアップ一覧の確認

```powershell
.\deploy-theme.ps1 -Environment Staging -ListBackups
.\deploy-theme.ps1 -Environment Production -ListBackups
```

`backups/` 配下にタイムスタンプ付き tar.gz 形式で最大 10 世代保存される。

### 5-2. ロールバック実行

```powershell
# Staging ロールバック
.\deploy-theme.ps1 -Environment Staging -Rollback

# Production ロールバック
.\deploy-theme.ps1 -Environment Production -Rollback
```

ロールバックは直近の `backups/` スナップショットから逆展開する。

特定タイムスタンプに戻す場合:
```powershell
.\deploy-theme.ps1 -Environment Production -Rollback -Timestamp "yyyyMMdd-HHmmss"
```

### 5-3. Snapshot 未生成時の対処

Step 7 で Snapshot が取得できない場合:
1. `WAVERWORKS_WPMUDEV_API_KEY` 設定を確認（任意項目だが推奨）
2. WP-CLI が動作しているか SSH 越しに確認
3. 解決しない場合は WPMUDEV コンパネ経由で手動 Snapshot を取得してから
   デプロイを再実行する

---

## 6. 実施タイミング指針

**殿運用方針（2026-04-21 確定）**: テーマ変更（PHP/CSS/JS/画像 等の更新）が発生した
タイミングで本 runbook を参照し実施する。

### 推奨サイクル

```
テーマ変更（PHP/CSS/JS 編集）
  ↓
ローカルで git commit
  ↓
.\deploy-theme.ps1 -Environment Staging -DryRun  # 初回・変更後推奨
  ↓
.\deploy-theme.ps1 -Environment Staging
  ↓
Staging サイト目視確認
  ↓
.\deploy-theme.ps1 -Environment Production -DryRun  # 強く推奨
  ↓
.\deploy-theme.ps1 -Environment Production
  ↓
Production サイト確認
  ↓
殿累積 git push（バンドル方式）
```

**DryRun の省略**: 初回は Staging DryRun 必須。以降は殿判断で省略可。
Production DryRun は常に推奨（数秒の追加コストで誤デプロイを防止できる）。

---

## 7. トラブルシューティング

| 事象 | 対処方法 | 連絡先 |
|------|----------|--------|
| SSH 鍵認証失敗 (`Permission denied`) | `.env` の `WAVERWORKS_SSH_KEY_STG/PRD` パス確認、WPMUDEV コンパネで公開鍵の再登録確認 | 殿自判断 |
| `.env` 変数未設定エラー | `.env` ファイルの存在確認と 8 変数の記入確認（プレースホルダ `<...>` が残っていないか） | 殿自判断 |
| `deploy-theme.ps1` バグ疑い | 家老 inbox 経由で軍師 QC 依頼（設計書 v3 参照でコード検証） | 家老 → 軍師 |
| Production Snapshot 未取得でデプロイ停止 | WPMUDEV コンパネで手動 Snapshot 取得 → デプロイ再実行 | 殿自判断、不明時は家老 |
| Production サイト崩れ・表示不正 | 即 Rollback → 家老緊急通知 → 軍師 + 家老で緊急判断 | 家老（緊急） |
| `backups/` にスナップショット未生成 | 家老 inbox 経由で `deploy-theme.ps1` Step 9/10 コード調査依頼 | 軍師 or 足軽 |
| `exit 1` でスクリプト終了（原因不明） | エラーメッセージを家老 inbox に転送し調査依頼 | 家老 → 軍師 |

### ロールバック判断基準

- Production サイトの表示崩れや機能不全が確認された場合 → **即ロールバック**
- ロールバック後も問題が継続する場合 → WPMUDEV コンパネ経由で Snapshot 手動復元にエスカレート

---

## 8. 付録: .env 変数一覧

ファイルパス: `skills/waverworks-deploy-theme/.env`（git-ignored、実値を記入）

```bash
# .env 記入例（実値は <...> で示した部分に記入）

# --- WPMUDEV SSH 接続 ---
WAVERWORKS_SSH_HOST=<your-wpmudev-ssh-host>
WAVERWORKS_SSH_USER_STG=<staging-ssh-username>
WAVERWORKS_SSH_USER_PRD=<production-ssh-username>

# --- 秘密鍵の絶対パス (Windows パス)
# 1 組共用の場合は STG/PRD に同値を記入
WAVERWORKS_SSH_KEY_STG=<C:\Users\<username>\.ssh\waverworks-web\waverworks>
WAVERWORKS_SSH_KEY_PRD=<C:\Users\<username>\.ssh\waverworks-web\waverworks>

# --- テーマ配置パス (リモートサーバー側絶対パス) ---
WAVERWORKS_THEME_PATH_STG=<staging-server-theme-absolute-path>
WAVERWORKS_THEME_PATH_PRD=<production-server-theme-absolute-path>

# --- WordPress ルートパス (WP-CLI 用) ---
WAVERWORKS_WP_ROOT=<wp-root-absolute-path>

# --- テーマソースパス (Windows ローカル) ---
WAVERWORKS_THEME_LOCAL=<windows-local-theme-source-path>

# --- (任意) WPMUDEV Snapshot API ---
# 未設定の場合は WP-CLI または手動確認にフォールバック
# WAVERWORKS_WPMUDEV_API_KEY=<wpmudev-hub-api-key>
# WAVERWORKS_WPMUDEV_SITE_ID_PRD=<production-site-id>
```

> **重要**: `.env` には実値を記入する。`.env.sample` はプレースホルダのみでコミット対象。
> `.env` を絶対に `git add` しないこと（`.gitignore` で除外済）。

---

## 関連ファイル

| ファイル | 説明 |
|---------|------|
| `skills/waverworks-deploy-theme/SKILL.md` | スキル概要・Quick Start |
| `skills/waverworks-deploy-theme/.env.sample` | 変数テンプレート（コミット対象） |
| `skills/waverworks-deploy-theme/scripts/deploy-theme.ps1` | PowerShell 主本 |
| `skills/waverworks-deploy-theme/scripts/deploy-theme.sh` | WSL2 Bash wrapper |
| `skills/waverworks-deploy-theme/scripts/load-env.ps1` | .env 読み込みヘルパー |
| `skills/waverworks-deploy-theme/deploy.config.yml` | デプロイ設定ファイル |
