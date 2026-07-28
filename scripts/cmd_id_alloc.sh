#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# cmd_id_alloc.sh — cmd番号の排他払い出しgate (cmd_1333)
#
# 背景: 2026-07-25 に採番衝突が6件発生 (cmd_1322/1324/1326/1328/1330/1331、
#       うち cmd_1331 は同日2度改番)。cmd_1251規律「台帳登録=採番gate」は手順として
#       在るが、将軍と家老が別プロセスで同時採番すると「台帳を読んでから書くまでの窓」
#       で衝突する。本scriptはその窓を flock で閉じ、採番を単一経路へ機械化する。
#       (cmd_1251規律の機械化であり置換ではない)
#
# Usage:
#   予約 (正式採番。払い出しと同時に slim entry schema v2 を台帳へ追記):
#     bash scripts/cmd_id_alloc.sh --title "短名" --origin karo \
#         --project multi-agent-shogun --priority high \
#         [--status pending] [--self-repair true|false] \
#         [--evidence "1行根拠" | --evidence-file <path>] \
#         [--timestamp 'YYYY-MM-DDTHH:MM:SS']
#     → stdout に払い出した id (例: cmd_1334) のみを出力。log は stderr。
#   番号のみ払い出し (cmd_1336 — 緊急の手書き起票・改番の充当先用。台帳へは書かない):
#     bash scripts/cmd_id_alloc.sh --claim --origin <shogun|karo|lord>
#     → 番号を journal に記録して払い出す。entry 本文は呼び出し側が手書きしてよい
#       (番号が gate を通っておれば ledger_guard の手動起票検知は鳴らない)。
#   参照 (予約なし。窓は開いたままゆえ正式採番には使うな):
#     bash scripts/cmd_id_alloc.sh --peek
#   高水位の初期化 (cmd_1466。値は人が明示する。導出はしない — 下の「なぜ導出しないか」):
#     bash scripts/cmd_id_alloc.sh --init-highwater <N>
#
# 払い出し記録 = journal + archive mirror (cmd_1336 / cmd_1341):
#   - reserve / claim の払い出しは queue/.cmd_id_alloc.journal へ1行追記される
#     (形式: cmd_N<TAB>timestamp<TAB>origin=X<TAB>mode=reserve|claim)。
#   - compute_next_id / assert_id_unused は journal も走査する
#     = claim 済みで台帳未記帳の番号を再払い出ししない。
#   - journal 追記は台帳 append より先 (台帳に現れる id は必ず journal 済 =
#     ledger_guard 検知層が script 経由の払い出しを誤検知しない順序保証)。
#     reserve の validate FAIL rollback 時も journal 行は残す (番号焼却=安全側)。
#   - ★cmd_1341 (B-N3): 番号の耐久性は journal 一枚に乗せない★。払い出しと同時に
#     queue/archive/alloc_journal_mirror.yaml へ「- id: cmd_N」行を併記する。
#     archive は compute_next_id / assert_id_unused の union 走査対象ゆえ、
#     ★journal が失われても mirror が番号の再払い出しを防ぐ★ (journal 削除→同番号
#     再払い出しの実証済み穴の封鎖)。journal は「速度 + 検知層突合の cache」であり
#     耐久の正本は mirror (archive = 剪定規律により削除されない領域)。
#
# 高水位 (highwater) = repo の外に置く「払い出した最大の番号」1行 (cmd_1466):
#   上の4点 (台帳・archive・journal・mirror) は全部 repo のディレクトリの中にある。
#   `git clean -xd` は queue/ を丸ごと消すので、4点が同時に無くなる。その後で
#   古い控えから台帳だけ戻しても、払い出しは止まらない。rc=0 で整った entry が並び、
#   既に使った番号をもう一度 払い出してしまう (cmd_1466 で実測 = 台帳を cmd_1099 の
#   控えへ戻したら cmd_1100 を返した。実機なら cmd_1107 以降 約360番が二度 出る)。
#   データが消える場合と害の性質が違う。データは file が無いので気付けるが、
#   番号の再利用は何事もなかったように通るので気付けない。
#
#   そこで「これまでに払い出した最大の番号」だけを repo の外の1行の file に持つ:
#     ${XDG_DATA_HOME:-$HOME/.local/share}/multi-agent-shogun/cmd_id_highwater
#   この置き場にした理由 = queue/inbox が既に同じ場所へ symlink で逃がしてあり、
#   git clean -xd を実際に生き延びる (cmd_1466 で使い捨ての repo に本物を実行して確認)。
#   同じやり方に揃えた。
#
#   払い出しの直前に「これから出す番号 > 高水位」を確かめる。満たさなければ止める
#   = 台帳が古い状態へ巻き戻った証拠。払い出せたら高水位をその番号へ上げる。
#   高水位を上げられなければ番号を出さない (fail-closed)。
#
#   file が無い時は止める (通さない)。「無ければ通す」だと今の穴がそのまま残るため。
#   git clean は高水位まで消さないが、環境が変われば file は無くなりうる。無い時に
#   通す作りだと、いちばん危ない場面で黙って素通りする。初回の1度だけ
#   `--init-highwater <N>` を人が実行する手間と引き換えに、巻き戻りを常に捕まえる。
#
#   なぜ --init-highwater は値を自動で計算しないか (cmd_1466 の item 3):
#   既存の `[ -d "$ARCHIVE_DIR" ]` と同じ穴を作らないため。あの検査は dir があるかだけを
#   見るので、`mkdir -p` を実行されると通ってしまう。同じく、高水位を repo の中から自動で
#   計算すると、巻き戻った状態から巻き戻った値が出て、検知が自分で自分を無効にする。
#   だから N は人が明示する。既にある値を下げる方向へは動かさない。
#
# 採番規則:
#   - 正本 = queue/shogun_to_karo.yaml + queue/archive/ 配下 *.yaml (再帰走査)。
#     union(active + archives) = 全史 invariant — 剪定済entryの番号を再利用しない。
#   - 払い出し = max(既存id) + 1。欠番の穴埋めはしない (履歴の連続性保全)。
#   - id を持たぬ legacy entry / 'cmd_id:' legacy entry は安全に読み飛ばす
#     (Chesterton's Fence — 直そうとしない)。
#
# 台帳保護 (cmd_1255 / feedback_ledger_edit_targeted_only 整合):
#   - 書込は「末尾への追記のみ」。既存 entry は1バイトも書換えない。
#   - 自由文 (title/evidence) は block scalar `|` で書く (半角`: `事故の構造的回避)。
#   - 追記後に scripts/ledger_validate.py で検証し、FAIL なら自分の追記のみを
#     rollback して非0終了 (snapshot は flock 内で取るため他者の書込は失わない)。
#
# lock 流儀: inbox_write.sh と同型 (mkdir 協調 + flock)。lock path は
#   ${LEDGER_FILE}.lock = ledger_guard.sh の LEDGER_LOCK と同一 → guard の
#   検証/rollback とも相互排他になる。
#
# env override (test harness が scratchpad 複製を注入する — ledger_guard.sh と同流儀):
#   LEDGER_FILE / ARCHIVE_DIR / LEDGER_VALIDATOR / LEDGER_PYTHON
#   ALLOC_JOURNAL / ALLOC_JOURNAL_MIRROR / ALLOC_HIGHWATER
#   CMD_ID_ALLOC_RACE_DELAY: read→append の窓を人工的に広げる秒数 (試験専用。本番0)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LEDGER_FILE="${LEDGER_FILE:-$SCRIPT_DIR/queue/shogun_to_karo.yaml}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$SCRIPT_DIR/queue/archive}"
VALIDATOR="${LEDGER_VALIDATOR:-$SCRIPT_DIR/scripts/ledger_validate.py}"
PYTHON="${LEDGER_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
[ -x "$PYTHON" ] || PYTHON="python3"

