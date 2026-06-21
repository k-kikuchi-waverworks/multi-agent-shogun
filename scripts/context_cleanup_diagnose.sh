#!/usr/bin/env bash
# context_cleanup_diagnose.sh — shogun-context-cleanup skill 段階①(診断)用
#
# 完全に非破壊。肥大層を計測し優先度付き一覧を出力するのみ。
# いかなるファイルも削除・移動・編集しない。
#
# 由来: cmd_948 で手動実施した掃除診断を再現可能化 (cmd_949)。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# memory dir (プロジェクト固有の Claude Code memory)
MEM_DIR="${SHOGUN_MEMORY_DIR:-$HOME/.claude/projects/-mnt-c-tools-multi-agent-shogun/memory}"

hr() { printf '%.0s─' {1..60}; echo; }

echo "🧹 shogun-context-cleanup 診断 (非破壊)"
echo "repo: $REPO"
hr

# ── ① dashboard ──────────────────────────────────────────
echo "■ dashboard.md"
if [[ -f dashboard.md ]]; then
  kb=$(( $(wc -c < dashboard.md) / 1024 ))
  lines=$(wc -l < dashboard.md)
  flag=""; (( kb >= 100 )) && flag="  ⚠️ >100KB (archive推奨)"
  echo "  size: ${kb}KB / ${lines}行${flag}"
else
  echo "  (なし)"
fi
hr

# ── ② inbox ──────────────────────────────────────────────
echo "■ queue/inbox/*.yaml (read内訳)"
for f in queue/inbox/*.yaml; do
  [[ -e "$f" ]] || continue
  name=$(basename "$f" .yaml)
  total=$(wc -l < "$f")
  unread=$(grep -c "read: false" "$f" 2>/dev/null) || unread=0
  rd=$(grep -c "read: true" "$f" 2>/dev/null) || rd=0
  flag=""; (( rd >= 30 )) && flag="  ⚠️ read済多 (保守的剪定候補)"
  printf "  %-28s %4d行 (未読:%-3s 既読:%-3s)%s\n" "$name" "$total" "$unread" "$rd" "$flag"
done
hr

# ── ③ plans ──────────────────────────────────────────────
echo "■ plans/"
if [[ -d plans ]]; then
  cnt=$(find plans -maxdepth 1 -name '*.md' | wc -l)
  vol=$(du -sh plans 2>/dev/null | cut -f1)
  arc="なし"; [[ -d plans/archive ]] && arc="$(find plans/archive -name '*.md' | wc -l)件"
  flag=""; (( cnt >= 30 )) && flag="  ⚠️ 完遂cmd plan を plans/archive/ へ退避検討"
  echo "  直下: ${cnt}件 / 容量: ${vol} / archive: ${arc}${flag}"
fi
hr

# ── ④ reports / tasks ────────────────────────────────────
echo "■ queue/reports & queue/tasks (status内訳)"
for d in reports tasks; do
  base="queue/$d"
  [[ -d "$base" ]] || continue
  cnt=$(find "$base" -maxdepth 1 -name '*.yaml' | wc -l)
  done_c=$(grep -lE "status: *(completed|done)" "$base"/*.yaml 2>/dev/null | wc -l || true)
  asg_c=$(grep -lE "status: *assigned" "$base"/*.yaml 2>/dev/null | wc -l || true)
  blk_c=$(grep -lE "status: *blocked" "$base"/*.yaml 2>/dev/null | wc -l || true)
  printf "  %-8s 計%2d件 (完遂:%s assigned:%s blocked:%s)\n" "$d" "$cnt" "$done_c" "$asg_c" "$blk_c"
done
hr

# ── ⑤ memory ─────────────────────────────────────────────
echo "■ memory (剪定は殿承認ゲート絶対 — ここは計測のみ)"
if [[ -d "$MEM_DIR" ]]; then
  mcnt=$(find "$MEM_DIR" -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' | wc -l)
  idx=0; [[ -f "$MEM_DIR/MEMORY.md" ]] && idx=$(wc -l < "$MEM_DIR/MEMORY.md")
  echo "  memoryファイル: ${mcnt}件 / MEMORY.md index: ${idx}行"
  echo "  → session_*_state など古いスナップショットが剪定候補だが、削除は殿承認後のみ"
else
  echo "  memory dir 不検出: $MEM_DIR"
fi
hr

# ── ⑥ pane context token (best-effort) ──────────────────
echo "■ tmux pane context token (best-effort / >100k は /clear 棚卸し候補)"
echo "  ※ token表示は CLI 状態依存。確実値は各paneで /context を見るのが正"
if command -v tmux >/dev/null 2>&1 && tmux has-session -t multiagent 2>/dev/null; then
  while read -r idx aid; do
    tok=$(tmux capture-pane -t "multiagent:0.$idx" -p 2>/dev/null \
          | grep -oiE "[0-9]+(\.[0-9]+)?k? tokens" | tail -1 || true)
    printf "  pane 0.%-2s %-12s %s\n" "$idx" "${aid:-?}" "${tok:-(token表示なし)}"
  done < <(tmux list-panes -t multiagent -F '#{pane_index} #{@agent_id}' 2>/dev/null)
else
  echo "  (multiagent session なし — pane診断スキップ)"
fi
hr

echo "✅ 診断完了 (非破壊)。整理は段階②③④へ — 誤削除厳禁・迷えば残す・memory剪定は殿承認。"
