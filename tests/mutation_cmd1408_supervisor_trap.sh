#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# cmd_1408 — watcher_supervisor の trap を【両方向】で撃つ
# ──────────────────────────────────────────────────────────────────
# ★問い★= 「trap を足した」を緑で終わらせぬ。次の三つを別々に見る:
#   D1 ★己で畳めば名乗る★     = SIGTERM → ENDED 行が出る (signal=TERM つき)
#   D2 ★SIGKILL では名乗らぬ★ = SIGKILL → ENDED 行は出ぬ (= probe が要る証)
#   D3 ★丁度 1 度だけ名乗る★  = 自然終了 → ENDED が ★1 行★ (2 行以上なら subshell 毎に
#        鳴っておる = ★log を汚す新しい不具合を我らが作った★ことになるゆえ数まで見る)
#   NC ★負の対照★             = 被検体から trap を抜いた版へ D1 を撃つ → ENDED 行が出ぬ
#        ⇒ ★之が無ければ D1 は「何を撃っても緑」と区別が付かぬ★
#
# ★枷 = 本番へ指一本 触れぬ★
#   ・`kill` は使わぬ (恒久 deny)。★signal は timeout(1) が己の子へのみ送る★
#     = 構造として本番 pid を撃てぬ。
#   ・偽の `tmux` を PATH の先頭へ置く (常に rc=1) ⇒ pane_exists が偽 ⇒
#     ★watcher を一体も起動せぬ★・pane_gate も不使用ゆえ drift 層も沈黙。
#   ・SHOGUN_LOCK_DIR を tmp へ逃がす ⇒ 本番の lock / marker の mtime を汚さぬ。
#   ・__WATCHER_SUPERVISOR_TESTING__=1 ⇒ 本番の lifetime lock を奪わぬ。
#   ・偽 `nohup` も置く ⇒ ★process を起こす道を構造として塞ぐ★
#     (偽 tmux だけでは ledger_guard が pane 非依存ゆえ漏れる)。
#   ・汚しておらぬ証は ★因果★ で採る = 己の log に [START] が在るか (0 であるべき)。
#     ★盤面の pid 増減は参考に留める★ = 本番 supervisor が 5 秒毎に回るゆえ
#     他所由来で動きうる ⇒ 之を FAIL にすれば ★己と無縁の赤★ を作る。
#   ・★計器 canary が当たらねば PASS を出さず UNDETERMINED (rc=2) へ倒す★
#     = ★「道具が見えぬ」を「盤面は綺麗」と混ぜぬ★。
# ══════════════════════════════════════════════════════════════════
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TMP="$(mktemp -d)"
# ★旧版は repo の scripts/ 配下へ置く★= SCRIPT_DIR は dirname($0)/.. ゆえ、
#   tmp へ置くと lib を読めず ★署名する前に死ぬ = 負の対照が真空で緑になる★
#   (初回撃ちで現に踏んだ)。
OLD="$REPO/scripts/.cmd1408_trap_probe_HEAD.sh"
trap 'rm -rf "$TMP"; rm -f "$OLD"' EXIT

# ── 偽 tmux (常に失敗) = pane を一つも見せぬ ──
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"

# ── ★偽 nohup = 本試験が process を起こす道を【構造として】塞ぐ★ ──
# 由来 = 偽 tmux だけでは足りぬ。★ledger_guard の起動は pane に依らぬ (singleton)★ゆえ、
#   ★本番の ledger_guard が偶々死んでおれば、本試験が本物を起こしてしまう★
#   = ★安全が【其の時の盤面】に懸かっておった★。
# ⇒ 偽 nohup は ★何も起こさず、起こそうとした事実だけを標へ刷る★
#   = 判定(i) が其れを拾う ⇒ ★「起こさなんだ」が盤面に依らず言える★。
printf '#!/bin/sh\necho "[FAKE-NOHUP] 起動を阻止: $*" >&2\nexit 0\n' > "$TMP/bin/nohup"
chmod +x "$TMP/bin/nohup"

