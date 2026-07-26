#!/usr/bin/env bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from>
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5
#
# Exit code contract (cmd_1338): 0 = message written & verified on disk / non-0 = NOT written.
#   Callers MUST NOT ignore a non-zero exit — the message is lost and must be resent.
# NOTE: overflow整理(50件超過時)は「unread全件 + read末尾30件」を残す仕様。
#   ★未読が配列先頭側へ並べ替えられ時系列順でなくなる★が、未読を落とさぬための設計 — 変更禁。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ${N:-} defaults: set -u の下で引数不足時も Usage 分岐へ到達させる (即死させない)
TARGET="${1:-}"
CONTENT="${2:-}"
TYPE="${3:-}"
FROM="${4:-}"

# ── cmd_1363: shell に食われぬ本文の受け口 ────────────────────────────────
# ★本文を二重引用符で渡す限り、shell が inbox_write.sh へ渡す【前に】中身を評価する★
#   (A)`…` (B)$(…) (C)未定義 $VAR は静かに置換され、道具が受け取った時には原文は失われておる。
#   ⇒ 道具の内側では直せぬ。★shell を一切通らぬ経路を用意する★のが本受け口である。
#   同日3人 (足軽四号・五号・家老) が別々に踏んだ実害への手当て。
# 使い方 (第2引数の位置に sentinel を置く):
#   bash scripts/inbox_write.sh karo --body-stdin type from <<'EOF'    ← ★引用符つき heredoc★
#   本文に ` も $(…) も $VAR も書けて、原文どおり届く
#   EOF
#   bash scripts/inbox_write.sh karo --body-file=/path/to/body.txt type from
# ★shell 側の入口は scripts/hooks/shell_expansion_guard.py が見張る (危うい形を止める)★
#   bash scripts/inbox_write.sh karo --content-file /path/body.txt type from
# ★綴りは scripts/shell_expansion_guard.py の BODY_SENTINELS と【必ず一致させよ】★
#   (食い違えば「関所は逃げ道と認めたのに道具は受け取らぬ」= 逃げ場の無い関所になる。
#    一致は guard の selftest が contract 検査で機械で見張る)
_read_body_file() {
    if [ ! -f "$1" ]; then
        echo "[inbox_write] FATAL: 本文 file が読めぬ: $1" >&2
        exit 1
    fi
    cat "$1"
}
# ★どの口から本文が入ったか★ (cmd_1371) — 道具は【必ず】これを知っておる。
#   argv  = shell を通った   (食われた痕跡は残らぬ = 道具側では原理的に検知不能)
#   stdin = shell を通らぬ   (引用符つき heredoc / pipe)
#   file  = shell を通らぬ
# ★末尾改行を守る作法★ (cmd_1371 の実射が拙者の実装欠陥を捕えた)
#   command substitution $(...) は ★末尾の改行を黙って剥がす★。
#   引用符つき heredoc の本文は必ず改行で終わるゆえ、素直に書くと
#   ★「shell を通らぬ安全な口」を名乗りながら、末尾の1文字を黙って落としておった★。
#   = 本 cmd が退けておる「黙って欠ける」の、拙者自身による小型再現である。
#   sentinel 文字を継いでから剥がすことで、原文を1 byte も動かさぬ。
#   ※ _read_body_file が exit 1 する時は sentinel へ到達せぬゆえ set -e が正しく効く。
_slurp_stdin() { cat; printf 'x'; }
IW_VIA="argv"
case "$CONTENT" in
    --stdin|--body-stdin|-)
        CONTENT="$(_slurp_stdin)"; CONTENT="${CONTENT%x}"
        IW_VIA="stdin"
        ;;
    --content-file=*|--body-file=*)
        CONTENT="$(_read_body_file "${CONTENT#*=}"; printf 'x')"; CONTENT="${CONTENT%x}"
        IW_VIA="file"
        ;;
    --content-file|--body-file)
        # 空白区切り形: 本文 file が $3 へ来るゆえ type/from が1つずつ後ろへずれる
        CONTENT="$(_read_body_file "${3:-}"; printf 'x')"; CONTENT="${CONTENT%x}"
        TYPE="${4:-}"
        FROM="${5:-}"
        IW_VIA="file"
        ;;
esac

