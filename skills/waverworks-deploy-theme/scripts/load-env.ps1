# load-env.ps1 — .env ファイルを読み込み、環境変数としてプロセスに設定する
# 使い方: . .\load-env.ps1 -EnvFile "path\to\.env"
param(
    [string]$EnvFile = "$PSScriptRoot\..\.env"
)

if (-not (Test-Path $EnvFile)) {
    Write-Error ".env ファイルが見つかりません: $EnvFile"
    Write-Error ".env.sample を参考に .env を作成してください:"
    Write-Error "  Copy-Item '$PSScriptRoot\..\env.sample' '$EnvFile'"
    exit 1
}

$missing = @()
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    # コメント行・空行をスキップ
    if ($line -match '^\s*#' -or $line -eq '') { return }
    if ($line -match '^([^=]+)=(.*)$') {
        $key   = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
    }
}

# 必須キー検証
$requiredKeys = @(
    'WAVERWORKS_SSH_HOST',
    'WAVERWORKS_SSH_USER_STG',
    'WAVERWORKS_SSH_USER_PRD',
    'WAVERWORKS_SSH_KEY_STG',
    'WAVERWORKS_SSH_KEY_PRD',
    'WAVERWORKS_THEME_PATH_STG',
    'WAVERWORKS_THEME_LOCAL'
)

foreach ($key in $requiredKeys) {
    $val = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    if (-not $val -or $val -match '^<') {
        $missing += $key
    }
}

if ($missing.Count -gt 0) {
    Write-Error "必須 .env キーが未設定または placeholder のままです:"
    foreach ($k in $missing) { Write-Error "  - $k" }
    Write-Error ".env を編集して実値を設定してください: $EnvFile"
    exit 1
}
