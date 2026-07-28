#!/usr/bin/env bash
# backup_freshness_check.sh — 控えが「いつ最後に成功したか」を見る (cmd_1439)
#
# なぜ在るか:
#   殿の資産を守る定時実行が黙って止まっても、誰も気づかない状態だった。
#   掃除タスク (\AituberDvcGc) は 2026-05-15 を最後に 74 日 落ち続け、誰も気づかなかった。
#   控えタスク (\AituberFBackupToD) はもっと悪く、成功も失敗もディスクへ 1 バイトも
#   残していなかった。唯一の証は Windows の定時タスクの「前回の結果」1 欄だけで、
#   次の実行で上書きされる。ゆえに落ちた後に「いつから落ちていたか」を数えられなかった。
#
# この検査が答えること / 答えないこと:
#   答える = 「最後に成功したのは何日 前か」
#   答えない = 「控えの中身が正しいか」。日時が新しくても、中身が壊れている見込みは残る。
#
# 記録の置き場を F: にしない理由:
#   この記録が答える問いは「F: が飛んだ時に、控えは何日 前か」である。
#   F: に置くと、答えるべき事故で記録も一緒に消える。D: も控えの送り先ゆえ同じ理由で避ける。
#   よって C: の repo 側へ置く。読む側 (この script) も C: に居るので、読む時に F:/D: へ触らない。
#
# 記録が無い時は「鳴る」側に倒す:
#   「無い」を「新しい」と読むと、今日 見つけた穴がそのまま残るため。
#
# rc: 0 = すべて新しい / 1 = 古いか、無い / 2 = 測れなかった
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# 試験で差し替えられるよう、外から与えられる形にしてある。
BACKUP_STATE_FILE="${BACKUP_STATE_FILE:-$REPO_DIR/logs/last_backup_f_to_d.txt}"
DVCGC_STATE_FILE="${DVCGC_STATE_FILE:-/mnt/f/aituber-project-ml/maintenance/last_dvc_gc.txt}"
DVCGC_MIRROR_FILE="${DVCGC_MIRROR_FILE:-$REPO_DIR/logs/last_dvc_gc_mirror.txt}"
BACKUP_MAX_AGE_DAYS="${BACKUP_MAX_AGE_DAYS:-2}"   # 毎日 2:00 に走るので、2 日 空けば異常
DVCGC_MAX_AGE_DAYS="${DVCGC_MAX_AGE_DAYS:-4}"     # 2 日ごとに走るので、4 日 空けば異常
NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"             # 試験で「今」を差し替えるため

rc=0

# 記録の中身 (yyyy-mm-dd HH:MM:SS) を秒へ直す。読めなければ空を返す。
#
# 先頭の BOM を落とす理由 (cmd_1439 で現に踏んだ):
#   書く側は Windows PowerShell 5.1 の Set-Content -Encoding UTF8 で、
#   ★この版は必ず先頭へ UTF-8 BOM (ef bb bf) を付ける★。
#   落とさないと date -d が日時と読めず、控えが現に成功した朝でも
#   「読めない」と出る。つまり ★正しく動いている時ほど嘘を返す★。
#   CR を落とすだけでは足りない (BOM は行末でなく行頭に付くため)。
age_days_of() {
    local file="$1" stamp epoch
    stamp="$(head -n1 "$file" 2>/dev/null | sed '1s/^\xef\xbb\xbf//' | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$stamp" ] && return 1
    epoch="$(date -d "$stamp" +%s 2>/dev/null)" || return 1
    echo $(( (NOW_EPOCH - epoch) / 86400 ))
}

# --- 1. 控え (F: → D:) ---
if [ ! -f "$BACKUP_STATE_FILE" ]; then
    echo "[BACKUP-MISSING] 控えの成功記録が無い ($BACKUP_STATE_FILE)。一度も成功していないか、記録を書く前の版で走っている"
    rc=1
elif ! age="$(age_days_of "$BACKUP_STATE_FILE")"; then
    echo "[BACKUP-UNREADABLE] 控えの成功記録を読めない ($BACKUP_STATE_FILE)。中身が想定の形でない"
    [ "$rc" -eq 0 ] && rc=2
elif [ "$age" -gt "$BACKUP_MAX_AGE_DAYS" ]; then
    echo "[BACKUP-STALE] 控えが ${age} 日 前から成功していない (許容 ${BACKUP_MAX_AGE_DAYS} 日)"
    rc=1
else
    echo "[BACKUP-OK] 控えは ${age} 日 前に成功"
fi

# --- 2. 掃除 (dvc gc) ---
# F: の現物が読めれば、それを C: 側へ写しておく。
# F: が飛んだ後に「最後にいつ掃除したか」を答えられるようにするため。
dvcgc_src=""
if [ -f "$DVCGC_STATE_FILE" ] && [ -r "$DVCGC_STATE_FILE" ]; then
    dvcgc_src="$DVCGC_STATE_FILE"
    mkdir -p "$(dirname "$DVCGC_MIRROR_FILE")" 2>/dev/null
    cp "$DVCGC_STATE_FILE" "$DVCGC_MIRROR_FILE" 2>/dev/null || true
elif [ -f "$DVCGC_MIRROR_FILE" ]; then
    dvcgc_src="$DVCGC_MIRROR_FILE"
    echo "[DVCGC-SOURCE] F: の現物を読めないので、C: 側の写しで判じた ($DVCGC_MIRROR_FILE)"
fi

if [ -z "$dvcgc_src" ]; then
    echo "[DVCGC-MISSING] 掃除の成功記録が、F: にも C: の写しにも無い"
    rc=1
elif ! age="$(age_days_of "$dvcgc_src")"; then
    echo "[DVCGC-UNREADABLE] 掃除の成功記録を読めない ($dvcgc_src)"
    [ "$rc" -eq 0 ] && rc=2
elif [ "$age" -gt "$DVCGC_MAX_AGE_DAYS" ]; then
    echo "[DVCGC-STALE] 掃除が ${age} 日 前から成功していない (許容 ${DVCGC_MAX_AGE_DAYS} 日)"
    rc=1
else
    echo "[DVCGC-OK] 掃除は ${age} 日 前に成功"
fi

# この検査が覆っていない範囲 (緑の時も出す = 緑の大きさを名乗るため)
echo "[射程] 見たのは「最後に成功した日時」だけ。控えの中身が正しいかは見ていない。"
echo "[射程] この検査は gate_nightly の中で走る。gate_nightly 自身が走らなくなった時は、誰も気づかない。"

exit "$rc"
