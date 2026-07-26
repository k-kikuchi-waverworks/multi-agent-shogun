#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""report_validate.py — report YAML の自己検め (cmd_1395)

★なぜ要るか★
    report は家老の唯一の受領経路である。★壊れれば、完遂が黙って消える★。
    本夜 現に起きた = 軍師一号の report が parse 落ちし、番人が其の完遂を読めず
    「働いておるのに idle」と誤判定した (五号が --dry-run で裏付け)。
    logs/idle_revive_scan.log の census = ★report YAML parse failed が 138 行・
    書き手 8 名すべてに前科が在る★ = 稀な事故ではなく常態である。

★何処へ据えるか (単一・cmd_1395 で (b) を採った)★
    Claude Code の PostToolUse hook (Write|Edit)。★書き手の側で落ちる★=
    家老が読む前に、書いた本人の画面へ返る。watcher でも規律でもない理由は
    docs/content/ops/cmd_1395_report_validate.md の実測比較を見よ。

★判定規則は【発明せぬ】= 実在の読み手の code から写す★
    此の門が問うのは「YAML として綺麗か」ではない。★現に居る読み手が読めるか★である。
    ゆえに規則1本ごとに、守っておる読み手の行を名指しできる:

    R1 safe_load_all が落ちる
       読み手 = scripts/idle_revive_scan.py:1302 / scripts/stall_watchdog_scan.py:112
       害     = 番人が完遂を読めぬ ⇒ ★働いておる者を idle と誤判定★ (本夜の実害そのもの)
    R2 safe_load (単一 document) が落ちる ＆ 当該 stem が slim_yaml の除外表に無い
       読み手 = scripts/slim_yaml.py:273 load_yaml (safe_load。失敗すると {} を返す)
       害     = parent_cmd を読めぬ ⇒ 非 active と見なされ ★queue/reports/ から archive へ移される★
                (cmd_1395 で sandbox 実走にて実証。同条件の健全 file は残り、壊れた方だけが移った)
       ★除外表 CANONICAL_REPORTS は slim_yaml から import する★= 読み手が変われば此の門も
       黙って追随する (写経すれば読み手と門の二つが黙って割れるゆえ)
    R3 mapping 内の同名 key
       害     = ★YAML 後勝ちで先の記録が黙って消える★ = どの読み手も救えぬ (load 時点で既に無い)
       出所   = ledger_validate.py の cmd_1341 と同型。台帳で起きた事は report でも起きる
    R4 document が mapping でない
       読み手 = 上記いずれも `isinstance(doc, dict)` でない doc を ★黙って skip する★
       害     = 落ちもせず、読まれもせぬ = 最も見つけにくい形で記録が消える

★fail-OPEN (loud)★
    此の門の誤りで全 agent の Write が止まる方が害が大きい。内部異常は通す。
    ★但し黙って通さぬ★= stderr へ出す (黙る番人こそ本 cmd の敵ゆえ)。

Usage:
    report_validate.py <report.yaml> [...]   # 手検め (exit 0=PASS / 1=FAIL)
    report_validate.py --selftest            # 変異試験 (己の牙が立っておるかを己で検める)
    report_validate.py --liveness            # ★門が現に走っておる pane を数える★
    (引数なし + stdin JSON)                  # PostToolUse hook 経路
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import time

import yaml

# slim_yaml の除外表を【写さず借りる】 — 読み手が変われば此の門も追随する
_SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
try:
    from slim_yaml import CANONICAL_REPORTS  # noqa: E402

    BORROW_ERROR = None
except Exception as _exc:  # fail-OPEN (loud) — 借りられねば R2 を諦め、其の旨を名乗る
    # ★之を「report が壊れておる」として数えぬ★ = 借り損ねは【門の不調】であって
    #   【書き手の落度】ではない。混ぜれば全ての書込が赤くなり、★狼少年になった門は
    #   本物の赤まで無視される★ (本 repo が繰り返し踏んでおる型)。
    #   ⇒ 書き手へは返さず stderr で名乗り、★--selftest では NG にする★ (機械が捕える)。
    CANONICAL_REPORTS = None
    BORROW_ERROR = f"{type(_exc).__name__}: {_exc}"


