#!/usr/bin/env python3
# stall_watchdog_scan.py — cmd_552 Phase 3 Watchdog: report↔task YAML 突合 scan
#
# Detects bookkeeping omissions where a task YAML stays `status: assigned`
# while the corresponding report YAML already records completion
# (`done`/`completed`/`success`) past a threshold elapsed time.
#
# Usage:
#   python3 scripts/stall_watchdog_scan.py [--dry-run] [--threshold-min N] [--json]
#     [--queue-root PATH]
#
# On hit: writes a `stall_watchdog_bookkeeping_alert` message to karo inbox via
# `scripts/inbox_write.sh`.

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TASKS_DIR = REPO_ROOT / "queue" / "tasks"
DEFAULT_REPORTS_DIR = REPO_ROOT / "queue" / "reports"
INBOX_WRITE_SH = REPO_ROOT / "scripts" / "inbox_write.sh"

COMPLETION_STATUSES = {"done", "completed", "success"}
DEFAULT_THRESHOLD_MIN = 30
SCANNED_AGENT_PREFIXES = ("ashigaru",)
SCANNED_AGENT_NAMES = {"gunshi"}


# status は機械 token ([a-z_]) — 最初の ASCII 語 run が status 本体。装飾は何であれ語ではない。
_STATUS_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_]*")


def normalize_status(value):
    """status 文字列を照合可能な正規形へ (最初の ASCII 語 run の抽出 + lowercase)。

    idle_revive_scan.py の同名関数と同型 (cmd_1356 d8fc7fd の同処方)。家老の帳簿慣行
    `status: 'assigned   # 2026-07-26 07:23 家老dispatch=…'` は YAML 上【引用符内の
    一つの文字列】であり、生のまま "assigned" と完全一致照合すると注記付き task が
    全て scan に不可視になる。本 scan では task 側 (assigned 照合) と report 側
    (COMPLETION_STATUSES 照合) の両方が同じ穴を持っておった = 帳簿漏れ alert が
    注記1つで永久に沈黙する (alert は「撃たれなかった」ことに誰も気付けぬ型)。
    注記は運用上有用ゆえ家老は書き続ける —「注記が在っても読める」側で吸収する。

    ★初版 (先頭空白 token + 末尾 :;,. 落とし) は装飾の blocklist であった★ —
    軍師二号 OBS-2 が『★assigned★家老dispatch★』(空白を挟まぬ ★ 密着)・全角括弧/
    全角句読点・…・—・/ の 9 形で盲目が戻ることを実証した (家老は ★ を常用ゆえ
    現実の的)。blocklist は次の装飾文字で必ず破れる — ★語の側を allowlist で取る★:
    status は機械 token ([A-Za-z][A-Za-z0-9_]*) ゆえ最初の ASCII 語 run が status。
    最初の run を採る = 注記中の状態語には乗っ取られぬ (偽 HIT を作らぬ側の契約
    T-SWD-002 は据え置き)。ASCII 語が一つも無ければ "" (従来どおり不可視)。
    idle_revive 側との copy drift は各 copy の変異登録 (MUT-1154-001,003 /
    MUT-0552-001,002,004) が独立に見張る。
    """
    if not isinstance(value, str):
        return value
    m = _STATUS_TOKEN_RE.search(value)
    return m.group(0).lower() if m else ""


def parse_task(path: Path):
    try:
        with path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"[stall_watchdog] WARN: task YAML parse failed: {path}: {e}",
              file=sys.stderr)
        return None
    if not isinstance(data, dict) or not isinstance(data.get("task"), dict):
        return None
    t = data["task"]
    # status は正規化して返す = 消費点 (scan の assigned 照合) が注記付きでも読める。
    # 出所は本関数の1点のみ (二重管理禁)。
    return (t.get("task_id"), t.get("parent_cmd"), normalize_status(t.get("status")))


def extract_report_record(doc):
    if not isinstance(doc, dict):
        return None
    inner = doc["report"] if isinstance(doc.get("report"), dict) else doc
    task_id = inner.get("task_id") or inner.get("primary_task")
    # report 側も同じ注記慣行がありうる — task 側と同じ正規形で読む (出所は本関数の1点)。
    # alert 本文へ運ばれるのも正規化 token = 注記の生文字列を inbox へ流さぬ。
    status = normalize_status(inner.get("status"))
    ts = inner.get("timestamp")
    return (task_id, status, ts)


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


def parse_report_latest(path: Path):
    try:
        with path.open(encoding="utf-8") as f:
            docs = list(yaml.safe_load_all(f))
    except yaml.YAMLError as e:
        print(f"[stall_watchdog] WARN: report YAML parse failed: {path}: {e}",
              file=sys.stderr)
        return None, None
    latest = None
    latest_dt = None
    for doc in docs:
        rec = extract_report_record(doc)
        if not rec:
            continue
        task_id, status, ts = rec
        if not ts:
            continue
        dt = parse_iso_to_naive_local(ts)
        if dt is None:
            continue
        if latest_dt is None or dt > latest_dt:
            latest, latest_dt = rec, dt
    return latest, latest_dt