# cmd_1336: 払い出し記録 (ledger_guard 手動起票検知の突合先。queue/ は git 管理外)
ALLOC_JOURNAL="${ALLOC_JOURNAL:-$SCRIPT_DIR/queue/.cmd_id_alloc.journal}"
# cmd_1341 (B-N3): 耐久mirror。archive 配下 = union走査対象ゆえ journal 喪失でも番号不再利用
ALLOC_MIRROR="${ALLOC_JOURNAL_MIRROR:-$ARCHIVE_DIR/alloc_journal_mirror.yaml}"
# cmd_1466: 高水位 = repo の外の1行。ここだけが git clean -xd で消えない場所にある
ALLOC_HIGHWATER="${ALLOC_HIGHWATER:-${XDG_DATA_HOME:-$HOME/.local/share}/multi-agent-shogun/cmd_id_highwater}"

LOCKFILE="${LEDGER_FILE}.lock"
LOCK_DIR="${LOCKFILE}.d"
LOCK_TIMEOUT_SEC=30
RACE_DELAY="${CMD_ID_ALLOC_RACE_DELAY:-0}"

# id 行の判定regex: indent 制限なし = 過小走査 (→衝突) より過大走査 (→欠番) に倒す。
# block scalar 内自由文の「id: cmd_N」も拾いうるが、max が上振れするだけで安全側。
ID_LINE_RE='^[[:space:]]*-?[[:space:]]*(id|cmd_id):[[:space:]]*["'"'"']?cmd_[0-9]+'

