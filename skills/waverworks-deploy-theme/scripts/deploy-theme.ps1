#Requires -Version 5.1
<#
.SYNOPSIS
    WaverWorks テーマデプロイスクリプト (PowerShell 主本)
    設計書: plans/design_cmd533_waverworks_deploy_skill.md v3

.EXAMPLE
    # Staging DryRun
    .\deploy-theme.ps1 -Environment Staging -DryRun

    # Staging デプロイ
    .\deploy-theme.ps1 -Environment Staging

    # Production デプロイ (Snapshot + yes 確認)
    .\deploy-theme.ps1 -Environment Production

    # ロールバック
    .\deploy-theme.ps1 -Environment Production -Rollback

    # バックアップ一覧
    .\deploy-theme.ps1 -Environment Production -ListBackups
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Staging','Production')]
    [string]$Environment,

    [switch]$DryRun,
    [switch]$SkipBuild,
    [switch]$Rollback,
    [switch]$ListBackups,
    [string]$Timestamp = '',
    [switch]$RestoreFromSnapshot,
    [string]$SnapshotId = '',
    [string]$EnvFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir   = $PSScriptRoot
$skillRoot   = Split-Path -Parent $scriptDir
$startTime   = Get-Date
$envUpper    = if ($Environment -eq 'Staging') { 'STG' } else { 'PRD' }
$ts          = Get-Date -Format 'yyyyMMdd-HHmmss'

# ──────────────────────────────────────────────────────────────────
# Step 1: .env 読み込み
# ──────────────────────────────────────────────────────────────────
if (-not $EnvFile) { $EnvFile = Join-Path $skillRoot '.env' }

if (-not (Test-Path $EnvFile)) {
    Write-Error @"
.env ファイルが見つかりません: $EnvFile

セットアップ手順:
  Copy-Item '$skillRoot\.env.sample' '$skillRoot\.env'
  次に .env を編集して実値を記入してください。

他の場所の .env を使う場合:
  .\deploy-theme.ps1 -Environment $Environment -EnvFile 'C:\path\to\.env'
"@
    exit 1
}

Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -match '^\s*#' -or $line -eq '') { return }
    if ($line -match '^([^=]+)=(.*)$') {
        $k = $Matches[1].Trim()
        $v = $Matches[2].Trim()
        [System.Environment]::SetEnvironmentVariable($k, $v, 'Process')
    }
}

# ──────────────────────────────────────────────────────────────────
# Step 2: 環境変数解決
# ──────────────────────────────────────────────────────────────────
function Get-EnvVal {
    param([string]$name)
    $v = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    return $v
}

function Require-EnvVal {
    param([string]$name)
    $v = Get-EnvVal $name
    if (-not $v -or $v -match '^<') {
        Write-Host "✗ 必須 .env 変数が未設定です: $name" -ForegroundColor Red
        Write-Host "  .env を編集してください: $EnvFile" -ForegroundColor Yellow
        exit 1
    }
    return $v
}

$sshHost    = Require-EnvVal 'WAVERWORKS_SSH_HOST'
$sshUser    = Require-EnvVal "WAVERWORKS_SSH_USER_$envUpper"
$sshKey     = Require-EnvVal "WAVERWORKS_SSH_KEY_$envUpper"
$themePath  = Require-EnvVal "WAVERWORKS_THEME_PATH_$envUpper"
$themeLocal = Require-EnvVal 'WAVERWORKS_THEME_LOCAL'

# WP Root: 環境別優先、なければ共通
$wpRoot = Get-EnvVal "WAVERWORKS_WP_ROOT_$envUpper"
if (-not $wpRoot) { $wpRoot = Get-EnvVal 'WAVERWORKS_WP_ROOT' }

# 権限設定 (fallback: www-data:www-data 755/644)
function Get-WithDefault {
    param([string]$name, [string]$default)
    $v = Get-EnvVal $name
    if ($v) { return $v }
    return $default
}
$themeOwner = Get-WithDefault 'WAVERWORKS_THEME_OWNER' 'www-data'
$themeGroup = Get-WithDefault 'WAVERWORKS_THEME_GROUP' 'www-data'
$modeFile   = Get-WithDefault 'WAVERWORKS_THEME_MODE_FILE' '644'
$modeDir    = Get-WithDefault 'WAVERWORKS_THEME_MODE_DIR' '755'