# ══════════════════════════════════════════════════════════════════════════
# 心拍 — ★此の門が【此の pane で】現に走っておるかを、外から測れる形★ (cmd_1371 の作法)
#
# ★之が要る理由は cmd_1395 の実測で出た★:
#   .claude/settings.json へ配線を足しても、★既に走っておる session では鳴らなんだ★
#   (実測 = probe を書いても feedback 無し。同時刻に PreToolUse の心拍は更新されており、
#    ★hook 機構は生きておる★ = 死んでおるのは【新しい配線が session 開始時の snapshot に
#    載っておらぬ】一点である)。
#   ⇒ ★「苦情が出ぬ」は【report が綺麗】とも【門が一度も走っておらぬ】とも読める★。
#     心拍が無ければ此の二つを分けられぬ = 本 repo が繰り返し踏んでおる「黙る番人」そのもの。
# ══════════════════════════════════════════════════════════════════════════
HEARTBEAT_DIRNAME = "queue/.report_guard_heartbeat"
HEARTBEAT_FRESH_SEC = 90 * 60  # ★Bash と違い Write は間遠ゆえ長く採る (60分)★


def heartbeat_key(payload: dict | None = None) -> str:
    """心拍の鍵 = ★pane 単位★ (隣の pane の心拍を己の生存と読み違えぬため)。"""
    raw = os.environ.get("TMUX_PANE") or (payload or {}).get("session_id") or "nopane"
    return re.sub(r"[^A-Za-z0-9_.-]", "_", str(raw))[:64]


def heartbeat_dir() -> pathlib.Path:
    return _SCRIPTS_DIR.parent / HEARTBEAT_DIRNAME


def touch_heartbeat(payload: dict | None = None) -> None:
    """★門が走った証★を残す。report 以外の書込 (素通り) でも必ず残す。fail-OPEN (loud)。"""
    try:
        d = heartbeat_dir()
        d.mkdir(parents=True, exist_ok=True)
        (d / heartbeat_key(payload)).write_text(
            f"{time.time():.3f} {os.getpid()}\n", encoding="utf-8"
        )
    except Exception as exc:
        print(f"[report_validate] WARN: 心拍を残せなんだ — 続行: {exc}", file=sys.stderr)


def liveness() -> int:
    """心拍を読み、★門が生きておる pane★ を数える。断定できぬ側は赤へ倒す。"""
    d = heartbeat_dir()
    beats = sorted(d.glob("*")) if d.is_dir() else []
    now = time.time()
    live = 0
    print(f"=== report_validate 心拍 ({d}) ===")
    if not beats:
        print("  ★心拍が1つも無い = 此の門は一度も走っておらぬ★"
              " (配線直後なら正常 — 各 agent が session を開き直すまで効かぬ)")
        return 1
    for b in beats:
        try:
            age = now - float(b.read_text(encoding="utf-8").split()[0])
        except Exception:
            print(f"  ?   {b.name}: 心拍を読めぬ")
            continue
        alive = age <= HEARTBEAT_FRESH_SEC
        live += 1 if alive else 0
        print(f"  {'生' if alive else '古'} {b.name}: {age / 60:.1f} 分前")
    print(f"=== 生きておる pane = {live} / 心拍 {len(beats)} 本 "
          f"(★『古』は死んでおるの断定ではない — 其の pane が暫く書いておらぬだけやも知れぬ★) ===")
    return 0 if live else 1


class DuplicateKeyError(yaml.YAMLError):
    """mapping 内の同名 key (YAML 後勝ちで記録が黙って消える) を表す。"""


class UniqueKeyLoader(yaml.SafeLoader):
    """重複 key を【後勝ちで潰れる前】に捕える SafeLoader (ledger_validate と同型)。"""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _value_node in node.value:
            key = self.construct_object(key_node, deep=True)
            try:
                is_dup = key in seen
                seen.add(key)
            except TypeError:
                continue  # unhashable key は SafeLoader 本体が別途エラーにする
            if is_dup:
                raise DuplicateKeyError(
                    f"同名 key {key!r} (line {key_node.start_mark.line + 1}) "
                    f"— YAML 後勝ちで先の記録が黙って消える。一意な key 名で追記せよ"
                )
        return super().construct_mapping(node, deep=deep)


def is_report_path(path: pathlib.Path) -> bool:
    """queue/reports/*.yaml か。★queue/archive/reports/ は含めぬ★ (祖父が queue でないゆえ)。"""
    if path.suffix not in (".yaml", ".yml"):
        return False
    parent = path.parent
    return parent.name == "reports" and parent.parent.name == "queue"


def _fmt(exc: Exception) -> str:
    return " ".join(str(exc).split())


