#!/usr/bin/env python3
# idle_revive_scan.py — cmd_1154 柱1: karo非依存の能動 idle-poll / auto-revive scan
#
# whack-a-mole(将軍が手動で idle 固着 agent を revive)を廃するための独立 scan。
# karo loop の外(cron 想定)で走るため、家老 degrade/固着に耐性がある。
# stall_watchdog_scan.py の scan/YAML/inbox_write パターンと lib/agent_status.sh の
# agent_is_busy_check(spinner 判定)、lib/agent_registry.sh の pane マッピングを流用する
# (車輪の再発明はしない)。
#
# ★誤 revive 防止 = 複合 AND 判定★ (設計 plans/cmd_1154_resume_reliability_design.md §2):
#   revive ⇔ (a) spinner 無 (agent_is_busy_check=idle)
#        AND (b) task status ∈ {assigned,in_progress} 且つ未完 (report が done でない)
#        AND (c) 出力 file の最終更新が stall 閾値を超過 (slow-gen は mtime 新鮮ゆえ除外)
#   → 3 signal のいずれか 1 つでも「稼働」を示せば触らない(安全側)。
#
# ★過剰介入防止 = rate limit★ (設計 §4):
#   - 同一 agent への連続 clear_command 最小間隔 (--min-interval-min, default 5 分)
#   - 連続 N 回 clear しても復帰せぬ場合は escalation 停止 + karo へ alert
#     (--max-consecutive, default 3)。clear-loop の断ち切り。
#   - state = queue/state/clear_log.yaml (agent → last_clear_ts / consecutive / last_task_id)
#
# ★Task B = 家老 degrade 検知(同居)★ (設計 §3):
#   idle_revive_scan は足軽/軍師の idle 固着に加え、家老 degrade(context 肥大で
#   dashboard 更新が止まる機能不全)も同じ scan で検知する。karo 非依存の cron scan
#   ゆえ、家老が degrade しても外から復旧を発行できる(whack-a-mole の根を断つ)。
#   degrade 判定 = 実データ乖離ベース(憶測禁・prose scrape 無):
#     (i)  dashboard.md mtime が --karo-stale-min(default 20)超 stale
#     (ii) 且つ active task(assigned/in_progress)が queue/tasks に存在
#          (= 誰かが稼働中なのに家老の dashboard が固まっている)
#     (iii) 乖離 corroboration = task/report YAML の mtime が dashboard mtime より新しい
#          (= 現場は進んだのに家老の記録が追随せず。mtime のみ・prose 非scrape)
#   hit → karo へ clear_command(rate limit --karo-min-interval-min, default 20 分)。
#   SessionStart hook が persona/state を復旧、CLAUDE.md Session Start が queue YAML から
#   dashboard を再構築するゆえ state 損失ゼロ(非破壊)。karo 連続 escalation は shogun へ。
#   backstop の定期 self-clear は karo.md 規律側(docs Task D)。本 script は primary(reactive)。
#
# Usage:
#   python3 scripts/idle_revive_scan.py [--dry-run] [--stall-min N] [--min-interval-min N]
#     [--max-consecutive N] [--karo-stale-min N] [--karo-min-interval-min N]
#     [--no-karo-check] [--dashboard-path PATH] [--pane-state-file PATH]
#     [--json] [--queue-root PATH]
#
# On hit (非 dry-run): `inbox_write.sh {agent} "<本文>" clear_command idle_revive_scan` を発行。
# --dry-run: 判定結果を stdout に出すのみ(実 clear 発行 0)。smoke / 動作検証用。
# --pane-state-file: smoke/test 用に pane 状態(agent→busy/idle/absent の JSON/YAML mapping)を
#     注入し tmux probe を bypass(S1/S2/S4 の決定論的再現用)。本番では未指定=実 tmux 観測。

import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TASKS_DIR = REPO_ROOT / "queue" / "tasks"
DEFAULT_REPORTS_DIR = REPO_ROOT / "queue" / "reports"
DEFAULT_STATE_DIR = REPO_ROOT / "queue" / "state"
INBOX_WRITE_SH = REPO_ROOT / "scripts" / "inbox_write.sh"

# (b) revive 候補となる task status。それ以外(done/completed/idle/reassigned_* 等)は除外。
ACTIVE_STATUSES = {"assigned", "in_progress"}
# report がこの status を記録していれば「完了済」→ 未完でない → 除外(stall_watchdog の領分)。
COMPLETION_STATUSES = {"done", "completed", "success"}

# revive 対象 agent (karo/shogun は除外。karo degrade は Task B が扱う)。
EXCLUDED_AGENTS = {"karo", "shogun"}