def should_scan_agent(agent: str) -> bool:
    if agent in SCANNED_AGENT_NAMES:
        return True
    return any(agent.startswith(p) for p in SCANNED_AGENT_PREFIXES)


def scan(tasks_dir: Path, reports_dir: Path, threshold_min: int, now=None):
    if now is None:
        now = datetime.datetime.now()
    hits = []
    # assigned_count = scan の目に映った assigned task の分母。hit 0 件時に印字する =
    # 「分母0 (status drift 等で何も見えておらぬ)」と「全員健全 (帳簿漏れなし)」を
    # log 上で区別可能にする (idle_revive の eligible=N と同処方・家老裁定 09:24)。
    assigned_count = 0
    for task_path in sorted(tasks_dir.glob("*.yaml")):
        agent = task_path.stem
        if not should_scan_agent(agent):
            continue
        parsed = parse_task(task_path)
        if not parsed:
            continue
        task_id, parent_cmd, task_status = parsed
        if task_status != "assigned":
            continue
        assigned_count += 1
        report_path = reports_dir / f"{agent}_report.yaml"
        if not report_path.is_file():
            continue
        latest, latest_dt = parse_report_latest(report_path)
        if not latest or latest_dt is None:
            continue
        r_task_id, r_status, _r_ts = latest
        if r_task_id != task_id:
            continue
        # r_status は extract_report_record で正規化済 (注記付き 'completed   # …' も
        # 完了と読める。lowercase も正規化に含まれる)。
        if not isinstance(r_status, str) or r_status not in COMPLETION_STATUSES:
            continue
        elapsed_min = int((now - latest_dt).total_seconds() // 60)
        if elapsed_min < threshold_min:
            continue
        hits.append({
            "agent": agent,
            "task_id": task_id,
            "parent_cmd": parent_cmd,
            "elapsed_min": elapsed_min,
            "report_status": r_status,
        })
    return hits, assigned_count


def format_alert_message(hit):
    return (f"🚨 bookkeeping 漏れ検出: {hit['agent']} task YAML "
            f"({hit['task_id']}, {hit['parent_cmd']}) status=assigned のまま、"
            f"report では {hit['report_status']} で {hit['elapsed_min']} 分経過。"
            f"status=done 更新 + 次 MT 起票要。")


def notify_karo(hit):
    msg = format_alert_message(hit)
    proc = subprocess.run(
        ["bash", str(INBOX_WRITE_SH), "karo", msg,
         "stall_watchdog_bookkeeping_alert", "stall_watchdog"],
        capture_output=True, text=True,
    )
    return proc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true",
                    help="Print hits to stdout without writing to karo inbox.")
    ap.add_argument("--threshold-min", type=int, default=DEFAULT_THRESHOLD_MIN,
                    help=f"Elapsed-minutes threshold (default {DEFAULT_THRESHOLD_MIN}).")
    ap.add_argument("--json", action="store_true",
                    help="Emit hits as JSON (skeleton for future dashboard wiring).")
    ap.add_argument("--queue-root", type=Path, default=None,
                    help="Override queue root (expects tasks/ and reports/ subdirs). "
                         "Primarily for tests.")
    args = ap.parse_args(argv)

    if args.queue_root is not None:
        tasks_dir = args.queue_root / "tasks"
        reports_dir = args.queue_root / "reports"
    else:
        tasks_dir = DEFAULT_TASKS_DIR
        reports_dir = DEFAULT_REPORTS_DIR

    hits, assigned_count = scan(tasks_dir, reports_dir, args.threshold_min)

    if args.json:
        print(json.dumps(hits, ensure_ascii=False))
    else:
        if not hits:
            # 無出力を契約にせぬ: assigned 存在下で assigned=0 が常態なら scan は
            # 盲目である (2026-07-26 注記drift の型)。分母0の検知層は全PASSと
            # 区別がつかぬ — hit なしでも分母を名指しで残す (家老裁定 09:24)。
            print(f"[stall_watchdog] 帳簿漏れ hit なし。assigned={assigned_count}")
        for h in hits:
            print(f"AGENT={h['agent']} TASK_ID={h['task_id']} "
                  f"PARENT_CMD={h['parent_cmd']} ELAPSED_MIN={h['elapsed_min']} "
                  f"REPORT_STATUS={h['report_status']}")

    if args.dry_run or args.queue_root is not None:
        return 0

    exit_code = 0
    for h in hits:
        proc = notify_karo(h)
        if proc.returncode != 0:
            print(f"[stall_watchdog] ERROR: inbox_write failed for {h['agent']}: "
                  f"{proc.stderr.strip()}", file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