# ── cmd_1371: ★関所が【此の pane で】生きておるかを測る★ ───────────────────
# ★なぜ要るのか (実測)★ 2026-07-26 の一日で、関所が DENY と判ずる命令 21 件のうち
#   ★19 件がすり抜けた★ (★是正 16:26: 初版 38/2/36 は過大 = file 単位の重複計上と
#   file mtime のみの絞りによる二重の水増し。21 = 2 + 19 で検算済・結論は不変★)。
#   四号の原文を関所へ食わせると DENY = ★関所は正しかった。
#   呼ばれておらなんだだけである★。⇒ 穴は「関所が無いこと」でなく
#   ★【関所が在るのに効いておるか誰も知らぬこと】★ であった。
# ★この検査が答える問い / 答えぬ問い (網の狭さを名乗る)★
#   答える = 「関所は此の pane で走っておるか」
#   答えぬ = 「此の本文が実際に検められたか」
#            (script の内側から本 script を呼ぶ経路を、関所は元より見ておらぬ)
_HB_FRESH_SEC=90
# ★鍵の順は関所側と【必ず揃えよ】★ (cmd_1371 — 実測が拙者の非対称を捕えた)
#   関所は TMUX_PANE → payload の session_id の順で鍵を選ぶ。
#   ★初版の道具は TMUX_PANE しか見ておらなんだ★ ゆえ、tmux pane を持たぬ経路
#   (将軍がまさにそれであった) は ★関所が現に生きておるのに永久に UNPROTECTED★ を
#   名乗る形になっておった = ★常に赤い門は信用されず、必ず外される★ =
#   本日ずっと退けてきた形を、拙者が新しく作りかけておった。
#   実測: 心拍 dir に将軍の session_id 鍵が 329 秒前の心拍を持っておるのに、
#         将軍の 15:20:18 の entry は guard=outside-pane / safety=UNPROTECTED であった。
_guard_key() {
    if [ -n "${TMUX_PANE:-}" ]; then printf '%s' "$TMUX_PANE"; return 0; fi
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf '%s' "$CLAUDE_CODE_SESSION_ID"; return 0; fi
    return 1
}
_guard_state() {
    local key raw ts age
    if ! key="$(_guard_key)"; then
        # tmux pane も session も無い (cron / script / CI) = 関所は元より掛からぬ経路である
        echo "outside-pane"; return 0
    fi
    # ★関所側 (python) の正規化と1文字も違えぬ★ = 綴りが割れれば鍵が割れ、
    #   「関所は心拍を残しておるのに道具は見つけられぬ」= 逃げ場の無い門になる。
    key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-64)"
    local hb="$SCRIPT_DIR/queue/.shell_guard_heartbeat/$key"
    [ -f "$hb" ] || { echo "absent"; return 0; }
    raw="$(cat "$hb" 2>/dev/null || true)"
    ts="${raw%% *}"
    case "$ts" in ''|*[!0-9.]*) echo "unreadable"; return 0 ;; esac
    # ★date +%s で採る★ = awk の systime() は mawk/gawk で在否が割れるゆえ
    #   「道具が環境で黙って別の振舞をする」形を作らぬ。
    age=$(( $(date +%s) - ${ts%%.*} ))
    if [ "$age" -le "$_HB_FRESH_SEC" ]; then echo "live"; else echo "stale"; fi
}
IW_GUARD="$(_guard_state)"

# ★札を三値で決める★ = 未検証を「守られておる」に混ぜぬ (三値化の作法)
#   by-construction = shell を通っておらぬゆえ本穴が原理的に存在せぬ
#   by-guard        = shell を通ったが、関所が此の pane で生きておる
#   UNPROTECTED     = shell を通り、且つ関所が走った証が無い ← 四号が踏んだ形
# ★言葉の線を跨がぬ (家老 2026-07-26 規律「存在は証せるが不在は証せぬ」)★
#   心拍が【在る】= 関所が走ったことの証明 (存在の証明ゆえ堅い)。
#   心拍が【無い】= ★「関所が死んでおる」の証明ではない★ = 走った証を我らが持たぬ、だけである。
#   ⇒ UNPROTECTED は関所の生死についての断定ではなく
#     ★「守られておると我らは言えぬ」★ という、我らの側の申告である。
#     未検証を緑へ混ぜぬため、言えぬ側は赤へ倒す。
if [ "$IW_VIA" != "argv" ]; then
    IW_SAFETY="by-construction"
