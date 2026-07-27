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
# ★★2026-07-27 08:5x 四号 = 己の負の対照が【他人の NG を吸い取っておった】ゆえ足す★★
#   ■ ★機序 (実測で掴んだ)★= 下の 208 の帳消しは ★「NG が 1 増えた」だけ★を見ておった。
#     ⇒ ★harness 自身の【赤の検め】(if [ $rc -eq 0 ]) を目潰しすると★、208 は
#        ★「緑のまま」ではなく【針が名指されぬ】で NG を立てる★ — 数は同じ 1 ゆえ
#        ★帳消しが其れを「期待どおり」と読み、rc=0 (緑) へ戻しておった★。
#   ■ ★之は本夜ずっと狩ってきた族そのもの★= ★数が合うだけで理由を検めぬ守り★。
#   ⇒ ★NG の【理由】を記録し、208 は【緑のまま】以外の理由を帳消しにせぬ★。
LAST_NG_KIND=""
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
#     書込そのものは止められぬ ⇒ ★己が書いた行だけを消す★ (下の cmd_1400 追補を見よ)。
#
# ★★cmd_1400 追補 (2026-07-27 13:3x 足軽四号・家老 13:27 の裁) — 戻し方を改めた★★
#   ■ ★旧の形★= ★開始時の複製から file 丸ごと書き戻す★ (cp "$LOGBK" …)。
#   ■ ★旧の名乗り★= 「之は記録の書き換えではない = 己が 60 秒前に作った物を己で畳んでおる」
#     ⇒ ★★其の名乗りが真なのは【走っておる間 誰も本番へ書かぬ】時に限る★★ =
#       ★★条件つきの真を、無条件の真として名乗っておった★★。
#     ⇒ ★走行中に家老が ntfy を撃たれれば、其の一行は復元で【黙って消える】★ =
#       ★★己の掃除が他者の記録を消す★★ = 本日ずっと狩ってきた族の、本 harness における顔。
#   ■ ★13:24 の実射で踏まなんだのは【家老が窓を約された】ゆえ★ =
#     ★★踏まなんだのは盤面のおかげであり、守りのおかげではない★★ ⇒ 盤面に頼るのをやめる。
#   ■ ★新の形 = 【前置きは触れぬ・末尾の追記のうち己の印を持つ行だけ消す】★:
#       (1) ★前置き (baseline の全行) が 1 byte でも動いておれば、何もせず名乗る★ = ★消すより残す★
#       (2) ★追記のうち【己の印】に厳密一致する行だけを落とす★
#       (3) ★★印に当たらぬ追記 (＝他者が窓の中で書いた行) は残し、其の旨と sha256 を名乗る★★
#       (4) ★消した本数と各行の sha256 を必ず出す★ = ★黙って減らさぬ (C3 と同じ作法)★
#   ■ ★sha256 の射程を正直に切る★= ★C3 は【予め知った行】の sha256 で照合できるが、
#     本件の行は【走行中に生まれ、時刻が入る】ゆえ予めの hash を持てぬ★
#     ⇒ ★★照合は「時刻以外を全て固定した厳密な形」で行い、sha256 は【消した証跡】として出す★★
#     = ★sha256 が matcher でない事を隠さぬ★ (隠せば「照合しておる」と読まれる = 本日の族)。
LOGBK="$WORK/ntfy_send.log.orig"
[ -f "$REPO/logs/ntfy_send.log" ] && cp "$REPO/logs/ntfy_send.log" "$LOGBK"
# ★己の印★= MUT-1400-209 の下で C1 が書く行 = 時刻以外は 1 byte も動かぬ
HARNESS_LINE_RE='^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+[0-9]{2}:[0-9]{2}\] HTTP=200 curl_rc=0 title=★C1 忘れっぽい試験★$'

