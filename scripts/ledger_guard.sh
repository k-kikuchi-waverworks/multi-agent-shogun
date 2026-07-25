#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# ledger_guard.sh — 台帳(shogun_to_karo.yaml)parse自己検証gate(常駐watcher)
# cmd_1255 / 軍師一号設計正本 plans/cmd_1255_ledger_parse_gate_design.md §(d) 忠実準拠。
#
# 事故: 2026-07-11 家老がevidence自由文編集で「半角コロン+空白」混入→YAML入れ子
#       mapping誤認→台帳全体parse失敗→殿のengine backlog view(SHOGUN_QUEUE_ROOT)死亡。
#
# 設計: 書込側に挟むwrapper(案a)はLLMのEdit直書きをバイパスできず規律忘却で穴が開く。
#       → 「書込後を監視する」watcher(案d)だけが書き手非依存で100%coverできる。
#
# 動作:
#   inotifywait(close_write,moved_to) → debounce ~2s → flock下でledger_validate.py実行
#     PASS → .last_good snapshot 更新(★台帳への書込は一切しない=正常系副作用ゼロ★) + log
#            + cmd_1336: 手動起票検知(採番gate非経由entryをjournal突合で検知→家老へ警告のみ)
#     FAIL → ①破損版を queue/archive/corrupt_shogun_to_karo_<ts>.yaml へquarantine(非破壊)
#            ②.last_good を台帳へ復元(rollback)  ※.last_good不在時はrollbackせず警告のみ
#            ③家老inboxへ警告emit(inbox_write.sh ... error ledger_guard)
#            ④logs/ledger_guard.log へ詳細
#   起動時: 現台帳を検証。PASSなら.last_good初期化 / FAILなら★警告のみ(rollback禁=安全側)★。
#
# 既存idiom流用: scripts/inbox_watcher.sh(inotifywait) / scripts/inbox_write.sh(flock+警告) /
#               scripts/slim_yaml.py(SHOGUN_QUEUE_DIR override / .venv python)。
#
# ─── Testing guard ───
# __LEDGER_GUARD_TESTING__=1 のとき関数定義のみ load(引数解析/inotifywait/main loop をskip)。
# test は tmp copy の台帳に対し startup_check / run_guard_check を直接呼んで検証する
# (★実台帳 queue/shogun_to_karo.yaml には一切触れない harness★)。
# ═══════════════════════════════════════════════════════════════

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Config (env overridable — test harness が tmp path を注入する) ───
QUEUE_DIR="${SHOGUN_QUEUE_DIR:-$SCRIPT_DIR/queue}"
LEDGER_FILE="${LEDGER_FILE:-$QUEUE_DIR/shogun_to_karo.yaml}"
LAST_GOOD_FILE="${LAST_GOOD_FILE:-$QUEUE_DIR/.shogun_to_karo.last_good}"
QUARANTINE_DIR="${QUARANTINE_DIR:-$QUEUE_DIR/archive}"
LEDGER_LOCK="${LEDGER_LOCK:-$LEDGER_FILE.lock}"
LOG_FILE="${LEDGER_GUARD_LOG:-$SCRIPT_DIR/logs/ledger_guard.log}"
VALIDATOR="${LEDGER_VALIDATOR:-$SCRIPT_DIR/scripts/ledger_validate.py}"
DEBOUNCE_SEC="${LEDGER_DEBOUNCE_SEC:-2}"

# venv python (PyYAML入り)。無ければ system python3 fallback。
PYTHON="${LEDGER_PYTHON:-$SCRIPT_DIR/.venv/bin/python3}"
[ -x "$PYTHON" ] || PYTHON="python3"

# 家老警告emit経路。test では tmp shim を差し込んで実inboxを汚さない。
INBOX_WRITE="${LEDGER_GUARD_INBOX_WRITE:-$SCRIPT_DIR/scripts/inbox_write.sh}"

