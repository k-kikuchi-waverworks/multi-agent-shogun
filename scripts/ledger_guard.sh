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

# ─── guard check 本体(flock内で呼ばれる想定。test は直接呼んでよい) ───
# PASS: .last_good を更新するのみ(台帳write無し)。 FAIL: quarantine + rollback + 警告。
run_guard_check() {
    local err
    if err=$(validate_ledger "$LEDGER_FILE"); then
        # ★PASS=正常系。台帳へは絶対に書かない=正しい編集を消さない★
        cp -p "$LEDGER_FILE" "$LAST_GOOD_FILE" 2>/dev/null || cp "$LEDGER_FILE" "$LAST_GOOD_FILE"
        ledger_log "PASS: ledger valid → last_good snapshot updated"
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
