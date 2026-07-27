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

    R5 (cmd_1407・警告のみ) ★門が己の要求する鍵を名乗る★
       R1〜R4 が問うたのは「読み手が parse できるか」までである。★parse できても
       読み手が【探しておる鍵】を持たねば、其の report は在って無いのと同じ★。
       六号が 05:46 に実測した形が之である = PASS を返した report を番人が読めておらぬ。
       読み手 = scripts/idle_revive_scan.py report_completion_state (1546-1585)
         1572  inner = doc["report"] if isinstance(doc.get("report"), dict) else doc
               ⇒ ★task_id を置く高さは「document 直下」か「report: の直下」の二つのみ★。
                 任意の名 (例 `cmd1426_two_writers:`) の下へ入れた鍵は ★読み手から見えぬ★。
         1573-1575  r_task_id != task_id なら continue  (★黙って飛ばす★)
         1576-1578  timestamp が解けねば continue      (★黙って飛ばす★)
         1534-1543  parse_iso_to_naive_local = ★isinstance(s, str) が偽なら即 None★
               ⇒ ★timestamp の引用符を外すと YAML が datetime へ変え、str でなくなり黙って飛ぶ★
       害 = status: done と書いてあっても not_done と読まれ、
            ★「働いておるのに idle」と判定される★ (cmd_1395 が塞いだ害の、鍵の側の面)
       ★落とさぬ★ = R5 は書き手の画面へ ★名指すだけ★ で、CLI の rc を赤にせぬ
            (家老 22:24 の枷「名指すまでに留めよ」)。hook 経路のみ exit 2 で書き手へ返すが、
            ★PostToolUse の exit 2 は既に済んだ書込を取り消さぬ★ = 何も落ちておらぬ。

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

import datetime
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


# ══════════════════════════════════════════════════════════════════════════
# R5 (cmd_1407) — ★門が【己の要求する鍵】を名乗る★
#
# ★規則を発明せぬ★= 下の 3 つは いずれも読み手の code を写した物である。
#   写経ではなく ★同じ形で書き、守っておる行を message に載せる★ (R1-R4 と同じ流儀)。
# ★警告のみ★= 返り値は problems と別の list。CLI の rc を赤にせぬ。
# ══════════════════════════════════════════════════════════════════════════
READER = "scripts/idle_revive_scan.py"
COMPLETION_WORDS = {"done", "completed", "complete", "finished"}


def reader_view(text: str) -> list[dict] | None:
    """★読み手が見る高さ★ の mapping を並べて返す (idle_revive_scan.py:1569-1572 の写し)。

    None = parse できぬ (R1 が既に名指しておる)。
    """
    try:
        parsed = list(yaml.safe_load_all(text))
    except yaml.YAMLError:
        return None
    view: list[dict] = []
    for doc in parsed:
        if not isinstance(doc, dict):
            continue  # 読み手も同じく飛ばす (R4 が別途 名指す)
        inner = doc["report"] if isinstance(doc.get("report"), dict) else doc
        if isinstance(inner, dict):
            view.append(inner)
    return view


def reader_can_parse_time(value) -> bool:
    """idle_revive_scan.py:1534-1543 (parse_iso_to_naive_local) と同じ判定。"""
    if not isinstance(value, str):
        return False  # ★引用符を外すと YAML が datetime を作り、此処で黙って落ちる★
    try:
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def current_task(stem: str) -> tuple[str | None, str | None, set]:
    """queue/tasks/{agent}.yaml の (task_id, updated_at, 前任 id の集合)。読めねば空。

    ★前任 id を併せて返す理由★= 新任が配られた直後に前任の完遂を書く形は ★正しい★。
    実測 (2026-07-27 22:3x) = 軍師二号が現に其の形であった (新任 22:30 / 前任の完遂 22:35)。
    task YAML は其れを prev_task_id* として自ら申告しておるゆえ、★申告に在る id では鳴らさぬ★。
    """
    empty: tuple[str | None, str | None, set] = (None, None, set())
    agent = stem.replace("_report", "")
    ty = _SCRIPTS_DIR.parent / "queue" / "tasks" / f"{agent}.yaml"
    if not ty.is_file():
        return empty
    try:
        loaded = yaml.safe_load(ty.read_text(encoding="utf-8"))
    except (yaml.YAMLError, OSError):
        return empty  # ★task 側の壊れを report の書き手の赤にせぬ★
    if not isinstance(loaded, dict):
        return empty
    body = loaded.get("task") if isinstance(loaded.get("task"), dict) else loaded
    if not isinstance(body, dict):
        return empty
    tid = body.get("task_id")
    upd = body.get("updated_at") or body.get("timestamp")
    prev = {v for k, v in body.items()
            if isinstance(k, str) and k.startswith("prev_task_id") and isinstance(v, str)}
    return (tid if isinstance(tid, str) else None,
            upd if isinstance(upd, str) else None,
            prev)


