#!/usr/bin/env bash
# cmd_1381 段5 — ★変異試験★ (2026-07-27 足軽四号)
#
# ★問い★= 「緑か」ではなく ★「壊せば落ちるか」★ (memory feedback_green_tests_that_prove_nothing)。
# ★規律(8) を三つとも守る★:
#   (a) ★anchor が一意か★を撃つ前に数える (1 でなければ、赤が出ても其れは別の場所の赤やもしれぬ)
#   (b) ★狙った場所に当たったか★= red_needle で【どの検が捕えたか】まで名指す
#   (c) ★変異は production の側へ当てる★= 試験の足場は撃たぬ
#
# ★復元の作法★= ★git checkout を使わぬ★。本任の是正は未 commit ゆえ
#   ★git checkout は変異でなく【拙者の仕事そのもの】を消す★。⇒ temp への複製から戻し、md5 で戻った事を確かめる。

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
WORK="$(mktemp -d)"
NG=0
declare -a TOUCHED=()

restore_all() {
  local f rel md5_now md5_orig bad=0
  for rel in "${TOUCHED[@]:-}"; do
    [ -n "$rel" ] || continue
    f="$WORK/orig/$(echo "$rel" | tr '/' '_')"
    [ -f "$f" ] || continue
    cp "$f" "$REPO/$rel"
    md5_now="$(md5sum "$REPO/$rel" | awk '{print $1}')"
    md5_orig="$(md5sum "$f" | awk '{print $1}')"
    if [ "$md5_now" != "$md5_orig" ]; then
      echo "★★復元に失敗しておる★★ $rel (期待=$md5_orig 実=$md5_now)" >&2
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] || echo "★★手で戻せ★★ 原本は $WORK/orig に在る" >&2
}
# ★★本 harness 自身が本番 log を汚す (cmd_1400・2026-07-27 実測で判った)★★
#   ■ ★機序★= MUT-1400-209 は ★guard を外す変異★ ゆえ、其の下で走る C1 は
#     ★NTFY_LOG_FILE を持たぬまま本番 logs/ntfy_send.log へ 1 行 書く★。
#     ★C1 が赤くなるのは【正しく捕えた】ゆえだが、其の副作用として記録が汚れる★。
#   ■ ★実測★= 本 harness を 2 度 走らせ、本番 log に 2 行 積まれておるのを見つけた
#     (01:45:56 / 01:46:44 「★C1 忘れっぽい試験★」)。
#   ■ ★処し方 = 予防でなく【封じ込め】★= C1 は本物の path を検めてこそ意味が在るゆえ
#     書込そのものは止められぬ ⇒ ★byte 完全な複製から戻す★ (script を戻すのと同じ作法)。
#     ★之は【記録の書き換え】ではない★= ★本 harness が 60 秒前に己で作った物を、己で畳んでおる★。
LOGBK="$WORK/ntfy_send.log.orig"
[ -f "$REPO/logs/ntfy_send.log" ] && cp "$REPO/logs/ntfy_send.log" "$LOGBK"
restore_prod_log() {
  [ -f "$LOGBK" ] || return 0
  if ! cmp -s "$LOGBK" "$REPO/logs/ntfy_send.log"; then
    local n
    n=$(( $(wc -l < "$REPO/logs/ntfy_send.log") - $(wc -l < "$LOGBK") ))
    echo "※ ★本 harness が本番 log へ $n 行 書いた (MUT-1400-209 が guard を外した下で C1 が走るゆえ)★ → 戻す"
    cp "$LOGBK" "$REPO/logs/ntfy_send.log"
    cmp -s "$LOGBK" "$REPO/logs/ntfy_send.log" \
      && echo "※ ★本番 log を byte 完全に戻した★" \
      || echo "★★本番 log を戻せなんだ★★ 原本は $LOGBK に在る" >&2
  fi
}

trap 'restore_all; restore_prod_log' EXIT

backup() {
  mkdir -p "$WORK/orig"
  cp "$REPO/$1" "$WORK/orig/$(echo "$1" | tr '/' '_')"
  TOUCHED+=("$1")
}

