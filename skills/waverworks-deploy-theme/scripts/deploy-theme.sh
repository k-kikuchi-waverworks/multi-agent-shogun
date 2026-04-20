#!/usr/bin/env bash
# deploy-theme.sh — WSL2 Ubuntu から deploy-theme.ps1 を呼び出すラッパー
# 使い方:
#   ./deploy-theme.sh --environment staging --dry-run
#   ./deploy-theme.sh --environment production
#   ./deploy-theme.sh --environment production --rollback
#   ./deploy-theme.sh --environment staging --list-backups

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_SCRIPT="$SCRIPT_DIR/deploy-theme.ps1"

# PowerShell.exe のパスを検索 (WSL2 想定)
if command -v powershell.exe &>/dev/null; then
    PS_CMD="powershell.exe"
elif command -v pwsh.exe &>/dev/null; then
    PS_CMD="pwsh.exe"
elif [ -x "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
    PS_CMD="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
else
    echo "ERROR: PowerShell が見つかりません。WSL2 環境であることを確認してください。" >&2
    exit 1
fi

# WSL パス → Windows パスに変換
to_win_path() {
    wslpath -w "$1" 2>/dev/null || echo "$1"
}

PS1_WIN="$(to_win_path "$PS1_SCRIPT")"

# 引数マッピング: bash --xxx → PowerShell -Xxx
ENVIRONMENT=""
PS_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment|-e)
            ENVIRONMENT="$2"
            # 先頭大文字に変換 (Staging / Production)
            ENVIRONMENT="$(echo "${ENVIRONMENT:0:1}" | tr '[:lower:]' '[:upper:]')${ENVIRONMENT:1}"
            shift 2
            ;;
        --dry-run|--dryrun)
            PS_ARGS+=("-DryRun")
            shift
            ;;
        --skip-build|--skipbuild)
            PS_ARGS+=("-SkipBuild")
            shift
            ;;
        --rollback)
            PS_ARGS+=("-Rollback")
            shift
            ;;
        --list-backups|--listbackups)
            PS_ARGS+=("-ListBackups")
            shift
            ;;
        --timestamp)
            PS_ARGS+=("-Timestamp" "$2")
            shift 2
            ;;
        --restore-from-snapshot|--restorefromsnapshot)
            PS_ARGS+=("-RestoreFromSnapshot")
            shift
            ;;
        --snapshot-id)
            PS_ARGS+=("-SnapshotId" "$2")
            shift 2
            ;;
        --env-file)
            WIN_ENV="$(to_win_path "$2")"
            PS_ARGS+=("-EnvFile" "$WIN_ENV")
            shift 2
            ;;
        --help|-h)
            cat <<'EOF'
Usage: deploy-theme.sh --environment <Staging|Production> [OPTIONS]

Options:
  --environment,-e   <Staging|Production>  デプロイ環境 (必須)
  --dry-run                                ドライラン (実際の転送なし)
  --skip-build                             Gulp ビルド確認スキップ
  --rollback                               直前バックアップへロールバック
  --timestamp        <YYYYMMDD-HHmmss>    ロールバック先タイムスタンプ
  --list-backups                           バックアップ一覧表示
  --restore-from-snapshot                  Snapshot から復元
  --snapshot-id      <id>                  Snapshot ID
  --env-file         <path>                .env ファイルのパス (WSL パス可)

Examples:
  ./deploy-theme.sh --environment staging --dry-run
  ./deploy-theme.sh --environment staging
  ./deploy-theme.sh --environment production
  ./deploy-theme.sh --environment production --rollback
  ./deploy-theme.sh --environment staging --list-backups
EOF
            exit 0
            ;;
        *)
            echo "ERROR: 不明な引数: $1" >&2
            echo "使い方: deploy-theme.sh --help" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$ENVIRONMENT" ]]; then
    echo "ERROR: --environment が必要です (例: --environment staging)" >&2
    exit 1
fi

echo "PowerShell: $PS_CMD"
echo "Script   : $PS1_WIN"
echo "Env      : $ENVIRONMENT"
echo "Args     : ${PS_ARGS[*]:-}"
echo ""

# PowerShell 実行
"$PS_CMD" -NonInteractive -ExecutionPolicy Bypass -File "$PS1_WIN" \
    -Environment "$ENVIRONMENT" \
    "${PS_ARGS[@]}"