def warn_text(text: str, stem: str, task_lookup=None) -> list[str]:
    """R5 = ★読み手が探す鍵を持っておるか★。返り = 警告 list (空 = 何も言うことなし)。

    task_lookup = (task_id, updated_at) を返す callable。★試験が現物の queue/tasks/ を
    書き換えずに R5c を撃てるようにする口★ (既定 = current_task)。
    """
    warnings: list[str] = []
    view = reader_view(text)
    if view is None:
        return warnings  # parse 落ちは R1/R2 の領分

    keyed = [d for d in view if d.get("task_id") or d.get("primary_task")]

    # ── R5a = 読み手の高さに鍵が1つも無い ──
    if not keyed:
        tops = []
        for d in view:
            tops += [k for k in d.keys() if isinstance(k, str)]
        warnings.append(
            "[R5a] 読み手に task_id が1つも見えぬ\n"
            f"     読み手 = {READER}:1572 は task_id を ★document 直下★ か ★report: の直下★ でしか探さぬ。\n"
            f"     此の report の最上位の鍵 = {tops[:6]}\n"
            "     ⇒ 任意の名 (例 cmd1426_xxx:) の下へ入れた task_id は ★見えぬ★。\n"
            f"     害 = {READER}:1573-1575 で全 document が continue され、"
            "status: done と書いても ★not_done と読まれる★ = 【働いておるのに idle】"
        )

    # ── R5b = 鍵は在るが timestamp が解けぬ ──
    for d in keyed:
        tid = d.get("task_id") or d.get("primary_task")
        ts = d.get("timestamp")
        if reader_can_parse_time(ts):
            continue
        if ts is None:
            why = "timestamp が無い"
        elif not isinstance(ts, str):
            why = (f"timestamp が str でない (got {type(ts).__name__}: {ts!r}) "
                   "— ★YAML は引用符の無い日時を datetime へ変える★ ⇒ '…' で括れ")
        else:
            why = f"timestamp を fromisoformat が解けぬ ({ts!r})"
        warnings.append(
            f"[R5b] task_id={tid!r} の document で {why}\n"
            f"     読み手 = {READER}:1576-1578 は解けぬ timestamp を ★黙って飛ばす★ "
            f"(判定は同 :1534-1543 = isinstance(s, str) が偽なら即 None)\n"
            "     害 = 其の document は無かったことになり、完遂が届かぬ"
        )

    # ── R5c = 現任の task_id と食い違う完遂 ──
    #   ★常に鳴る門にせぬ★= 単なる不一致では鳴らさぬ。前任の完遂を書いた直後に
    #   新任が配られる形は ★正しく不一致★ ゆえ (実測: 22:2x 時点で現物 9 本すべて不一致)。
    #   鳴らすのは ★現任が配られた【後に】書かれた完遂が、別の id を名乗っておる時★ のみ。
    task_id, task_upd, prev_ids = (task_lookup or current_task)(stem)
    if task_id and keyed:
        ids = {d.get("task_id") or d.get("primary_task") for d in keyed}
        if task_id not in ids:
            newer = []
            for d in keyed:
                st = d.get("status")
                if not (isinstance(st, str) and st.strip().lower() in COMPLETION_WORDS):
                    continue
                rid = d.get("task_id") or d.get("primary_task")
                if rid in prev_ids:
                    continue  # ★task YAML 自身が前任と申告しておる = 正しい形★
                ts = d.get("timestamp")
                if (isinstance(ts, str) and isinstance(task_upd, str)
                        and reader_can_parse_time(ts) and ts >= task_upd):
                    newer.append(rid)
            if newer:
                warnings.append(
                    f"[R5c] 現任が配られた後に書かれた完遂が、別の task_id を名乗っておる\n"
                    f"     task YAML = {task_id!r} (updated_at={task_upd}) / 此の report = {newer}\n"
                    f"     読み手 = {READER}:1573-1575 は現任の id でしか探さぬ ⇒ "
                    "★此の完遂は現任の完遂として数えられぬ★\n"
                    "     (前任の報告を書いておるだけなら、之は正しい形である — 書き手が判ぜよ)"
                )
    return warnings