# _restore_log_surgical <log> <backup> <印の正規>
#   ★引数で受けるのは【己に牙を立てられる形】にする為である★ (--selftest-restore が本物の path を撃たぬ)
_restore_log_surgical() {
  HL_LOG="$1" HL_BK="$2" HL_RE="$3" python3 - <<'PY'
import hashlib, os, re, sys

log = os.environ["HL_LOG"]; bk = os.environ["HL_BK"]
pat = re.compile(os.environ["HL_RE"])

def lines(p):
    with open(p, "rb") as f:
        b = f.read()
    return b.split(b"\n")[:-1] if b.endswith(b"\n") else b.split(b"\n")

base, cur = lines(bk), lines(log)

# (1) ★前置きが動いておれば何もせぬ★ = ★消すより残す (不可逆ゆえ安全側へ倒す)★
if cur[:len(base)] != base:
    print("★★本番 log の【前置き】が動いておる ⇒ 何も消さぬ★★ (原本は %s に在る)" % bk, file=sys.stderr)
    sys.exit(3)

added = cur[len(base):]
if not added:
    sys.exit(0)   # ★何も足されておらぬ = 触れる要が無い★

mine    = [l for l in added if pat.match(l.decode("utf-8", "replace"))]
foreign = [l for l in added if not pat.match(l.decode("utf-8", "replace"))]

# (4) ★消す物は必ず名乗る (黙って減らさぬ)★
for l in mine:
    print("※ ★己が書いた 1 行を消す★ sha256=%s" % hashlib.sha256(l).hexdigest()[:16])
# (3) ★他者の行は残す★= ★之が本改修の芯である★
for l in foreign:
    print("※ ★★他者が窓の中で書いた 1 行 = 残す★★ sha256=%s | %s"
          % (hashlib.sha256(l).hexdigest()[:16], l.decode("utf-8", "replace")[:60]))

out = base + foreign
with open(log, "wb") as f:
    f.write(b"".join(x + b"\n" for x in out))
print("※ ★戻した★ 己の行 %d 消し / 他者の行 %d 残し / 前置き %d 行は無傷"
      % (len(mine), len(foreign), len(base)))
PY
}

restore_prod_log() {
  [ -f "$LOGBK" ] || return 0
  cmp -s "$LOGBK" "$REPO/logs/ntfy_send.log" && return 0
  _restore_log_surgical "$REPO/logs/ntfy_send.log" "$LOGBK" "$HARNESS_LINE_RE" \
    || echo "★★本番 log を戻せなんだ (前置きが動いた等)★★ 原本は $LOGBK に在る" >&2
}

# ─────────── ★牙に牙を立てる★ = 戻し方そのものの自己試験 ───────────
# ★何ゆえ要るか★= ★本改修は【他者の記録を消さぬ】という【不在の保証】である★=
#   ★不在は普段の走りでは見えぬ (他者が書かねば旧の形でも同じ答が出る)★
#   ⇒ ★★他者の行を人工に作って撃たねば、直った事も壊れた事も判らぬ★★。
if [ "${1:-}" = "--selftest-restore" ]; then
  T="$(mktemp -d)"; fail=0
  _ck() { [ "$1" = "$2" ] || { echo "★NG★ $3 (期待=[$1] 実=[$2])"; fail=1; }; }
  _mk() { printf '%s\n' "$@" ; }

  # (i) ★己の行だけが足された時 = 消す★
  _mk '[2026-07-27T00:00:00+09:00] HTTP=200 curl_rc=0 title=seed' > "$T/bk"
  cp "$T/bk" "$T/log"
  _mk '[2026-07-27T13:30:00+09:00] HTTP=200 curl_rc=0 title=★C1 忘れっぽい試験★' >> "$T/log"
  _restore_log_surgical "$T/log" "$T/bk" "$HARNESS_LINE_RE" >/dev/null
  _ck "$(cat "$T/bk")" "$(cat "$T/log")" "(i) 己の行を消して母数へ戻る"

  # (ii) ★★他者の行が混じった時 = 残す (本改修の芯・旧の形は之を消しておった)★★
  cp "$T/bk" "$T/log"
  _mk '[2026-07-27T13:30:00+09:00] HTTP=200 curl_rc=0 title=★C1 忘れっぽい試験★' \
      '[2026-07-27T13:30:05+09:00] HTTP=200 curl_rc=0 title=🚨 家老が窓の中で撃った急報' >> "$T/log"
  _restore_log_surgical "$T/log" "$T/bk" "$HARNESS_LINE_RE" >/dev/null
  _ck "2" "$(wc -l < "$T/log")" "(ii) 他者の行が残り、己の行だけ消える"
  grep -q '家老が窓の中で撃った急報' "$T/log" || { echo "★NG★ (ii) 他者の行を消しておる"; fail=1; }
  grep -q 'C1 忘れっぽい試験' "$T/log" && { echo "★NG★ (ii) 己の行が残っておる"; fail=1; }

  # (iii) ★前置きが動いておれば何もせぬ (消すより残す)★
  #   ★★此の検は一度 空虚であった (2026-07-27 13:3x 実測)★★ =
  #     ★前置きを変えるだけでは【追記 0 行】ゆえ、検めを外しても早仕舞いで同じ答が出た★
  #     ⇒ ★★前置きの改竄と追記を【同時に】置かねば、検めの有無が答に出ぬ★★
  #     = ★「変異させても落ちぬ検」を己の手で作っておった形ゆえ、記して残す★。
  cp "$T/bk" "$T/log"
  _mk '書き換えられた前置き' \
      '[2026-07-27T13:30:00+09:00] HTTP=200 curl_rc=0 title=★C1 忘れっぽい試験★' > "$T/log"
  _restore_log_surgical "$T/log" "$T/bk" "$HARNESS_LINE_RE" >/dev/null 2>&1
  _ck "2" "$(wc -l < "$T/log")" "(iii) 前置きが動いた時は 1 行も触れぬ"
  grep -q '書き換えられた前置き' "$T/log" || { echo "★NG★ (iii) 前置きを消しておる"; fail=1; }

  # (iv) ★1 byte でも違えば己の行と見做さぬ (印は厳密である事の証)★
  cp "$T/bk" "$T/log"
  _mk '[2026-07-27T13:30:00+09:00] HTTP=500 curl_rc=0 title=★C1 忘れっぽい試験★' >> "$T/log"
  _restore_log_surgical "$T/log" "$T/bk" "$HARNESS_LINE_RE" >/dev/null
  _ck "2" "$(wc -l < "$T/log")" "(iv) HTTP が違う行は【他者】として残す"

  rm -rf "$T"
  [ "$fail" -eq 0 ] && echo "ok   --selftest-restore 4 本 緑 (己の行のみ消し・他者は残し・前置き改竄は不触・印は厳密)"
  exit "$fail"