die() {
    echo "[cmd_id_alloc] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[cmd_id_alloc] $*" >&2
}

# ─── lock (inbox_write.sh 同型: mkdir 協調 + flock) ───
_acquire_lock() {
    # TEST-HOOK:LOCK-BEGIN (試験用marker — scratchpad複製でこの区間を除去し衝突を再現する)
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ "$i" -ge $((LOCK_TIMEOUT_SEC * 10)) ] && return 1
    done
    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w "$LOCK_TIMEOUT_SEC" 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    # TEST-HOOK:LOCK-END
    return 0
}

_release_lock() {
    # TEST-HOOK:LOCK-BEGIN
    if command -v flock &>/dev/null; then
        exec 200>&- 2>/dev/null || true
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    # TEST-HOOK:LOCK-END
    return 0
}

# ─── 次番号算出 (union(active+archives) の max + 1) ───
compute_next_id() {
    local max
    max=$(
        {
            grep -hE "$ID_LINE_RE" "$LEDGER_FILE" 2>/dev/null || true
            # find は maxdepth 制限なし (探索漏れ防止)。corrupt_*/backup_* も含めて
            # 全走査 = 広い方が再利用事故に対して厳密に安全。
            find "$ARCHIVE_DIR" -type f -name '*.yaml' -print0 2>/dev/null \
                | xargs -0 -r grep -hE "$ID_LINE_RE" 2>/dev/null || true
            # cmd_1336: claim 済み・台帳未記帳の番号も max に含める (再払い出し防止)
            if [ -f "$ALLOC_JOURNAL" ]; then
                cut -f1 "$ALLOC_JOURNAL" 2>/dev/null || true
            fi
        } \
            | grep -oE 'cmd_[0-9]+' \
            | sed -e 's/^cmd_//' -e 's/^0*\([0-9]\)/\1/' \
            | sort -n | tail -1
    )
    [ -n "$max" ] || return 1
    echo $((max + 1))
}

# ─── 二重払い出しの最終防衛 (scan bug 検知。max+1 なら通常ヒットしない) ───
# 注: exit code 判定は使わない (空 archive dir だと xargs が何も実行せず exit 0 に
# なり「該当あり」と誤判定する)。hit 行そのものを収集して判定する。
assert_id_unused() {
    local candidate="$1"
    local hit_re="^[[:space:]]*-?[[:space:]]*(id|cmd_id):[[:space:]]*[\"']?cmd_0*${candidate}([^0-9]|[\"']|\$)"
    local hits
    hits=$(
        {
            grep -hE "$hit_re" "$LEDGER_FILE" 2>/dev/null || true
            find "$ARCHIVE_DIR" -type f -name '*.yaml' -print0 2>/dev/null \
                | xargs -0 -r grep -hE "$hit_re" 2>/dev/null || true
            # cmd_1336: journal 上の claim/reserve 済み番号も「使用済」扱い
            if [ -f "$ALLOC_JOURNAL" ]; then
                grep -hE "^cmd_0*${candidate}([^0-9]|\$)" "$ALLOC_JOURNAL" 2>/dev/null || true
            fi
        } | head -1
    )
    [ -z "$hits" ]
}