# ★被検体を差し替え可能にする★ = ★己の牙が現に落ちるかを、
#   本番 file を書き換えずに撃つため★ (既定は従前どおり本番 path)。
SUT="${SUP_UNDER_TEST:-scripts/watcher_supervisor.sh}"

MARKER='watcher_supervisor ENDED'
FAIL=0

# ★数でなく【pid の集合】を、/proc の cmdline から直に採る★
#   由来 = 初版は `pgrep -fc` で数えており、★己の測定 shell の command line が
#   pattern を含むゆえ己を数える★・且つ ★他所の一過性 process まで拾う★。
#   ⇒ ★「増えた」が出ても【誰が増やしたか】を言えなんだ★ (現に一度 誤検知した)。
# ★argv[1] の basename で照合する★ =
#   初版は `"bash scripts/X.sh "*` という【綴りの前方一致】であった ⇒
#   ★inbox_watcher は絶対 path で起動されており (bash /mnt/c/.../inbox_watcher.sh)、
#     ledger_guard は相対 path★ ⇒ ★前者が丸ごと 0 件に化けておった★
#   = ★★空の集合が「居らぬ」の顔で返る★★ = 本 repo が繰り返し踏んだ族。
#   ⇒ ★path の綴りに依らぬ basename 照合★ + ★argv[0] が bash/sh である事★で絞る
#     (後者は ★己の測定 shell (`bash -c …`) を数える穴★ を塞ぐ = argv[1] が "-c" ゆえ外れる)。
proc_pids() {
    local want="$1" p pid a0 a1
    local -a argv
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        mapfile -d '' -t argv < "$p/cmdline" 2>/dev/null || continue
        [ "${#argv[@]}" -ge 2 ] || continue
        a0="${argv[0]##*/}"
        a1="${argv[1]##*/}"
        case "$a0" in bash|sh) ;; *) continue ;; esac
        [ "$a1" = "$want" ] && echo "$pid"
    done | sort -n | tr '\n' ' '
}
board_snapshot() {
    echo "watcher=[$(proc_pids inbox_watcher.sh)] ledger=[$(proc_pids ledger_guard.sh)]"
}

# ★LOGF は大域で返す★ = command substitution で受けると、進捗の行まで混ざり
#   「grep の当たり先が空 path」になって ★何を撃っても緑★ に化ける
#   (本試験の初回撃ちで現に踏んだ。負の対照つきでなければ気付けなんだ形ゆえ、註として残す)。
LOGF=""
run_case() {
    # ★`local a="$1" b="${a}"` と書くな★= local は全引数を【先に】展開してから代入するゆえ
    #   b の中の ${a} は未設定になる (set -u で落ちる)。之も初回撃ちで踏んだ。
    local label="$1"
    local script="$2"
    local sig="$3"
    LOGF="$TMP/${label}.log"
    # ★TESTING=1 では proc_lock_acquire を通らぬ = 誰も lock dir を掘らぬ★
    #   掘らねば 9>"$start_lock" が失敗し ★signal が届く前に set -e で死ぬ★ (初回撃ちで踏んだ)。
    mkdir -p "$TMP/locks_${label}"

    PATH="$TMP/bin:$PATH" \
    SHOGUN_LOCK_DIR="$TMP/locks_${label}" \
    __WATCHER_SUPERVISOR_TESTING__=1 \
    WATCHER_SUPERVISOR_MAX_CYCLES=100 \
    WATCHER_DRIFT_DETECT=0 \
    timeout -s "$sig" 4 bash "$script" >"$LOGF" 2>&1
    local rc=$?

    # ★当たり先が実在し、且つ空でないことを先に確かめる★ = 空 log を「出ておらぬ」と
    #   読めば ★不在の証明を道具の不具合で作る★ = 本夜ずっと狩ってきた形そのもの。
    if [ ! -s "$LOGF" ]; then
        echo "  ✘ 計器不良: log が空 or 不在 ($LOGF) — 判定を打ち切る"
        FAIL=1
        return 1
    fi
    echo "  (timeout rc=${rc} / signal=${sig} / log $(wc -c <"$LOGF") byte)"
    return 0
}