fi

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
    LAST_NG_KIND=anchor; NG=$((NG + 1)); return
  fi

  # ── ★★(a2) baseline の検め (2026-07-27 08:5x 四号の是正)★★ ────────────────────
  #   ■ ★何を塞ぐか★= ★素の盤面で既に赤いなら、変異後の赤は【変異ゆえ】と申せぬ★。
  #     本 harness は「赤くなったか + 針が名指されたか」しか見ておらなんだゆえ、
  #     ★元から赤い盤面では 12/12 ok を出し rc=0 (緑) を返しておった★。
  #   ■ ★実測 (2026-07-27 08:53)★= ★追跡外の 2 file (config/settings.yaml /
  #     logs/ntfy_send.log) を欠いた盤面 = fresh clone の姿★ では
  #     ★bats -f 'A2' が変異前から `not ok 1 A2`★ (ntfy.sh が settings を読めぬ)。
  #     其れでも本 harness は ★ok MUT-1381-201 — 赤 rc=1 / 名指し=[not ok 1 A2]★ と刷り、
  #     ★rc=0 で緑を返した★ = ★配られた木では此の harness の緑は何も証しておらなんだ★。
  #   ⇒ ★変異の前に素の盤面で一度 撃ち、緑でなければ ok を出さぬ (SKIP=FAIL の harness 版)★。
  local bout brc
  bout="$(eval "$testcmd" 2>&1)"; brc=$?
  if [ $brc -ne 0 ]; then
    echo "★NG★ $id: ★baseline が既に赤 (rc=$brc)★ = 変異後の赤は【変異ゆえ】と申せぬ (UNDETERMINED)"
    echo "$bout" | tail -3 | sed 's/^/      /'
    LAST_NG_KIND=baseline; NG=$((NG + 1)); return
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
    echo "★NG★ $id: 変異そのものが当たらなんだ"; LAST_NG_KIND=mutate; NG=$((NG + 1)); restore_all; return
  fi
  # ── ★着弾の証明★= byte が現に動いたか ──
  if cmp -s "$REPO/$rel" "$WORK/orig/$(echo "$rel" | tr '/' '_')"; then
    echo "★NG★ $id: 変異後も byte が同一 = ★撃っておらぬ (UNDETERMINED)★"
    LAST_NG_KIND=bytes; NG=$((NG + 1)); restore_all; return
  fi

  # ── 試験を走らせ、★赤くなること★と★狙った検が名指されること★を見る ──
  local out rc
  out="$(eval "$testcmd" 2>&1)"; rc=$?
  restore_all

  if [ $rc -eq 0 ]; then
    echo "★NG★ $id ($desc): ★変異させても試験が緑のまま★ = 此の緑は何も証しておらぬ"
    LAST_NG_KIND=green; NG=$((NG + 1)); return
  fi
  if ! grep -qF -- "$needle" <<<"$out"; then
    echo "★NG★ $id ($desc): 赤くはなったが ★狙った検 [$needle] が名指されておらぬ★ = 別の場所に当たった疑い"
    echo "$out" | tail -5 | sed 's/^/      /'
    LAST_NG_KIND=needle; NG=$((NG + 1)); return
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

