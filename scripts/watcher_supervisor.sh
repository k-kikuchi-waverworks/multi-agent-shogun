#!/usr/bin/env bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.
#
# cmd_652 (2026-05-16): settings.yaml `cli.agents` 動的読込化 (cmd_645 hard-coded list 廃止)。
# - ashigaru / gunshi 列挙は scripts/lib/agent_list.sh 経由で settings.yaml から動的取得
# - shogun (別 pane shogun:main.0) と karo (multiagent:agents.0) は special、hardcoded retain
# - deprecated agent (settings.yaml の deprecated:true) は自動 skip
# - pane 不在時 (例: gunshi2 の pane 0.9 殿手動起動前) は start_watcher_if_missing 内 pane_exists guard で skip
#
# cmd_1339 (2026-07-25): 交差配達事故 (軍師一号×足軽六号 session 喪失) を受けた構造是正。
# - pane 解決は @agent_id 正本 (scripts/lib/pane_gate.sh)。命名規約/settings.yaml は fallback。
# - dedup は lifetime lock 契約 (scripts/lib/proc_lock.sh)。★旧 `pgrep -Ef` は procps-ng
#   4.0.4 に -E が無く常時 rc=2 の死にコードで、実際の単一化は start lock fd9 の
#   偶然相続に依存していた。shutsujin 直撃起動の watcher は lock を持たず、
#   supervisor 再起動で全 agent 二重起動した (2026-07-25 18:52:57 実測)★。
# - supervisor 自身も lifetime lock を保持 = 二重 supervisor 防止 + 生存監視の beacon
#   (idle_revive_scan.sh cron が lock を probe し、不在なら家老へ警告する)。
# - drift 検知層: watcher の配線 (lock metadata の pane) と実体 (@agent_id の pane) を
#   定期突合し、ズレたら是正手順つきで家老へ警告 (2-strike + 同一内容 warn-once)。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# shellcheck source=lib/agent_list.sh
. "$SCRIPT_DIR/scripts/lib/agent_list.sh"
# shellcheck source=lib/proc_lock.sh
. "$SCRIPT_DIR/scripts/lib/proc_lock.sh"
# shellcheck source=lib/pane_gate.sh
. "$SCRIPT_DIR/scripts/lib/pane_gate.sh"

mkdir -p logs queue/inbox queue/state

sup_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# ── cmd_1339 ③: [LEGACY] は状態でありイベントではない — episode につき 1 行のみ ──
# main loop (5s毎) から毎回 log すると実測 54行/5分 ≈ 15.5K行/日 の spam になる
# (2026-07-25 実測)。marker file で「旧 instance 生存」episode の初回のみ log し、
# 解消 (契約 lock 世代へ移行 or 消滅=start 実行) で marker を消して次の episode に備える。
# marker は file ベース: 呼出元 start_*_if_missing は subshell 内ゆえ shell 変数では
# 親 loop へ持ち越せない。
legacy_note_once() {
    local name="$1"; shift
    local marker="$SHOGUN_LOCK_DIR/legacy_noted_${name}"
    [ -e "$marker" ] && return 0
    sup_log "[LEGACY] $* (本行は episode につき一度のみ・解消まで再出力せぬ)"
    : > "$marker" 2>/dev/null || true
}

legacy_note_clear() {
    local marker="$SHOGUN_LOCK_DIR/legacy_noted_${1}"
    [ -e "$marker" ] && rm -f "$marker" 2>/dev/null || true
}

# ── cmd_1339 ②: supervisor lifetime lock (二重 supervisor 防止 + 生存 beacon) ──
if [ "${__WATCHER_SUPERVISOR_TESTING__:-}" != "1" ]; then
    if ! proc_lock_acquire "watcher_supervisor" 208 "watcher_supervisor"; then
        sup_log "DUPLICATE: watcher_supervisor 既に稼働中 ($(proc_lock_read_meta watcher_supervisor)) — 本 instance は退場"
        exit 0
    fi
    sup_log "watcher_supervisor started (pid=$$, lifetime lock acquired)"
fi