# ─── cmd_1336: 手動起票検知層 config (★警告のみ・rollback/quarantine 経路に不干渉★) ───
# ALLOC_JOURNAL   = cmd_id_alloc.sh の払い出し記録 (突合先)
# BASELINE        = 検知層導入時点の最大id (それ以前の既存entryはgrandfather=誤警告しない)
# WARNED          = 警告済みid (同一idへの警告は一度のみ=家老spam防止)
ALLOC_JOURNAL="${ALLOC_JOURNAL:-$QUEUE_DIR/.cmd_id_alloc.journal}"
MANUAL_ALLOC_BASELINE="${MANUAL_ALLOC_BASELINE:-$QUEUE_DIR/.ledger_guard_manual_baseline}"
MANUAL_ALLOC_WARNED="${MANUAL_ALLOC_WARNED:-$QUEUE_DIR/.ledger_guard_warned_ids}"
MANUAL_ALLOC_DETECT="${MANUAL_ALLOC_DETECT:-1}"

ledger_log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    echo "$msg" >&2
}

# ─── 検証: exit 0 = PASS / 非0 = FAIL(理由をstdoutに返す) ───
validate_ledger() {
    local target="$1"
    "$PYTHON" "$VALIDATOR" "$target" 2>&1
}

# ─── 家老inboxへ警告emit ───
emit_karo_warning() {
    local detail="$1"
    local msg="🚨台帳(shogun_to_karo.yaml) parse破損を検知${2:+しrollbackした}。破損版=${detail}。編集内容を修正して再適用せよ(原因はほぼ自由文の『: 』(半角コロン+空白)quote漏れ=block scalar | かquote/全角コロンで回避)。"
    if bash "$INBOX_WRITE" karo "$msg" error ledger_guard >/dev/null 2>&1; then
        ledger_log "INFO: karo warning emitted"
    else
        ledger_log "WARN: karo inbox_write failed (warning not delivered)"
    fi
}

# ═══ cmd_1336: 採番gate非経由の手動起票 検知層 (警告のみ) ═══════════
#
# 検知できるもの:
#   (S1) baseline より新しい純数値id (cmd_N) の entry が払い出しjournalに無い = gate非経由追記
#   (S2) 台帳内で entry id が重複 (ledger_validate.py は重複を検査しない=本検知層が唯一の網)
# 検知できないもの (正直な明示):
#   - baseline 以前の番号での手動追記 (導入時grandfather帯。番号は既使用ゆえ新規衝突は起きない)
#   - suffix付きid (cmd_123b 等) / archive file への直接追記 / 番号を変えない本文編集
#   - journal を消されると gate経由分も S1 誤検知しうる (journal は queue/ 配下・通常触らない)
#
# ★台帳へは一切書かない・戻り値は常に0 = rollback/quarantine 経路に関与しない★
# (検知の誤爆で正常な台帳が巻き戻るのが最悪の結果、ゆえ構造的に切り離す)

# 台帳 entry id 抽出。grep でなく YAML parse = block scalar 自由文内の
# 「id: cmd_N」を構造的に誤検知しない。validate PASS 後にのみ呼ぶ前提。
# 重複idもそのまま列挙 (S2 の材料)。純数値 cmd_N のみ対象。
extract_entry_ids() {
    "$PYTHON" - "$LEDGER_FILE" <<'PYEOF'
import re, sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
key = "commands" if "commands" in data else "queue"
for cmd in data.get(key) or []:
    if isinstance(cmd, dict):
        cid = cmd.get("id") or cmd.get("cmd_id")
        if isinstance(cid, str) and re.fullmatch(r"cmd_[0-9]+", cid):
            print(cid)
PYEOF
}

# 次の空き番号の目安 (cmd_id_alloc.sh compute_next_id と同じ union 走査を inline 再現。
# ★alloc script を呼ばない=guard は台帳lock保持中ゆえ、同一lockを取る alloc 呼出はdeadlock★)
compute_next_free_id() {
    local re='^[[:space:]]*-?[[:space:]]*(id|cmd_id):[[:space:]]*["'"'"']?cmd_[0-9]+'
    local max
    max=$(
        {
            grep -hE "$re" "$LEDGER_FILE" 2>/dev/null || true
            find "$QUARANTINE_DIR" -type f -name '*.yaml' -print0 2>/dev/null \
                | xargs -0 -r grep -hE "$re" 2>/dev/null || true
            if [ -f "$ALLOC_JOURNAL" ]; then
                cut -f1 "$ALLOC_JOURNAL" 2>/dev/null || true
            fi
        } \
            | grep -oE 'cmd_[0-9]+' \
            | sed -e 's/^cmd_//' -e 's/^0*\([0-9]\)/\1/' \
            | sort -n | tail -1
    )
    echo "cmd_$(( ${max:-0} + 1 ))"
}

