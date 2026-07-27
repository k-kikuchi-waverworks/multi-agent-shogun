#!/usr/bin/env bash
# lib/switch_record.sh — ★体が生まれた刻を、機械が読める形で 1 行 落とす★ (cmd_1387)
#
# ━━ 何ゆえ要るか ━━
#   番人 (scripts/idle_revive_scan.py) は「名乗る沈黙 > process の齢」を
#   ★起き直り (crash-loop)★ と読む。★而して我らが撃った切替も、朝の出陣も、
#   全く同じ顔で映る★ = 2026-07-27 14:12〜14:21 に ★三体 (ash1/ash2/ash6) が
#   同時に其の顔で鳴った★ (真因 = 13:59:53 と 14:12:25 の切替)。
#   ⇒ ★番人の【判定】は誤っておらぬ = 誤っておったのは【真因を渡さなんだ事】である★。
#
# ━━ ★書き手を 1 つに保つ理由★ ━━
#   本 file が生まれる前、書き手は switch_cli.sh の中に 1 つだけ在った。
#   出陣 (shutsujin_departure.sh) にも同じ物が要る ⇒ ★写せば 2 つになる★ =
#   ★★形 (列の並び) が黙って割れる日が必ず来る★★ (本日 家中で幾度も狩ってきた族)
#   ⇒ ★源を 1 つに保ち、両者が source する★。
#
# ━━ ★形 (TSV・追記のみ)★ ━━
#   epoch <TAB> iso <TAB> agent <TAB> cli/model <TAB> event
#   ・epoch  … 突合の本体 (読み手は之だけを使う)
#   ・iso    … 人が読む為 (機械は使わぬ)
#   ・event  … ★switch (切替) / boot (出陣)★ = ★読み手が言葉を選ぶ為★
#              ★之が無ければ出陣で生まれた体に「切替が在った」と名乗る事になる★
#   ★追記のみ★= 最後の 1 件だけ持てば「切替の無い日に何通 鳴るか」を後から数えられぬ。
#
# ━━ ★fail-open である (家老 17:31 の枷②)★ ━━
#   ★記録は【添え物】であり、切替も出陣も止めてはならぬ★
#   (出陣が失敗すれば全軍が起きぬ = 本日 最も高い代償)。
#   ⇒ ★書けずとも 0 を返す★・★而して【黙らぬ】= 書けなんだ事を 1 行 名乗る★。
#
# ★呼び方★: record_switch_ts <agent> <cli> <model> [event]   (event 既定 = switch)

# ★呼び手が log() を持たぬ時でも黙らぬ形にする★ (出陣 script は log_info を持つ)。
if ! declare -F _switch_record_log >/dev/null 2>&1; then
    _switch_record_log() {
        if declare -F log >/dev/null 2>&1; then log "$*"
        elif declare -F log_info >/dev/null 2>&1; then log_info "$*"
        else echo "[switch_record] $*" >&2
        fi
    }
fi

record_switch_ts() {
    local agent="$1" cli="$2" model="$3" event="${4:-switch}"
    local root file epoch iso
    # ★在処は呼び手の PROJECT_ROOT を尊ぶ★ (試験が差し替えられる口を残す)。
    root="${SWITCH_RECORD_ROOT:-${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
    file="${SWITCH_HISTORY_FILE:-${root}/queue/state/switch_history.tsv}"
    epoch="$(date '+%s')"
    iso="$(date '+%Y-%m-%dT%H:%M:%S')"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    if ! printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$iso" "$agent" "${cli}/${model}" "$event" \
            >> "$file" 2>/dev/null; then
        _switch_record_log "WARN: 生年の記録を落とせなんだ (${file}) — 番人は此の体の真因を読めぬ"
    fi
    return 0   # ★fail-open★= 呼び手 (切替・出陣) を決して止めぬ
}
