#!/usr/bin/env bash
# gate_precommit.sh — pre-commit から呼ばれる本体 (cmd_1352)
#
# ★正本はこの file である★ — .git/hooks/pre-commit には薄い shim しか置かぬ
# (設定の出所を1つに保つ。hook 側を太らせると repo 管理外のコードが増え、
#  cmd_1350 の「harness 順 ≠ 実機順」と同型の二重管理が生える)。
#
# 方針:
#   gate-1 (--all)    … 登録済み manifest 全件の git 捕捉検分 (数百ms・毎commitで回す)
#   gate-2 (--sanity) … 変異台帳の形だけ検分 (実行なし・数百ms)。
#                     ★フル再走を撃つ者は今 居ない★ — 毎朝の gate_nightly.sh は cmd_1479 で撤去した
#                     (cron 停止 = cmd_1476 / file 削除 = 88aa167)。手で撃つ口だけが残っている:
#                       python3 scripts/gate_mutation_replay.py   (引数なし = フル再走。--replay は無い)
#   FAIL(1)         → ★commit を止める★
#   UNDETERMINED(2) → ★大声で警告するが通す★ (緑ではない。全agent が commit する repo ゆえ
#                     一過性の未判定で全軍の commit を塞がぬ — cmd_1342 zip 関所の WARN-through と同じ流儀。
#                     ★取り零しを後から拾う者も今 居ない★ = 此処で読み流せば誰も気付かぬ)
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
# gate-4 (cmd_1409): ★「登録した」と「登録されておる」を分ける★。
#   ★五号 08:15 実測★= 台帳の末尾へ entry を継ぐと mutations: の下に入らず、最後の key の
#   値として ★黙って呑まれる★ (parse は通り・道具も何も申さず・総数も動かぬ)。
#   ⇒ ★呑まれは【翌朝の replay にも見えぬ】★= 台帳に載っておらぬ牙は撃たれもせぬゆえ、
#     ★書いた其の瞬間 (commit) に名指す以外に捕える口が無い★ (gate-3 の時差論とは別の理由)。
#   ★既定は 1 を返さぬ (UNDETERMINED=2 で警告するのみ)★ / REGISTRY_APPEND_STRICT=1 で commit を止める。
#   ★所要 = 触った台帳のみ・実測 0.2 秒級 (6 冊 全数でも 0.20s)★。
out4="$(python3 "$SCRIPT_DIR/scripts/gate_registry_append.py" 2>&1)"; rc4=$?
# gate-5 (cmd_1435): ★正本 (CLAUDE.md ほか) と、そこから作る生成物のずれを見る★。
#   ★2026-07-27 実害★= CLAUDE.md が 10:40 と 17:36 の2度 変わり、写しは1度も追いつかなんだ。
#   作業ツリーに残っておった写しは 02:17 版で、★10:40 に「言い過ぎ」として訂正された記述★を持っており、
#   そのまま commit すれば訂正前の版だけが Codex / Copilot / 既定エージェントへ配られる所であった。
#   ★気づけたのは、たまたま未 commit として git に見えておったからである★=
#   02:17 に commit されておれば、写しは古いまま緑になり、誰も気付かなんだ。
#   ★探し方★= 一時の場所へ index の中身だけで作り直し、index の生成物と1バイト単位で比べる
#   (mtime やコミット時刻は見ぬ。★時刻は「誰が書いたか」を答えぬ★)。
#   ★1 を返す = commit を止める★ (生成物は1行で作り直せるゆえ書き手を止める費えが小さい)。
#   ★所要★= 正本にも生成物にも触れぬ commit では 0.05 秒で黙る。触れた時のみ 4 秒級 (実測)。
out5="$(bash "$SCRIPT_DIR/scripts/gate_generated_sync.sh" 2>&1)"; rc5=$?

for pair in "gate-1:$rc1" "gate-2:$rc2" "gate-3:$rc3" "gate-4:$rc4" "gate-5:$rc5"; do
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
    [ "$rc4" -ne 0 ] && printf '%s\n' "$out4"
    [ "$rc5" -ne 0 ] && printf '%s\n' "$out5"
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
    [ "$rc4" -ne 0 ] && printf '%s\n' "$out4"
    [ "$rc5" -ne 0 ] && printf '%s\n' "$out5"
    echo "  ★この警告を後から拾う者は居ない★ = 毎朝の門 (gate_nightly.sh) は cmd_1479 で撤去した。"
    echo "  ⇒ 今 読み流せば誰も気付かぬ。今直せるなら今直せ。直せぬなら commit message へ理由を残せ。"
    echo "  ★gate-4 (台帳の呑まれ) は、手でフル再走を撃っても見えぬ★ = 台帳に載らぬ牙は撃たれもせぬゆえ。"
    echo "════════════════════════════════════════════════════════════════"
    exit 0
fi
echo "[gate] PASS: gate-1 (manifest捕捉) + gate-2 (台帳sanity) + gate-3 (牙の着弾) + gate-4 (台帳の呑まれ) + gate-5 (正本と生成物のずれ) 緑"
exit 0
