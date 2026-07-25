#!/usr/bin/env bash
# gate_nightly.sh — 両 gate のフル再走 backstop (cmd_1352)
#
# cron (毎朝 06:30) から回る。pre-commit hook の取り零しを埋める:
#   ・hook は .git/hooks 住まいゆえ環境再構築で消えうる (cmd_1342 で六号が指摘した弱点)
#   ・gate-2 のフル再走 (変異全件) は commit 毎には重いゆえ日次でここが受け持つ
#   ・commit が無い日でも drift (後から足された ignore 規則・仕様変更による変異の無効化) を検分する
# 非 PASS は家老 inbox へ警告 (是正手順つき)。人が思い出して回す形にはせぬ。
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
STAMP="$(date '+%Y-%m-%dT%H:%M:%S')"

echo "── [gate_nightly] $STAMP 開始 ──"
out1="$(bash "$SCRIPT_DIR/scripts/gate_artifact_capture.sh" --all 2>&1)"; rc1=$?
out2="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" 2>&1)"; rc2=$?
printf '%s\n%s\n' "$out1" "$out2"

verdict() { case "$1" in 0) echo PASS;; 1) echo FAIL;; *) echo UNDETERMINED;; esac; }

if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
    # 警告は1行に畳む (inbox message の YAML 安全のため改行・コロン+空白を避ける)
    detail="$(printf '%s\n%s\n' "$out1" "$out2" | grep -E '\[(IGNORED|UNTRACKED|MISSING|COUNT|EMPTY-DIR)\]|★NG★|UNDETERMINED' | head -8 | tr '\n' '・' | sed 's/: /：/g')"
    msg="【gate_nightly警告】沈黙落とし穴gate非PASS=gate-1(commit捕捉)=$(verdict "$rc1")/gate-2(変異台帳)=$(verdict "$rc2")。所見=${detail} 処方=docs/content/ops/cmd_1352_silent_pitfall_gates.md を見て名指しされた項目を是正し、bash scripts/gate_artifact_capture.sh --all と python3 scripts/gate_mutation_replay.py の再走で緑を確認せよ。"
    bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$msg" error gate_nightly \
        || echo "[gate_nightly] WARN: 家老への inbox_write が失敗 (次回 cron で再警告)" >&2
fi

echo "── [gate_nightly] 終了 gate-1=$(verdict "$rc1") gate-2=$(verdict "$rc2") ──"
if [ "$rc1" -eq 1 ] || [ "$rc2" -eq 1 ]; then exit 1; fi
if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then exit 2; fi
exit 0
