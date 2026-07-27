#!/usr/bin/env bash
# SayTask通知 — ntfy.sh経由でスマホにプッシュ通知
# FR-066: ntfy認証対応 (Bearer token / Basic auth)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# ntfy_auth.sh読み込み
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

# ★★cmd_1080 追補 (2026-07-27 足軽四号) — 「file が無い」と「設定されておらぬ」を分ける★★
#   ■ ★病 (実測)★= 殿の機の外 (git archive HEAD を展開した木) で撃つと、
#     ★`grep: …/config/settings.yaml: No such file or directory` の一行だけを残して rc=2 で打ち切れた★
#     (set -euo pipefail の下で代入が非0を拾うゆえ)。★何が起きたのか・咎が何処に在るのかを名乗っておらぬ★。
#   ■ ★之は cmd_1381 F-2 / morning_readiness.sh と同じ族にござる★=
#     ★「log が無い」は「届かなんだ」ではない★ ⇒ ★「settings.yaml が無い」は「通知が死んでおる」ではない★。
#   ■ ★config/settings.yaml は .gitignore:7 (`*`) ゆえ配られぬのが【正しい】★=
#     ★first_setup.sh:620 が其の機で作る物である★ (実物を読んで確かめた = 推測ではない)。
#   ■ ★rc は変えておらぬ★= ★従前も grep の rc がそのまま 2 で出ておった★ ⇒ ★呼び手から見て 1 つも変わらぬ★。
#     ★変えたのは【口上】だけである★。
if [ ! -f "$SETTINGS" ]; then
  echo "[ntfy] ★検めておらぬ★: $SETTINGS が此の木に無い。" >&2
  echo "[ntfy]   ★.gitignore:7 ゆえ配られぬのが正しい★ = ★first_setup.sh が其の機で作る物★。" >&2
  echo "[ntfy]   ⇒ ★通知路が死んでおるのではない。此の木に設定が無いだけである★ (rc=2 = 未検分)。" >&2
  exit 2
fi
TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml" >&2
  exit 1
fi

# 認証引数を取得（設定がなければ空 = 後方互換）
AUTH_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

TITLE="${1:-}"
BODY="${2:-}"

# ── cmd_1363: shell に食われぬ本文の受け口 (inbox_write.sh と同じ綴り) ──────
# ★家老が 2026-07-26 に本 script で同型を踏んだ★ = 本文の backtick を shell が先に
#   評価し、送信そのものが失敗した。綴りは scripts/shell_expansion_guard.py の
#   BODY_SENTINELS と一致させること (関所が認めた逃げ道を道具が受け取らねば意味がない)。
#   例: bash scripts/ntfy.sh "🚨 要対応" --body-stdin <<'EOF'
case "$BODY" in
    --stdin|--body-stdin|-)
        BODY="$(cat)"
        ;;
    --content-file=*|--body-file=*)
        _BF="${BODY#*=}"
        [ -f "$_BF" ] || { echo "[ntfy] FATAL: 本文 file が読めぬ: $_BF" >&2; exit 1; }
        BODY="$(cat "$_BF")"
        ;;
    --content-file|--body-file)
        _BF="${3:-}"
        [ -f "$_BF" ] || { echo "[ntfy] FATAL: 本文 file が読めぬ: $_BF" >&2; exit 1; }
        BODY="$(cat "$_BF")"
        ;;
esac
# ★NTFY_LOG_FILE = 試験の口★ (既定は従前どおり logs/ntfy_send.log)。
#   ★之が無ければ (c) の変異試験は【本物の log を汚す】か【撃たぬ】かの二択になる★。
LOG_FILE="${NTFY_LOG_FILE:-$SCRIPT_DIR/logs/ntfy_send.log}"