elif [ "$IW_GUARD" = "live" ]; then
    IW_SAFETY="by-guard"
else
    IW_SAFETY="UNPROTECTED"
fi

# ★強制したい者のための口★ = 既定は off (在走中の全 agent の呼出を壊さぬため)。
#   ★禁ずるのは【黙って配ること】ではなく、この口を立てた者に対しては【危うい口そのもの】★。
if [ "${IW_REQUIRE_SAFE_BODY:-0}" = "1" ] && [ "$IW_VIA" = "argv" ]; then
    echo "[inbox_write] REJECTED: IW_REQUIRE_SAFE_BODY=1 の下では本文を位置引数で渡せぬ" >&2
    echo "[inbox_write]   位置引数 = shell が道具へ渡す【前に】本文を評価する経路ゆえ。" >&2
    echo "[inbox_write]   引用符つき heredoc を使え:" >&2
    echo "[inbox_write]     bash scripts/inbox_write.sh <target> --body-stdin <type> <from> <<'EOF'" >&2
    echo "[inbox_write]     本文をここへ (backtick も ドル記号 も原文どおり届く)" >&2
    echo "[inbox_write]     EOF" >&2
    exit 1
fi

# Deprecated gunshi redirect (write-layer): gunshi/gunshi_a/gunshi_b → active gunshi (Round-robin)
# Ensures ashigaru reports land in active gunshi1/2 inboxes regardless of caller using deprecated name.
case "$TARGET" in
    gunshi|gunshi_a|gunshi_b)
        _LIB="$SCRIPT_DIR/scripts/lib/agent_list.sh"
        if [ -f "$_LIB" ]; then
            # shellcheck source=scripts/lib/agent_list.sh
            . "$_LIB"
            _ACTIVE_GUNSHI=$(get_active_gunshi_agents 2>/dev/null || true)
            if [ -n "$_ACTIVE_GUNSHI" ]; then
                # Round-robin: pick agent with fewest unread messages
                _BEST_TARGET=""
                _BEST_COUNT=999999
                while IFS= read -r _AGENT; do
                    [ -z "$_AGENT" ] && continue
                    _AGENT_INBOX="$SCRIPT_DIR/queue/inbox/${_AGENT}.yaml"
                    if [ -f "$_AGENT_INBOX" ]; then
                        _COUNT=$(grep -c "read: false" "$_AGENT_INBOX" 2>/dev/null || true)
                        _COUNT=${_COUNT:-0}
                    else
                        _COUNT=0
                    fi
                    if [ "$_COUNT" -lt "$_BEST_COUNT" ]; then
                        _BEST_COUNT=$_COUNT
                        _BEST_TARGET=$_AGENT
                    fi
                done <<< "$_ACTIVE_GUNSHI"
                if [ -n "$_BEST_TARGET" ]; then
                    echo "[inbox_write] REDIRECT: deprecated '$TARGET' → '$_BEST_TARGET' (active gunshi, unread=$_BEST_COUNT)" >&2
                    TARGET="$_BEST_TARGET"
                else
                    echo "[inbox_write] WARNING: redirect failed, defaulting '$TARGET' → 'gunshi1'" >&2
                    TARGET="gunshi1"
                fi
            else
                echo "[inbox_write] WARNING: no active gunshi found, defaulting '$TARGET' → 'gunshi1'" >&2
                TARGET="gunshi1"
            fi
        else
            echo "[inbox_write] WARNING: agent_list.sh not found, defaulting '$TARGET' → 'gunshi1'" >&2
            TARGET="gunshi1"
        fi
        ;;
esac

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from>" >&2
    exit 1
fi