echo "═══ cmd_1408 supervisor trap — 両方向 + 負の対照 ═══"
echo "採取時刻 = $(date -Is)"
echo

# ★★計器の canary = 0 を報ずる前に【当たる筈の物】を同じ道具で撃つ★★
#   ★本試験を走らせておる此の瞬間、watcher_supervisor は現に走っておる筈★
#   ⇒ ★之が 0 なら盤面でなく【道具】が壊れておる★= 盤面の判定を信じてはならぬ。
SUP_PIDS="$(proc_pids watcher_supervisor.sh)"
echo "■ 計器 canary: 同じ道具で watcher_supervisor を探す = [${SUP_PIDS}]"
if [ -z "${SUP_PIDS// /}" ]; then
    echo "  ▲ ★0 件★ — ★本番の番人が不在か、又は照合器が盲目か★の何れか。"
    echo "    ⇒ ★以下の盤面判定は【信じるに足らぬ】ゆえ参考に留める★"
    BOARD_TRUSTED=0
else
    echo "  ✔ 当たった ⇒ ★照合器は現に process を見ておる★ (空集合を『居らぬ』と読んでよい)"
    BOARD_TRUSTED=1
fi
echo

BEFORE="$(board_snapshot)"
echo "■ 事前の盤面 (pid 集合) = $BEFORE"
echo

# ══════════════════════════════════════════════════════════════════
# ── 負の対照 = ★被検体から trap の据付だけを抜いた版を、其の場で作る★ ──
# ══════════════════════════════════════════════════════════════════
# ★★初版は `git show HEAD:…` で旧版を取っておった = 之が誤りであった★★
#   ⇒ ★HEAD は動く★。四号が本 trap を commit した其の瞬間、
#     ★HEAD が trap を持つに至り、負の対照が【被検体と同じ物】に化けた★
#     = ★対照が対照でなくなったのに、其れを報せる口が無かった★
#     (現に commit 直後の撃ちで NC が落ち、初めて露見した)。
#   ⇒ ★★対照は【歴史】に拠らせるな。【被検体そのもの】から作れ★★
#     = 何時 誰が何を commit しようとも、対照は常に「trap 抜き」であることが構造で決まる。
# ★綴りに引用符が挟まる形 (trap '_sup_on_signal TERM 15' TERM) を取り零すな★
#   = 初手の regex は `^trap (_sup…)` と書いて ★引用符つきの 3 本を取り零した★。
#   ★而して下の門が其の場で捕えた★ = 「対照が対照でない」を緑にせぬ口が現に働いた証。
sed -E "s/^trap .*_sup_on_.*/# CONTROL: trap を据えておらぬ (負の対照)/" \
    "$SUT" > "$OLD" || { echo "対照を作れぬ"; exit 1; }
OLD_TRAPS=$(grep -c '^trap ' "$OLD" || true)
NEW_TRAPS=$(grep -c '^trap ' "$SUT" || true)

# ★★対照が対照であることを、撃つ前に機械へ言わせる★★
#   = ★之が無ければ「対照が壊れた」が【緑】の顔で通る★ (初版が現に其の形であった)。
if [ "$OLD_TRAPS" != "0" ]; then
    echo "✘ ★負の対照が trap を ${OLD_TRAPS} 本 持っておる = 対照になっておらぬ★"
    echo "  ⇒ ★判定を打ち切る★ (壊れた対照の上の緑は、何も証さぬ)"
    exit 1
fi
if [ "$NEW_TRAPS" = "0" ]; then
    echo "✘ ★被検体が trap を 1 本も持っておらぬ = 対照と同じ物★ — 判定を打ち切る"
    exit 1
fi
if cmp -s "$OLD" "$SUT"; then
    echo "✘ ★対照と被検体が byte 一致 = 同じ物を二度 撃っておる★ — 判定を打ち切る"
    exit 1
