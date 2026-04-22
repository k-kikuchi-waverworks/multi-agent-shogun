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
    return (t.get("task_id"), t.get("parent_cmd"), t.get("status"))


def extract_report_record(doc):
    if not isinstance(doc, dict):
        return None
    inner = doc["report"] if isinstance(doc.get("report"), dict) else doc
    task_id = inner.get("task_id") or inner.get("primary_task")
    status = inner.get("status")
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
        report_path = reports_dir / f"{agent}_report.yaml"
        if not report_path.is_file():
            continue
        latest, latest_dt = parse_report_latest(report_path)
        if not latest or latest_dt is None:
            continue
        r_task_id, r_status, _r_ts = latest
        if r_task_id != task_id:
            continue
        if not isinstance(r_status, str) or r_status.lower() not in COMPLETION_STATUSES:
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
    return hits


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

    hits = scan(tasks_dir, reports_dir, args.threshold_min)

    if args.json:
        print(json.dumps(hits, ensure_ascii=False))
    else:
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
