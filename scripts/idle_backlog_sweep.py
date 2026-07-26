#!/usr/bin/env python3
"""
idle_backlog_sweep.py — cron backstop for karo idle backlog auto-pull (cmd_1095)

判定条件(全 true で nudge):
  1. in_progress cmd ゼロ
  2. deferred & autopull:eligible が 1 件以上
  3. 空き足軽 1 体以上
  4. cooldown: 直近 nudge から 20 分以上 & 未処理 idle_backlog_sweep nudge なし

false 条件が 1 つでもあれば無書込で静かに終了(空振り静か)。
冪等: nudge 内容は「評価せよ」のみ — 実際の pull 可否はすべて karo 側ガードが再判定。
"""

import sys
import os
import subprocess
import datetime
import yaml
from pathlib import Path

ROOT = Path(__file__).parent.parent
SHOGUN_TO_KARO = ROOT / "queue" / "shogun_to_karo.yaml"
KARO_INBOX = ROOT / "queue" / "inbox" / "karo.yaml"
SWEEP_LOG = ROOT / "logs" / "idle_backlog_sweep.log"
COOLDOWN_MINUTES = 20
DRY_RUN = "--dry-run" in sys.argv


def log(msg: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def check_in_progress_zero() -> bool:
    """shogun_to_karo.yaml に status: in_progress の cmd がゼロか確認。

    YAML parse 失敗時は grep フォールバックで top-level status 行を確認。
    """
    if not SHOGUN_TO_KARO.exists():
        log("WARN: shogun_to_karo.yaml not found — treating as in_progress=0")
        return True
    try:
        data = yaml.safe_load(SHOGUN_TO_KARO.read_text(encoding="utf-8")) or {}
        cmds = data.get("commands") or []
        for c in cmds:
            if isinstance(c, dict) and c.get("status") == "in_progress":
                log(f"SKIP: in_progress cmd found: {c.get('id', '?')}")
                return False
        return True
    except Exception:
        # YAML parse 失敗 → grep フォールバック
        try:
            result = subprocess.run(
                ["grep", "-n", "status: in_progress", str(SHOGUN_TO_KARO)],
                capture_output=True, text=True
            )
            if result.returncode == 0 and result.stdout.strip():
                log(f"SKIP (grep fallback): in_progress found:\n{result.stdout.strip()[:200]}")
                return False
            return True
        except Exception as e2:
            log(f"ERROR: grep fallback failed: {e2} — skipping nudge for safety")
            return False


def check_eligible_deferred() -> bool:
    """status:deferred かつ defer.autopull:eligible の cmd が 1 件以上あるか。"""
    if not SHOGUN_TO_KARO.exists():
        return False
    try:
        data = yaml.safe_load(SHOGUN_TO_KARO.read_text(encoding="utf-8")) or {}
        cmds = data.get("commands") or []
        for c in cmds:
            if not isinstance(c, dict):
                continue
            if c.get("status") == "deferred":
                defer = c.get("defer") or {}
                if defer.get("autopull") == "eligible":
                    return True
        log("SKIP: no deferred+eligible cmd found")
        return False
    except Exception:
        # YAML parse 失敗 → grep フォールバック (deferred+eligible の両パターン連続確認)
        try:
            result = subprocess.run(
                ["grep", "-c", "autopull: eligible", str(SHOGUN_TO_KARO)],
                capture_output=True, text=True
            )
            if result.returncode == 0 and result.stdout.strip() not in ("", "0"):
                return True
            log("SKIP (grep fallback): no eligible deferred found")
            return False
        except Exception as e2:
            log(f"ERROR: grep fallback for eligible failed: {e2}")
            return False


def check_ashigaru_available() -> bool:
    """空き足軽が 1 体以上いるか (agent_status.sh 経由)。"""
    script = ROOT / "scripts" / "agent_status.sh"
    if not script.exists():
        log("WARN: agent_status.sh not found — assuming no free ashigaru")
        return False
    try:
        result = subprocess.run(
            ["bash", str(script)],
            capture_output=True, text=True, timeout=30
        )
        output = result.stdout
        # 「待機中」行(Pane=待機中)かつ ashigaru* を含む行があれば空きあり
        for line in output.splitlines():
            if "ashigaru" in line.lower() and "待機中" in line:
                return True
        log("SKIP: no idle ashigaru found")
        return False
    except Exception as e:
        log(f"WARN: agent_status.sh failed: {e} — assuming no free ashigaru")
        return False


def check_cooldown() -> bool:
    """cooldown: 直近 idle_backlog_sweep nudge から 20 分以上経過 & 未処理 nudge なし。"""
    if not KARO_INBOX.exists():
        return True
    try:
        data = yaml.safe_load(KARO_INBOX.read_text(encoding="utf-8")) or {}
        msgs = data.get("messages") or []
        now = datetime.datetime.now()
        last_sent = None
        for m in msgs:
            if not isinstance(m, dict):
                continue
            if m.get("type") != "idle_backlog_sweep":
                continue
            # 未処理 (read:false) の nudge がある → 重複抑止
            if not m.get("read", False):
                log("SKIP: unprocessed idle_backlog_sweep nudge exists in karo inbox")
                return False
            # 最新 sent timestamp を追跡
            ts_str = m.get("timestamp", "")
            if ts_str:
                try:
                    ts = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                    if ts.tzinfo is not None:
                        ts = ts.astimezone().replace(tzinfo=None)
                    if last_sent is None or ts > last_sent:
                        last_sent = ts
                except ValueError:
                    pass
        if last_sent is not None:
            elapsed = (now - last_sent).total_seconds() / 60
            if elapsed < COOLDOWN_MINUTES:
                log(f"SKIP: cooldown active ({elapsed:.1f} min < {COOLDOWN_MINUTES} min)")
                return False
        return True
    except Exception as e:
        log(f"ERROR parsing karo inbox: {e} — skipping nudge for safety")
        return False


def send_nudge() -> None:
    """inbox_write.sh 経由で karo に idle_backlog_sweep nudge を送る。"""
    inbox_write = ROOT / "scripts" / "inbox_write.sh"
    if not inbox_write.exists():
        log("ERROR: inbox_write.sh not found — cannot send nudge")
        return
    if DRY_RUN:
        log("DRY-RUN: would send nudge to karo (idle_backlog_sweep)")
        return
    try:
        result = subprocess.run(
            [
                "bash", str(inbox_write),
                "karo",
                "idle backlog あり。自動pull評価せよ。",
                "idle_backlog_sweep",
                "watcher"
            ],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            log("NUDGE SENT to karo (idle_backlog_sweep)")
        else:
            log(f"ERROR: inbox_write.sh failed: {result.stderr.strip()}")
    except Exception as e:
        log(f"ERROR sending nudge: {e}")


def main() -> None:
    if DRY_RUN:
        log("--- DRY-RUN mode (no writes) ---")

    # ガード1: in_progress ゼロ
    if not check_in_progress_zero():
        return

    # ガード2: eligible deferred あり
    if not check_eligible_deferred():
        return

    # ガード3: 空き足軽あり
    if not check_ashigaru_available():
        return

    # ガード4: cooldown
    if not check_cooldown():
        return

    # 全ガード通過 → nudge 送信
    log("All guards passed → sending idle_backlog_sweep nudge")
    send_nudge()


if __name__ == "__main__":
    main()