fi
echo "■ 被検体 = $SUT"
echo "■ trap の数: 負の対照=${OLD_TRAPS} (0 であるべき) / 被検体=${NEW_TRAPS}"
echo

# ── NC: 旧版 + SIGTERM → ENDED は出ぬ筈 (試験に刃が在る証) ──
echo "■ NC ★負の対照★ = trap を抜いた版へ SIGTERM"
run_case "nc_old_term" "$OLD" TERM
if grep -q "$MARKER" "$LOGF"; then
    echo "  ✘ NC FAIL: 対照が ENDED を刷った = ★試験が版を見分けておらぬ★"; FAIL=1
else
    echo "  ✔ NC PASS: 対照は名乗らぬ ⇒ ★D1 の緑は trap 由来と言える★"
fi
echo

# ── D1: 新版 + SIGTERM → ENDED が出る筈 ──
echo "■ D1 ★己で畳めば名乗る★ = 新版へ SIGTERM"
run_case "d1_new_term" "$SUT" TERM
if grep -q "$MARKER" "$LOGF"; then
    echo "  ✔ D1 PASS — 実出力:"
    grep "$MARKER" "$LOGF" | sed 's/^/      /'
    if grep -q 'signal=TERM' "$LOGF"; then
        echo "      ✔ signal=TERM を名指しておる (どう死んだかまで言える)"
    else
        echo "      ✘ signal 名が出ておらぬ"; FAIL=1
    fi
else
    echo "  ✘ D1 FAIL: 新版が名乗らなんだ"; FAIL=1
fi
echo

# ── D2: 新版 + SIGKILL → ENDED は出ぬ筈 (= probe が要る証) ──
echo "■ D2 ★SIGKILL では名乗らぬ★ = 新版へ SIGKILL"
run_case "d2_new_kill" "$SUT" KILL
if grep -q "$MARKER" "$LOGF"; then
    echo "  ✘ D2 FAIL: SIGKILL で名乗った = ★あり得ぬゆえ試験の側を疑え★"; FAIL=1
else
    echo "  ✔ D2 PASS: SIGKILL では終いの行が出ぬ"
    echo "      ⇒ ★★『trap が在るゆえ安心』は誤り★★ = 此の族を拾うのは"
    echo "        外から見る口 (idle_revive_scan の lock probe) のみ = ★両方 要る★"
fi
echo

# ── D3: 新版 + 自然終了 → ENDED が【丁度 1 行】出る筈 ──
# ★signal を使わぬ = MAX_CYCLES で己から畳む形★。trap が subshell 毎に鳴いておらぬかを数で見る。
echo "■ D3 ★丁度 1 度だけ名乗る★ = 新版を自然終了させ、ENDED の【数】を見る"
LOGF="$TMP/d3_new_natural.log"
mkdir -p "$TMP/locks_d3"
PATH="$TMP/bin:$PATH" \
SHOGUN_LOCK_DIR="$TMP/locks_d3" \
__WATCHER_SUPERVISOR_TESTING__=1 \
WATCHER_SUPERVISOR_MAX_CYCLES=2 \
WATCHER_DRIFT_DETECT=0 \
timeout 30 bash "$SUT" >"$LOGF" 2>&1
d3_rc=$?
if [ ! -s "$LOGF" ]; then
    echo "  ✘ 計器不良: log が空 or 不在 — 判定を打ち切る"; FAIL=1
else
    d3_n=$(grep -c 'watcher_supervisor ENDED' "$LOGF" || true)
    echo "  (rc=${d3_rc} / ENDED = ${d3_n} 行 / log $(wc -c <"$LOGF") byte)"
    if [ "$d3_n" = "1" ]; then
        echo "  ✔ D3 PASS: 丁度 1 行 ⇒ ★subshell 毎に鳴いてはおらぬ★"
        grep -q 'signal=なし' "$LOGF" \
            && echo "      ✔ 「signal=なし」と正しく名乗っておる (signal 死と区別が付く)" \
            || { echo "      ✘ 自然終了なのに signal 名が付いておる"; FAIL=1; }
    else
        echo "  ✘ D3 FAIL: ENDED が ${d3_n} 行 = ★1 行であるべき★"; FAIL=1
    fi