# ★★cmd_1400 (2026-07-27 足軽四号) — 試験の既定を tmp へ向ける★★
#   ■ ★何ゆえ要るか = 現に実害が出たゆえ★:
#     test_cmd1363 が偽 curl で本 script を走らせ ★本番 logs/ntfy_send.log へ 4 行 書いた★。
#     ★矢は一本も飛んでおらぬ (偽 curl) が、記録は現に汚れた★ ⇒ ★段5(b) の判定子が其の試験行の
#     500 を数え、初回の実読みで【偽の赤 (BURST)】を出した★ = 本番の記録が試験で汚れた実害である。
#   ■ ★何ゆえ「各試験が NTFY_LOG_FILE を書け」で足りぬか★:
#     ★忘れることが当の不具合であった★ = 忘れられる仕掛けは、いつか必ず忘れられる。
#     ⇒ ★書き手の規律でなく、道具の既定で塞ぐ★ = ★試験の中では、何も書かずとも本番へ届かぬ★。
#   ■ ★判じ方 = bats が立てる env のみを見る★ (己で「試験か」を推し量らぬ)。
#     ★明示の NTFY_LOG_FILE は常に優先★ = 試験が己で行き先を決めたいなら、其れを妨げぬ。
#   ■ ★答えぬ問い (名乗っておく)★ = ★bats 以外の枠組み (素の bash 試験・pytest) は之では捕まらぬ★。
#     其方は ★NTFY_LOG_FILE を明示せよ★ = 本 guard は bats の分だけを構造で塞ぐ物である。
if [ -z "${NTFY_LOG_FILE:-}" ] && \
   [ -n "${BATS_TEST_FILENAME:-}${BATS_TEST_TMPDIR:-}${BATS_RUN_TMPDIR:-}" ]; then
  _TESTDIR="${BATS_TEST_TMPDIR:-${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}}"
  LOG_FILE="$_TESTDIR/ntfy_send.log"
  echo "[ntfy] ★試験の中ゆえ log を tmp へ向けた★: $LOG_FILE (本番 log は汚さぬ / cmd_1400)" >&2
fi

mkdir -p "$(dirname "$LOG_FILE")"

# ★★cmd_1381 段5 (a) — log を【機械が読める1行】にする (2026-07-27 足軽四号)★★
#   ■ ★実測で判った瑕疵 (推測ではない)★= 本 log 1,097 行を byte で検めた:
#       ★46 箇所の【不正 UTF-8】が現に在った★ = 全て 117 byte 行の 115〜116 byte 目 =
#       ★`head -c 80` が多byte文字を途中で切っておった★ (前置き "…title=" が 37 byte / 37+80=117)。
#     ⇒ ★python の read_text(encoding="utf-8") は本物の log を今 読めば落ちる★ (実測で落ちた)。
#     ⇒ ★之は cmd_1381 差し戻し F-2 と同じ族★= 我らの側の byte 列の落ち度が、
#       読み手を落とし ★「通知路が死んだ」の色に化けうる★。
#   ■ ★併せて【1行1事象】が構造で保たれておらなんだ★= title に改行が在れば行が割れる。
#     (本 log では現に起きておらぬ = ★起きなんだのは盤面のおかげであり、守りのおかげではない★)
#   ■ ★処方 = 三段★ (順序に意味が在る):
#       (1) 制御文字を除く    → ★改行/CR/TAB が消える = 1行1事象が【構造で】立つ★
#       (2) 80 byte で切る    → 従前と同じ長さの上限
#       (3) iconv -c で漉す   → ★(2) が作った壊れた末尾の多byteだけが落ちる★
#     ★(3) を (2) の後に置かねば意味が無い★= 壊すのは (2) ゆえ、漉すのは其の後である。
_log_title() {
  # ★|| true★= head の早仕舞い (SIGPIPE) と iconv の「末尾が不完全」の rc を飲む。
  #   ★飲んでよいのは rc のみ★= 出力 (漉された妥当な UTF-8) は現に出ておる。
  printf '%s' "${1-}" | tr -d '\000-\037\177' | head -c 80 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
}

# ★cmd_1381 段4 (2026-07-27 足軽四号): curl が死んだ時【1行も残らぬ】のを塞ぐ★
#   旧版は set -e の下で `_http_status=$(curl …)` を撃っており、★curl が非0で死ぬと代入の段で
#   script が打ち切られ、下の log 行へ辿り着かなんだ★ = ★真理表の B (curl 自体が死ぬ) だけが
#   【不在】でしか判らぬ形★であった (★存在は証せるが不在は証せぬ★)。
#   ⇒ ★`|| _curl_rc=$?` で【落ちても進む】のは此の代入 1 箇所のみ★。set -e は外さぬ。
#   ⇒ ★rc は呼び手から見て 1 つも変わらぬ★ = curl 死は従前どおり curl の rc で落ちる。
#   ⇒ ★成功時の log 行は従前と byte 一致★ = curl_rc は【非0 の時だけ】足す。
# ══ cmd_1419 (2026-07-27 足軽四号) — 「誰が撃ったか」と「何を撃ったか」をログに残す ══
#
# 起きたこと: 14:28:34 と 14:28:42 に同じ題が8秒差で2本 飛び、殿のスマホが2回 鳴った。
#   このスクリプトに再送の口は無い（curl は1発）。よって呼び手が二度 撃ったことになる。
#   ところが従来のログ行は HTTP と curl_rc と題しか残さないため、
#   ★誰が二度 撃ったかはログから永久に分からない★。
#   問題は二重送信そのものより、二度 撃って誰も気付かない形が残っていることである。
#
# 足したもの2つ:
#   caller = 呼び手の印。tmux の agent id が取れればそれを使い、取れなければ親プロセス（pid/名）。
#   fp     = 題と本文の指紋（sha256 の頭8桁）。★本文そのものは書かない★
#            = 個人情報と行長の問題があるため。指紋なら「同じ本文か」だけが分かる。
#
# 重複が来た時の扱い: ★送信は止めず、印を残して警告する★（dup_age= と stderr）。
#   理由: このスクリプトは呼び手の意図を持たないため、抑止すると「意図した再送・訂正」まで
#   無言で消してしまう。本件の核心は「気付けない」ことなので、見えるようにする方を採る。
_CALLER=""
if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
  _CALLER=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