# ★★O-7 = 【牙の牙】★★ (軍師二号 01:59 / 家老 02:03)
#   ★裁可(ii)「成功行の byte 一致を手放した」は【牙 A7 が生きておる限りにおいて】妥当である★ =
#   ★A7 が死ねば「証拠を捨てただけ」に転ずる★ ⇒ ★A7 自身に牙が在るかを、変異で撃って示す★。
#   ⇒ 後方互換を壊す変異 (curl_rc を必須にする = 旧 1,097 行が解けなくなる) を当て、★A7 が現に落ちるか★を見る。
mutate MUT-1400-212 "★牙の牙★ 後方互換を壊す (curl_rc を必須へ)→A7 が旧 1,097 行の喪失を捕えるか" \
  scripts/gate_ntfy_sendlog.py \
  '    r"(?: curl_rc=(?P<rc>\S+))?"' \
  '    r" curl_rc=(?P<rc>\S+)"' \
  "bats tests/test_cmd1381_ntfy_logline.bats -f 'A7'" \
  "not ok 1 A7"

# ── ★★負の対照 = 此の道具そのものが【常に ok を出す物】でないことの証★★ ─────────────
#   ★上の 11 本は全て「赤が出た」で ok を出しておる★ = ★然れば【何を撃っても赤が出る道具】と
#   区別がつかぬ★ (本日 全軍で積んだ「鳴る側と鳴らぬ側を同数 撃て」の、変異台帳の側の顔)。
#   ⇒ ★振舞いを 1 bit も変えぬ変異 (註釈のみ) を撃ち、道具が【捕まらなんだ】と正しく申すかを見る★。
NG_BEFORE=$NG
LAST_NG_KIND=""   # ★208 の直前で必ず洗う★= 前の変異が残した理由を 208 の判定に持ち込まぬ
mutate MUT-1381-208 "★負の対照★ 註釈だけの変異 → 捕まらぬ筈" \
  scripts/gate_ntfy_sendlog.py \
  "★北極星 (cmd_1381 の起源)★" \
  "★北極星 (cmd_1381 の起源・此の行は註釈ゆえ振舞いを変えぬ)★" \
  "python3 scripts/gate_ntfy_sendlog.py --selftest" \
  "★NG★"
# ★★帳消しは【数】でなく【理由】で判ずる (2026-07-27 08:5x 四号の是正)★★
#   ★数だけで判ずれば、208 は己と無縁の NG (針が名指されぬ 等) まで吸い取って緑へ戻す★
#   = ★実測で現に起きた形ゆえ、理由 [green] を要求する★。
if [ "$NG" -eq $((NG_BEFORE + 1)) ] && [ "$LAST_NG_KIND" = "green" ]; then
  NG=$NG_BEFORE   # ★此の NG は【期待どおり】ゆえ帳消しにする★
  echo "ok   MUT-1381-208 — ★道具は無害な変異を『緑のまま』と正しく名指した★ = 常に赤を出す道具ではない"
elif [ "$NG" -eq $((NG_BEFORE + 1)) ]; then
  echo "★NG★ MUT-1381-208: ★NG は 1 件 立ったが、其の理由が [$LAST_NG_KIND] であって [green] でない★"
  echo "      = ★帳消しにせぬ★ (数が合うだけで理由を検めねば、己と無縁の NG を吸い取る門になる)"
  NG=$((NG + 1))
else
  echo "★NG★ MUT-1381-208: ★振舞いを変えぬ変異を『捕えた』と申しておる★ = 此の道具の赤は信用できぬ"
  NG=$((NG + 1))
fi

echo "── 変異 11 本 + 負の対照 1 本 / NG $NG 件 ──"
# ★最後にもう一度 復元を確かめる★ (試験の途中で落ちても、盤面を汚したままにせぬ)
git diff --stat -- scripts/ntfy.sh scripts/gate_ntfy_sendlog.py > "$WORK/after.txt" 2>/dev/null || true
exit $((NG > 0 ? 1 : 0))