get_multiagent_pane_base() {
    if [ -n "${SHOGUN_PANE_BASE:-}" ]; then
        echo "$SHOGUN_PANE_BASE"
        return 0
    fi
    tmux show-options -gv pane-base-index 2>/dev/null || echo 0
}

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli
    local start_lock="$SHOGUN_LOCK_DIR/start_${agent}.lock"

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    (
        flock -n 9 || return 0

        # ── cmd_1339 ②: 契約 dedup = watcher 自身が保持する lifetime lock を probe ──
        # pgrep と違い、起動元 (shutsujin/supervisor/手動)・PID namespace・cmdline
        # 自己一致に依存しない。watcher 側が lock を取れなければ自主退場するため、
        # ここの判定と start の間の TOCTOU も実害にならない (二重側が自滅する)。
        if proc_lock_is_held "inbox_watcher_${agent}"; then
            legacy_note_clear "$agent"   # 契約 lock 世代へ移行済 = legacy episode 解消
            return 0
        fi

        # 旧世代 watcher (lifetime lock 非保持 = cmd_1339 以前のコードで起動) への
        # 後方互換 fallback。★-Ef は使わぬ (procps-ng 4.0.4 に -E は無い=常時 rc=2)★。
        # 注意: pgrep -f は「pattern 文字列を cmdline に含む別プロセス」(例: 手動 grep)
        # にも当たりうる=自己一致 hazard。契約は上の lock probe であり、これは移行期の網。
        if pgrep -f "scripts/inbox_watcher\.sh ${agent} " >/dev/null 2>&1; then
            legacy_note_once "$agent" "${agent}: lifetime lock 無しの旧 watcher が生存 — 起動せず (次回出陣で契約 lock 世代へ移行)"
            return 0
        fi
        legacy_note_clear "$agent"   # 旧 instance 消滅 = episode 終了 (次回検知は再度 log)

        cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")

        # shogun watcher は安全 env 必須 (escalation /clear が殿の session を吹き飛ばすため)。
        # 従来 supervisor 経由の再起動でこの env が落ちる不整合があった (shutsujin と統一)。
        # 9>&- 208>&- : start lock fd と supervisor lifetime lock fd を子へ相続させない。
        # 9 の相続は「偶然相続 dedup」(廃止=契約は watcher 自身の lifetime lock)、
        # ★208 の相続は watcher が supervisor の生存 lock を保持し続け、supervisor 死後も
        # 生存監視 (idle_revive) が『生きている』と誤認する致命穴★ (harness 実測で発見)。
        if [ "$agent" = "shogun" ]; then
            nohup env ASW_DISABLE_ESCALATION=1 ASW_PROCESS_TIMEOUT=0 ASW_DISABLE_NORMAL_NUDGE=0 \
                bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 9>&- 208>&- &
        else
            nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 9>&- 208>&- &
        fi
        sup_log "[START] inbox_watcher started for ${agent} pane=${pane} PID=$!"
    ) 9>"$start_lock"
}

ashigaru_pane() {
    # ★@agent_id 優先 (pane_gate) → 見つからねば命名規約 ashigaru{N} → multiagent:agents.{N}★
    local agent="$1"
    local resolved=""
    if resolved=$(pane_gate_resolve_by_agent_id "$agent"); then
        echo "$resolved"
        return 0
    fi
    local idx="${agent#ashigaru}"
    echo "multiagent:agents.${idx}"
}

gunshi_pane_resolved() {
    # ★gunshi も @agent_id 優先。settings.yaml の pane: field は fallback★
    # (2026-07-25: settings.yaml は gunshi1=agents.7 と記載されていたが実体は agents.6 だった。
    #  さらに同日 19:25 には pane 再作成で実体が agents.7 へ戻った=静的記載は信用できない)
    local agent="$1"
    local resolved=""
    if resolved=$(pane_gate_resolve_by_agent_id "$agent"); then
        echo "$resolved"
        return 0
    fi
    get_agent_pane "$agent"
}

# cmd_1255 (2026-07-11): 台帳(shogun_to_karo.yaml)parse自己検証gate=ledger_guard watcher。
# per-agent inbox watcher と異なり pane 非依存の singleton(台帳file監視)。
# cmd_1339: dedup を lifetime lock 契約へ (ledger_guard 自身も lock を保持する)。
start_ledger_guard_if_missing() {
    local start_lock="$SHOGUN_LOCK_DIR/start_ledger_guard.lock"
    (
        flock -n 9 || return 0
        if proc_lock_is_held "ledger_guard"; then
            legacy_note_clear "ledger_guard"   # 契約 lock 世代へ移行済 = episode 解消
            return 0
        fi
        if pgrep -f "scripts/ledger_guard\.sh" >/dev/null 2>&1; then
            legacy_note_once "ledger_guard" "ledger_guard: lifetime lock 無しの旧 instance が生存 — 起動せず"
            return 0
        fi
        legacy_note_clear "ledger_guard"   # 旧 instance 消滅 = episode 終了
        nohup bash scripts/ledger_guard.sh >> "logs/ledger_guard.log" 2>&1 9>&- 208>&- &
        sup_log "[START] ledger_guard started PID=$!"
    ) 9>"$start_lock"
}