DEFAULT_STALL_MIN = 15          # (c) 出力 file 無更新の許容(slow_gen_grace)。re-author 重 loop 想定 15-20。
DEFAULT_MIN_INTERVAL_MIN = 5    # rate limit: 同一 agent 連続 clear 最小間隔(CLAUDE.md「5分1回」整合)。
DEFAULT_MAX_CONSECUTIVE = 3     # 連続 clear 上限。超過で escalation 停止 + karo alert。
DEFAULT_ALERT_COOLDOWN_MIN = 30 # cmd_1280: escalation latch中の同一agent同一task再警報の抑止間隔。
                                # cron 3分毎 scan が latch 中に毎回 alert を再送し karo inbox が
                                # 未読spamで溢れた実戦incident(2026-07-14 未読212通)の再発防止。

# ── Task B: 家老 degrade 検知パラメータ(設計 §3) ──
DEFAULT_KARO_STALE_MIN = 20        # dashboard.md staleness 閾値。家老 clear は重いゆえ長め。
DEFAULT_KARO_MIN_INTERVAL_MIN = 20 # rate limit: karo 連続 clear 最小間隔(≥15-20分・設計 §4)。
DEFAULT_DASHBOARD = REPO_ROOT / "dashboard.md"
KARO_STATE_KEY = "karo"


# ─────────────────────────────────────────────────────────────
# pane busy 判定 (lib/agent_status.sh + lib/agent_registry.sh を bash で流用)
# ─────────────────────────────────────────────────────────────
_PANE_STATE_BASH = r'''
set -uo pipefail
cd "$1"
source lib/agent_registry.sh
source lib/agent_status.sh
CLI_ADAPTER=false
if [ -f lib/cli_adapter.sh ]; then
    source lib/cli_adapter.sh 2>/dev/null && CLI_ADAPTER=true
fi
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    pane=$(agent_registry_multiagent_pane_for_agent "$agent" "$PANE_BASE" 2>/dev/null || echo "")
    if [ -z "$pane" ]; then
        echo "${agent}	absent"
        continue
    fi
    cli=""
    if $CLI_ADAPTER; then
        cli=$(get_cli_type "$agent" 2>/dev/null || echo "")
    fi
    agent_is_busy_check "$pane" "$cli" && rc=0 || rc=$?
    case $rc in
        0) echo "${agent}	busy" ;;
        1) echo "${agent}	idle" ;;
        2) echo "${agent}	absent" ;;
        *) echo "${agent}	absent" ;;
    esac
done < <(agent_registry_multiagent_agents)
'''