# サイト URL (HTTP 検証用、任意)
$siteUrl = Get-EnvVal "WAVERWORKS_SITE_URL_$envUpper"
if (-not $siteUrl) { $siteUrl = Get-EnvVal 'WAVERWORKS_SITE_URL' }

# WPMUDEV Snapshot API (任意)
$wpmudevApiKey  = Get-EnvVal 'WAVERWORKS_WPMUDEV_API_KEY'
$wpmudevSiteId  = Get-EnvVal "WAVERWORKS_WPMUDEV_SITE_ID_$envUpper"

# パス計算 (Linux パスのため文字列操作)
$themeParent = $themePath.Substring(0, $themePath.LastIndexOf('/'))
$themeName   = $themePath.Substring($themePath.LastIndexOf('/') + 1)
$sshTarget   = "${sshUser}@${sshHost}"

# SSH 引数配列 (-T: 疑似端末無効化、stdin pipe 方式の前提)
$sshArgs = @('-i', $sshKey, '-T', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes')
# SCP 引数配列 (-T は scp 非対応のため分離)
$scpArgs = @('-i', $sshKey, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'BatchMode=yes')

# ローカルバックアップディレクトリ
$localBackupDir = Join-Path $env:USERPROFILE ".waverworks-deploy\backups"

# ──────────────────────────────────────────────────────────────────
# Step 3: ヘルパー関数
# ──────────────────────────────────────────────────────────────────
function Write-Step { param([string]$m) Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] ◆ $m" -ForegroundColor Cyan }
function Write-Info { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-OK   { param([string]$m) Write-Host "    ✓ $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    ⚠ $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    ✗ $m" -ForegroundColor Red }

function Invoke-SSH {
    param([string]$cmd, [switch]$AllowFail)
    if ($DryRun) {
        Write-Info "[DryRun] ssh $sshTarget << 'EOF'`n$cmd`nEOF"
        return ''
    }
    # stdin pipe 方式: Windows OpenSSH でのマルチライン互換のため
    $out = ($cmd | & ssh @sshArgs $sshTarget 'bash -s') 2>&1
    $ec  = $LASTEXITCODE
    if ($ec -ne 0 -and -not $AllowFail) {
        throw "SSH 失敗 (exit $ec):`n出力: $($out -join "`n")"
    }
    return $out
}

function Invoke-SCP {
    param([string]$localPath, [string]$remotePath)
    if ($DryRun) {
        Write-Info "[DryRun] scp '$localPath' → '${sshTarget}:$remotePath'"
        return
    }
    & scp @scpArgs $localPath "${sshTarget}:${remotePath}" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SCP 失敗: $localPath → $remotePath" }
}

# ──────────────────────────────────────────────────────────────────
# Step 4: SSH 接続テスト
# ──────────────────────────────────────────────────────────────────
function Test-SSHConnection {
    Write-Step "SSH 接続テスト ($sshTarget)"
    if ($DryRun) { Write-Info "[DryRun] 接続テストスキップ"; return }
    $out = Invoke-SSH "echo 'SSH_OK'" -AllowFail
    if ($out -notmatch 'SSH_OK') {
        Write-Fail "SSH 接続失敗"
        $connInfo = @"

接続情報確認:
  WAVERWORKS_SSH_HOST       : $sshHost
  WAVERWORKS_SSH_USER_$envUpper : $sshUser
  WAVERWORKS_SSH_KEY_$envUpper  : $sshKey

確認事項:
  1. 鍵ファイルが存在するか: Test-Path '$sshKey'
  2. WPMUDEV 管理画面で公開鍵が登録済みか
  3. ssh-agent に鍵が追加済みか: ssh-add '$sshKey'
"@
        Write-Host $connInfo -ForegroundColor Yellow
        exit 1
    }
    Write-OK "SSH 接続成功"
}

# ──────────────────────────────────────────────────────────────────
# Step 5: Pre-flight チェック
# ──────────────────────────────────────────────────────────────────
function Test-Preflight {
    Write-Step "Pre-flight チェック"

    # テーマソースディレクトリ存在確認
    if (-not (Test-Path $themeLocal)) {
        Write-Fail "テーマソースが見つかりません: $themeLocal"
        exit 1
    }
    Write-OK "テーマソース: $themeLocal"

    # git uncommitted changes 確認
    $gitStatus = & git -C $themeLocal status --porcelain 2>&1
    if ($gitStatus) {
        Write-Warn "未コミット変更あり ($($gitStatus.Count) ファイル) — デプロイは続行可"
    } else {
        Write-OK "git: クリーンな状態"
    }

    # commit hash 取得
    $script:commitHash = & git -C $themeLocal rev-parse --short HEAD 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "commit: $script:commitHash"
    } else {
        $script:commitHash = 'unknown'
    }

    # Gulp ビルド成果物確認
    if (-not $SkipBuild) {
        $buildCheck = Join-Path $themeLocal 'public\css'
        $minCss     = Get-ChildItem -Path $buildCheck -Filter '*.min.css' -ErrorAction SilentlyContinue
        if (-not $minCss) {
            Write-Fail "Gulp ビルド成果物が見つかりません: $buildCheck\*.min.css"
            Write-Host "    ビルドを実行してください: cd '$themeLocal'; npx gulp build" -ForegroundColor Yellow
            Write-Host "    または -SkipBuild フラグで確認をスキップ" -ForegroundColor Yellow
            exit 1
        }
        Write-OK "Gulp ビルド成果物確認 ($($minCss.Count) ファイル)"
    } else {
        Write-Warn "SkipBuild: Gulp 成果物チェックをスキップ"
    }

    # リモートディスク容量確認
    if (-not $DryRun) {
        $dfCmd    = "df -k '$themeParent' | tail -1 | awk '{print \$4}'"
        $dfResult = Invoke-SSH $dfCmd -AllowFail
        if ($dfResult -match '^\d+$') {
            $freeKB = [long]$dfResult
            if ($freeKB -lt 200000) {
                Write-Warn "リモートディスク空き容量が少ない: $([math]::Round($freeKB/1024))MB"
            } else {
                Write-OK "リモート空き容量: $([math]::Round($freeKB/1024))MB"
            }
        }
    }
}

# ──────────────────────────────────────────────────────────────────
# Step 6: Production 確認
# ──────────────────────────────────────────────────────────────────
function Confirm-ProductionDeploy {
    if ($Environment -ne 'Production' -or $DryRun) { return }
    Write-Host "`n⚠⚠⚠  本番環境 (Production) へのデプロイです  ⚠⚠⚠" -ForegroundColor Red
    Write-Host "  対象: ${sshTarget}:${themePath}" -ForegroundColor Yellow
    $input = Read-Host 'デプロイを実行しますか？ (続行するには "yes" と入力)'
    if ($input -ne 'yes') {
        Write-Host "`nデプロイをキャンセルしました。" -ForegroundColor Yellow
        exit 0
    }
}

# ──────────────────────────────────────────────────────────────────
# Step 7: Snapshot 取得 (Production のみ、fail-fast)
# ──────────────────────────────────────────────────────────────────
function Get-ProductionSnapshot {
    if ($Environment -ne 'Production') { return $null }

    Write-Step "Production Snapshot 取得 (fail-fast)"

    # Phase 1: WPMUDEV Snapshot REST API
    if ($wpmudevApiKey -and $wpmudevSiteId) {
        Write-Info "Phase1: WPMUDEV Hub API で Snapshot 要求..."
        if ($DryRun) {
            Write-Info "[DryRun] POST https://wpmudev.com/api/hub/v1/sites/$wpmudevSiteId/snapshots"
            return 'dryrun-snapshot-id'
        }
        try {
            $headers  = @{ 'Authorization' = "Bearer $wpmudevApiKey"; 'Content-Type' = 'application/json' }
            $apiUrl   = "https://wpmudev.com/api/hub/v1/sites/$wpmudevSiteId/snapshots"
            $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body '{}' -TimeoutSec 60
            if ($response.id -or $response.snapshot_id) {
                $snapId = if ($response.id) { $response.id } else { $response.snapshot_id }
                Write-OK "Snapshot 作成成功 (API): $snapId"
                return $snapId
            }
            Write-Warn "Snapshot API レスポンス不明 — Phase2 へフォールバック"
        } catch {
            Write-Warn "Snapshot API 失敗: $_ — Phase2 へフォールバック"
        }
    }

    # Phase 2: WP-CLI snapshot package
    Write-Info "Phase2: WP-CLI snapshot package 確認..."
    if (-not $DryRun) {
        $pkgList = Invoke-SSH "wp package list --fields=name 2>/dev/null | grep -i snapshot" -AllowFail
        if ($pkgList -match 'snapshot') {
            Write-Info "WP-CLI snapshot package 検出 → Snapshot 作成..."
            $result = Invoke-SSH "wp snapshot create --path=$wpRoot 2>&1" -AllowFail
            if ($LASTEXITCODE -eq 0 -and $result) {
                Write-OK "Snapshot 作成成功 (WP-CLI): $result"
                return "wpcli-$ts"
            }
            Write-Warn "WP-CLI snapshot 失敗 — Phase3 へフォールバック"
        } else {
            Write-Warn "WP-CLI snapshot package なし — Phase3 へフォールバック"
        }
    }

    # Phase 3: 手動確認プロンプト
    Write-Host "`n  ────────────────────────────────────────────────" -ForegroundColor Yellow
    Write-Host "  ⚠ 手動 Snapshot 取得が必要です" -ForegroundColor Yellow
    Write-Host "  1. WPMUDEV Hub (https://wpmudev.com) にログイン" -ForegroundColor White
    Write-Host "  2. Sites → [サイト] → Backups → Create Backup" -ForegroundColor White
    Write-Host "  3. Backup 完了後、ここに戻って 'done' と入力" -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────`n" -ForegroundColor Yellow

    $confirm = Read-Host "Snapshot 取得完了? ('done' で続行 / Enter でキャンセル)"
    if ($confirm -ne 'done') {
        Write-Fail "Snapshot 確認がキャンセルされました。Production デプロイを中止します。"
        exit 2
    }
    Write-OK "手動 Snapshot 確認完了"
    return "manual-$ts"
}

# ──────────────────────────────────────────────────────────────────
# Step 8: ZIP 作成
# ──────────────────────────────────────────────────────────────────
function Build-ThemeZip {
    Write-Step "テーマ ZIP 作成"

    $envLower = $Environment.ToLower()
    $zipName  = "${themeName}-${envLower}-${ts}.zip"
    $stageDir = Join-Path $env:TEMP "waverworks-deploy-stage-$ts"
    $stageTmp = Join-Path $stageDir $themeName
    $zipPath  = Join-Path $stageDir $zipName

    # 除外ディレクトリ
    $excludeDirs = @(
        'node_modules', '.git', 'vendor', '.storybook', 'stories',
        '.vscode', '.idea', 'coverage', '.nyc_output', '.cursor',
        'playwright-report', 'test-results', 'tests',
        '.phpunit.result.cache', 'build', '.phpcs.cache',
        'plans', 'docs', 'bin', '.history'
    )

    # 除外ファイルパターン
    $excludeFiles = @(
        '*.log', '.env', '.env.local', '.env.development.local',
        '.env.test.local', '.env.production.local', '.env.sample',
        '*.map', 'npm-debug.log*', 'yarn-*.log*',
        'phpunit.xml.dist', 'phpunit-unit.xml', 'playwright.config.ts'
    )

    if ($DryRun) {
        Write-Info "[DryRun] robocopy '$themeLocal' '$stageTmp' /E /XD $($excludeDirs -join ' ')"
        Write-Info "[DryRun] Compress-Archive '$stageTmp' '$zipPath'"
        $script:zipPath   = $zipPath
        $script:zipName   = $zipName
        $script:sha256    = 'dryrun-sha256'
        return $zipPath
    }

    New-Item -ItemType Directory -Path $stageTmp -Force | Out-Null

    $robocopyArgs = @($themeLocal, $stageTmp, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS')
    foreach ($d in $excludeDirs) { $robocopyArgs += '/XD'; $robocopyArgs += $d }
    foreach ($f in $excludeFiles) { $robocopyArgs += '/XF'; $robocopyArgs += $f }

    & robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        throw "Robocopy 失敗 (exit $LASTEXITCODE)"
    }

    # ZIP サイズ事前チェック
    $sizeMB = [math]::Round((Get-ChildItem $stageTmp -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    if ($sizeMB -lt 1) {
        Write-Warn "ZIP 対象サイズが小さすぎます (${sizeMB}MB) — 除外設定を確認してください"
        $confirm = Read-Host "続行しますか? (yes/no)"
        if ($confirm -ne 'yes') { exit 1 }
    } elseif ($sizeMB -gt 500) {
        Write-Warn "ZIP 対象サイズが大きすぎます (${sizeMB}MB) — 除外設定を見直してください"
        $confirm = Read-Host "続行しますか? (yes/no)"
        if ($confirm -ne 'yes') { exit 1 }
    }

    Compress-Archive -Path $stageTmp -DestinationPath $zipPath -Force
    Write-OK "ZIP 作成: $zipPath ($sizeMB MB)"

    # SHA256 計算
    $hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
    Write-OK "SHA256: $hash"

    # ローカルバックアップへコピー
    if (-not (Test-Path $localBackupDir)) { New-Item -ItemType Directory -Path $localBackupDir -Force | Out-Null }
    Copy-Item $zipPath (Join-Path $localBackupDir $zipName)

    # ステージングディレクトリ掃除 (ZIPのみ残す)
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    Copy-Item (Join-Path $localBackupDir $zipName) $zipPath

    # ローカルバックアップ世代管理 (10世代)
    $backups = Get-ChildItem $localBackupDir -Filter "${themeName}-*.zip" | Sort-Object Name
    if ($backups.Count -gt 10) {
        $backups | Select-Object -First ($backups.Count - 10) | Remove-Item -Force
    }

    $script:zipPath = $zipPath
    $script:zipName = $zipName
    $script:sha256  = $hash
    $script:stageDir = $stageDir
    return $zipPath
}

# ──────────────────────────────────────────────────────────────────
# Step 9: リモートバックアップ
# ──────────────────────────────────────────────────────────────────
function Backup-RemoteTheme {
    Write-Step "リモートテーマバックアップ"
    $backupName = "${themeName}-backup-${ts}.tar.gz"
    $cmd = "cd '$themeParent' && tar czf '$backupName' '$themeName' 2>&1 && echo 'BACKUP_OK'"
    $result = Invoke-SSH $cmd
    if (-not $DryRun -and $result -notmatch 'BACKUP_OK') {
        Write-Warn "リモートバックアップ失敗 — デプロイは続行します: $result"
    } else {
        Write-OK "リモートバックアップ: $themeParent/$backupName"
    }

    # リモートバックアップ世代管理 (10世代)
    $cleanCmd = @"
backups=(`$( ls -t '$themeParent/${themeName}-backup-'*.tar.gz 2>/dev/null )`); count=`${#backups[@]}; if [ `$count -gt 10 ]; then for old in `${backups[@]:10}; do rm -f `$old; done; fi; echo "CLEAN_OK"
"@
    Invoke-SSH $cleanCmd -AllowFail | Out-Null
}

# ──────────────────────────────────────────────────────────────────
# Step 10: ZIP 転送
# ──────────────────────────────────────────────────────────────────
function Transfer-ThemeZip {
    Write-Step "ZIP 転送 ($sshTarget)"
    Invoke-SCP $script:zipPath "$themeParent/"
    Write-OK "転送完了: $script:zipName"
}

# ──────────────────────────────────────────────────────────────────
# Step 11: リモート展開 + 権限設定
# ──────────────────────────────────────────────────────────────────
function Extract-RemoteTheme {
    Write-Step "リモート展開 + 権限設定"

    $tmpDir  = "${themeName}.tmp"
    $oldDir  = "${themeName}.old"
    $zipFile = $script:zipName

    # ZIP構造検出付きアトミック差替 (dir名あり/なし両対応)
    $deployCmd = @"
set -e
cd '$themeParent'
rm -rf '$tmpDir'
mkdir '$tmpDir'
unzip -q '$zipFile' -d '$tmpDir'
if [ -d '$tmpDir/$themeName' ]; then
    mv_src='$tmpDir/$themeName'
else
    mv_src='$tmpDir'
fi
rm -rf '$oldDir'
mv '$themeName' '$oldDir' 2>/dev/null || true
mv "`$mv_src" '$themeName'
[ "`$mv_src" != '$tmpDir' ] && rm -rf '$tmpDir'
rm -f '$zipFile'
echo 'DEPLOY_OK'
"@

    $result = Invoke-SSH $deployCmd
    if (-not $DryRun -and $result -notmatch 'DEPLOY_OK') {
        Write-Fail "展開失敗 — ロールバックを試みます"
        Invoke-RemoteRollback $ts
        throw "展開失敗 (ロールバック実行済み)"
    }
    Write-OK "展開完了"

    # 権限設定
    $permCmd = "find '$themePath' -type d -exec chmod $modeDir {} \; && find '$themePath' -type f -exec chmod $modeFile {} \; && chown -R ${themeOwner}:${themeGroup} '$themePath' 2>&1; echo 'PERM_OK'"
    $permResult = Invoke-SSH $permCmd -AllowFail
    if ($DryRun -or $permResult -match 'PERM_OK') {
        Write-OK "権限設定: ${themeOwner}:${themeGroup} dir=${modeDir} file=${modeFile}"
    } else {
        Write-Warn "権限設定部分失敗 (続行): $permResult"
    }
}

# ──────────────────────────────────────────────────────────────────
# Step 12: WP-CLI テーマアクティベート
# ──────────────────────────────────────────────────────────────────
function Invoke-WPActivate {
    Write-Step "WP-CLI テーマアクティベート"

    if (-not $wpRoot) {
        Write-Warn "WAVERWORKS_WP_ROOT 未設定 — アクティベートをスキップします"
        Write-Host "    WordPress 管理画面 → 外観 → テーマ から手動で '$themeName' をアクティベートしてください" -ForegroundColor Yellow
        return
    }

    # WP-CLI の存在確認
    $wpCheck = Invoke-SSH "which wp 2>/dev/null || wp --info 2>/dev/null | head -1" -AllowFail
    if (-not $DryRun -and -not $wpCheck) {
        Write-Warn "WP-CLI が見つかりません — アクティベートをスキップします"
        Write-Host "    手動対応: WordPress 管理画面 → 外観 → テーマ → '$themeName' をアクティベート" -ForegroundColor Yellow
        return
    }

    $activateCmd = "wp theme activate '$themeName' --path='$wpRoot' && echo 'ACTIVATE_DONE' || echo 'ACTIVATE_FAIL'"
    $result      = Invoke-SSH $activateCmd -AllowFail
    if (-not $DryRun -and $result -match 'ACTIVATE_FAIL') {
        Write-Warn "WP-CLI activate 失敗 — ロールバックを試みます"
        Invoke-RemoteRollback $ts
        throw "WP-CLI activate 失敗 (ロールバック実行済み)"
    }
    Write-OK "テーマアクティベート完了: $themeName"
}

# ──────────────────────────────────────────────────────────────────
# Step 13: HTTP 疎通確認
# ──────────────────────────────────────────────────────────────────
function Test-HTTPVerification {
    Write-Step "HTTP 疎通確認"

    if (-not $siteUrl) {
        Write-Warn "WAVERWORKS_SITE_URL 未設定 — HTTP 確認をスキップ"
        Write-Host "    手動確認: $siteUrl" -ForegroundColor Yellow
        return
    }

    $paths = if ($Environment -eq 'Production') {
        @('/', '/wp-login.php')
    } else {
        @('/', '/wp-login.php')
    }

    $allOK = $true
    foreach ($path in $paths) {
        $url = $siteUrl.TrimEnd('/') + $path
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Write-OK "HTTP 200: $url"
            } else {
                Write-Warn "HTTP $($resp.StatusCode): $url"
                $allOK = $false
            }
        } catch {
            Write-Warn "HTTP 確認失敗: $url ($_)"
            $allOK = $false
        }
    }

    if (-not $allOK) {
        Write-Warn "HTTP 確認で問題あり — サイトを目視確認してください"
        Write-Warn "ロールバックが必要な場合: .\deploy-theme.ps1 -Environment $Environment -Rollback"
    }
}

# ──────────────────────────────────────────────────────────────────
# ロールバック補助 (内部呼び出し用)
# ──────────────────────────────────────────────────────────────────
function Invoke-RemoteRollback {
    param([string]$deployTs = '')
    Write-Step "緊急ロールバック実行"
    $backupGlob = if ($deployTs) { "${themeName}-backup-${deployTs}.tar.gz" } else { "${themeName}-backup-*.tar.gz" }
    $rollbackCmd = @"
set -e
cd '$themeParent'
latest=`$( ls -t '${themeName}-backup-'*.tar.gz 2>/dev/null | head -1 )
if [ -z "`$latest" ]; then echo 'NO_BACKUP'; exit 1; fi
rm -rf '${themeName}.old'
mv '$themeName' '${themeName}.old' 2>/dev/null || true
tar xzf "`$latest"
rm -rf '${themeName}.old'
echo "ROLLBACK_OK:`$latest"
"@
    $result = Invoke-SSH $rollbackCmd -AllowFail
    if ($result -match 'ROLLBACK_OK') {
        Write-OK "ロールバック完了: $result"
    } else {
        Write-Fail "ロールバック失敗 — 手動復旧が必要です"
        Write-Host "    リモートバックアップ: $themeParent/${themeName}-backup-*.tar.gz" -ForegroundColor Yellow
    }
}

# ──────────────────────────────────────────────────────────────────
# バックアップ一覧 (-ListBackups)
# ──────────────────────────────────────────────────────────────────
function Invoke-ListBackups {
    Write-Step "リモートバックアップ一覧 [$Environment]"
    Test-SSHConnection
    $listCmd = "ls -lh '$themeParent/${themeName}-backup-'*.tar.gz 2>/dev/null || echo 'NO_BACKUPS'"
    $result  = Invoke-SSH $listCmd
    if ($result -match 'NO_BACKUPS') {
        Write-Warn "バックアップが見つかりません: $themeParent/"
    } else {
        Write-Host "`n$result" -ForegroundColor White
    }

    Write-Step "ローカルバックアップ一覧"
    if (Test-Path $localBackupDir) {
        Get-ChildItem $localBackupDir -Filter "${themeName}-*.zip" |
            Sort-Object Name -Descending |
            ForEach-Object { Write-Host "    $($_.Name)  $([math]::Round($_.Length/1MB,1))MB" -ForegroundColor Gray }
    } else {
        Write-Warn "ローカルバックアップなし: $localBackupDir"
    }
}

# ──────────────────────────────────────────────────────────────────
# ロールバック (-Rollback)
# ──────────────────────────────────────────────────────────────────
function Invoke-Rollback {
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] ◆ ロールバック開始 [$Environment]" -ForegroundColor Magenta
    Test-SSHConnection

    if ($Environment -eq 'Production' -and -not $DryRun) {
        Write-Host "`n⚠ Production ロールバックです。" -ForegroundColor Red
        $input = Read-Host 'ロールバックを実行しますか? (続行するには "yes" と入力)'
        if ($input -ne 'yes') { Write-Host "キャンセルしました。"; exit 0 }
    }

    # ロールバック先を決定
    if ($Timestamp) {
        $target = "${themeName}-backup-${Timestamp}.tar.gz"
        $rollbackCmd = @"
set -e
cd '$themeParent'
if [ ! -f '$target' ]; then echo 'BACKUP_NOT_FOUND'; exit 1; fi
rm -rf '${themeName}.old'
mv '$themeName' '${themeName}.old' 2>/dev/null || true
tar xzf '$target'
rm -rf '${themeName}.old'
echo "ROLLBACK_OK:$target"
"@
    } else {
        $rollbackCmd = @"
set -e
cd '$themeParent'
latest=`$( ls -t '${themeName}-backup-'*.tar.gz 2>/dev/null | head -1 )
if [ -z "`$latest" ]; then echo 'NO_BACKUP'; exit 1; fi
rm -rf '${themeName}.old'
mv '$themeName' '${themeName}.old' 2>/dev/null || true
tar xzf "`$latest"
rm -rf '${themeName}.old'
echo "ROLLBACK_OK:`$latest"
"@
    }

    $result = Invoke-SSH $rollbackCmd -AllowFail
    if ($result -match 'NO_BACKUP') {
        Write-Fail "バックアップが見つかりません: $themeParent/"
        exit 1
    } elseif ($result -match 'BACKUP_NOT_FOUND') {
        Write-Fail "指定バックアップが見つかりません: $Timestamp"
        exit 1
    } elseif ($DryRun -or $result -match 'ROLLBACK_OK') {
        Write-OK "ロールバック完了: $result"
    } else {
        Write-Fail "ロールバック失敗: $result"
        exit 1
    }

    # ロールバック後 WP-CLI activate
    Invoke-WPActivate

    # HTTP 確認
    Test-HTTPVerification

    Write-Host "`n✅ ロールバック完了 [$Environment] $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green
}

# ──────────────────────────────────────────────────────────────────
# メインデプロイフロー
# ──────────────────────────────────────────────────────────────────
function Invoke-Deploy {
    $modeTag = if ($DryRun) { ' [DryRun]' } else { '' }
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  WaverWorks テーマデプロイ [$Environment]$modeTag" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    $script:commitHash = 'unknown'
    $script:snapId     = $null
    $script:zipPath    = ''
    $script:zipName    = ''
    $script:sha256     = ''
    $script:stageDir   = ''

    # 1. SSH 接続テスト
    Test-SSHConnection

    # 2. Pre-flight
    Test-Preflight

    # 3. Production 確認
    Confirm-ProductionDeploy

    # 4. Snapshot (Production のみ)
    $script:snapId = Get-ProductionSnapshot

    # 5. ZIP 作成
    Build-ThemeZip

    # 6. リモートバックアップ
    Backup-RemoteTheme

    # 7. ZIP 転送
    Transfer-ThemeZip

    # 8. 展開 + 権限
    Extract-RemoteTheme

    # 9. WP-CLI activate
    Invoke-WPActivate

    # 10. HTTP 確認
    Test-HTTPVerification

    # 11. ステージングディレクトリ掃除
    if ($script:stageDir -and (Test-Path $script:stageDir)) {
        Remove-Item $script:stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 12. サマリ出力
    $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "  ✅ デプロイ完了 [$Environment]$modeTag" -ForegroundColor Green
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
    Write-Host "  環境     : $Environment" -ForegroundColor White
    Write-Host "  commit   : $($script:commitHash)" -ForegroundColor White
    Write-Host "  ZIP      : $($script:zipName)" -ForegroundColor White
    Write-Host "  SHA256   : $($script:sha256)" -ForegroundColor White
    if ($script:snapId) {
    Write-Host "  Snapshot : $($script:snapId)" -ForegroundColor White }
    Write-Host "  ローカルBK: $localBackupDir" -ForegroundColor White
    if ($siteUrl) {
    Write-Host "  サイト   : $siteUrl" -ForegroundColor White }
    Write-Host "  所要時間 : ${elapsed}秒" -ForegroundColor White
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Green
}

# ──────────────────────────────────────────────────────────────────
# エントリーポイント
# ──────────────────────────────────────────────────────────────────
if ($ListBackups) {
    Invoke-ListBackups
} elseif ($Rollback) {
    Invoke-Rollback
} elseif ($RestoreFromSnapshot) {
    if (-not $SnapshotId) {
        Write-Host "✗ -SnapshotId パラメータが必要です" -ForegroundColor Red
        exit 1
    }
    Write-Host "RestoreFromSnapshot は現在未実装です。WPMUDEV 管理画面から手動で復元してください。" -ForegroundColor Yellow
    Write-Host "Snapshot ID: $SnapshotId" -ForegroundColor Yellow
} else {
    Invoke-Deploy
}