fi
if [ -z "$_CALLER" ]; then
  # 取れない場合は親プロセス。★「取れなかった」と「不明な誰か」を混ぜない★ため ppid: を冠する。
  _PPID=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || true)
  _PCOMM=$(ps -o comm= -p "${_PPID:-0}" 2>/dev/null | tr -d ' ' || true)
  _CALLER="ppid:${_PPID:-unknown}${_PCOMM:+/$_PCOMM}"
fi
# 空白と制御文字を落とす = 1行1事象と、フィールド境界を壊さないため。
_CALLER=$(printf '%s' "$_CALLER" | tr -d '\000-\037\177 ' | head -c 32)
[ -n "$_CALLER" ] || _CALLER="unknown"

# 指紋。sha256sum が無い機では nosha と名乗る（★黙って空にしない★）。
if command -v sha256sum >/dev/null 2>&1; then
  _FP=$(printf '%s\037%s' "$TITLE" "$BODY" | sha256sum | cut -c1-8)
else
  _FP="nosha"
fi

# 短時間に同じ指紋が再来したか。窓は既定 120 秒（NTFY_DUP_WINDOW_SEC で変えられる）。
#   窓に 0 を渡すと重複判定そのものを止める（試験と、意図した連投のための逃げ道）。
_DUP_WINDOW_SEC="${NTFY_DUP_WINDOW_SEC:-120}"
_DUP_FIELD=""
if [ "$_DUP_WINDOW_SEC" -gt 0 ] && [ "$_FP" != "nosha" ] && [ -f "$LOG_FILE" ]; then
  _prev=$(grep -F " fp=$_FP " "$LOG_FILE" 2>/dev/null | tail -n 1 || true)
  if [ -n "$_prev" ]; then
    _prev_ts=${_prev#\[}
    _prev_ts=${_prev_ts%%\]*}
    _prev_epoch=$(date -d "$_prev_ts" +%s 2>/dev/null || true)
    if [ -n "$_prev_epoch" ]; then
      _age=$(( $(date +%s) - _prev_epoch ))
      if [ "$_age" -ge 0 ] && [ "$_age" -le "$_DUP_WINDOW_SEC" ]; then
        _DUP_FIELD=" dup_age=${_age}s"
        echo "[ntfy] 警告: 同じ題と本文が ${_age} 秒前にも送られている (fp=$_FP caller=$_CALLER)。" >&2
        echo "[ntfy]   送信は止めない。二度 鳴らす意図が無いなら呼び手を確かめること。" >&2
      fi
    fi
  fi
fi

# ══ cmd_1419 その5 — 試験の送信が殿の端末を鳴らす形を塞ぐ ══════════════════
#
# 実測（軍師二号が本日の通知30本を点検）: 試験由来の送信6本が殿の端末へ実際に飛んでいた
#   （01:20 に4本、07:23 と 12:09 に1本ずつ）。
#   cmd_1400 で★ログの向き先★は tmp へ逃がしたが、★送信そのもの★は本番の宛先へ飛んでいた。
#   = 「記録を汚さない」と「鳴らさない」は別の守りである。片方だけでは足りなかった。
#
# 塞ぎ方: 試験の中では curl を呼ばない。★ただし黙って送らない形にはしない★ =
#   どこへ送らなかったかを画面（stderr）に出し、ログにも mode=dryrun として残す。
# 判じ方: bats が立てる env、または明示の NTFY_DRY_RUN=1。★自分で「試験か」を推し量らない★。
# 答えない問い: bats 以外の枠組み（素の bash 試験・pytest）はこれでは捕まらない。
#   そちらは NTFY_DRY_RUN=1 を明示すること。cmd_1400 の log guard と同じ射程である。
#
# 逃げ道: NTFY_DRY_RUN=0 を明示すれば試験の中でも本物の経路を通る。
#   ★これは黙っては通らない★ = 通る時は画面にそう出す。
#   要る場面: 偽 curl を PATH に置いて 500 や接続失敗を作る試験（cmd_1381）。
#   そこでは矢は飛ばないが、curl を呼ぶ経路そのものを試したいためである。
_DRY_RUN=0
if [ "${NTFY_DRY_RUN:-}" = "1" ]; then
  _DRY_RUN=1
  _DRY_WHY="NTFY_DRY_RUN=1 が立っている"