fi
echo

# ══ 盤面を汚しておらぬ証を【二段】で採る ══
# ★(i) 因果の証 = 己の log に [START] が在るか★ ← ★之が主★
#   ★己が起こしたのでなければ、盤面が動いても己の咎ではない★ =
#   ★数の増減だけでは【誰が増やしたか】を言えぬ★ (初版が現に取り違えた)。
echo "■ (i) ★因果★ = 本試験の全 case log に [START] が在るか (★0 であるべき★)"
started=$(cat "$TMP"/*.log 2>/dev/null | grep -c '\[START\]' || true)
blocked=$(cat "$TMP"/*.log 2>/dev/null | grep -c 'FAKE-NOHUP' || true)
echo "  走査 = $(ls -1 "$TMP"/*.log 2>/dev/null | wc -l) 本の log / [START] = ${started} 件 / 偽 nohup が阻止 = ${blocked} 件"
if [ "$started" = "0" ]; then
    echo "  ✔ ★本試験は watcher も ledger_guard も一体も起こしておらぬ★"
    echo "    (偽 tmux ⇒ pane 不在 / 本番の ledger_guard 生存 ⇒ 「起動せず」の枝)"
else
    echo "  ✘ ★本試験が現に process を起こした★:"; cat "$TMP"/*.log | grep '\[START\]' | sed 's/^/      /'; FAIL=1
fi
echo

# ★(ii) 参考 = 盤面の前後★。★合わぬでも FAIL にせぬ★ =
#   ★本番の supervisor が 5 秒毎に回っており、他所由来の増減が常に起こりうるゆえ★
#   = ★之を FAIL にすれば「己と無縁の赤」を作る (本夜 己の harness で現に踏んだ形)★。
AFTER="$(board_snapshot)"
echo "■ (ii) 事後の盤面 (pid 集合) = $AFTER"
if [ "$BEFORE" = "$AFTER" ]; then
    echo "  ✔ 盤面は前後で一致"
else
    echo "  ▲ 盤面が動いた — ★而して (i) が 0 ゆえ本試験の仕業ではない★"
    echo "      前= $BEFORE"
    echo "      後= $AFTER"
    echo "      (本番 supervisor が 5 秒毎に回っておるゆえ他所由来で動きうる。★判定には使わぬ★)"
fi
echo

if [ "$FAIL" != "0" ]; then
    echo "═══ 総合 = FAIL ═══"; exit 1
fi

# ★★計器が「見えておらぬ」と名乗った時、緑を出すな★★
#   ★之は実害で見つけた穴である★= canary が ★0 件★ と名乗っておるのに
#   総合は PASS を刷っておった (MUT-1408-T4 が現に其れを暴いた)。
#   = ★★「道具が見えぬと申した」と「盤面は綺麗であった」を混ぜておった★★
#     — 本 repo が一晩 狩ってきた形そのものを、四号が己の harness で作っておった。
#   ⇒ ★言えぬ側は緑へ混ぜず UNDETERMINED (非零) へ倒す★
#     (★D1〜NC の四つは【盤面に依らず】成立しておるゆえ、其の旨は併せて刷る★)。
if [ "${BOARD_TRUSTED}" != "1" ]; then
    echo "═══ 総合 = ★UNDETERMINED★ — ★緑ではない★ ═══"
    echo "  ・trap の四つ (D1 / D2 / D3 / NC) は ★成立しておる★ (盤面に依らぬ判定ゆえ)"
    echo "  ・★而して【本試験が盤面を汚しておらぬ】は証せておらぬ★"
    echo "    = 計器 canary が当たらなんだゆえ、空集合を『居らぬ』と読めぬ。"
    echo "  ⇒ ★未検証を緑に混ぜぬため非零で返す★"
    exit 2
fi

echo "═══ 総合 = PASS (D1 / D2 / D3 / NC の四つとも) ═══"; exit 0