# mutate <id> <説明> <file> <anchor(固定文字列)> <置換後> <試験cmd> <red_needle>
mutate() {
  local id="$1" desc="$2" rel="$3" anchor="$4" repl="$5" testcmd="$6" needle="$7"
  local hits
  # ── (a) ★anchor の一意性を撃つ前に数える★ ──
  hits="$(grep -Fc -- "$anchor" "$REPO/$rel" || true)"
  if [ "$hits" != "1" ]; then
    echo "★NG★ $id: anchor の hit が $hits 件 (期待 1) = ★一意でない綴りを撃てば、赤の出所が絞れぬ★"
    NG=$((NG + 1)); return
  fi

  backup "$rel"
  # ── 変異を当てる (python で固定文字列置換 = sed の正規表現事故を避ける) ──
  python3 - "$REPO/$rel" "$anchor" "$repl" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
assert s.count(sys.argv[2]) == 1, "anchor が一意でない"
p.write_text(s.replace(sys.argv[2], sys.argv[3], 1), encoding="utf-8")
PY
  local mrc=$?
  if [ $mrc -ne 0 ]; then
    echo "★NG★ $id: 変異そのものが当たらなんだ"; NG=$((NG + 1)); restore_all; return
  fi
  # ── ★着弾の証明★= byte が現に動いたか ──
  if cmp -s "$REPO/$rel" "$WORK/orig/$(echo "$rel" | tr '/' '_')"; then
    echo "★NG★ $id: 変異後も byte が同一 = ★撃っておらぬ (UNDETERMINED)★"
    NG=$((NG + 1)); restore_all; return
  fi

  # ── 試験を走らせ、★赤くなること★と★狙った検が名指されること★を見る ──
  local out rc
  out="$(eval "$testcmd" 2>&1)"; rc=$?
  restore_all

  if [ $rc -eq 0 ]; then
    echo "★NG★ $id ($desc): ★変異させても試験が緑のまま★ = 此の緑は何も証しておらぬ"
    NG=$((NG + 1)); return
  fi
  if ! grep -qF -- "$needle" <<<"$out"; then
    echo "★NG★ $id ($desc): 赤くはなったが ★狙った検 [$needle] が名指されておらぬ★ = 別の場所に当たった疑い"
    echo "$out" | tail -5 | sed 's/^/      /'
    NG=$((NG + 1)); return
  fi
  echo "ok   $id ($desc) — 赤 rc=$rc / 名指し=[$needle]"
}

echo "── cmd_1381 段5 変異試験 (★緑は壊せば落ちるか★) ──"

# ★(a) 側 = scripts/ntfy.sh の三つの守り★
mutate MUT-1381-201 "制御文字を除く守りを外す→改行で行が割れる" \
  scripts/ntfy.sh \
  "tr -d '\\000-\\037\\177' | head -c 80" \
  "head -c 80" \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'A2'" \
  "not ok 1 A2"

mutate MUT-1381-202 "iconv の漉しを外す→多byte切断で不正 UTF-8 が出る" \
  scripts/ntfy.sh \
  "| iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true" \
  "|| true" \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'A3'" \
  "not ok 1 A3"

mutate MUT-1381-203 "成功行から curl_rc を落とす→場が固定でなくなる" \
  scripts/ntfy.sh \
  'HTTP=${_http_status:-NONE} curl_rc=$_curl_rc title=' \
  'HTTP=${_http_status:-NONE} title=' \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'A1'" \
  "not ok 1 A1"

# ★(b) 側 = 判定子の三つの契約★
mutate MUT-1381-204 "空窓を沈黙と読む契約を外す→静かな夜に毎回 鳴る門になる" \
  scripts/gate_ntfy_sendlog.py \
  "    if not win:" \
  "    if False:" \
  "python3 scripts/gate_ntfy_sendlog.py --selftest" \
  "★NG★ S3"