def get_pane_states(repo_root: Path):
    """Return {agent: 'busy'|'idle'|'absent'} reusing lib/agent_status.sh.

    Falls back to an empty dict (all agents treated as unknown → skipped) when
    tmux/libs are unavailable so the scanner degrades safely instead of crashing.
    """
    try:
        proc = subprocess.run(
            ["bash", "-c", _PANE_STATE_BASH, "_", str(repo_root)],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as e:
        print(f"[idle_revive] WARN: pane state probe failed: {e}", file=sys.stderr)
        return {}
    states = {}
    for line in proc.stdout.splitlines():
        if "\t" not in line:
            continue
        agent, state = line.split("\t", 1)
        states[agent.strip()] = state.strip()
    if proc.returncode != 0 and not states:
        print(f"[idle_revive] WARN: pane state probe rc={proc.returncode}: "
              f"{proc.stderr.strip()}", file=sys.stderr)
    return states


# ─────────────────────────────────────────────────────────────
# cmd_1339 (e)(f): /clear は破壊的操作 — 単発 pane 再probe + 文脈材料
# ─────────────────────────────────────────────────────────────
# ★非対称の明示★: nudge の誤配・誤発火は軽症 (起こされた agent は自分の inbox を
# 読むだけ) だが、/clear の誤発火は稼働中の session context を殺す。2026-07-25
# 19:21 に thinking 中の足軽四号へ誤 /clear が 3 連発した (52列 pane で status bar
# の『esc to interrupt』が切詰められ、queued 行が spinner 判定を汚した=
# lib/agent_status.sh 側で根治済)。本層はそれに加え、scan 時点と発行時点の
# TOCTOU を閉じる: ★発行直前にその agent の pane を再 probe し、busy へ転じて
# いれば発行しない★。閾値 (stall_min 等) は触らない=機構の修理であって
# 感度の推測調整ではない。

_SINGLE_AGENT_STATE_BASH = r'''
set -uo pipefail
cd "$1"
agent="$2"
source lib/agent_registry.sh
source lib/agent_status.sh
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
pane=$(agent_registry_pane_for_agent "$agent" "$PANE_BASE" 2>/dev/null || echo "")
if [ -z "$pane" ]; then echo "absent"; exit 0; fi
agent_is_busy_check "$pane" "" && rc=0 || rc=$?
case $rc in 0) echo busy ;; 1) echo idle ;; *) echo absent ;; esac
'''


def probe_agent_state(agent):
    """単一 agent の pane 状態を今この瞬間に再 probe する ('busy'|'idle'|'absent'|'unknown')。

    pane 解決は agent_registry (cmd_1339 で @agent_id 第一正本化済) 経由 —
    pane 番号のずれで別 agent の pane を読む誤 probe を構造的に避ける。
    """
    try:
        proc = subprocess.run(
            ["bash", "-c", _SINGLE_AGENT_STATE_BASH, "_", str(REPO_ROOT), agent],
            capture_output=True, text=True, timeout=30,
        )
        lines = [l.strip() for l in proc.stdout.splitlines() if l.strip()]
        v = lines[-1] if lines else ""
        return v if v in ("busy", "idle", "absent") else "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unknown"


_PANE_TAIL_BASH = r'''
set -uo pipefail
cd "$1"
agent="$2"
source lib/agent_registry.sh
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
pane=$(agent_registry_pane_for_agent "$agent" "$PANE_BASE" 2>/dev/null || echo "")
[ -n "$pane" ] || exit 0
tmux capture-pane -t "$pane" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -2
'''


def agent_context_note(agent, reports_dir):
    """(f) 家老が『誤検知か本当の固着か』を判断できる材料を 1 行で返す。

    内容 = 対象 pane の末尾 2 行 (空白圧縮・160 字上限) + report YAML の最終更新
    経過分。警報だけ渡されても家老は pane を実査するまで判断できぬ、という
    2026-07-25 の実戦不便 (足軽四号誤 clear の検分) への直接回答。
    """
    tail = ""
    try:
        proc = subprocess.run(
            ["bash", "-c", _PANE_TAIL_BASH, "_", str(REPO_ROOT), agent],
            capture_output=True, text=True, timeout=30,
        )
        lines = [" ".join(l.split()) for l in proc.stdout.splitlines() if l.strip()]
        tail = " / ".join(lines)
        if len(tail) > 160:
            tail = tail[-160:]
    except (OSError, subprocess.SubprocessError):
        pass
    if not tail:
        tail = "取得不能"
    age = "不明"
    try:
        rp = reports_dir / f"{agent}_report.yaml"
        if rp.is_file():
            age_min = (datetime.datetime.now().timestamp() - rp.stat().st_mtime) / 60.0
            age = f"{round(age_min, 1)}分前"
    except OSError:
        pass
    return f"直前pane末尾『{tail}』/ report最終更新={age}"


# ─────────────────────────────────────────────────────────────
# YAML helpers (stall_watchdog_scan.py と同型)
# ─────────────────────────────────────────────────────────────
def parse_task(path: Path):
    try:
        with path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (yaml.YAMLError, OSError) as e:
        print(f"[idle_revive] WARN: task YAML parse failed: {path}: {e}",
              file=sys.stderr)
        return None
    if not isinstance(data, dict):
        return None
    t = data["task"] if isinstance(data.get("task"), dict) else data
    return {
        "task_id": t.get("task_id"),
        "parent_cmd": t.get("parent_cmd"),
        "status": t.get("status"),
        "target_path": t.get("target_path"),
    }


def parse_iso_to_naive_local(s):
    if not isinstance(s, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone().replace(tzinfo=None)
    return dt


def report_shows_completion(report_path: Path, task_id):
    """True if the latest report record for task_id records a completion status.

    Used for the (b) 未完 gate: a task whose report already says done is a
    bookkeeping omission (stall_watchdog territory), not an idle-stuck task.
    """
    if not report_path.is_file():
        return False
    try:
        with report_path.open(encoding="utf-8") as f:
            docs = list(yaml.safe_load_all(f))
    except (yaml.YAMLError, OSError) as e:
        print(f"[idle_revive] WARN: report YAML parse failed: {report_path}: {e}",
              file=sys.stderr)
        return False
    latest_status = None
    latest_dt = None
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        inner = doc["report"] if isinstance(doc.get("report"), dict) else doc
        r_task_id = inner.get("task_id") or inner.get("primary_task")
        if r_task_id != task_id:
            continue
        dt = parse_iso_to_naive_local(inner.get("timestamp"))
        if dt is None:
            continue
        if latest_dt is None or dt > latest_dt:
            latest_dt = dt
            latest_status = inner.get("status")
    if isinstance(latest_status, str):
        return latest_status.lower() in COMPLETION_STATUSES
    return False


def _newest_mtime_in_dir(root: Path, cap: int = 2000):
    newest = None
    count = 0
    for p in root.rglob("*"):
        if count >= cap:
            break
        try:
            if p.is_file():
                count += 1
                m = p.stat().st_mtime
                if newest is None or m > newest:
                    newest = m
        except OSError:
            continue
    return newest


def newest_output_mtime(agent, task, tasks_dir: Path, reports_dir: Path, repo_root: Path):
    """Newest mtime among the agent's task YAML, report YAML, and declared output.

    (c) の主 signal。target_path が示す出力(file or dir)が最も slow-gen 峻別に効く:
    出力が漸進していれば mtime 新鮮 → revive しない。
    """
    candidates = []
    task_yaml = tasks_dir / f"{agent}.yaml"
    report_yaml = reports_dir / f"{agent}_report.yaml"
    for p in (task_yaml, report_yaml):
        try:
            if p.is_file():
                candidates.append(p.stat().st_mtime)
        except OSError:
            pass

    tp = task.get("target_path")
    if isinstance(tp, str) and tp.strip():
        tp_path = Path(tp)
        if not tp_path.is_absolute():
            tp_path = repo_root / tp_path
        try:
            if tp_path.is_file():
                candidates.append(tp_path.stat().st_mtime)
            elif tp_path.is_dir():
                m = _newest_mtime_in_dir(tp_path)
                if m is not None:
                    candidates.append(m)
        except OSError:
            pass

    return max(candidates) if candidates else None


# ─────────────────────────────────────────────────────────────
# rate limit state (queue/state/clear_log.yaml)
# ─────────────────────────────────────────────────────────────
def load_clear_log(state_path: Path):
    if not state_path.is_file():
        return {}
    try:
        with state_path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (yaml.YAMLError, OSError) as e:
        print(f"[idle_revive] WARN: clear_log parse failed: {state_path}: {e}",
              file=sys.stderr)
        return {}
    if not isinstance(data, dict):
        return {}
    return data.get("agents", {}) if isinstance(data.get("agents"), dict) else {}


def save_clear_log(state_path: Path, agents: dict):
    state_path.parent.mkdir(parents=True, exist_ok=True)
    doc = {
        "# managed by": "scripts/idle_revive_scan.py (cmd_1154)",
        "agents": agents,
    }
    tmp = state_path.with_suffix(state_path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        yaml.safe_dump(doc, f, allow_unicode=True, sort_keys=False)
    tmp.replace(state_path)


def load_pane_state_file(path: Path):
    """Load an {agent: 'busy'|'idle'|'absent'} mapping (smoke/test injection).

    Lets S1/S2/S4 be reproduced deterministically without a live tmux formation.
    Production never passes this — get_pane_states() probes real panes instead.
    """
    try:
        with path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (yaml.YAMLError, OSError) as e:
        print(f"[idle_revive] WARN: pane-state-file load failed: {path}: {e}",
              file=sys.stderr)
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v).strip() for k, v in data.items()}


# ─────────────────────────────────────────────────────────────
# Task B: 家老 degrade 検知 (設計 §3) — 実データ乖離ベース・prose 非scrape
# ─────────────────────────────────────────────────────────────
def _has_active_task(tasks_dir: Path):
    """True if any scanned agent holds an active task (someone should be working)."""
    for task_path in tasks_dir.glob("*.yaml"):
        agent = task_path.stem
        if agent in EXCLUDED_AGENTS:
            continue
        if not (agent.startswith("ashigaru") or agent.startswith("gunshi")):
            continue
        t = parse_task(task_path)
        if t and t.get("status") in ACTIVE_STATUSES:
            return True
    return False


def _reality_moved_after(dashboard_mtime, tasks_dir: Path, reports_dir: Path,
                         grace_sec=60):
    """True if any task/report YAML changed after the dashboard was last written.

    Concrete mtime-only proxy for 実態乖離(設計 §3.1-ii): the fleet state advanced
    but karo's dashboard did not follow. No prose scraping, no guessing.
    """
    threshold = dashboard_mtime + grace_sec
    for d in (tasks_dir, reports_dir):
        if not d.is_dir():
            continue
        for p in d.glob("*.yaml"):
            try:
                if p.stat().st_mtime > threshold:
                    return True
            except OSError:
                continue
    return False


def scan_karo_degrade(dashboard_path: Path, tasks_dir: Path, reports_dir: Path,
                      clear_log, karo_stale_min, karo_min_interval_min,
                      max_consecutive, alert_cooldown_min=DEFAULT_ALERT_COOLDOWN_MIN,
                      now=None):
    """Detect karo degrade and return (candidate|None, updated_clear_log).

    revive ⇔ (i) dashboard.md mtime > karo_stale_min stale
          AND (ii) active task exists (誰か稼働中なのに家老の記録が固まっている)
    (iii) 乖離 corroboration(reality_moved)は detail に付すが必須ではない — (i)+(ii)
    が本 incident(2026-07-01 dashboard 4h 放置 + 足軽稼働)を捉える主 signal。
    """
    if now is None:
        now = datetime.datetime.now()
    clear_log = dict(clear_log)
    if not dashboard_path.is_file():
        return None, clear_log
    try:
        dash_mtime = dashboard_path.stat().st_mtime
    except OSError:
        return None, clear_log
    dash_age_min = (now.timestamp() - dash_mtime) / 60.0

    entry = clear_log.get(KARO_STATE_KEY, {})

    # 健全(dashboard 新鮮)→ 復帰扱いで consecutive reset + alert cooldown クリア (cmd_1280)。
    if dash_age_min < karo_stale_min:
        if entry.get("consecutive") or entry.get("last_alert_ts"):
            entry = dict(entry)
            entry["consecutive"] = 0
            entry.pop("last_alert_ts", None)
            clear_log[KARO_STATE_KEY] = entry
        return None, clear_log

    # (ii) active task が無ければ正当 idle(誰も稼働してない)ゆえ触らない。
    if not _has_active_task(tasks_dir):
        return None, clear_log

    reality_moved = _reality_moved_after(dash_mtime, tasks_dir, reports_dir)
    consecutive = int(entry.get("consecutive", 0) or 0)

    base = {
        "agent": KARO_STATE_KEY,
        "task_id": None,
        "parent_cmd": "cmd_1154",
        "idle_min": round(dash_age_min, 1),
        "consecutive": consecutive,
        "reality_moved": reality_moved,
    }

    # rate limit(karo は SessionStart 全復旧で重いゆえ長め)。
    last_ts = entry.get("last_clear_ts")
    last_dt = parse_iso_to_naive_local(last_ts) if isinstance(last_ts, str) else None
    if last_dt is not None:
        since_min = (now - last_dt).total_seconds() / 60.0
        if since_min < karo_min_interval_min:
            base["action"] = "rate_limited"
            base["detail"] = (f"前回 karo clear から {round(since_min, 1)}分 "
                              f"(< {karo_min_interval_min}分) ゆえ skip")
            return base, clear_log

    if consecutive >= max_consecutive:
        # cmd_1280: shogun への再警報も同一 cooldown で抑止。
        alert_ts = entry.get("last_alert_ts")
        alert_dt = parse_iso_to_naive_local(alert_ts) if isinstance(alert_ts, str) else None
        if alert_dt is not None:
            since_alert_min = (now - alert_dt).total_seconds() / 60.0
            if since_alert_min < alert_cooldown_min:
                base["action"] = "alert_cooldown"
                base["detail"] = (f"karo escalation latch 中: 前回 alert から "
                                  f"{round(since_alert_min, 1)}分 "
                                  f"(< {alert_cooldown_min}分) ゆえ再警報抑止")
                return base, clear_log
        base["action"] = "escalation_stop"
        base["detail"] = (f"karo 連続 clear {consecutive}回 (≥{max_consecutive}) で "
                          f"staleness 解消せず。clear-loop 断ち切り→shogun alert")
        entry = dict(entry)
        entry["last_alert_ts"] = now.isoformat(timespec="seconds")
        base["_new_state"] = entry
        return base, clear_log

    corr = "実態乖離有(YAML mtime>dashboard)" if reality_moved else "乖離未検出(staleのみ)"
    base["action"] = "revive"
    base["detail"] = (f"家老degrade: dashboard {round(dash_age_min, 1)}分 stale + "
                      f"active task 存在 + {corr} → karo /clear で SessionStart 復旧")
    entry = dict(entry)
    entry["last_clear_ts"] = now.isoformat(timespec="seconds")
    entry["consecutive"] = consecutive + 1
    entry["last_task_id"] = "karo_degrade"
    entry.pop("last_alert_ts", None)  # 新 clear cycle 開始 → cooldown リセット (cmd_1280)
    base["_new_state"] = entry
    return base, clear_log


# ─────────────────────────────────────────────────────────────
# scan
# ─────────────────────────────────────────────────────────────
def scan(tasks_dir, reports_dir, repo_root, pane_states, clear_log,
         stall_min, min_interval_min, max_consecutive,
         alert_cooldown_min=DEFAULT_ALERT_COOLDOWN_MIN, now=None):
    """Evaluate every scanned agent and return (candidates, updated_clear_log).

    Each returned candidate dict carries the reason + the action decided
    (revive / rate_limited / escalation_stop / alert_cooldown) so --dry-run
    can report it.
    """
    if now is None:
        now = datetime.datetime.now()
    now_ts = now.timestamp()
    results = []
    clear_log = dict(clear_log)

    for task_path in sorted(tasks_dir.glob("*.yaml")):
        agent = task_path.stem
        if agent in EXCLUDED_AGENTS:
            continue
        if not (agent.startswith("ashigaru") or agent.startswith("gunshi")):
            continue
        # Only scan agents that actually occupy a pane in the current formation.
        state = pane_states.get(agent)
        if state is None:
            continue

        task = parse_task(task_path)
        if not task:
            continue

        entry = clear_log.get(agent, {})

        # (a) spinner: busy/absent → 稼働 or 不在 → 触らない。復帰とみなし consecutive reset。
        # latch 解除ゆえ再警報 cooldown (last_alert_ts) もクリア (cmd_1280)。
        if state != "idle":
            if entry.get("consecutive") or entry.get("last_alert_ts"):
                entry = dict(entry)
                entry["consecutive"] = 0
                entry.pop("last_alert_ts", None)
                clear_log[agent] = entry
            continue

        # (b) task status ∈ active。それ以外は対象外(復帰扱いで reset)。
        status = task.get("status")
        if status not in ACTIVE_STATUSES:
            if entry.get("consecutive") or entry.get("last_alert_ts"):
                entry = dict(entry)
                entry["consecutive"] = 0
                entry.pop("last_alert_ts", None)
                clear_log[agent] = entry
            continue

        # (b) 未完: report が既に done → bookkeeping 漏れ(stall_watchdog 領分)ゆえ除外。
        report_path = reports_dir / f"{agent}_report.yaml"
        if report_shows_completion(report_path, task.get("task_id")):
            continue

        # (c) file mtime: 直近書込があれば slow-gen とみなし触らない。
        newest = newest_output_mtime(agent, task, tasks_dir, reports_dir, repo_root)
        if newest is not None:
            idle_min = (now_ts - newest) / 60.0
        else:
            idle_min = None  # no observable output — treat as stalled (conservative revive)
        if idle_min is not None and idle_min < stall_min:
            # 出力漸進中 → slow-gen → revive しない
            continue

        # ── ここまでで複合 AND 成立 = revive 候補 ──
        idle_min_disp = round(idle_min, 1) if idle_min is not None else None

        # rate limit: 前回 clear からの間隔
        last_ts = entry.get("last_clear_ts")
        last_dt = parse_iso_to_naive_local(last_ts) if isinstance(last_ts, str) else None
        consecutive = int(entry.get("consecutive", 0) or 0)
        last_task_id = entry.get("last_task_id")

        # 別 task に変わっていれば復帰とみなし consecutive リセット
        if last_task_id and last_task_id != task.get("task_id"):
            consecutive = 0

        base = {
            "agent": agent,
            "task_id": task.get("task_id"),
            "parent_cmd": task.get("parent_cmd"),
            "idle_min": idle_min_disp,
            "consecutive": consecutive,
        }

        if last_dt is not None:
            since_min = (now - last_dt).total_seconds() / 60.0
            if since_min < min_interval_min:
                base["action"] = "rate_limited"
                base["detail"] = (f"前回 clear から {round(since_min, 1)}分 "
                                  f"(< {min_interval_min}分) ゆえ skip")
                results.append(base)
                continue

        if consecutive >= max_consecutive:
            # cmd_1280: escalation latch 中の再警報 cooldown。cron 毎 scan が同一
            # agent 同一 task の alert を再送し続け karo inbox が spam で溢れるのを防ぐ。
            # last_alert_ts 無し(旧 schema)は「未警報」扱いで即 alert(後方互換)。
            alert_ts = entry.get("last_alert_ts")
            alert_dt = parse_iso_to_naive_local(alert_ts) if isinstance(alert_ts, str) else None
            if alert_dt is not None and last_task_id == task.get("task_id"):
                since_alert_min = (now - alert_dt).total_seconds() / 60.0
                if since_alert_min < alert_cooldown_min:
                    base["action"] = "alert_cooldown"
                    base["detail"] = (f"escalation latch 中: 前回 alert から "
                                      f"{round(since_alert_min, 1)}分 "
                                      f"(< {alert_cooldown_min}分) ゆえ再警報抑止")
                    results.append(base)
                    continue
            base["action"] = "escalation_stop"
            base["detail"] = (f"連続 clear {consecutive}回 (≥{max_consecutive}) で復帰せず。"
                              f"clear-loop 断ち切り→karo alert")
            # alert 発行成功時に caller が last_alert_ts を永続化(cooldown の要)。
            entry = dict(entry)
            entry["last_alert_ts"] = now.isoformat(timespec="seconds")
            base["_new_state"] = entry
            results.append(base)
            continue

        # revive 決定
        base["action"] = "revive"
        base["detail"] = (f"複合 AND 成立: spinner無 + status={status}未完 + "
                          f"出力停止{idle_min_disp}分")
        # state 更新(実発行は非 dry-run 時に caller が行うが、記録は一括で反映)
        entry = dict(entry)
        entry["last_clear_ts"] = now.isoformat(timespec="seconds")
        entry["consecutive"] = consecutive + 1
        entry["last_task_id"] = task.get("task_id")
        # 新 clear cycle 開始 → 旧 task の alert 時刻を残すと task 変更後の
        # 同名 latch で誤 cooldown するためクリア (cmd_1280)。
        entry.pop("last_alert_ts", None)
        base["_new_state"] = entry
        results.append(base)

    return results, clear_log


# ─────────────────────────────────────────────────────────────
# revive 発行
# ─────────────────────────────────────────────────────────────
def format_clear_body(hit, context=""):
    ctx = f"{context} " if context else ""
    return (f"idle固着検知({hit['idle_min']}分 出力停止・spinner無・task {hit['task_id']} 未完)。"
            f"{ctx}"
            f"/clear で session reset → task YAML 再読で自走再開せよ。"
            f"(idle_revive_scan cmd_1154)")


def format_escalation_alert(hit, context=""):
    ctx = f" 判断材料: {context}" if context else ""
    return (f"🚨 clear-loop 断ち切り: {hit['agent']} を連続 {hit['consecutive']}回 "
            f"clear しても復帰せず (task {hit['task_id']}, {hit['parent_cmd']})。"
            f"自動 revive を停止した。手動確認要。{ctx}"
            f"(idle_revive_scan cmd_1154)")


def format_karo_clear_body(hit, context=""):
    ctx = f"{context} " if context else ""
    return (f"家老degrade検知(dashboard {hit['idle_min']}分 stale + active task 存在)。"
            f"{ctx}"
            f"/clear で session reset → SessionStart hook で persona/戦国口調/state 復旧 → "
            f"CLAUDE.md Session Start で queue YAML から dashboard 再構築せよ"
            f"(state は YAML 永続ゆえ非破壊)。(idle_revive_scan cmd_1154)")


def format_karo_escalation_alert(hit, context=""):
    ctx = f" 判断材料: {context}" if context else ""
    return (f"🚨 家老 clear-loop 断ち切り: karo を連続 {hit['consecutive']}回 clear しても "
            f"dashboard staleness({hit['idle_min']}分)解消せず。自動 revive を停止した。"
            f"家老 session を手動確認要。{ctx}(idle_revive_scan cmd_1154)")


def send_inbox(target, body, msg_type, from_agent):
    return subprocess.run(
        ["bash", str(INBOX_WRITE_SH), target, body, msg_type, from_agent],
        capture_output=True, text=True,
    )


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true",
                    help="判定を stdout に出すのみ(clear/alert を発行しない・state 書込なし)。")
    ap.add_argument("--stall-min", type=int, default=DEFAULT_STALL_MIN,
                    help=f"(c) 出力 file 無更新の許容分=slow_gen_grace (default {DEFAULT_STALL_MIN})。")
    ap.add_argument("--min-interval-min", type=int, default=DEFAULT_MIN_INTERVAL_MIN,
                    help=f"rate limit: 同一 agent 連続 clear 最小間隔分 (default {DEFAULT_MIN_INTERVAL_MIN})。")
    ap.add_argument("--max-consecutive", type=int, default=DEFAULT_MAX_CONSECUTIVE,
                    help=f"連続 clear 上限。超過で escalation 停止 (default {DEFAULT_MAX_CONSECUTIVE})。")
    ap.add_argument("--alert-cooldown-min", type=int, default=DEFAULT_ALERT_COOLDOWN_MIN,
                    help=f"escalation latch 中の同一 agent 同一 task 再警報の抑止間隔分 "
                         f"(default {DEFAULT_ALERT_COOLDOWN_MIN})。")
    ap.add_argument("--karo-stale-min", type=int, default=DEFAULT_KARO_STALE_MIN,
                    help=f"Task B: dashboard.md staleness 閾値分 (default {DEFAULT_KARO_STALE_MIN})。")
    ap.add_argument("--karo-min-interval-min", type=int, default=DEFAULT_KARO_MIN_INTERVAL_MIN,
                    help=f"Task B: karo 連続 clear 最小間隔分 (default {DEFAULT_KARO_MIN_INTERVAL_MIN})。")
    ap.add_argument("--no-karo-check", action="store_true",
                    help="Task B: 家老degrade check を無効化(足軽/軍師 idle scan のみ)。")
    ap.add_argument("--dashboard-path", type=Path, default=None,
                    help=f"Task B: dashboard.md path 上書き (default {DEFAULT_DASHBOARD})。主にテスト用。")
    ap.add_argument("--pane-state-file", type=Path, default=None,
                    help="smoke/test: pane 状態(agent→busy/idle/absent の JSON/YAML mapping)を "
                         "注入し tmux probe を bypass。")
    ap.add_argument("--json", action="store_true", help="結果を JSON で出力。")
    ap.add_argument("--queue-root", type=Path, default=None,
                    help="queue root 上書き(tasks/ reports/ state/ を含む)。主にテスト用。")
    args = ap.parse_args(argv)

    if args.queue_root is not None:
        tasks_dir = args.queue_root / "tasks"
        reports_dir = args.queue_root / "reports"
        state_path = args.queue_root / "state" / "clear_log.yaml"
    else:
        tasks_dir = DEFAULT_TASKS_DIR
        reports_dir = DEFAULT_REPORTS_DIR
        state_path = DEFAULT_STATE_DIR / "clear_log.yaml"

    dashboard_path = args.dashboard_path if args.dashboard_path is not None else DEFAULT_DASHBOARD

    if args.pane_state_file is not None:
        pane_states = load_pane_state_file(args.pane_state_file)
    else:
        pane_states = get_pane_states(REPO_ROOT)
    clear_log = load_clear_log(state_path)

    results, new_clear_log = scan(
        tasks_dir, reports_dir, REPO_ROOT, pane_states, clear_log,
        stall_min=args.stall_min,
        min_interval_min=args.min_interval_min,
        max_consecutive=args.max_consecutive,
        alert_cooldown_min=args.alert_cooldown_min,
    )

    # ── Task B: 家老 degrade 検知(同居)。scan() の clear_log を引き継ぐ。 ──
    if not args.no_karo_check:
        karo_hit, new_clear_log = scan_karo_degrade(
            dashboard_path, tasks_dir, reports_dir, new_clear_log,
            karo_stale_min=args.karo_stale_min,
            karo_min_interval_min=args.karo_min_interval_min,
            max_consecutive=args.max_consecutive,
            alert_cooldown_min=args.alert_cooldown_min,
        )
        if karo_hit is not None:
            results.append(karo_hit)

    if args.json:
        printable = [{k: v for k, v in r.items() if not k.startswith("_")}
                     for r in results]
        print(json.dumps(printable, ensure_ascii=False))
    else:
        if not results:
            print("[idle_revive] revive 対象なし(全 agent 稼働 or 完了 or 出力漸進)。")
        for r in results:
            print(f"ACTION={r['action']} AGENT={r['agent']} TASK_ID={r['task_id']} "
                  f"IDLE_MIN={r['idle_min']} CONSECUTIVE={r['consecutive']} "
                  f"— {r['detail']}")

    if args.dry_run:
        return 0

    # ── 実発行(非 dry-run) ──
    exit_code = 0
    # scan() 段階の reset(復帰した agent の consecutive=0 等)も永続化対象に含める。
    state_dirty = (new_clear_log != clear_log)
    for r in results:
        is_karo = (r["agent"] == KARO_STATE_KEY)
        if r["action"] == "revive":
            # cmd_1339 (e): /clear は★破壊的操作★ — 発行直前に対象 pane を再 probe し、
            # busy/absent/unknown へ転じていれば発行しない (scan→発行の TOCTOU 封鎖)。
            # 判定不能 (unknown) も発行しない = 破壊的操作は疑わしきは止める側に倒す。
            state_now = probe_agent_state(r["agent"])
            if state_now != "idle":
                print(f"[idle_revive] SKIP(発行直前gate): {r['agent']} は再probeで "
                      f"{state_now} — 破壊的 /clear を発行せず (cmd_1339 (e))",
                      file=sys.stderr)
                # state を進めない (rate limit / consecutive を消費させない)
                if r["agent"] in clear_log:
                    new_clear_log[r["agent"]] = clear_log[r["agent"]]
                else:
                    new_clear_log.pop(r["agent"], None)
                continue
            # cmd_1339 (f): 家老が後から誤検知/真stall を検分できる文脈を本文へ添付
            context = agent_context_note(r["agent"], reports_dir)
            body = (format_karo_clear_body(r, context) if is_karo
                    else format_clear_body(r, context))
            proc = send_inbox(r["agent"], body, "clear_command", "idle_revive_scan")
            if proc.returncode != 0:
                print(f"[idle_revive] ERROR: clear_command 発行失敗 {r['agent']}: "
                      f"{proc.stderr.strip()}", file=sys.stderr)
                exit_code = 1
                # 発行失敗時は state を進めない(次回再試行)。旧 state を維持。
                if r["agent"] in clear_log:
                    new_clear_log[r["agent"]] = clear_log[r["agent"]]
                else:
                    new_clear_log.pop(r["agent"], None)
            else:
                # 発行成功 → last_clear_ts / consecutive を永続化(rate limit の要)。
                # scan() が算出した _new_state を反映しないと連続回数が進まず、
                # cron 毎回 clear 再発行 → ≥5分間隔 / escalation 停止が機能しない。
                new_clear_log[r["agent"]] = r["_new_state"]
                state_dirty = True
        elif r["action"] == "escalation_stop":
            # karo degrade の escalation は shogun へ(karo 自身が復帰不能ゆえ)。
            # 足軽/軍師の escalation は従来どおり karo へ。
            # cmd_1339 (f): 警報に対象 agent の直前文脈 (pane末尾/report mtime) を添付
            context = agent_context_note(r["agent"], reports_dir)
            if is_karo:
                target, body = "shogun", format_karo_escalation_alert(r, context)
            else:
                target, body = "karo", format_escalation_alert(r, context)
            proc = send_inbox(target, body,
                              "idle_revive_escalation_alert", "idle_revive_scan")
            if proc.returncode != 0:
                print(f"[idle_revive] ERROR: escalation alert 発行失敗: "
                      f"{proc.stderr.strip()}", file=sys.stderr)
                exit_code = 1
            elif "_new_state" in r:
                # alert 発行成功 → last_alert_ts を永続化(再警報 cooldown の要・cmd_1280)。
                # 発行失敗時は進めない(次回 scan で再試行)。
                new_clear_log[r["agent"]] = r["_new_state"]
                state_dirty = True

    if state_dirty:
        try:
            save_clear_log(state_path, new_clear_log)
        except OSError as e:
            print(f"[idle_revive] ERROR: clear_log 書込失敗: {e}", file=sys.stderr)
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