# ─── cmd_1336/cmd_1341: 払い出し記録の追記。記録できぬ番号は払い出さない (fail-closed) ───
journal_record() {
    local id="$1" mode="$2"
    printf '%s\t%s\torigin=%s\tmode=%s\n' "$id" "$TIMESTAMP" "$ORIGIN" "$mode" \
        >> "$ALLOC_JOURNAL" \
        || die "journal 追記失敗 ($ALLOC_JOURNAL)。記録できぬ番号は払い出さない (fail-closed)"
    # cmd_1341 (B-N3): 耐久mirror へ併記。「- id: cmd_N」形式 = compute_next_id /
    # assert_id_unused の ID_LINE_RE に合致するゆえ、journal が消えても番号は焼却済のまま。
    printf -- '- id: %s  # %s origin=%s mode=%s (alloc mirror)\n' \
        "$id" "$TIMESTAMP" "$ORIGIN" "$mode" \
        >> "$ALLOC_MIRROR" \
        || die "alloc mirror 追記失敗 ($ALLOC_MIRROR)。記録できぬ番号は払い出さない (fail-closed)"
}

# ─── cmd_1466: 高水位の読み書き (repo の外の1行) ───
# 返り値で3つの状態を分ける。「file が無い」と「読めぬ」を同じ扱いにしない。
# どちらも0として扱うと、空の file を置くだけで検知を外せてしまう
# (archive dir の存在検査と同じ穴になる)。
#   rc=0 → stdout に整数 / rc=1 → file が無い / rc=2 → 在るが整数を読み取れぬ
read_highwater() {
    [ -f "$ALLOC_HIGHWATER" ] || return 1
    local first val
    first="$(head -1 "$ALLOC_HIGHWATER" 2>/dev/null || true)"
    val="${first%%[$' \t']*}"
    case "$val" in
        ''|*[!0-9]*) return 2 ;;
    esac
    # 先頭0を落とす (008 → 8)。空にはしない
    val="$(printf '%s' "$val" | sed -e 's/^0*\([0-9]\)/\1/')"
    printf '%s' "$val"
    return 0
}

# 高水位を書く (tmp へ書いて mv = 途中で落ちても壊れた中身が残らない)。中身は1行だけ。
# file 自身に「下げるな」を書き添える。中身を開いた人が、値だけ見て手で書き替えるのを
# 思い止まる手掛かりになる。
write_highwater() {
    local num="$1" note="$2" dir tmp
    dir="$(dirname "$ALLOC_HIGHWATER")"
    mkdir -p "$dir" 2>/dev/null || return 1
    tmp="$(mktemp "${dir}/.cmd_id_highwater.XXXXXX" 2>/dev/null)" || return 1
    printf '%s\t%s\torigin=%s\t%s\t# cmd番号の高水位 (cmd_1466)。手で下げないこと — 下げると番号の二度払い出しが黙って通る\n' \
        "$num" "$TIMESTAMP" "${ORIGIN:-unknown}" "$note" > "$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    mv -f "$tmp" "$ALLOC_HIGHWATER" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    return 0
}