detect_manual_alloc() {
    [ "$MANUAL_ALLOC_DETECT" = "1" ] || return 0

    local ids
    if ! ids=$(extract_entry_ids 2>/dev/null); then
        ledger_log "MANUAL-ALLOC: id抽出失敗 — skip (次回checkで再試行)"
        return 0
    fi
    [ -n "$ids" ] || return 0

    # baseline 初期化 (初回のみ): 既存entry全てをgrandfatherし、以後の新番号だけを検査する
    if [ ! -f "$MANUAL_ALLOC_BASELINE" ]; then
        local maxnow
        maxnow=$(printf '%s\n' "$ids" | sed 's/^cmd_//' | sort -n | tail -1)
        printf '%s\n' "${maxnow:-0}" > "$MANUAL_ALLOC_BASELINE"
        ledger_log "MANUAL-ALLOC: baseline initialized = cmd_${maxnow:-0} (既存entryはgrandfather)"
        return 0
    fi
    local baseline
    baseline=$(head -1 "$MANUAL_ALLOC_BASELINE" 2>/dev/null)
    case "$baseline" in
        ''|*[!0-9]*)
            ledger_log "MANUAL-ALLOC: baseline file 不正 ($MANUAL_ALLOC_BASELINE) — skip"
            return 0 ;;
    esac

    local dups
    dups=$(printf '%s\n' "$ids" | sort | uniq -d)

    local id n reason findings="" fresh_ids=""
    for id in $(printf '%s\n' "$ids" | sort -u); do
        n="${id#cmd_}"
        [ "$n" -gt "$baseline" ] 2>/dev/null || continue
        grep -qx "$id" "$MANUAL_ALLOC_WARNED" 2>/dev/null && continue
        reason=""
        if printf '%s\n' "$dups" | grep -qx "$id"; then
            reason="台帳内id重複=衝突"
        elif ! { [ -f "$ALLOC_JOURNAL" ] && cut -f1 "$ALLOC_JOURNAL" 2>/dev/null | grep -qx "$id"; }; then
            reason="gate非経由(払い出しjournal記録なし)"
        fi
        [ -n "$reason" ] || continue
        findings="${findings}${id}=${reason} / "
        fresh_ids="${fresh_ids}${id} "
    done

    [ -n "$findings" ] || return 0
    findings="${findings% / }"

    local next_free
    next_free=$(compute_next_free_id)
    local msg="⚠️採番gate非経由の手動起票を検知【${findings}】。是正手順=①id重複(衝突)の場合: 先着(journal記録側)を正とし、手動側entryのidを空き番号へ改番+renumber_note追記(targeted Edit・全書換禁)。②改番先/緊急起票の番号は必ず「bash scripts/cmd_id_alloc.sh --claim --origin karo」で払い出せ(現時点の目安=${next_free}だが--claimの出力が正式)。③重複でなければ番号自体は有効(台帳記帳済ゆえ以後の払い出しと衝突しない)=是正は以後のgate経由徹底のみ。本警告は同一idにつき一度のみ。詳細=logs/ledger_guard.log"
    if bash "$INBOX_WRITE" karo "$msg" warning ledger_guard >/dev/null 2>&1; then
        ledger_log "MANUAL-ALLOC: karo warning emitted → ${findings}"
        # 警告が届いた id のみ warned 記録 (emit失敗時は次回checkで再警告=取り零し防止)
        printf '%s\n' $fresh_ids >> "$MANUAL_ALLOC_WARNED"
    else
        ledger_log "MANUAL-ALLOC: WARN inbox_write failed (次回checkで再警告) → ${findings}"
    fi
    return 0
}

