#!/usr/bin/env bash
# mutation_cmd1392_clock_family.sh — cmd_1392 是正 (二族の刻) の★牙が現に噛むか★を撃つ。
#
# ★本 script が答える問い★= ★「緑か」ではない = ★★「壊せば落ちるか」★★である。
#   (memory feedback_green_tests_that_prove_nothing = 本夜 三件 独立に露見した族)
#
# ★枷★= ★番人 (scripts/idle_revive_scan.py) は cron で毎 3 分 現に走っておる★
#   ⇒ ★変異は【複写】へ当て、SCAN_PY_OVERRIDE で其の複写を撃つ★。本体へ 1 byte も書かぬ。
#
# ★両向きを撃つ (家老 09:58 の任(3))★:
#   ・是正を戻す向き (族の混線・pid を秒と読む・NameError 地雷・母数を落とす)
#   ・★守りを減らす向き★ (抑止を広げて真の固着を見逃す / 抑止を殺す)
#   ・★負の対照★ (何も変えぬ複写 = 全数緑) ← ★之が無ければ harness の生死が判らぬ★
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
SUITE="tests/unit/test_idle_revive_proc_age.bats"
SRC="scripts/idle_revive_scan.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mut1392.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# $1=名 $2=期待(赤くなるべき牙の名 / "NONE"=全数緑) $3=python の変異式
mutate() {
    local name="$1" expect="$2" pycode="$3"
    local copy="$WORK/${name}.py"
    cp "$SRC" "$copy"
    # ★複写は repo の外に在るゆえ REPO_ROOT が /tmp を指す★ ⇒ ★bash helper が
    #   registry を見失い、齢が常に None になる★= ★変異と無関係に赤が出る (偽の赤)★。
    #   ⇒ ★根を実 repo へ焼き直す★ (2026-07-27 10:1x に拙者が此の傷で 0/10 を誤報した)。
    python3 - "$copy" "$REPO" <<PY || { echo "  ★変異を当てられなんだ: $name★"; fail=$((fail+1)); return; }
import re, sys
p, repo = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
before = s
# ★引用符の入り組む錨は名前で持つ★ (shell を二重に通すゆえ = cmd_1371 の教訓の変異版)
_J = chr(73) + "MPOSSIBLE_JUDGE_STATS[" + chr(34) + "judged" + chr(34) + "]"
_JZ = "if _st[" + chr(34) + "judged" + chr(34) + "] == 0:"
$pycode
if s == before:
    raise SystemExit("★錨が当たっておらぬ (hit=0) = 変異が入っておらぬ★")
s = s.replace('REPO_ROOT = Path(__file__).resolve().parents[1]',
              'REPO_ROOT = Path(%r)' % repo, 1)
open(p, "w", encoding="utf-8").write(s)
PY
    find "$WORK" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    local out red
    out="$(SCAN_PY_OVERRIDE="$copy" timeout 900 bats "$SUITE" 2>&1)"
    red="$(echo "$out" | grep '^not ok ' | sed 's/^not ok [0-9]* //;s/:.*//' | tr '\n' ',' )"
    if [ "$expect" = "NONE" ]; then
        if [ -z "$red" ]; then echo "✅ $name — 期待どおり全数緑 (負の対照)"; pass=$((pass+1))
        else echo "❌ $name — 変えておらぬのに赤が出た: $red"; fail=$((fail+1)); fi
    else
        if echo ",$red" | grep -q ",$expect"; then
            echo "✅ $name — ★$expect が現に赤★ (赤の全数: ${red%,})"; pass=$((pass+1))
        else
            echo "❌ $name — ★$expect が緑のまま生き残った★ (赤の全数: ${red:-なし})"; fail=$((fail+1))
        fi
    fi
}

echo "===== cmd_1392 二族の刻 — 変異試験 (母数を先に印字する) ====="
echo "牙の総数 = $(grep -c '^@test' "$SUITE") 本 / 変異 = 8 本 (うち負の対照 1)"
echo

echo "── (甲) 是正を戻す向き = 【族の混線】が帰ってくる形 ──"
mutate revert_to_ps_clock T-AGE-016 \
  's = s.replace("pgrep -P \"$ppid\" 2>/dev/null || true", "for c in $(pgrep -P \"$ppid\"); do ps -o etimes= -p \"$c\"; done", 1)'

mutate read_pid_as_seconds T-AGE-002 \
  's = s.replace("starts = [m for m in (_proc_start_mtime(tok) for tok in stdout_text.split())\n              if m is not None]", "starts = []\n    _ages = [int(t) for t in stdout_text.split() if t.isdigit()]\n    if _ages:\n        return max(_ages)", 1)'

mutate nameerror_landmine T-AGE-017 \
  's = s.replace("now_ts = datetime.datetime.now().timestamp()", "now_ts = time.time()", 1)'

echo
echo "── (乙) 母数を落とす向き = 【0 が再び読めなくなる】形 ──"
# ★母数を数え損なう★= 印字の形は残るが JUDGED が永久に 0 =
#   ★「判定へ入った者が居らぬ」と毎回 名乗る = 0 が再び読めなくなる★。
mutate drop_denominator T-AGE-019 \
  's = s.replace(_J + " += 1", "pass", 1)'

# ★三義の分岐を潰す★= 何が起きても「現に問うて、成らなんだ」と名乗る =
#   ★門が盲であっても「検めた」と読ませる★= 本夜の族そのもの。
mutate collapse_zero_readings T-AGE-019 \
  's = s.replace(_JZ, "if False:", 1)'

echo
echo "── (丙) ★守りを減らす向き★ = 真の固着を見逃す / 抑止を殺す ──"
mutate widen_suppression T-AGE-018 \
  's = s.replace("if age_sec is not None and age_sec < claimed_silence_sec:", "if age_sec is not None and age_sec < claimed_silence_sec * 2:", 1)'

mutate kill_suppression T-AGE-001 \
  's = s.replace("if age_sec is not None and age_sec < claimed_silence_sec:", "if False and age_sec is not None and age_sec < claimed_silence_sec:", 1)'

echo
echo "── (丁) ★負の対照★ = 何も変えぬ (harness が生きておる証) ──"
mutate no_op NONE \
  's = s.replace("# ─────────────────────────────────────────────────────────────", "# ── (負の対照: 意味を変えぬ書き換え) ──", 1)'

echo
echo "===== 変異 $((pass+fail)) 本中 ★期待どおり $pass 本★ / 外れ $fail 本 ====="
[ "$fail" -eq 0 ]