# 台帳が古い状態へ巻き戻っていないかの検査。払い出しの直前に呼ぶ
assert_not_rewound() {
    local candidate="$1" hw rc
    hw="$(read_highwater)" && rc=0 || rc=$?
    case "$rc" in
        1)
            die "高水位 file が無い ($ALLOC_HIGHWATER)。番号を払い出さずに止まる (fail-closed)。
  これは「初回」か「repo の外の控えごと失った」かのどちらか。通さないのは後者を捕まえるため。
  据える手順 = bash scripts/cmd_id_alloc.sh --init-highwater <これまでに払い出した最大の番号>
  N は台帳/archive/journal から自動で計算しない (巻き戻った状態から巻き戻った値が出るため)。
  N を決める時は台帳・archive・journal・mirror だけでなく、queue/inbox・plans/・dashboard・
  git log など repo の外や履歴に残る記録も併せて見て、いちばん大きい番号を人が判断して渡す。"
            ;;
        2)
            die "高水位 file を読めぬ ($ALLOC_HIGHWATER)。先頭行の1つ目の欄が整数でない。
  空の file や壊れた中身を0として扱わない (0扱いにすると空 file を置くだけで検知を外せる)。
  中身を確かめ、正しい値で --init-highwater を実行し直すこと。"
            ;;
    esac
    if [ "$candidate" -le "$hw" ]; then
        die "台帳が古い状態へ巻き戻っている疑いがある — 払い出そうとした番号 cmd_${candidate} が高水位 cmd_${hw} 以下。
  台帳・archive・journal・mirror は全て queue/ の下にあり、git clean -xd 一手で同時に消える。
  古い控えから戻すと払い出しは止まらず、既に使った番号を黙ってもう一度 出してしまう (cmd_1466 で実測)。
  高水位 = $ALLOC_HIGHWATER (repo の外にあるので、その一手では消えない)。
  やること = ①台帳/archive/journal/mirror が巻き戻っていないかを先に確かめる
            ②本当に復旧が正しく、高水位の方が古いと判断したなら --init-highwater で上げる
  高水位を下げて通してはいけない。番号が二度 払い出される。"
    fi
    HIGHWATER_NOW="$hw"
}

# ─── block scalar 整形: 全行に4space indent (空行は素通し) ───
indent4() {
    awk '{ if ($0 == "") print ""; else print "    " $0 }'
}

usage() {
    # 綴りで指す (行番号で焼かない — 次に誰かが註を足した瞬間に別の行を指すため)
    awk '/^# Usage:/{f=1} f && /^# 払い出し記録/{exit} f{print}' "${BASH_SOURCE[0]}" >&2
    exit 2
}

# ─── 引数解析 ───
MODE="reserve"
TITLE=""
ORIGIN=""
PROJECT=""
PRIORITY=""
STATUS="pending"
EVIDENCE=""
EVIDENCE_FILE=""
SELF_REPAIR=""
TIMESTAMP=""
INIT_HIGHWATER=""
HIGHWATER_NOW=""

while [ $# -gt 0 ]; do
    case "$1" in
        --peek) MODE="peek"; shift ;;
        --claim) MODE="claim"; shift ;;
        # 値が無い時に `shift 2` すると set -e で何も表示せずに落ちる (既存のオプションと同じ形)。
        # このオプションは人が手で実行する復旧用なので、必ず理由を表示してから止める。
        --init-highwater)
            MODE="init_highwater"; INIT_HIGHWATER="${2:-}"; shift
            [ $# -gt 0 ] && shift || true
            ;;
        --title) TITLE="${2:-}"; shift 2 ;;
        --origin) ORIGIN="${2:-}"; shift 2 ;;
        --project) PROJECT="${2:-}"; shift 2 ;;
        --priority) PRIORITY="${2:-}"; shift 2 ;;
        --status) STATUS="${2:-}"; shift 2 ;;
        # cmd_1475: 起票の時点で「自己修正か」を記録する。
        # 後から推測で判定すると、殿が誤った物を承認なさる。書けるのは起票する本人だけである。
        --self-repair) SELF_REPAIR="${2:-}"; shift 2 ;;
        --evidence) EVIDENCE="${2:-}"; shift 2 ;;
        --evidence-file) EVIDENCE_FILE="${2:-}"; shift 2 ;;
        --timestamp) TIMESTAMP="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1 (--help for usage)" ;;
    esac
done