# ═══════════════════════════════════════════════════════════════
# cmd_1339 ①: pane 配線 drift 検知層
# ─────────────────────────────────────────────────────────────
# 本質: 2026-07-25 の交差配達は「事故が起きるまで誰も気付けなかった」。
# plain nudge が機能して見えるため、致命経路 (clear_command 直送) の誤配線が
# 隠れる=★軽い経路が重い経路を覆い隠す★型。ゆえに配線と実体の突合を常時回す。
#
# 検知できるもの:
#   (D1) watcher の宛先 pane と、その agent の実体 pane (@agent_id) の不一致 (交差配達の芽)
#   (D2) watcher の宛先 pane が消失している (nudge が虚空へ)
#   (D3) agent の実体 pane (@agent_id) が見つからない (pane 再作成中 or @agent_id 消失)
# 検知できないもの (正直な明示):
#   - lifetime lock 非保持の旧世代 watcher (metadata が無い=inventory に載らない。
#     次回出陣で全 watcher が lock 世代へ移行し次第、全数が対象になる)
#   - tmux server 分断 (別 socket) など、この supervisor から見えない配線
#
# 誤爆防止:
#   - 2-strike: 同一内容の drift が連続 2 回 (既定 60s 間隔) 観測されて初めて警告
#     (pane 再作成・出陣直後の一過性ズレで鳴らさない)
#   - warn-once: 同一 signature への警告は一度のみ (家老 inbox spam 防止)。
#     内容が変われば別 signature として再警告。
#   - 警告 emit 失敗時は warned に記録せず次回再警告 (cmd_1338 流儀=握り潰さない)
# 注: watcher 自身も配達直前に自己是正する (inbox_watcher ensure_delivery_pane) ため、
#     本層は「宛先へ配達が起きる前」「旧世代 watcher」「解決不能」のズレを家老へ可視化する網。
# ═══════════════════════════════════════════════════════════════
DRIFT_DETECT="${WATCHER_DRIFT_DETECT:-1}"
DRIFT_EVERY_SEC="${WATCHER_DRIFT_EVERY_SEC:-60}"
DRIFT_STRIKES="${WATCHER_DRIFT_STRIKES:-2}"
DRIFT_STATE_DIR="${WATCHER_DRIFT_STATE_DIR:-$SCRIPT_DIR/queue/state}"
DRIFT_PENDING_FILE="$DRIFT_STATE_DIR/watcher_drift_pending"
DRIFT_WARNED_FILE="$DRIFT_STATE_DIR/watcher_drift_warned"
DRIFT_INBOX_WRITE="${DRIFT_INBOX_WRITE:-$SCRIPT_DIR/scripts/inbox_write.sh}"