# Self-send guard: reject messages where sender == target
if [ "$FROM" = "$TARGET" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Escalate suppression: skip if suppress flag file exists for this sender
SUPPRESS_FLAG="$SCRIPT_DIR/queue/suppress_escalate_${FROM}.flag"
if [ "$TYPE" = "escalate" ] && [ -f "$SUPPRESS_FLAG" ]; then
    echo "[inbox_write] SUPPRESSED: escalate from $FROM suppressed by flag file" >&2
    exit 0
fi

# Initialize inbox if not exists
# dangling symlink recovery: queue/inbox が壊れたシンボリックリンクならリンク先を再生成
_inbox_parent="$(dirname "$INBOX")"
if [ -L "$_inbox_parent" ] && [ ! -d "$_inbox_parent" ]; then
    mkdir -p "$(readlink "$_inbox_parent")"
fi
if [ ! -f "$INBOX" ]; then
    mkdir -p "$_inbox_parent"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-process lock: mkdir coordinates with OpenCode tools; flock is added when available.
LOCK_DIR="${LOCKFILE}.d"

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

# External inputs (content/from/type) and paths MUST NOT be interpolated into the
# python source: a body containing a backslash (e.g. a Windows path C:\Users\...)
# becomes a truncated \UXXXXXXXX escape → SyntaxError → all retries fail (cmd_1345),
# and a body containing ''' escapes the string literal entirely. Pass everything
# via environment variables; the python source below is a fixed single-quoted string.
export IW_INBOX="$INBOX"
export IW_MSG_ID="$MSG_ID"
export IW_FROM="$FROM"
export IW_TIMESTAMP="$TIMESTAMP"
export IW_TYPE="$TYPE"
# ── cmd_1371: ★本文だけは環境変数へ載せぬ★ ──────────────────────────────
# ★規模の層の実測が捕えた欠陥 (cmd_1363 版から在った・拙者が作った物ではない)★
#   本文を export すると、以後この shell が呼ぶ ★全ての外部 command★ の
#   environ に本文が積まれる。本文が 10万字級になると環境が ARG_MAX を越え、
#   ★sleep すら exec できず (Argument list too long)、lock が取れず配達が落ちる★。
#   ⇒ ★長文の本命として我らが勧めておる --content-file / --body-stdin が、
#     まさに長文で壊れる★ = 勧めた逃げ道が新しい穴になっておった。
#   実測: 60,000 字の本文を HEAD 版へ file 経路で渡すと entry 0 件で配達失敗。
#   ⇒ 本文は ★file で渡す★ (path だけを環境変数に載せる)。
#     ★python source へ補間はせぬ★ = cmd_1345 の教訓 (backslash/quote 事故) は不変。
IW_BODY_TMP="$(mktemp "${TMPDIR:-/tmp}/iw_body.XXXXXX")"
_cleanup_body_tmp() { rm -f "$IW_BODY_TMP" 2>/dev/null || true; }
# ★配達に失敗した時だけは本文を残す★ (cmd_1371 — 足軽五号の具申 2026-07-26)
#   ★agent の context は揮発する = 送信前の本文はどこにも永続しておらぬ★。
#   実害で判った: 拙者が本 script を編んでおる最中の窓で五号の3通が落ちた時、
#   ★五号の側にも /clear で原文が残っておらず「そのまま再送」が果たせなんだ★。
#   ⇒ 道具は本文を既に file へ持っておる。★落ちた時に消さねば、再送できる★。
#   成功時は残さぬ (本文が /tmp や repo へ散り続ける方が害ゆえ)。
_preserve_body_on_failure() {
    local dest="$SCRIPT_DIR/queue/.inbox_write_undelivered"
    mkdir -p "$dest" 2>/dev/null || return 0
    local out="$dest/${MSG_ID}.txt"
    cp "$IW_BODY_TMP" "$out" 2>/dev/null || return 0
    echo "[inbox_write] ★送信を試みた本文を残した★: $out" >&2
    echo "[inbox_write]   再送: bash scripts/inbox_write.sh $TARGET --content-file $out $TYPE $FROM" >&2
}
trap _cleanup_body_tmp EXIT
printf '%s' "$CONTENT" > "$IW_BODY_TMP"
export IW_CONTENT_FILE="$IW_BODY_TMP"
# cmd_1371: ★経路の札を entry へ焼く★ = 受け手 (家老) が
#   「此の文は守られた経路で来たのか」を、送り手の申告でなく機械の記録で判別できる。
#   ★stderr へ出すだけでは足りぬ★ = 出力は流れて消え、次に読む者には残らぬ。
export IW_VIA
export IW_GUARD
export IW_SAFETY

# cmd_1355 (軍師束ねQC具申R2): fresh clone には .venv が無い — ★警報を「鳴らす経路」自体が
# 復旧シナリオで落ちると、番人 (idle_revive_scan / gate_nightly) の警報が3回retry後に
# LOST する★。venv 優先・system python3 fallback。限界の正直明示: system python3 に
# PyYAML が無い環境では依然失敗する (その場合も下の FATAL が大声で落ちる=無言 LOST はせぬ)。
IW_PYTHON="$SCRIPT_DIR/.venv/bin/python3"
if [ ! -x "$IW_PYTHON" ]; then
    IW_PYTHON="$(command -v python3 || true)"
    if [ -z "$IW_PYTHON" ]; then
        echo "[inbox_write] FATAL: python3 が見つからぬ (.venv 不在かつ PATH にも無し) — 配達不能" >&2
        exit 1
    fi
    echo "[inbox_write] WARN: .venv 不在 — system python3 ($IW_PYTHON) へ fallback (cmd_1355)" >&2
fi

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        trap '_release_lock; _cleanup_body_tmp' EXIT
        # 書く前の姿を控える (cmd_1363): 本文が変質して届いた時に ★壊れた entry を
        # 残したまま去らぬ★ ため。content 不一致は決定的ゆえ retry しても同じ結果になり、
        # retry すれば同じ id の entry が3つ積まれる = 直す気の穴を新しく開けることになる。
        _IW_BACKUP="$(mktemp "${INBOX}.bak.XXXXXX")"
        cp "$INBOX" "$_IW_BACKUP" 2>/dev/null || true
        if "$IW_PYTHON" -c '
import os, sys, yaml

def _read_body():
    # cmd_1371: 本文は file から読む (環境変数へ載せると長文で exec が壊れる)。
    # errors="surrogateescape" = 旧 os.environ 経由と同じ非UTF8 の扱いを保つ。
    with open(os.environ["IW_CONTENT_FILE"], encoding="utf-8", errors="surrogateescape") as f:
        return f.read()

try:
    inbox = os.environ["IW_INBOX"]

    # Load existing inbox
    with open(inbox) as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get("messages"):
        data["messages"] = []

    # Add new message
    new_msg = {
        "id": os.environ["IW_MSG_ID"],
        "from": os.environ["IW_FROM"],
        "timestamp": os.environ["IW_TIMESTAMP"],
        "type": os.environ["IW_TYPE"],
        "content": _read_body(),
        "read": False,
        # cmd_1371: 本文が入った口と、関所の生死。★UNPROTECTED は黙って消えぬ★
        "via": os.environ.get("IW_VIA", "argv"),
        "guard": os.environ.get("IW_GUARD", "unknown"),
        "safety": os.environ.get("IW_SAFETY", "UNPROTECTED"),
    }
    data["messages"].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data["messages"]) > 50:
        msgs = data["messages"]
        unread = [m for m in msgs if not m.get("read", False)]
        read = [m for m in msgs if m.get("read", False)]
        # Keep all unread + newest 30 read messages
        data["messages"] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox), suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox)
    except:
        os.unlink(tmp_path)
        raise

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
'; then
            STATUS=0
        else
            STATUS=$?
        fi
        # Read-back verify (still under lock): python exit 0 でも実在を確かめる。
        # 書けたつもり事故の最終網 (cmd_1338)。
        # ★cmd_1363 で【中身の突合】へ格上げした★= 旧版は `grep "id: $MSG_ID"` = ★entry が
        #   在ることしか見ておらず、本文が変わって届いても緑であった★。本件 (黙って中身が
        #   変わる) と同じ family の穴が verify 自身に在った形ゆえ、id ではなく
        #   ★content を byte 単位で突合する★。不正 UTF-8 / YAML round-trip 事故もここで落ちる。
        #   ※ shell に食われる口はここでは捕まらぬ (道具に届く前に原文が失われるゆえ) —
        #     それは scripts/hooks/shell_expansion_guard.py の領分である。
        if [ $STATUS -eq 0 ]; then
            # ★`if ! cmd` で受けるな★: then 節の $? は【否定の結果 (=0)】であって
            #   python の終了値ではない = 3 (決定的不一致) を取り落とす。
            #   本 test (V-001) がこの取り落としを実際に捕まえた。ゆえに素直に受ける。
            _VRC=0
            "$IW_PYTHON" -c '