# ─── cmd_1466: 高水位の初期化。台帳/archive の検査より前に置く ───
# 理由 = 据え直しが必要になるのは、まさに台帳も archive も消えた後だから。
# repo の中の状態に依存させると、いちばん必要な場面で使えない道具になる。
if [ "$MODE" = "init_highwater" ]; then
    case "$INIT_HIGHWATER" in
        ''|*[!0-9]*) die "--init-highwater <N> の N は整数で明示せよ (got: '${INIT_HIGHWATER}')。
  台帳や journal から自動で計算はしない = 巻き戻った状態から巻き戻った値を作らないため。" ;;
    esac
    INIT_HIGHWATER="$(printf '%s' "$INIT_HIGHWATER" | sed -e 's/^0*\([0-9]\)/\1/')"
    [ "$INIT_HIGHWATER" -gt 0 ] || die "--init-highwater の N は1以上であること (got: $INIT_HIGHWATER)"
    TIMESTAMP="${TIMESTAMP:-$(date '+%Y-%m-%dT%H:%M:%S')}"
    ORIGIN="${ORIGIN:-manual}"

    cur="$(read_highwater)" && cur_rc=0 || cur_rc=$?
    if [ "$cur_rc" = "0" ]; then
        if [ "$INIT_HIGHWATER" -lt "$cur" ]; then
            die "高水位を下げようとしている (今 $cur → 指定された値 $INIT_HIGHWATER)。下げない。
  下げると cmd_$((INIT_HIGHWATER + 1)) から cmd_${cur} までが二度 払い出される。
  本当に下げるべきと判断したなら、その理由を書き残した上で $ALLOC_HIGHWATER を手で書き替えること
  (この script は下げる口を持たない = 事故で下がらないようにするため)。"
        fi
        log "高水位を上げる: $cur → $INIT_HIGHWATER"
    elif [ "$cur_rc" = "1" ]; then
        log "高水位 file が無いので新しく据える: $INIT_HIGHWATER ($ALLOC_HIGHWATER)"
    else
        log "WARN: 今の高水位 file を読めぬ (第1欄が整数でない)。指した値で上書きする: $INIT_HIGHWATER"
    fi

    write_highwater "$INIT_HIGHWATER" "mode=init" \
        || die "高水位を書けぬ ($ALLOC_HIGHWATER)。置き場の権限と親 dir を検めよ"
    log "高水位を据えた: cmd_${INIT_HIGHWATER} → $ALLOC_HIGHWATER"
    echo "$INIT_HIGHWATER"
    exit 0
fi

[ -f "$LEDGER_FILE" ] || die "ledger not found: $LEDGER_FILE"
[ -d "$ARCHIVE_DIR" ] || die "archive dir not found: $ARCHIVE_DIR (union(active+archives)=全史 invariant を守れないため fail-closed)"
case "$RACE_DELAY" in
    ''|*[!0-9.]*) die "CMD_ID_ALLOC_RACE_DELAY must be numeric: $RACE_DELAY" ;;
esac

if [ "$MODE" = "reserve" ]; then
    [ -n "$TITLE" ] || die "--title is required (slim entry schema v2 必須field)"
    [ -n "$ORIGIN" ] || die "--origin is required (shogun|karo|lord)"
    [ -n "$PROJECT" ] || die "--project is required"
    [ -n "$PRIORITY" ] || die "--priority is required"
    case "$ORIGIN" in
        shogun|karo|lord) ;;
        *) die "--origin must be shogun|karo|lord (got: $ORIGIN)" ;;
    esac
    case "$STATUS" in
        pending|in_progress|deferred|done|superseded|archived|dispatched|cancelled) ;;
        *) die "--status must be in schema v2 正規語彙 (got: $STATUS)" ;;
    esac
    printf '%s' "$PROJECT" | grep -qE '^[A-Za-z0-9._-]+$' \
        || die "--project must match [A-Za-z0-9._-]+ (got: $PROJECT)"
    printf '%s' "$PRIORITY" | grep -qE '^[a-z][a-z_-]*$' \
        || die "--priority must match [a-z][a-z_-]* (got: $PRIORITY)"

    # cmd_1475: 自己修正かどうか。指定しなければ欄を書かない (= 未記入)。
    # 未記入を false と読ませないため、既定値を勝手に入れない。
    case "$SELF_REPAIR" in
        ''|true|false) ;;
        *) die "--self-repair must be true|false (got: $SELF_REPAIR)。
  true  = この仕組み自身の改修 (殿の承認が要る)
  false = 殿の指令そのもの
  省略  = 未記入 (後から scripts/cmd_approval.py で書ける)" ;;
    esac

    if [ -n "$EVIDENCE_FILE" ]; then
        [ -f "$EVIDENCE_FILE" ] || die "--evidence-file not found: $EVIDENCE_FILE"
        [ -n "$EVIDENCE" ] && die "--evidence と --evidence-file は同時指定不可"
        EVIDENCE="$(cat "$EVIDENCE_FILE")"
    fi
    [ -n "$EVIDENCE" ] || die "--evidence または --evidence-file が必須 (schema v2 必須field)"

    # CRLF 混入は block scalar 内に \r を残すため除去 (改行コードLF規律)
    TITLE="$(printf '%s' "$TITLE" | tr -d '\r')"
    EVIDENCE="$(printf '%s' "$EVIDENCE" | tr -d '\r')"

    # block scalar は先頭行の indent で内容境界を自動検出する。先頭行が空白始まりだと
    # 誤検出で parse 破損しうるため fail-closed (整形して再投入せよ)。
    printf '%s' "$TITLE" | head -1 | grep -qE '^[[:space:]]' \
        && die "--title の先頭行が空白始まり (block scalar 制約)。整形して再実行せよ"
    printf '%s' "$EVIDENCE" | head -1 | grep -qE '^[[:space:]]' \
        && die "--evidence の先頭行が空白始まり (block scalar 制約)。整形して再実行せよ"

    if [ -n "$TIMESTAMP" ]; then
        printf '%s' "$TIMESTAMP" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?$' \
            || die "--timestamp must be YYYY-MM-DDTHH:MM[:SS] (got: $TIMESTAMP)"
    else
        TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S')"   # 実測 (推測禁 規律)
    fi