# ─── guard check 本体(flock内で呼ばれる想定。test は直接呼んでよい) ───
# PASS: .last_good を更新するのみ(台帳write無し)。 FAIL: quarantine + rollback + 警告。
run_guard_check() {
    local err
    if err=$(validate_ledger "$LEDGER_FILE"); then
        # ★PASS=正常系。台帳へは絶対に書かない=正しい編集を消さない★
        cp -p "$LEDGER_FILE" "$LAST_GOOD_FILE" 2>/dev/null || cp "$LEDGER_FILE" "$LAST_GOOD_FILE"
        ledger_log "PASS: ledger valid → last_good snapshot updated"
        # cmd_1336: 手動起票検知 (警告のみ。戻り値・台帳・rollback経路に不干渉)
        detect_manual_alloc || true
        return 0
    fi

    ledger_log "FAIL: ledger invalid → $err"

    # ①quarantine(破損版を非破壊保全=家老が中身を直して再適用できる)
    local ts quar
    ts="$(date '+%Y%m%d%H%M%S')_$$"
    mkdir -p "$QUARANTINE_DIR" 2>/dev/null || true
    quar="$QUARANTINE_DIR/corrupt_shogun_to_karo_${ts}.yaml"
    cp "$LEDGER_FILE" "$quar" 2>/dev/null || true
    ledger_log "FAIL: corrupt version quarantined → $quar"

    # ②rollback(.last_good が在るときのみ。無ければ安全側=rollbackせず警告のみ)
    if [ -f "$LAST_GOOD_FILE" ]; then
        cp "$LAST_GOOD_FILE" "$LEDGER_FILE"
        ledger_log "FAIL: rolled back ledger ← last_good"
        emit_karo_warning "$quar" "rolled_back"
    else
        ledger_log "FAIL: no last_good snapshot — cannot rollback (warn only)"
        emit_karo_warning "$quar"
    fi
    return 1
}

# ─── flock wrapper(inbox_write/slim_yaml と同型の atomic 整合) ───
run_guard_check_locked() {
    (
        if command -v flock &>/dev/null; then
            flock -x -w 10 9 || { ledger_log "WARN: lock timeout — skipping guard check"; exit 0; }
        fi
        run_guard_check
    ) 9>"$LEDGER_LOCK"
}

# ─── 起動時検証(rollback禁=既存破損を勝手に古い版へ巻き戻さない安全側) ───
startup_check() {
    local err
    if err=$(validate_ledger "$LEDGER_FILE"); then
        cp -p "$LEDGER_FILE" "$LAST_GOOD_FILE" 2>/dev/null || cp "$LEDGER_FILE" "$LAST_GOOD_FILE"
        ledger_log "STARTUP: ledger valid → last_good initialized"
        # cmd_1336: 起動時も手動起票検知 (guard停止中に入った手動追記を再起動時に拾う)
        detect_manual_alloc || true
        return 0
    fi
    # ★起動時FAIL=警告のみ・rollbackしない(設計§(d)・§5(5))★
    ledger_log "STARTUP: ledger INVALID at startup → WARN only (NO rollback). $err"
    emit_karo_warning "(起動時に既存破損を検知・自動rollbackせず)"
    return 1
}

# ─── main loop(inotifywait + debounce) ───
main_loop() {
    if ! command -v inotifywait &>/dev/null; then
        ledger_log "ERROR: inotifywait not found. Install: sudo apt install inotify-tools"
        exit 1
    fi

    ledger_log "ledger_guard started — ledger=$LEDGER_FILE debounce=${DEBOUNCE_SEC}s"
    startup_check || true

    while true; do
        # 台帳ディレクトリ単位で監視(Edit の atomic rename=tmp→rename も moved_to で拾う)。
        # 30s timeout で inotify 不発(WSL2)の安全網。
        inotifywait -q -t 30 -e close_write,moved_to,create \
            "$(dirname "$LEDGER_FILE")" >/dev/null 2>&1 || true

        # 対象ファイルが直近で変わっていなければ何もしない(dir内の別file変更を無視)
        [ -f "$LEDGER_FILE" ] || continue

        # debounce: 編集連打を吸収(まとめて1回検証)
        sleep "$DEBOUNCE_SEC"

        run_guard_check_locked || true
    done
}

# ─── Entry point(testing guard) ───
if [ "${__LEDGER_GUARD_TESTING__:-}" != "1" ]; then
    set -uo pipefail
    main_loop
fi
