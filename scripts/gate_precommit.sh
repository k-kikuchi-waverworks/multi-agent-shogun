#!/usr/bin/env bash
# gate_precommit.sh — pre-commit から呼ばれる本体 (cmd_1352)
#
# ★正本はこの file である★ — .git/hooks/pre-commit には薄い shim しか置かぬ
# (設定の出所を1つに保つ。hook 側を太らせると repo 管理外のコードが増え、
#  cmd_1350 の「harness 順 ≠ 実機順」と同型の二重管理が生える)。
#
# 方針:
#   gate-1 (--all)    … 登録済み manifest 全件の git 捕捉検分 (数百ms・毎commitで回す)
#   gate-2 (--sanity) … 変異台帳の形だけ検分 (実行なし・数百ms)。フル再走は cron 側 (gate_nightly.sh)
#   FAIL(1)         → ★commit を止める★
#   UNDETERMINED(2) → ★大声で警告するが通す★ (緑ではない。全agent が commit する repo ゆえ
#                     一過性の未判定で全軍の commit を塞がぬ — cmd_1342 zip 関所の WARN-through と同じ流儀。
#                     取り零しは gate_nightly.sh が家老へ警告する)
#
# 逃がし口 (隠すな・使ったら理由を commit message へ):
#   SHOGUN_GATE_SKIP=1 git commit ...
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

if [ "${SHOGUN_GATE_SKIP:-0}" = "1" ]; then
    echo "[gate] SKIP (SHOGUN_GATE_SKIP=1) — 理由を commit message に残せ" >&2
    exit 0
fi

worst=0
out1="$(bash "$SCRIPT_DIR/scripts/gate_artifact_capture.sh" --all 2>&1)"; rc1=$?
out2="$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --sanity 2>&1)"; rc2=$?
# gate-3 (cmd_1387): ★触った file に anchor を持つ牙の【着弾数】だけを実測する★。
#   ★anchor の一意性は牙の性質でなく【今の盤面の性質】ゆえ、他人の commit が他人の牙を鈍らせうる★
#   (実例 = 7d35e40 が MUT-1355-001 を非一意化した。書いた者は知る術を持たなんだ)。
#   ★1 を返さぬ設計ゆえ commit を止めることは無い★ (UNDETERMINED=2 で警告するのみ)。
#   ★所要 = 触った file を持つ牙のみ・物差しB のみゆえ 0.2s 級 (実測)★。
out3="$(python3 "$SCRIPT_DIR/scripts/gate_anchor_touched.py" 2>&1)"; rc3=$?

for pair in "gate-1:$rc1" "gate-2:$rc2" "gate-3:$rc3"; do
    rc="${pair#*:}"
    if [ "$rc" -eq 1 ]; then worst=1
    elif [ "$rc" -eq 2 ] && [ "$worst" -ne 1 ]; then worst=2; fi
done

if [ "$worst" -eq 1 ]; then
    echo "════════════════════════════════════════════════════════════════"
    echo "[gate] ★FAIL — commit を止めた★ (沈黙する落とし穴 gate / cmd_1352)"
    [ "$rc1" -ne 0 ] && printf '%s\n' "$out1"
    [ "$rc2" -ne 0 ] && printf '%s\n' "$out2"
    [ "$rc3" -ne 0 ] && printf '%s\n' "$out3"
    echo "  詳細と処方: docs/content/ops/cmd_1352_silent_pitfall_gates.md"
    echo "  緊急回避 (理由必須): SHOGUN_GATE_SKIP=1 git commit ..."
    echo "════════════════════════════════════════════════════════════════"
    exit 1
fi
if [ "$worst" -eq 2 ]; then
    echo "════════════════════════════════════════════════════════════════"
    echo "[gate] ⚠ UNDETERMINED — ★緑ではない★ (通すが、放置するな)"
    [ "$rc1" -ne 0 ] && printf '%s\n' "$out1"
    [ "$rc2" -ne 0 ] && printf '%s\n' "$out2"
    [ "$rc3" -ne 0 ] && printf '%s\n' "$out3"
    echo "  gate_nightly.sh (cron) が家老へ警告する。今直せるなら今直せ。"
    echo "════════════════════════════════════════════════════════════════"
    exit 0
fi
echo "[gate] PASS: gate-1 (manifest捕捉) + gate-2 (台帳sanity) + gate-3 (牙の着弾) 緑"
exit 0