fi

# cmd_1336: claim = 番号のみ払い出し (journal 記録あり・台帳へは書かない)
if [ "$MODE" = "claim" ]; then
    [ -n "$ORIGIN" ] || die "--origin is required (shogun|karo|lord)"
    case "$ORIGIN" in
        shogun|karo|lord) ;;
        *) die "--origin must be shogun|karo|lord (got: $ORIGIN)" ;;
    esac
    if [ -n "$TIMESTAMP" ]; then
        printf '%s' "$TIMESTAMP" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?$' \
            || die "--timestamp must be YYYY-MM-DDTHH:MM[:SS] (got: $TIMESTAMP)"
    else
        TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S')"
    fi
fi

# ─── 本体: lock 下で 読み→採番→(予約なら)追記→検証 を一括実行 ───
_acquire_lock || die "lock acquisition failed after ${LOCK_TIMEOUT_SEC}s ($LOCK_DIR が stale なら手で除去せよ)"
trap _release_lock EXIT

NEXT_NUM="$(compute_next_id)" || {
    die "id scan returned empty — ledger path 誤り疑い ($LEDGER_FILE)。fail-closed で採番しない"
}
assert_id_unused "$NEXT_NUM" || die "invariant breach: cmd_${NEXT_NUM} は既に台帳/archiveに存在する (scan bug 疑い。採番中止)"
# cmd_1466: repo の外の高水位と突き合わせる。上の2つの検査はどちらも repo の中しか見ないので、
# repo ごと巻き戻ると揃って黙る。この検査だけが repo の外を見る。peek も同じ検査を通す
# = 巻き戻った状態で「次の空き番号」を平然と答えさせないため。
assert_not_rewound "$NEXT_NUM"

# 試験専用: read→append の窓を人工的に広げる (lock が本当に閉じているかの実証用)
if [ "$RACE_DELAY" != "0" ]; then
    sleep "$RACE_DELAY"
fi

NEW_ID="cmd_${NEXT_NUM}"

if [ "$MODE" = "peek" ]; then
    log "peek: 次の空き番号は $NEW_ID (★予約していない。正式採番は予約モードで行え★)"
    echo "$NEW_ID"
    exit 0
fi

# cmd_1336: 払い出しは journal 記録が先 (台帳に現れる id は必ず journal 済の順序保証。
# peek は上で exit 済 = 記録しない)
journal_record "$NEW_ID" "$MODE"

# cmd_1466: repo の外の高水位を上げる。上げられなければ番号を出さない (fail-closed)。
# journal/mirror と同じやり方。その番号は使用済みとして残るので、安全な側に倒れる。
write_highwater "$NEXT_NUM" "mode=$MODE" \
    || die "高水位を書けぬ ($ALLOC_HIGHWATER)。記録できない番号は払い出さない (fail-closed)。
  repo の外の置き場が消えているか、書き込めない状態。ここが動かないと巻き戻り検知が止まる。"