def validate_text(text: str, stem: str) -> list[str]:
    """report 本文を検める。落ちた規則の説明を list で返す (空 list = PASS)。"""
    problems: list[str] = []

    # ── R1 = 番人 2 体が使う loader (idle_revive_scan / stall_watchdog_scan) ──
    docs = None
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError as e:
        problems.append(
            f"[R1] safe_load_all が落ちる: {_fmt(e)}\n"
            f"     ⇒ 番人 (idle_revive_scan.py:1302 / stall_watchdog_scan.py:112) が此の report を読めぬ。"
            f" ★貴殿の完遂は届かず、【働いておるのに idle】と誤判定される★"
        )

    # ── R2 = slim_yaml の load_yaml (safe_load)。除外表に在る stem は読まれぬゆえ問わぬ ──
    if CANONICAL_REPORTS is None:
        pass  # ★門の不調は書き手の赤にせぬ★ (出所は BORROW_ERROR。--selftest と stderr が名乗る)
    elif stem not in CANONICAL_REPORTS:
        try:
            yaml.safe_load(text)
        except yaml.YAMLError as e:
            problems.append(
                f"[R2] safe_load (単一 document) が落ちる: {_fmt(e)}\n"
                f"     ⇒ slim_yaml.py:273 が {{}} を受け取り parent_cmd を読めぬ ⇒ 非 active と見なされ、"
                f" ★24h stale になった時 queue/reports/ から archive へ移される★"
                f" (stem '{stem}' は slim_yaml の除外表に無い = 現に読まれる側)"
            )

    # ── R3 = 後勝ちで黙って消える同名 key ──
    try:
        list(yaml.load_all(text, Loader=UniqueKeyLoader))
    except DuplicateKeyError as e:
        problems.append(
            f"[R3] {_fmt(e)}\n"
            f"     ⇒ どの読み手も救えぬ (load した時には既に先の記録が無い)"
        )
    except yaml.YAMLError:
        pass  # parse 自体の落ちは R1/R2 が既に名指しておる

    # ── R4 = 落ちもせず読まれもせぬ document ──
    if docs is not None:
        for i, doc in enumerate(docs):
            if doc is None:
                continue  # 空 document は害が無い
            if not isinstance(doc, dict):
                problems.append(
                    f"[R4] document[{i}] が mapping でない (got {type(doc).__name__})\n"
                    f"     ⇒ 読み手は isinstance(doc, dict) で ★黙って skip する★"
                    f" = 落ちもせず読まれもせぬ = 最も見つけにくい形で記録が消える"
                )

    return problems