def warn_file(path: pathlib.Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    return warn_text(text, path.stem)


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


def render_warn(path: pathlib.Path, warnings: list[str]) -> str:
    """R5 の名指し。★落としておらぬ★ = 書込は既に済んでおり、之は報せである。"""
    head = (
        f"[report_validate] ⚠ {path} は parse できるが ★読み手が探す鍵を持っておらぬ★ (R5)\n"
        f"★何も落としておらぬ★ — 書込は済んでおる。直さねば ★完遂が黙って届かぬ★ という報せである。"
    )
    return head + "\n" + "\n".join(warnings)


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

# ══════════════════════════════════════════════════════════════════════════
# ★前提を焼き付けぬ★ — M2/M2n の stem は【借りた表そのものから立てる】
#
# ★何故こう書き直したか (cmd_1404・2026-07-27 03:2x・実害が現に出た)★
#   初版は M2 の stem に 'gunshi1_report' を ★焼き付けて★おった。当時 其の綴りは
#   slim_yaml の除外表に ★無かった★ ゆえ、R2 (除外表の外なら safe_load 落ちを咎める)
#   が現に発火し、緑を採れておった。
#   ⇒ ★其の 14 分後、同じ拙者が cmd_1397-B (d4c3f89 01:39) で gunshi1/gunshi2 を
#      除外表へ加えた★ ⇒ ★M2 の前提 (此の stem は表の外に在る) が偽になった★ ⇒
#      門は無変異のまま rc=1 になり、三号が 03:1x に「建てた其の日に死んでおる門」
#      として掘り当てた (bbfba81=緑 / d4c3f89=赤 を git archive で二分して確かめた)。
#   ★門の判定規則 (R1-R4) は一文字も壊れておらなんだ★= 腐ったのは ★試験の前提★ である。
#   ★而も M2 は M2n と同じ側 (表の中) へ黙って移り、R2 の【表の外】の枝を
#     誰も撃たぬ形になっておった★= 数は減らず、守りだけが消える型。
#
#   ⇒ ★処方 = 前提を保存せず、前提を立て直す口を保存する★ (本夜の一般形)。
#     表の中/外の stem を ★実行時に表から採る★ ゆえ、表がどう変わっても
#     M2 は常に【表の外】を、M2n は常に【表の中】を撃つ。★二度と黙って移らぬ★。
#     採れなんだ時は ★NG として名乗る★ (黙って skip すれば同じ穴が開く)。
# ══════════════════════════════════════════════════════════════════════════
def _stem_outside_table() -> tuple[str | None, str]:
    """★除外表の【外】に在ると機械で確かめた stem★ を返す。(stem, 説明)。"""
    if CANONICAL_REPORTS is None:
        return None, "除外表を借りられておらぬ (B1 が既に名乗っておる)"
    for i in range(1, 1000):
        cand = f"zz_outside_table_{i}_report"
        if cand not in CANONICAL_REPORTS:
            return cand, f"表 {len(CANONICAL_REPORTS)} 件の外から採った ('{cand}')"
    return None, "表の外の stem を採れなんだ (1000 候補すべて表の中)"


def _stem_inside_table() -> tuple[str | None, str]:
    """★除外表の【中】に現に在る stem★ を返す。(stem, 説明)。"""
    if CANONICAL_REPORTS is None:
        return None, "除外表を借りられておらぬ (B1 が既に名乗っておる)"
    if not CANONICAL_REPORTS:
        return None, "表が空 = 表の中の stem が採れぬ (★0 件は緑ではない★)"
    cand = sorted(CANONICAL_REPORTS)[0]
    return cand, f"表 {len(CANONICAL_REPORTS)} 件の中から採った ('{cand}')"


_MULTIDOC = _HEALTHY + "---\ncmd_9002_example:\n  status: done\n"


# (名, 本文, stem, 期待する赤の needle。None = 緑であるべき)
def _cases() -> list[tuple[str, str, str | None, str | None]]:
    out_stem, _ = _stem_outside_table()
    in_stem, _ = _stem_inside_table()
    return [
    (
        "M1 孤児 list (軍師一号が本夜 現に踏んだ機序 = list の途中へ mapping を挿す)",
        "cmd_9001_example:\n  items:\n    - 一つ目\n    key: 割り込み\n    - 孤児\n",
        "gunshi1_report",
        "[R1]",
    ),
    (
        "M2 多 document ＆ slim_yaml の除外表に【無い】stem (stem は表から立てる)",
        _MULTIDOC,
        out_stem,
        "[R2]",
    ),
    (
        "M2n 同じ多 document なれど除外表に【在る】stem = ★緑★ (読み手が読まぬゆえ)",
        _MULTIDOC,
        in_stem,
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

    # ★B2 = 前提そのものを名乗る★ (cmd_1404)。M2/M2n は「表の外/中」を撃つ試験ゆえ、
    #   其の stem が現に外/中に在ることを ★先に言葉で出す★。焼き付けた綴りが黙って
    #   反対側へ移った (cmd_1397-B) のが今回の事故の機序である。
    out_stem, out_why = _stem_outside_table()
    in_stem, in_why = _stem_inside_table()
    #   ★立てた口を信ぜず、立った物を表へ当て直す★= 誰かが再び綴りを焼き付けても
    #   (今回の事故の再演)、此処が【前提が反対側に在る】と名指す。
    for label, stem, why, want_inside in (
        ("表の外", out_stem, out_why, False),
        ("表の中", in_stem, in_why, True),
    ):
        if stem is None:
            ok = False
            print(f"  NG  B2 {label} の stem を立てられなんだ = ★M2/M2n の前提が崩れておる★: {why}")
            continue
        inside = CANONICAL_REPORTS is not None and stem in CANONICAL_REPORTS
        if inside != want_inside:
            ok = False
            print(f"  NG  B2 {label} を撃つ筈の stem '{stem}' が ★実際には表の"
                  f"{'中' if inside else '外'}に在る★ = ★前提が反対側へ移っておる★"
                  f" (cmd_1397-B で現に起きた型・{why})")
        else:
            print(f"  ok  B2 {label} の stem を表から立て、表へ当て直して確かめた: {why}")

    for name, text, stem, needle in _cases():
        if stem is None:
            ok = False
            print(f"  NG  {name} / ★前提の stem を立てられず撃てなんだ★ (B2 を見よ)")
            continue
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

    # ── R5 (cmd_1407) = ★鍵を消せば赤・正しい物では静か★ を両方向で ──
    #   ★試験の前提を焼き付けぬ★= task YAML は差し替え可能な口 (task_lookup) から与える。
    _NO_TASK = lambda _stem: (None, None, set())  # noqa: E731  R5c を黙らせる (R5a/R5b だけを撃つ)
    for name, text, stem, lookup, needle in [
        (
            "W1 任意名の下へ入れた task_id (三号の現物と同じ形) = 読み手から見えぬ",
            "cmd1426_two_writers:\n  task_id: subtask_1426\n  status: done\n"
            "  timestamp: '2026-07-27T20:42:00'\n",
            "ashigaru3_report", _NO_TASK, "[R5a]",
        ),
        (
            "W1n report: の直下へ置けば ★緑★ (読み手が見る高さ)",
            "report:\n  task_id: subtask_1426\n  status: done\n"
            "  timestamp: '2026-07-27T20:42:00'\n",
            "ashigaru3_report", _NO_TASK, None,
        ),
        (
            "W1n2 document 直下へ平置きしても ★緑★ (読み手が見るもう一つの高さ)",
            "task_id: subtask_1426\nstatus: done\ntimestamp: '2026-07-27T20:42:00'\n",
            "ashigaru3_report", _NO_TASK, None,
        ),
        (
            "W2 timestamp が無い (六号 05:46 の実測と同じ形)",
            "task_id: subtask_1426\nstatus: done\n",
            "ashigaru3_report", _NO_TASK, "[R5b]",
        ),
        (
            "W3 timestamp の引用符を外した = YAML が datetime を作り str でなくなる",
            "task_id: subtask_1426\nstatus: done\ntimestamp: 2026-07-27T20:42:00\n",
            "ashigaru3_report", _NO_TASK, "[R5b]",
        ),
        (
            "W4 現任が配られた後の完遂が別の id を名乗る",
            "task_id: subtask_OLD\nstatus: done\ntimestamp: '2026-07-27T23:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_NEW", "2026-07-27T22:24:00", set()), "[R5c]",
        ),
        (
            "W4n 前任の完遂を書いた【後に】新任が配られた形 = ★緑★ (常に鳴る門にせぬ)",
            "task_id: subtask_OLD\nstatus: done\ntimestamp: '2026-07-27T18:16:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_NEW", "2026-07-27T22:24:00", set()), None,
        ),
        (
            "W4n2 task YAML が prev_task_id で前任と申告しておる = ★緑★ "
            "(軍師二号 22:35 の現物と同じ形)",
            "task_id: subtask_OLD\nstatus: done\ntimestamp: '2026-07-27T22:35:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_NEW", "2026-07-27T22:30:00", {"subtask_OLD"}), None,
        ),
    ]:
        got = warn_text(text, stem, task_lookup=lookup)
        if needle is None:
            passed = not got
            detail = "" if passed else " / 出た警告=" + "; ".join(g.split("\n")[0] for g in got)
        else:
            passed = any(needle in g for g in got)
            detail = (" / " + "; ".join(g.split("\n")[0] for g in got)) if got else \
                     " / ★警告が1つも出ておらぬ★"
        ok = ok and passed
        print(f"  {'ok ' if passed else 'NG '} {name}{detail}")

    # ★盤面の側の負例★= 現に在る report 9 本が緑であること (門が狼少年でない証)
    reports_dir = _SCRIPTS_DIR.parent / "queue" / "reports"
    live = sorted(reports_dir.glob("*.yaml")) if reports_dir.is_dir() else []
    r5_hit = []
    for p in live:
        problems = validate_file(p)
        passed = not problems
        ok = ok and passed
        mark = "ok " if passed else "NG "
        detail = "" if passed else " / " + "; ".join(x.split("\n")[0] for x in problems)
        w = warn_file(p)
        if w:
            r5_hit.append((p.name, [x.split("]")[0] + "]" for x in w]))
        print(f"  {mark}N2 現物 {p.name} = 緑であるべき{detail}")
    if not live:
        print("  -- N2 現物の report が見当たらぬ (skip)")
    # ★N3 = 母数の印字★ (judge には効かせぬ)。R5 は警告ゆえ現物が赤くとも FAIL にせぬが、
    #   ★数を黙らせぬ★= 「R1-R4 は全部 緑、なれど読み手には見えておらぬ」を一目で出す。
    print(f"  ── N3 現物 {len(live)} 本のうち ★R5 が名指す物 = {len(r5_hit)} 本★ "
          f"(judge には効かせぬ = 警告ゆえ)")
    for nm, rules in r5_hit:
        print(f"       {nm}: {'+'.join(sorted(set(rules)))}")

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
    warnings = warn_file(path)
    if not problems and not warnings:
        return 0
    out = []
    if problems:
        out.append(render(path, problems))
    if warnings:
        out.append(render_warn(path, warnings))
    print("\n".join(out), file=sys.stderr)
    # PostToolUse: exit 2 = stderr を書き手へ返す。
    # ★R5 だけの時も 2 を返す★ = 書き手の画面へ届く口は之しか無い (家老 22:24 の
    #   「書き手の画面へ即座に名指す」)。★PostToolUse の 2 は済んだ書込を取り消さぬ★
    #   ゆえ「落とすな」の枷は破っておらぬ。CLI 経路 (main) の rc は赤にせぬ。
    return 2


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
        # ★R5 は rc を動かさぬ★ (家老 22:24「名指すまでに留めよ」)。
        #   ★但し黙らぬ★= PASS の直後に警告を出す = 「PASS だが読み手には見えぬ」を
        #   一目で分ける (之が本 cmd の当の病である)。
        warnings = warn_file(path)
        if warnings:
            print(render_warn(path, warnings), file=sys.stderr)
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # ★fail-OPEN だが黙らぬ★
        print(f"[report_validate] WARN: 内部異常 — 通す (fail-OPEN): {exc}", file=sys.stderr)
        sys.exit(0)