detect_pane_drift() {
    [ "$DRIFT_DETECT" = "1" ] || return 0
    pane_gate_in_use || return 0   # @agent_id 未運用環境では判定不能ゆえ沈黙

    local findings="" details="" f name meta agent pane pid
    for f in "$SHOGUN_LOCK_DIR"/inbox_watcher_*.lock; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .lock)
        proc_lock_is_held "$name" || continue   # lock 保持なし = watcher 死亡 → 対象外
        meta=$(head -1 "$f" 2>/dev/null) || true
        agent=$(printf '%s\n' "$meta" | grep -oE 'agent=[^ ]+' | cut -d= -f2) || true
        pane=$(printf '%s\n' "$meta" | grep -oE 'pane=[^ ]+' | cut -d= -f2) || true
        pid=$(printf '%s\n' "$meta" | grep -oE 'pid=[0-9]+' | cut -d= -f2) || true
        [ -n "$agent" ] && [ -n "$pane" ] || continue

        local wired_id="" actual="" actual_id="" occupant=""
        wired_id=$(pane_gate_pane_id "$pane" 2>/dev/null) || true
        actual=$(pane_gate_resolve_by_agent_id "$agent") || true

        if [ -z "$wired_id" ]; then
            findings="${findings}${agent}:宛先pane消失(${pane});"
            details="${details}【${agent}】watcher(PID ${pid:-?})の宛先 ${pane} が存在せぬ(実体=${actual:-不明})。"
            continue
        fi
        if [ -z "$actual" ]; then
            findings="${findings}${agent}:実体pane不明;"
            details="${details}【${agent}】@agent_id=${agent} の pane が見つからぬ(pane再作成中か@agent_id消失。watcher PID ${pid:-?} は ${pane} 向き)。"
            continue
        fi
        actual_id=$(pane_gate_pane_id "$actual" 2>/dev/null) || true
        if [ -n "$actual_id" ] && [ "$wired_id" != "$actual_id" ]; then
            occupant=$(pane_gate_agent_id_of "$pane" 2>/dev/null || echo "<unset>")
            findings="${findings}${agent}:${pane}(実体=${occupant})→正=${actual};"
            details="${details}【${agent}】watcher(PID ${pid:-?})は pane ${pane} へ配線されておるが、その pane の実体は『${occupant}』。${agent} の実体は ${actual}。"
        fi
    done

    mkdir -p "$DRIFT_STATE_DIR" 2>/dev/null || true

    if [ -z "$findings" ]; then
        rm -f "$DRIFT_PENDING_FILE" 2>/dev/null || true
        return 0
    fi

    local sig prev_sig="" prev_cnt=0 cnt
    sig=$(printf '%s' "$findings" | md5sum | cut -d' ' -f1)
    if [ -f "$DRIFT_PENDING_FILE" ]; then
        read -r prev_sig prev_cnt < "$DRIFT_PENDING_FILE" 2>/dev/null || true
    fi
    if [ "$sig" = "$prev_sig" ]; then
        cnt=$(( ${prev_cnt:-0} + 1 ))
    else
        cnt=1
    fi
    printf '%s %s\n' "$sig" "$cnt" > "$DRIFT_PENDING_FILE"
    if [ "$cnt" -lt "$DRIFT_STRIKES" ]; then
        sup_log "[DRIFT] 1st strike (未警告・次回 ${DRIFT_EVERY_SEC}s 後も同一なら警告): ${findings}"
        return 0
    fi
    if grep -qx "$sig" "$DRIFT_WARNED_FILE" 2>/dev/null; then
        return 0   # 同一内容は一度のみ
    fi

    local msg="🚨watcher配線ズレ検知(cmd_1339 drift層) ${details} ★nudgeは軽症だがclear_commandの誤配は別agentのsessionを吹き飛ばす★。是正手順=①該当watcherを kill <PID> ②supervisorが5秒以内に@agent_id正本で正しいpaneへ自動再起動 ③『ps -eo pid,args | grep inbox_watcher』でagent毎1体+配線を確認。新世代watcherは配達直前にも自己是正するが、宛先pane消失/@agent_id消失は自己是正できぬゆえ本警告を要す。本警告は同一内容につき一度のみ。詳細=logs/watcher_supervisor.log"
    if bash "$DRIFT_INBOX_WRITE" karo "$msg" warning watcher_supervisor >&2; then
        printf '%s\n' "$sig" >> "$DRIFT_WARNED_FILE"
        sup_log "[DRIFT] karo warning emitted: ${findings}"
    else
        sup_log "[DRIFT] FATAL: 警告の inbox_write 失敗 — warned 記録せず次回再警告: ${findings}"
    fi
    return 0
}

# ─── main loop ───
if [ "${__WATCHER_SUPERVISOR_TESTING__:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0   # test harness は関数を直接呼ぶ
fi

_drift_last_ts=0
while true; do
    start_watcher_if_missing "shogun" "shogun:main.0" "logs/inbox_watcher_shogun.log"
    start_watcher_if_missing "karo" "multiagent:agents.0" "logs/inbox_watcher_karo.log"

    # cmd_1255: 台帳parse自己検証gate(singleton・pane非依存)
    start_ledger_guard_if_missing

    # cmd_652 (2026-05-16): ashigaru list を settings.yaml から動的取得
    while IFS= read -r ash; do
        [ -n "$ash" ] || continue
        start_watcher_if_missing "$ash" "$(ashigaru_pane "$ash")" "logs/inbox_watcher_${ash}.log"
    done < <(get_active_ashigaru_agents)

    # cmd_652 (2026-05-16): active gunshi list を settings.yaml から動的取得 (deprecated 除外)
    while IFS= read -r gun; do
        [ -n "$gun" ] || continue
        local_pane=$(gunshi_pane_resolved "$gun")   # cmd_1339: @agent_id 優先・settings.yaml は fallback
        [ -n "$local_pane" ] || continue  # pane 未設定 gunshi はスキップ
        start_watcher_if_missing "$gun" "$local_pane" "logs/inbox_watcher_${gun}.log"
    done < <(get_active_gunshi_agents)

    # cmd_1339 ①: drift 検知 (既定 60s 毎)
    _now_ts=$(date +%s)
    if [ $(( _now_ts - _drift_last_ts )) -ge "$DRIFT_EVERY_SEC" ]; then
        _drift_last_ts=$_now_ts
        detect_pane_drift || true
    fi

    # 208>&- : ループ待ちの sleep 子にも lifetime lock fd を相続させない
    # (supervisor 死後に sleep が lock を保持し生存監視が誤認する窓を消す)
    sleep 5 208>&-
done