import os, sys, yaml
try:
    with open(os.environ["IW_INBOX"]) as f:
        data = yaml.safe_load(f) or {}
    hit = [m for m in (data.get("messages") or []) if m.get("id") == os.environ["IW_MSG_ID"]]
    if not hit:
        print("entry not found after write", file=sys.stderr); sys.exit(1)
    with open(os.environ["IW_CONTENT_FILE"], encoding="utf-8", errors="surrogateescape") as _bf:
        want = _bf.read()
    got = hit[-1].get("content")
    if got != want:
        print("CONTENT MISMATCH after write (本文が届く途中で変わった)", file=sys.stderr)
        print(f"  wrote(len={len(want)}): {want[:120]!r}", file=sys.stderr)
        print(f"  read (len={len(got) if isinstance(got,str) else got}): {str(got)[:120]!r}", file=sys.stderr)
        sys.exit(3)   # 3 = 決定的な不一致 (retry しても同じ) — 呼び手側で即座に諦める
except SystemExit:
    raise
except Exception as e:
    print(f"VERIFY ERROR: {e}", file=sys.stderr); sys.exit(1)
' || _VRC=$?
            if [ $_VRC -ne 0 ]; then
                if [ $_VRC -eq 3 ]; then
                    # ★決定的な不一致★ = retry しても同じ本文が積まれるだけゆえ即座に諦める。
                    # 壊れた entry を残さぬよう書く前の姿へ戻す (黙って壊れた文を配らぬ)。
                    cp "$_IW_BACKUP" "$INBOX" 2>/dev/null || true
                    rm -f "$_IW_BACKUP"
                    _release_lock; trap _cleanup_body_tmp EXIT
                    echo "[inbox_write] FATAL: 本文が変質して届いた ($MSG_ID) — ★配達を取り消し書込前へ戻した★。" >&2
                    echo "[inbox_write]        送り手は本文を検めて再送せよ (message は配達されておらぬ)。" >&2
                    _preserve_body_on_failure
                    exit 1
                fi
                echo "[inbox_write] VERIFY FAILED: $MSG_ID content mismatch in $INBOX" >&2
                STATUS=1
            fi
        fi
        rm -f "$_IW_BACKUP"
        _release_lock
        trap _cleanup_body_tmp EXIT
        if [ $STATUS -eq 0 ]; then
            # ★OK の行そのものに経路を焼く★ (cmd_1371) = 四号が踏んだのは
            #   ★道具が [OK] を返しながら本文が欠けておった★ 形ゆえ、
            #   ★[OK] を「無条件の安心」として読ませぬ★。
            echo "[inbox_write] OK: $MSG_ID -> $TARGET (経路=$IW_VIA 関所=$IW_GUARD 守り=$IW_SAFETY)" >&2
            if [ "$IW_SAFETY" = "UNPROTECTED" ]; then
                echo "[inbox_write] ★守られておらぬ経路で配った★ — 本文は shell を通り、且つ関所が走った証が無い。" >&2
                echo "[inbox_write]   ⇒ backtick / ドル記号+丸括弧 / 未定義のドル変数 を書いておれば" >&2
                echo "[inbox_write]     ★道具に届く前に消えており、道具にも受け手にも判らぬ★ (痕跡が残らぬゆえ)。" >&2
                echo "[inbox_write]   ⇒ 送った本文を自分の目で読み返せ。以後は引用符つき heredoc を使え:" >&2
                echo "[inbox_write]     bash scripts/inbox_write.sh <target> --body-stdin <type> <from> <<'EOF'" >&2
                echo "[inbox_write]     本文をここへ" >&2
                echo "[inbox_write]     EOF" >&2
            fi
            exit 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] WRITE FAILED for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        fi
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done

# Retry exhausted = message was NOT written. Never fall through silently (cmd_1338).
echo "[inbox_write] FATAL: message NOT delivered to $TARGET after $max_attempts attempts (from=$FROM, type=$TYPE, msg_id=$MSG_ID). Message is LOST — sender must resend or escalate." >&2
_preserve_body_on_failure
exit 1