if [ "$MODE" = "claim" ]; then
    _release_lock
    trap - EXIT
    log "claimed: $NEW_ID (journal記録のみ・台帳へは未記帳。entry本文は手書きしてよいが id は本番号を使え)"
    echo "$NEW_ID"
    exit 0
fi

# ─── 予約 = slim entry schema v2 (必須8field) を末尾追記 ───
SNAP="$(mktemp "${TMPDIR:-/tmp}/cmd_id_alloc_snap.XXXXXX")"
cleanup_snap() { rm -f "$SNAP" 2>/dev/null || true; }

# cmd_1341 (B-N2): rollback 前に現状版を quarantine (ledger_guard.sh と同じ流儀 =
# queue/archive/corrupt_shogun_to_karo_<ts>.yaml へ非破壊退避)。
# snapshot→validate の窓 (~0.2s) に gate 非経由の書き手 (家老の Edit 等) が追記して
# いた場合、cp "$SNAP" はその追記ごと消す。quarantine が在れば中身を復元できる。
quarantine_before_rollback() {
    local ts quar
    ts="$(date '+%Y%m%d%H%M%S')_$$"
    quar="$ARCHIVE_DIR/corrupt_shogun_to_karo_${ts}.yaml"
    if cp "$LEDGER_FILE" "$quar" 2>/dev/null; then
        log "quarantine: rollback前の台帳を退避 → $quar (他者の並行追記が在れば其処から復元できる)"
    else
        log "WARN: quarantine copy failed ($quar) — rollback は続行する"
    fi
}

cp -p "$LEDGER_FILE" "$SNAP" 2>/dev/null || cp "$LEDGER_FILE" "$SNAP"
SNAP_SIZE="$(stat -c%s "$SNAP" 2>/dev/null || wc -c < "$SNAP")"

# 末尾が改行で終わらぬ場合のみ改行を1byte追記 (既存byteは不変)
if [ "$(tail -c1 "$LEDGER_FILE" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$LEDGER_FILE"
fi

{
    printf -- '- id: %s\n' "$NEW_ID"
    printf '  title: |\n'
    printf '%s\n' "$TITLE" | indent4
    printf '  origin: %s\n' "$ORIGIN"
    printf '  status: %s\n' "$STATUS"
    printf '  project: %s\n' "$PROJECT"
    printf '  priority: %s\n' "$PRIORITY"
    printf "  timestamp: '%s'\n" "$TIMESTAMP"
    # cmd_1475: 自己修正と名乗った時だけ、承認待ちとして起こす (殿の裁可を待つ形)
    if [ -n "$SELF_REPAIR" ]; then
        printf '  self_repair: %s\n' "$SELF_REPAIR"
        [ "$SELF_REPAIR" = "true" ] && printf '  approval: awaiting\n'
    fi
    printf '  evidence: |\n'
    printf '%s\n' "$EVIDENCE" | indent4
} >> "$LEDGER_FILE"

# 自己検証①: 既存部分が1byteも変わっていないこと (追記のみ保証)
if ! cmp -s -n "$SNAP_SIZE" "$SNAP" "$LEDGER_FILE"; then
    quarantine_before_rollback
    cp "$SNAP" "$LEDGER_FILE"
    cleanup_snap
    die "追記のはずが既存部分が変化した — rollback した (quarantine に退避済。手で調査せよ)"
fi

# 自己検証②: 台帳全体が parse+schema PASS すること (ledger_guard と同じ validator)
if ! "$PYTHON" "$VALIDATOR" "$LEDGER_FILE"; then
    quarantine_before_rollback
    cp "$SNAP" "$LEDGER_FILE"
    cleanup_snap
    die "追記後の ledger_validate FAIL — 自分の追記を rollback した (quarantine に退避済)。入力の自由文を確認せよ"
fi

cleanup_snap
_release_lock
trap - EXIT

log "reserved: $NEW_ID (slim entry v2 を台帳へ追記済・validate PASS)"
echo "$NEW_ID"