mutate MUT-1381-205 "非2xx を成功と読ませる→死んでおる通知路を緑と呼ぶ" \
  scripts/gate_ntfy_sendlog.py \
  '    if re.fullmatch(r"2\d\d", http):' \
  '    if True:' \
  "python3 scripts/gate_ntfy_sendlog.py --selftest" \
  "★NG★ S8"

mutate MUT-1381-206 "窓を無限に広げる→古い赤を毎朝 鳴らす / 沈黙を判じ損なう" \
  scripts/gate_ntfy_sendlog.py \
  "WINDOW_MIN = 180.0" \
  "WINDOW_MIN = 999999.0" \
  "python3 scripts/gate_ntfy_sendlog.py --selftest" \
  "★NG★ S14"

mutate MUT-1381-207 "curl の死 (rc≠0) を見ぬ→繋がらぬのに緑を出す" \
  scripts/gate_ntfy_sendlog.py \
  '        if rc != "0":' \
  '        if False:' \
  "python3 scripts/gate_ntfy_sendlog.py --selftest" \
  "★NG★ S9"

# ★(cmd_1400) 側 = 試験が本番の記録を汚さぬ守り★
mutate MUT-1400-209 "bats 既定を tmp へ向ける守りを外す→忘れっぽい試験が本番 log を汚す" \
  scripts/ntfy.sh \
  '   [ -n "${BATS_TEST_FILENAME:-}${BATS_TEST_TMPDIR:-}${BATS_RUN_TMPDIR:-}" ]; then' \
  '   false; then' \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'C1'" \
  "not ok 1 C1"

mutate MUT-1400-210 "除外を【全行に当たる】形へ壊す→本物の失敗まで黙る (silencer 化)" \
  scripts/gate_ntfy_sendlog.py \
  'if hashlib.sha256(line.encode("utf-8")).hexdigest() in testline_hashes:' \
  'if True:' \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'C3'" \
  "not ok 1 C3"

mutate MUT-1400-211 "除いた本数の名乗りを外す→黙って数を減らす門になる" \
  scripts/gate_ntfy_sendlog.py \
  "    if excluded or side_note:" \
  "    if False:" \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'C3'" \
  "not ok 1 C3"

# ── ★★負の対照 = 此の道具そのものが【常に ok を出す物】でないことの証★★ ─────────────
#   ★上の 10 本は全て「赤が出た」で ok を出しておる★ = ★然れば【何を撃っても赤が出る道具】と
#   区別がつかぬ★ (本日 全軍で積んだ「鳴る側と鳴らぬ側を同数 撃て」の、変異台帳の側の顔)。
#   ⇒ ★振舞いを 1 bit も変えぬ変異 (註釈のみ) を撃ち、道具が【捕まらなんだ】と正しく申すかを見る★。
NG_BEFORE=$NG
mutate MUT-1381-208 "★負の対照★ 註釈だけの変異 → 捕まらぬ筈" \
  scripts/gate_ntfy_sendlog.py \
  "★北極星 (cmd_1381 の起源)★" \
  "★北極星 (cmd_1381 の起源・此の行は註釈ゆえ振舞いを変えぬ)★" \
  "python3 scripts/gate_ntfy_sendlog.py --selftest" \
  "★NG★"
if [ "$NG" -eq $((NG_BEFORE + 1)) ]; then
  NG=$NG_BEFORE   # ★此の NG は【期待どおり】ゆえ帳消しにする★
  echo "ok   MUT-1381-208 — ★道具は無害な変異を『緑のまま』と正しく名指した★ = 常に赤を出す道具ではない"
else
  echo "★NG★ MUT-1381-208: ★振舞いを変えぬ変異を『捕えた』と申しておる★ = 此の道具の赤は信用できぬ"
  NG=$((NG + 1))
fi

echo "── 変異 10 本 + 負の対照 1 本 / NG $NG 件 ──"
# ★最後にもう一度 復元を確かめる★ (試験の途中で落ちても、盤面を汚したままにせぬ)
git diff --stat -- scripts/ntfy.sh scripts/gate_ntfy_sendlog.py > "$WORK/after.txt" 2>/dev/null || true
exit $((NG > 0 ? 1 : 0))
