---
name: waverworks-deploy-theme
description: waverworks-base-for-wp WordPressテーマをWPMUDEV環境(Staging/Production)にSSH経由でデプロイするスキル。「テーマデプロイ」「deploy」「waverworks deploy」で起動。
---

# /waverworks-deploy-theme — WaverWorks テーマデプロイ

## Overview

`waverworks-base-for-wp` WordPress テーマを **1 コマンドで WPMUDEV サーバへデプロイ**する。

- 手動 15-30 分 → 自動 30-60 秒
- Staging / Production 環境切り替え
- 誤デプロイ防止インタラクティブ確認
- Production は Snapshot 取得 fail-fast
- WP-CLI アクティベート自動化
- ロールバック機構（tar.gz 10 世代）

## When to Use

- WordPress テーマ更新を Staging/Production にデプロイするとき
- 「テーマデプロイ」「waverworks deploy」「deploy theme」と言われたとき
- テーマ変更後に本番反映が必要なとき
- ロールバックが必要なとき

## Prerequisites (殿先行アクション必須)

1. SSH 鍵ペア生成（殿自身が実施、1組共用可）：
   - `ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\waverworks-web\waverworks`
   - Staging/Production 共用の場合は `WAVERWORKS_SSH_KEY_STG/PRD` に同値記入
2. WPMUDEV 管理画面で公開鍵を登録 (Staging/Production 各環境)
3. `skills/waverworks-deploy-theme/.env` を `.env.sample` から作成し実値を記入
   - または `.env.sample` から `backend/.env` の WAVERWORKS_* 変数を参照するよう設定

## Quick Start

```powershell
# Windows PowerShell (multi-agent-shogun root から)
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Staging -DryRun
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Staging
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Production
```

```bash
# WSL2 Ubuntu
./skills/waverworks-deploy-theme/scripts/deploy-theme.sh --environment staging --dry-run
```

## Instructions

### Step 1: 環境確認

```
Read skills/waverworks-deploy-theme/.env.sample
# .env が存在するか確認
# 必須キーが揃っているか確認
```

### Step 2: DryRun で手順確認

```powershell
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Staging -DryRun
```

### Step 3: Staging デプロイ → 確認 → Production

```powershell
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Staging
# Staging サイト確認後...
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Production
```

### Step 4: 問題発生時のロールバック

```powershell
.\skills\waverworks-deploy-theme\scripts\deploy-theme.ps1 -Environment Production -Rollback
```

## Security Notes

- `.env` は git-ignored。**絶対に git add しない**。
- 秘密鍵ファイルは殿ローカルのみ。設計書・YAML・コードへのベタ書き禁止。
- Production デプロイは `yes` 完全一致確認 + Snapshot fail-fast の二重防御。