def validate_file(path: pathlib.Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        return [f"[R0] 読めぬ: {e}"]
    return validate_text(text, path.stem)


def render(path: pathlib.Path, problems: list[str]) -> str:
    writer = path.stem.replace("_report", "")
    head = (
        f"[report_validate] ★{path} が壊れておる (書き手={writer})★\n"
        f"★家老は此の report を読めぬ = 貴殿の完遂は届かぬ★ — 直してから報告せよ。"
    )
    return head + "\n" + "\n".join(problems)


# ══════════════════════════════════════════════════════════════════════════
# 変異試験 — ★己の門を己で壊して検める★ (「書いたから効く」は本夜 三度 破られておる)
# ══════════════════════════════════════════════════════════════════════════
_HEALTHY = (
    "cmd_9001_example:\n"
    "  worker_id: ashigaru1\n"
    "  task_id: subtask_9001\n"
    "  status: done\n"
    "  timestamp: '2026-07-27T01:00:00'\n"
    "  items:\n"
    "    - 一つ目\n"
    "    - 二つ目\n"
)

# (名, 本文, stem, 期待する赤の needle。None = 緑であるべき)
_CASES = [
    (
        "M1 孤児 list (軍師一号が本夜 現に踏んだ機序 = list の途中へ mapping を挿す)",
        "cmd_9001_example:\n  items:\n    - 一つ目\n    key: 割り込み\n    - 孤児\n",
        "gunshi1_report",
        "[R1]",
    ),
    (
        "M2 多 document ＆ slim_yaml の除外表に無い stem",
        _HEALTHY + "---\ncmd_9002_example:\n  status: done\n",
        "gunshi1_report",
        "[R2]",
    ),
    (
        "M2n 同じ多 document なれど除外表に在る stem = ★緑★ (読み手が読まぬゆえ)",
        _HEALTHY + "---\ncmd_9002_example:\n  status: done\n",
        "ashigaru3_report",
        None,
    ),
    (
        "M3 同名 key (後勝ちで先の記録が黙って消える)",
        "cmd_9001_example:\n  status: done\n  progress: 一報目\n  progress: 二報目\n",
        "ashigaru1_report",
        "[R3]",
    ),
    (
        "M4 mapping でない document (落ちもせず読まれもせぬ)",
        _HEALTHY + "---\n- 一つ目\n- 二つ目\n",
        "ashigaru1_report",
        "[R4]",
    ),
    ("N1 無改変 = ★緑★", _HEALTHY, "ashigaru1_report", None),
]


def selftest() -> int:
    ok = True
    print("=== report_validate --selftest (変異=赤 / 無改変=緑) ===")
    # ★門の不調を、門の側で捕える★= R2 は slim_yaml から借りた表に依る。借り損ねれば
    #   R2 は黙って消える (書き手には何も見えぬ) ゆえ、機械が此処で名指す。
    if CANONICAL_REPORTS is None:
        ok = False
        print(f"  NG  B1 slim_yaml の除外表を借りられなんだ = ★R2 が黙って消えておる★: {BORROW_ERROR}")
    else:
        print(f"  ok  B1 除外表を借りられた ({len(CANONICAL_REPORTS)} 件)")
    for name, text, stem, needle in _CASES:
        problems = validate_text(text, stem)
        got_red = bool(problems)
        if needle is None:
            passed = not got_red
            detail = "" if passed else " / 出た赤=" + "; ".join(p.split("\n")[0] for p in problems)
        else:
            passed = got_red and any(needle in p for p in problems)
            detail = (
                " / 期待した needle が出ておらぬ: " + "; ".join(p.split("\n")[0] for p in problems)
                if not passed else " / " + "; ".join(p.split("\n")[0] for p in problems)
            )
        ok = ok and passed
        print(f"  {'ok ' if passed else 'NG '} {name}{detail}")

    # ★盤面の側の負例★= 現に在る report 9 本が緑であること (門が狼少年でない証)
    reports_dir = _SCRIPTS_DIR.parent / "queue" / "reports"
    live = sorted(reports_dir.glob("*.yaml")) if reports_dir.is_dir() else []
    for p in live:
        problems = validate_file(p)
        passed = not problems
        ok = ok and passed
        mark = "ok " if passed else "NG "
        detail = "" if passed else " / " + "; ".join(x.split("\n")[0] for x in problems)
        print(f"  {mark}N2 現物 {p.name} = 緑であるべき{detail}")
    if not live:
        print("  -- N2 現物の report が見当たらぬ (skip)")

    print("=== 総judge:", "PASS" if ok else "FAIL", "===")
    return 0 if ok else 1


# ══════════════════════════════════════════════════════════════════════════
# hook 経路 (PostToolUse: Write|Edit) — ★書き手の側で落ちる★
# ══════════════════════════════════════════════════════════════════════════
def hook_main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception as exc:  # fail-OPEN (loud)
        print(f"[report_validate] WARN: stdin JSON 解釈不能 — 通す: {exc}", file=sys.stderr)
        touch_heartbeat(None)  # ★JSON が読めずとも「門は呼ばれた」は真★
        return 0

    touch_heartbeat(payload)
    tool_input = payload.get("tool_input") or {}
    raw = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not raw:
        return 0

    path = pathlib.Path(str(raw))
    if not path.is_absolute():
        path = pathlib.Path(payload.get("cwd") or ".") / path
    path = path.resolve()

    if not is_report_path(path) or not path.is_file():
        return 0  # ★門は report 以外へ出歩かぬ★

    if CANONICAL_REPORTS is None:  # ★黙って痩せた守りにせぬ★ (書き手の赤とは別枠で名乗る)
        print(f"[report_validate] WARN: slim_yaml の除外表を借りられぬ = R2 が効いておらぬ:"
              f" {BORROW_ERROR}", file=sys.stderr)

    problems = validate_file(path)
    if not problems:
        return 0
    print(render(path, problems), file=sys.stderr)
    return 2  # PostToolUse: exit 2 = stderr を書き手へ返す


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--"]
    if "--selftest" in args:
        return selftest()
    if "--liveness" in args:
        return liveness()
    if not args:
        return hook_main()

    rc = 0
    for arg in args:
        path = pathlib.Path(arg).resolve()
        problems = validate_file(path)
        if problems:
            print(render(path, problems), file=sys.stderr)
            rc = 1
        else:
            print(f"PASS: {path}")
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # ★fail-OPEN だが黙らぬ★
        print(f"[report_validate] WARN: 内部異常 — 通す (fail-OPEN): {exc}", file=sys.stderr)
        sys.exit(0)