elif [ "${NTFY_DRY_RUN:-}" = "0" ]; then
  _DRY_RUN=0
  echo "[ntfy] NTFY_DRY_RUN=0 が明示されている = 試験の中でも送信の経路を通る。" >&2
elif [ -n "${BATS_TEST_FILENAME:-}${BATS_TEST_TMPDIR:-}${BATS_RUN_TMPDIR:-}" ]; then
  _DRY_RUN=1
  _DRY_WHY="bats の中で走っている"
fi

_curl_rc=0
if [ "$_DRY_RUN" = "1" ]; then
  echo "[ntfy] 送っていない（$_DRY_WHY）。宛先は https://ntfy.sh/$TOPIC であった。" >&2
  echo "[ntfy]   題=$(_log_title "$TITLE")" >&2
  echo "[ntfy]   本物へ送るなら NTFY_DRY_RUN=0 を明示し、bats の外で撃つこと。" >&2
  _http_status="DRYRUN"
  _DUP_FIELD="$_DUP_FIELD mode=dryrun"
fi
# shellcheck disable=SC2086
if [ "$_DRY_RUN" = "1" ]; then
  :   # 試験の中では curl を呼ばない（呼ばないことが本件の守りそのもの）
elif [ -n "$BODY" ]; then
  _http_status=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_ARGS[@]}" -H "Title: $TITLE" -H "Tags: outbound" -d "$BODY" "https://ntfy.sh/$TOPIC" 2>/dev/null) || _curl_rc=$?
else
  _http_status=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_ARGS[@]}" -H "Tags: outbound" -d "$TITLE" "https://ntfy.sh/$TOPIC" 2>/dev/null) || _curl_rc=$?
fi
# ★★段5 (a) の書き出し = 【一本の口】から出す★★
#   ■ ★旧版は成功と失敗で別々の echo を持っており、★成功行にだけ curl_rc が無かった★ =
#     ★読み手から見て【場が固定でない】★ = 段5 (a) の下命「rc と HTTP と時刻が固定位置に在る形」に反する。
#   ■ ★時刻に offset を足した★ (%:z) = 旧行は naive ゆえ ★読み手が盤面の TZ を仮定せねば齢を出せなんだ★。
#     ⇒ ★新しい行は盤面の TZ に依らず齢が出る★ (判定子の [NTFY-SEND-CALENDAR] が要らぬ側へ寄る)。
#   ■ ★旧 1,097 行との後方互換は実測で確かめてある★= curl_rc を optional 群にした正規で
#     ★1,097/1,097 が今も解ける★ (足軽四号 01:1x)。★形を変えたが、過去を読めなくはしておらぬ★。
#   ■ ★失うた物も名乗る★= 段4 で得た「成功行は従前と byte 一致」は ★本改修で意図して手放した★ =
#     ★機械可読の方が値打ちが上と判じたゆえ★ (家老の下命が其れを求めておる)。
_log_line() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%:z')] HTTP=${_http_status:-NONE} curl_rc=$_curl_rc caller=$_CALLER fp=$_FP${_DUP_FIELD} title=$(_log_title "$TITLE")" >> "$LOG_FILE"
}
_log_line
if [ "$_curl_rc" -ne 0 ]; then
  exit "$_curl_rc"   # ★従前 set -e が返しておった値と同じ★
fi

# ★cmd_1363: 送信の失敗を【黙って】飲まぬ★
#   旧版は HTTP status を log へ書くだけで ★何が起きても exit 0★ であった =
#   ★「撃ったこと」を成功の証拠にしており、「届いたこと」を見ておらぬ★
#   (五号の教訓 = 解放は「撃った」でなく「VRAM が戻った」で確かめよ、の通知版)。
#   家老が本日 ntfy の送信失敗に気付けなんだのは、この沈黙が理由である。
case "$_http_status" in
    2??) ;;  # 届いた
    DRYRUN)  # 試験ゆえ送っていない。★失敗ではない★ = 上で既に画面へ名乗ってある
        exit 0 ;;
    *)
        # ★同じ helper を通す★= stderr も ★多byteを途中で切って化けさせぬ・改行で行を割らせぬ★
        #   (60→80 byte へ揃えた。同じ瑕疵が二箇所に在ったゆえ、二箇所とも塞ぐ)
        echo "[ntfy] FAILED: HTTP=$_http_status — ★通知は届いておらぬ★ (title=$(_log_title "$TITLE"))" >&2
        exit 1
        ;;
esac
