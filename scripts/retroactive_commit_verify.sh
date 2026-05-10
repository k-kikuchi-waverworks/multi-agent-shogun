#!/usr/bin/env bash
# scripts/retroactive_commit_verify.sh (cmd_639 起源)
#
# 過去 cmd 累積分の commit hash を 3 repo (aituber-project canonical / ml /
# multi-agent-shogun + 必要 repo: ai-automate-engine / backend submodule) で
# git cat-file -t commit 検証し、3 分類 (truth / misdetection_revealed /
# fabrication_candidate) を markdown report で出力する。
#
# 設計根拠: plans/cmd_639_ash_report_verification.md §2.3
# 規律根拠: instructions/gunshi.md "Commit Hash Verification Protocol"
#
# Usage:
#   bash scripts/retroactive_commit_verify.sh \
#     > logs/audits/cmd_639_retroactive_verify_$(date +%Y%m%d).md
#
# Notes:
#   - fetch 失敗 (auth / network / origin 未設定) は continue、verdict に
#     明示 (memory feedback_no_misleading_information 整合)
#   - 抽出 source: queue/reports/ + queue/shogun_to_karo.yaml + dashboard.md
#   - 抽出 regex: \b[0-9a-f]{7,40}\b (commit hash 想定)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# === 検証対象 repo 一覧 (name:path 形式) ===
REPOS=(
  "aituber_canonical:/home/k-kikuchi/aituber-project"
  "aituber_archive:/mnt/c/Users/k-kikuchi/development/aituber-project"
  "ml:/mnt/f/aituber-project-ml"
  "shogun:/mnt/c/tools/multi-agent-shogun"
  "backend:/home/k-kikuchi/aituber-project/backend"
  "ai_automate_engine:/mnt/c/Users/k-kikuchi/development/ai-automate-engine"
)

now_iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
echo "# cmd_639 retroactive commit verify audit"
echo ""
echo "- generated_at: \`${now_iso}\`"
echo "- script: \`scripts/retroactive_commit_verify.sh\`"
echo "- protocol: \`instructions/gunshi.md § Commit Hash Verification Protocol\`"
echo ""

# === Step 1: 3 repo 全 git fetch ===
echo "## Step 1: git fetch 結果"
echo ""
echo "| repo | path | fetch status |"
echo "|------|------|--------------|"
declare -A REPO_PATH
declare -A FETCH_STATUS
for entry in "${REPOS[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"
  REPO_PATH["$name"]="$path"
  if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
    if git -C "$path" fetch origin --quiet 2>/dev/null; then
      FETCH_STATUS["$name"]="ok"
      echo "| ${name} | \`${path}\` | ✅ ok |"
    else
      FETCH_STATUS["$name"]="fail"
      echo "| ${name} | \`${path}\` | ⚠️ fetch fail (auth/network/origin 未設定の可能性、verdict に明示) |"
    fi
  else
    FETCH_STATUS["$name"]="absent"
    echo "| ${name} | \`${path}\` | ❌ .git 不在 |"
  fi
done
echo ""

# === Step 2: commit hash 抽出 ===
echo "## Step 2: commit hash 抽出"
echo ""
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

# 抽出 source
SOURCES=(
  "${REPO_ROOT}/queue/reports"
  "${REPO_ROOT}/queue/shogun_to_karo.yaml"
  "${REPO_ROOT}/dashboard.md"
)
for src in "${SOURCES[@]}"; do
  [ -e "$src" ] || continue
  grep -rohE '\b[0-9a-f]{7,40}\b' "$src" 2>/dev/null \
    | grep -E '^[0-9a-f]{7,40}$' \
    | awk 'length($0) >= 7 && length($0) <= 40' \
    >> "$TMPFILE" || true
done

# dedupe
HASHES_LIST="$(sort -u "$TMPFILE")"
HASH_COUNT="$(printf '%s\n' "$HASHES_LIST" | grep -c . || true)"
echo "- 抽出 source: \`queue/reports/\` + \`queue/shogun_to_karo.yaml\` + \`dashboard.md\`"
echo "- 抽出 regex: \`\\\\b[0-9a-f]{7,40}\\\\b\`"
echo "- unique hash 数: ${HASH_COUNT}"
echo ""

# === Step 3: 各 hash を 3 repo で git cat-file -t 確認 ===
echo "## Step 3: 3 分類 verify 結果"
echo ""
echo "| classification | hash | found_in_repos |"
echo "|----------------|------|----------------|"

truth_count=0
fab_count=0
misdetection_count=0

# 軍師 fabrication 判定済 hash list (gunshi_report.yaml から抽出)
FAB_HASHES=""
if [ -f "${REPO_ROOT}/queue/reports/gunshi_report.yaml" ]; then
  FAB_HASHES="$(grep -B1 -A3 -i 'fabrication' "${REPO_ROOT}/queue/reports/gunshi_report.yaml" 2>/dev/null \
    | grep -oE '\b[0-9a-f]{7,40}\b' | sort -u || true)"
fi

while IFS= read -r hash; do
  [ -n "$hash" ] || continue
  found=""
  for entry in "${REPOS[@]}"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
      type_out="$(git -C "$path" cat-file -t "$hash" 2>/dev/null || true)"
      if [ "$type_out" = "commit" ]; then
        found+="${name} "
      fi
    fi
  done

  is_fab_judged=0
  if [ -n "$FAB_HASHES" ] && printf '%s\n' "$FAB_HASHES" | grep -qx "$hash"; then
    is_fab_judged=1
  fi

  if [ -n "$found" ]; then
    if [ "$is_fab_judged" = "1" ]; then
      echo "| 🔍 misdetection_revealed | \`${hash}\` | ${found% } |"
      misdetection_count=$((misdetection_count + 1))
    else
      echo "| ✅ truth | \`${hash}\` | ${found% } |"
      truth_count=$((truth_count + 1))
    fi
  else
    echo "| ❌ fabrication_candidate | \`${hash}\` | (3 repo 全 fetch 後も不在) |"
    fab_count=$((fab_count + 1))
  fi
done <<< "$HASHES_LIST"

echo ""
echo "## Step 4: 集計"
echo ""
echo "| 分類 | 件数 |"
echo "|------|------|"
echo "| ✅ truth | ${truth_count} |"
echo "| 🔍 misdetection_revealed | ${misdetection_count} |"
echo "| ❌ fabrication_candidate | ${fab_count} |"
echo "| 合計 | ${HASH_COUNT} |"
echo ""
echo "- 07de510 該当: \`grep '07de510' <this_log>\` で確認 (truth または misdetection_revealed が期待値)"
echo "- fabrication_candidate hit 時は ash 担当者へ家老経由 confirmation 依頼 (memory feedback_no_misleading_information)"
