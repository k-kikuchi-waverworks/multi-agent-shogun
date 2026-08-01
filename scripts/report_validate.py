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
       読み手 = scripts/idle_revive_scan.py の report_completion_state /
                scripts/stall_watchdog_scan.py の parse_report_latest
                (どちらも `list(yaml.safe_load_all(f))` で報告を読む口である)
       ★行番号で指さぬ★ = 行が動いた瞬間に別の物を指すゆえ (CLAUDE.md 条F)。
                探し方 = grep -n "safe_load_all" scripts/idle_revive_scan.py scripts/stall_watchdog_scan.py
       害     = 番人が完遂を読めぬ ⇒ ★働いておる者を idle と誤判定★ (本夜の実害そのもの)
    R2 safe_load (単一 document) が落ちる ＆ 当該 stem が slim_yaml の除外表に無い
       読み手 = scripts/slim_yaml.py の load_yaml (safe_load。失敗すると {} を返す)
                ★行番号で指さぬ★ = 行が動いた瞬間に別の物を指すゆえ (条F)。
                探し方 = grep -n "def load_yaml" scripts/slim_yaml.py
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
       R5d/R5d2 (cmd_1450・警告のみ) ★帳面が指す稿の名と、現に在る物の食い違い★
       R5a〜R5c が問うたのは ★報告そのものの形★ である。R5d が問うのは
       ★報告が「畢わった」と名乗る其の刻に、帳面の指す先に物が在るか★ である。
       出所 = 2026-07-28 未明、軍師二号が帳面の target_path (plans/cmd_1442_rules_draft.md)
         と ★別の名★ で稿を書いた (…_rules_consolidation.md)。★捕える門が無く、
         家老の差し戻しで人が気付いた★ (CLAUDE.md 条D-2 の二例目)。
         同族は本夜 三度 出て ★三度とも人が気付き、機械は一度も鳴っておらぬ★。
       ★常に鳴る門にせぬ★ = 完遂を名乗った report にのみ撃つ。実測 (2026-07-28 06:34) =
         完遂の条件が無ければ ★走行中の任 5/5 が鳴り★、条件を付ければ ★0 件★。
       R5d2 = target_path が ★路として読めぬ★ 時は「無い」と数えず別に名乗る。
         黙って捨てる形は番人 (idle_revive_scan.py の report_completion_state・
         「if dt is None: continue」= 刻が解けねば黙って飛ばす) が現に踏んでおる病である。
         ★行番号でなく綴りで指す★ = 行が動いた刻に別の物を指すゆえ (CLAUDE.md 条F)。
       ★機械が判ずるのは綴りの突き合わせだけ★ = 註の【意味】の真偽 (「未配線である」等) は
         此の門の外である。稿 plans/cmd_1450_annotation_gate.md §5 に分けて書いた。
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
    report_validate.py --stats               # 門が止めた回数・機械が刻を入れた回数 (cmd_1567)
    (引数なし + stdin JSON)                  # PostToolUse hook 経路

★刻は機械が入れる (cmd_1567)★
    報告の timestamp は書き手が書く欄ではない。hook 経路で、検める前に機械が入れる。
    timestamp の行が無い / timestamp: AUTO → 入れる  ・  数字が既に在る → 触らない。
    入れた事は必ず書き手の画面へ出す (黙って書き換えない)。詳しくは stamp_text の註。
"""

from __future__ import annotations

import datetime
import json
import os
import pathlib
import re
import sys
import tempfile
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

# ★完了語は【写さず借りる】★ (cmd_1461)
#
# 何が在ったか。此処は元は手で写した集合であった。上の註は「読み手の code を写した物」と
# 名乗っておるが、★写した中身は読み手が一度も持たなんだ集合であった★ (2026-07-28 17:59 実測):
#     読み手 (idle_revive_scan の COMPLETION_STATUSES) = {done, completed, success}
#     此処の写し                                        = {done, completed, complete, finished}
#     読み手にだけ在った = success  /  写しにだけ在った = complete, finished
#
# 害 (現物では未発現・下の「撃っていない所」も見よ):
#   ・報告が `status: success` → 読み手は完遂と読む (revive せぬ) が、
#     此の門は完遂と読まぬゆえ ★R5c/R5d の検めを黙って素通りする★
#   ・報告が `status: finished` → 此の門は完遂と読むが、読み手は読まぬゆえ
#     ★完遂を報せた者が revive される★
#   ⇒ 同じ 1 つの欄を、二つの機械が違う語彙で判じておった。
#
# ゆえに借りる形へ替える。読み手が語を足せば此の門も追随し、写しが化ける道が塞がる。
# 借り損ねた時は ★読み手が今 持つ集合★ へ倒し、其の旨を名乗る (fail-OPEN・B6 が捕える)。
# ★倒す先も手書きの定数ゆえ、いずれ読み手から離れる★ — 之も B6 が照合する。
COMPLETION_WORDS_FALLBACK = {"done", "completed", "success"}
try:
    from idle_revive_scan import COMPLETION_STATUSES as COMPLETION_WORDS  # noqa: E402

    COMPLETION_BORROW_ERROR = None
except Exception as _exc:  # fail-OPEN (loud) — 借りられねば倒し、其の旨を名乗る
    COMPLETION_WORDS = COMPLETION_WORDS_FALLBACK
    COMPLETION_BORROW_ERROR = f"{type(_exc).__name__}: {_exc}"

# ★門が「今は警告である」と「いつ赤へ変えるか」を己の口で名乗る★ (cmd_1407・軍師一号 22:4x)
#   理 = 軍師一号が本日 二度「警告は出るが読む者が居らぬ」を名指した。R5a の読み手は現に
#   居る (報告を書く者) ゆえ、★据え置きの理由と期日の条件★ を門自身に言わせる。
#   条件を「日付」でなく ★数★ で書くのは、日付は黙って過ぎるが数は撃てば出るゆえ。
RED_PLAN = (
    "★今は警告 = rc を動かさぬ。いつ赤へ変えるか★ = "
    "現物の report (queue/reports/*_report.yaml) で R5a が名指す物が ★0 本★ になった時、"
    "R5a を R1-R4 と同じ赤 (CLI rc=1) へ上げる。\n"
    "     今の本数は `python3 scripts/report_validate.py --selftest` の N3 行が刷る "
    "(2026-07-27 22:5x 実測 = 9 本中 1 本)。\n"
    "     ★0 を待つ理由★ = 0 でない間に赤へ上げると、既に居る書き手の報告が門で止まる "
    "(門が直す物を、門が書けなくする)。上げる時は此の行も併せて書き換えよ。"
)


def reader_view(text: str) -> list[dict] | None:
    """★読み手が見る高さ★ の mapping を並べて返す。

    写し元 = idle_revive_scan.py の report_completion_state に在る
    `inner = doc["report"] if isinstance(doc.get("report"), dict) else doc`
    (report: を1枚 被せた形と、被せぬ形の両方を同じ高さで読む所)。
    ★行番号で指さぬ★ = 行が動いた瞬間に別の物を指すゆえ (CLAUDE.md 条F)。


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


def current_task(stem: str, tasks_dir=None) -> tuple[str | None, str | None, set, str | None]:
    """queue/tasks/{agent}.yaml の (task_id, updated_at, 前任 id の集合, target_path)。読めねば空。

    tasks_dir = 帳面の在処を差し替える口。★試験が現物の queue/tasks/ へ 1 byte も
    書かずに【帳面を読む口そのもの】を撃つために要る★ (cmd_1450 の変異4 が現に生き残った)。

    ★前任 id を併せて返す理由★= 新任が配られた直後に前任の完遂を書く形は ★正しい★。
    実測 (2026-07-27 22:3x) = 軍師二号が現に其の形であった (新任 22:30 / 前任の完遂 22:35)。
    task YAML は其れを prev_task_id* として自ら申告しておるゆえ、★申告に在る id では鳴らさぬ★。
    """
    empty: tuple[str | None, str | None, set, str | None] = (None, None, set(), None)
    agent = stem.replace("_report", "")
    base = pathlib.Path(tasks_dir) if tasks_dir else _SCRIPTS_DIR.parent / "queue" / "tasks"
    ty = base / f"{agent}.yaml"
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
    tgt = body.get("target_path")
    return (tid if isinstance(tid, str) else None,
            upd if isinstance(upd, str) else None,
            prev,
            tgt if isinstance(tgt, str) else None)


# ── R5d (cmd_1450) が使う口 ────────────────────────────────────────────────
#   ★名の突き合わせ以外はせぬ★= 中身の真偽 (「この稿は規を4条 書いた」等) は
#   機械では判ぜられぬ。判ぜられるのは ★帳面が指す綴りと、現に在る物の綴り★ だけである。
DELIVERABLE_FIELDS = ("deliverable", "deliverables", "target_path",
                      "artifact", "artifacts", "output", "outputs")
#   路と読める拡張子。★此処に無い綴りは「路として読めぬ」と名乗る (黙って捨てぬ)★=
#   黙って捨てる形こそ、番人が現に踏んでおる病である (task YAML 206-211 行の実例)。
PATH_SUFFIXES = {".md", ".py", ".sh", ".yaml", ".yml", ".bats", ".txt",
                 ".ts", ".tsx", ".js", ".kt", ".json", ".toml", ".log"}


def looks_like_path(value) -> bool:
    """★路として読めるか★。読めぬ物を「無い」と数えぬための見分け。"""
    if not isinstance(value, str) or not value.strip() or "\n" in value:
        return False
    return pathlib.PurePosixPath(value.strip()).suffix in PATH_SUFFIXES


def repo_path_exists(rel: str) -> bool:
    """repo 根からの相対で現物が在るか。★試験は此処を差し替えて現物へ触れぬ★。"""
    return (_SCRIPTS_DIR.parent / rel.strip()).exists()


def repo_path_is_dir(rel: str) -> bool:
    """repo 根からの相対で、現に在るディレクトリか。

    何ゆえ要るか (cmd_1395・四号が 2026-07-28 に二度 踏んだ):
      looks_like_path() は ★拡張子の有無だけ★ を見る。ゆえに
      ディレクトリは必ず「路として読めぬ」側へ落ちていた。
      ★ところが読み手 (idle_revive_scan.py の newest_output_mtime) は
      is_dir() を現に扱い、ディレクトリの中でいちばん新しい mtime を拾う★
      (現物の綴り = `elif tp_path.is_dir():`)。
      ⇒ 門が「読めぬ」と名指すので、書き手は帳面を 1 ファイルへ狭める。
        すると revive の判断が束全体でなくその 1 本だけを見る形になり、
        ★門が守りを弱める方向へ人を導いていた★。
    """
    return (_SCRIPTS_DIR.parent / rel.strip()).is_dir()


def named_paths(doc: dict) -> list[str]:
    """報告が己で名乗った成果物の路を集める (deliverable 系の欄のみ)。"""
    out: list[str] = []
    for field in DELIVERABLE_FIELDS:
        value = doc.get(field)
        for item in (value if isinstance(value, list) else [value]):
            if looks_like_path(item) and item.strip() not in out:
                out.append(item.strip())
    return out


def _now_naive_local() -> datetime.datetime:
    """今の刻を、tz を持たぬ現地時刻で返す。★R5e が比べる基準★"""
    return datetime.datetime.now()


def _to_naive_local(value: str):
    """timestamp の綴りを tz を持たぬ現地時刻へ直す。読めねば None。

    ★何ゆえ揃えるか★= 報告には tz つき ('…+09:00') と tz 無しが混ざる。
    そのまま引き算すると python が TypeError を投げる。読み手
    (idle_revive_scan.py の parse_iso_to_naive_local) も同じ形で naive へ寄せておる。
    """
    try:
        dt = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone().replace(tzinfo=None)
    return dt


# ★どれだけ先なら赤か★ (cmd_1469・軍師二号が決めた)
#   分単位の丸めは最大 60 秒 先へ倒れる (書き手が「11:52:44」を「11:53:00」と書く形)。
#   ★丸めは切り上げの側へ寄る★ = 番人が読む欄では此の向きが最も悪い。
#   ゆえに丸めの幅の倍 (120 秒) を許し、それを超える先は ★丸めでは出ぬ★ と判ずる。
#   実測 = 軍師二号が現に書いた誤りは 2 分 16 秒 先 ⇒ ★此の閾値で現に捕まる★。
FUTURE_TOLERANCE_SEC = 120


def warn_text(text: str, stem: str, task_lookup=None, path_exists=None,
              path_is_dir=None, now=None) -> list[str]:
    """R5 = ★読み手が探す鍵を持っておるか★。返り = 警告 list (空 = 何も言うことなし)。

    task_lookup = (task_id, updated_at, 前任 id, target_path) を返す callable。★試験が
    現物の queue/tasks/ を書き換えずに R5c/R5d を撃てるようにする口★ (既定 = current_task)。
    ★3 つ組を返す古い口も受ける★ (target_path 無しと読む = R5d は黙る)。
    path_exists = 路の現物在否を返す callable (既定 = repo_path_exists)。
    path_is_dir = 路が現に在るディレクトリか返す callable (既定 = repo_path_is_dir)。
    ★試験が此処を差し替える理由 = 条C「己を母数から外す」★ = 試験の作り物が
    plans/ 等へ現物を作れば、門が数える盤面を門の試験が動かす形になる。
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
            "status: done と書いても ★not_done と読まれる★ = 【働いておるのに idle】\n"
            f"     {RED_PLAN}"
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
    looked = tuple((task_lookup or current_task)(stem))
    task_id, task_upd, prev_ids, target_path = (looked + (None,) * 4)[:4]
    if prev_ids is None:
        prev_ids = set()
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

    # ── R5d = ★帳面が指す稿の名と、現に在る物が食い違う★ (cmd_1450) ──
    #   ★出所★= 2026-07-28 未明、軍師二号が帳面の target_path
    #   (plans/cmd_1442_rules_draft.md) と別の名 (…_rules_consolidation.md) で稿を書いた。
    #   ★之を捕える門は無く、家老の差し戻しで人が気付いた★ (CLAUDE.md 条D-2 の二例目)。
    #   同族は本夜 三度 出て、★三度とも人が気付き、機械は一度も鳴っておらぬ★。
    #
    #   ★常に鳴る門にせぬ★ (cmd_1388 の族・実測で二度 確かめた):
    #     ・完遂の条件を付けずに撃つと ★走行中の任が悉く鳴る★
    #       = 2026-07-28 06:34 実測で 5/5 件 (稿は書き終わる前は無いのが当たり前ゆえ)。
    #     ・完遂の条件を付ければ同じ盤面で ★0 件★。
    #   ゆえに鳴らすのは ★現任の完遂を己で名乗った report★ に限る。
    #
    #   ★退けた案 = 「同じ cmd 番号の別名の file が在れば鳴らす」★
    #     plans/ には一つの cmd につき走査器・生の出力が並ぶ (実測 cmd_1449 = 11 本)。
    #     ★而も此の門を作る拙者自身の probe 2 本が、其の母数へ現に入った★
    #     = 条C「己を母数から外せ」を、判定に使えば必ず破る形ゆえ採らぬ。
    #     ★手掛かりとしてだけ出す★= 判定には使わず、報告が名乗った路のみを並べる。
    exists = path_exists or repo_path_exists
    is_dir = path_is_dir or repo_path_is_dir
    if task_id and target_path is not None:
        done_docs = [
            d for d in keyed
            if (d.get("task_id") or d.get("primary_task")) == task_id
            and isinstance(d.get("status"), str)
            and d.get("status").strip().lower() in COMPLETION_WORDS
        ]
        if done_docs:
            # ★ディレクトリを「読めぬ」と名指してはならぬ★ (cmd_1395)。
            #   読み手は is_dir() を現に扱うので、ディレクトリは現に読める。
            #   ここを外すと、門が「帳面を 1 ファイルへ狭めよ」と誤って導く。
            if not (looks_like_path(target_path) or is_dir(target_path)):
                warnings.append(
                    "[R5d2] 帳面の target_path が ★路として読めぬ★\n"
                    f"     task YAML = {task_id!r} の target_path = {target_path!r}\n"
                    "     読み手 = scripts/idle_revive_scan.py の newest_output_mtime は\n"
                    "     ★target_path を【路として】読み、読めねば警告も出さず黙って候補から捨てる★\n"
                    "     (読み手が現に持つ綴り = `elif tp_path.is_dir():` ゆえ\n"
                    "      ★現に在るディレクトリは【読める】。此の警告は出ぬ★)\n"
                    "     害 = 「出力が漸進しておれば revive せぬ」守りが、註釈 1 つで黙って外れる\n"
                    "     ⇒ ★直すのは帳面の側★ (註は target_path_note へ書き、path 欄は路のみ)"
                )
            elif not exists(target_path):
                named = []
                for d in done_docs:
                    for p in named_paths(d):
                        if p != target_path and p not in named:
                            named.append(p)
                alive = [p for p in named if exists(p)]
                warnings.append(
                    "[R5d] 完遂を名乗っておるが、★帳面が指す稿の先に物が無い★\n"
                    f"     task YAML = {task_id!r} の target_path = {target_path!r} (現物 無し)\n"
                    f"     此の report が名乗る別の路 = {named or '(名乗り無し)'}"
                    f" / 其のうち現物 在り = {alive or '(無し)'}\n"
                    "     ⇒ 考えられる形は二つ。★書き手が判ぜよ★\n"
                    "       (甲) ★名を己で付けた★= 帳面から写さず別の名で書いた (条D-2)\n"
                    "       (乙) ★帳面の側が古い★= 任が替わった時に target_path が追随しておらぬ\n"
                    "     ★どちらでも「稿を書いた」と「帳面の指す所に在る」は別である★\n"
                    "     害 = 引く者が指す先を失う。★番人も此の path を出力の漸進の物差しに使う★"
                )

    # ── R5e = ★timestamp が未来を指しておる★ (cmd_1469) ──
    #   ★出所★= 2026-07-28、家老が全員の帳面へ刻を手で書き、4〜5 時間 先の値が入った
    #     (将軍が現物を見て気づいた)。同じ日、軍師二号も報告の timestamp を分単位で
    #     丸め、実時刻より 2 分 16 秒 先へ倒れておった。★桁は違うが向きは同じ★。
    #   ★何ゆえ「読めるか」だけでは足りぬか★= R5b は fromisoformat が解けるかしか見ぬ。
    #     未来の刻は ★綺麗に解ける★。ゆえに R5b は黙る。
    #   ★害★= 番人 (idle_revive_scan.py / stall_watchdog_scan.py) は此の欄を
    #     「最後に動いた刻」として読む。未来の刻が入っておれば、其の刻が過ぎるまで
    #     ★ずっと「今さっき更新された」と読まれ続ける★ ⇒ 止まっておる者を働いておると誤判定。
    #     R5a〜R5c が守るのは「働いておるのに idle」の側。★R5e は其の逆向きを守る★。
    #   ★上書きせぬ理由 (家老 12:02 の裁)★= 書き手が何を書いたかを消せば、誰も間違えぬ
    #     代わりに ★誰も間違いに気づけなくなる★。今回のずれは人が現物を見て割れた。
    for d in keyed:
        ts = d.get("timestamp")
        if not reader_can_parse_time(ts):
            continue  # ★刻が無い/読めぬは R5b の領分★ (あちらが現に鳴る)
        stamped = _to_naive_local(ts)
        if stamped is None:
            continue
        ahead = (stamped - (now or _now_naive_local)()).total_seconds()
        if ahead <= FUTURE_TOLERANCE_SEC:
            continue
        tid = d.get("task_id") or d.get("primary_task")
        warnings.append(
            f"[R5e] task_id={tid!r} の timestamp が ★未来を指しておる★ "
            f"({ts!r} = 今より {ahead / 60:.1f} 分 先)\n"
            f"     許す幅 = {FUTURE_TOLERANCE_SEC} 秒。★丸めは切り上げの側へ寄る★ゆえ"
            " 分単位の丸め (最大 60 秒) の倍を採った。\n"
            "     ⇒ 之を超える先の刻は丸めでは出ぬ = ★date を撃たずに書いた値★である。\n"
            f"     読み手 = {READER} は此の欄を「最後に動いた刻」として読む。\n"
            "     害 = 其の刻が過ぎるまで ★ずっと『今さっき更新された』と読まれ続ける★\n"
            "          ⇒ 止まっておる者が働いておると判ぜられ、番人が起こしに来ぬ\n"
            "     直し = `date '+%Y-%m-%dT%H:%M:%S'` を撃った値をそのまま入れよ。\n"
            "     ★門は上書きせぬ★ = 書いた物を消せば、誰も間違えぬ代わりに"
            " ★誰も間違いに気づけなくなる★ (家老 12:02 の裁)"
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
# 刻を機械が入れる (cmd_1567) — 報告の timestamp を、書き手の手から外す
#
# なぜ要るか (2026-08-01 の実測)
#   足軽三号が報告の刻に 16:05 と書いた。撃つと 15:55 だった (10分 先)。
#   足軽五号も数分後に同じ 16:05 を書いた (三号の報告を読む前)。軍師二号も同日、
#   分単位に丸めて 2分16秒 先へ倒れた。3人とも下の R5e に名指されて直った。
#   人は3人とも素通りしている。
#   ⇒ 殿の裁 = 「時刻を人に書かせず、機械が入れる。人に注意を促す形にしない」。
#     ゆえに門を増やさず、警告も足さない。人が書く欄そのものを無くす。
#
# 何をするか
#   timestamp の行が無い / timestamp: AUTO (値が空も同じ) → その場の時計を入れる
#   数字が既に書いてある                                   → 触らない
#
#   3つめが要る理由は2つ。
#     ① 家老 12:02 の裁「門は上書きしない」を壊さないため。書き手が現に書いた値を
#        消すと、間違いも一緒に消える (R5e の註と同じ理屈)。
#     ② 移行がこれ1つで済むため。hook は session 開始時の snapshot ゆえ、配線を
#        替えても既に開いている session には効かない (cmd_1395 の実測)。
#        数字が在れば触らない形なら、古い session が手で書き続けても壊れない。
#
# 黙って書き換えない (家老 19:52 の条件)
#   入れた事と、入れた先の document を必ず書き手の画面へ出す。理由は 2026-08-01 に
#   我らが1日 潰し続けたのが「道具が黙って何かをする」形だったため。黙って0を返す・
#   黙って古い姿を返す・黙って34%を落とす。刻を黙って入れる道具はその仲間になる。
#
# YAML を parse して dump し直さない
#   行単位の置換だけにする。yaml.dump の全書き換えは block scalar (|) を現に壊した
#   実績がある (台帳 shogun_to_karo.yaml)。報告本文は block scalar だらけである。
#
# この口が見ないもの (射程)
#   ・block scalar の中身は鍵として読まない = 本文に書かれた "timestamp:" は触らない
#   ・"timestamp: AUTO  # 註" のように註が付いた形は置き換えない (値が AUTO 単体でない)
#   ・複数行にまたがる引用符つき文字列の中は見分けていない
# ══════════════════════════════════════════════════════════════════════════
STAMP_KEYS = ("task_id", "primary_task")  # 挿す時の目印 = 読み手が探す鍵と同じ物

# 鍵の行。`- ` 始まりの list 要素の中の鍵も拾う。
_KEY_LINE_RE = re.compile(r"^(\s*)(?:-\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*:(?:\s+(.*))?\s*$")
# block scalar を開く行 (`key: |` `key: >-` `key: |2` など)
_BLOCK_OPEN_RE = re.compile(r"^[|>][+-]?\d*\s*(?:#.*)?$")


def _iter_marks(lines: list[str]):
    """行を上から見て (行番号, 種, 字下げ, 鍵, 値) を返す。

    種 = "key" (鍵の行) / "block" (block scalar を開く行) / "docsep" (--- の行)。
    block scalar の中身は飛ばす = 本文に書かれた "timestamp:" を鍵と読み違えないため。
    """
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        stripped = line.strip()
        if stripped == "---" or stripped.startswith("--- "):
            yield (i, "docsep", 0, None, None)
            i += 1
            continue
        m = _KEY_LINE_RE.match(line)
        if not m:
            i += 1
            continue
        indent, key, raw = len(m.group(1)), m.group(2), (m.group(3) or "").strip()
        if _BLOCK_OPEN_RE.match(raw):
            yield (i, "block", indent, key, raw)
            j = i + 1
            # 中身 = 空行、または開いた鍵より深い字下げの行
            while j < n and (not lines[j].strip()
                             or len(lines[j]) - len(lines[j].lstrip()) > indent):
                j += 1
            i = j
            continue
        yield (i, "key", indent, key, raw)
        i += 1


def _is_placeholder(value: str) -> bool:
    """書き手が「機械が入れてください」と書いた形か。空欄も同じ扱い。"""
    v = value.strip()
    if v[:1] in ("'", '"') and v[-1:] == v[:1] and len(v) >= 2:
        v = v[1:-1].strip()
    return v.lower() in ("", "auto")


def stamp_text(text: str, now_str: str) -> tuple[str, list[dict]]:
    """本文へ刻を入れる。返り = (直した本文, 入れた先の記録)。

    記録が空 = 何も触っていない。行単位の置換と挿入だけで、他の行は1 byte も動かさない。
    """
    lines = text.split("\n")
    marks = list(_iter_marks(lines))

    bounds, start = [], 0
    for i, kind, *_ in marks:
        if kind == "docsep":
            bounds.append((start, i))
            start = i + 1
    bounds.append((start, len(lines)))

    records: list[dict] = []
    inserts: list[tuple[int, str]] = []
    for doc_no, (lo, hi) in enumerate(bounds):
        keys = [m for m in marks if lo <= m[0] < hi and m[1] == "key"]
        if not keys:
            continue
        tid = next((v for _i, _k, _ind, k, v in keys if k in STAMP_KEYS), None)
        ts_lines = [m for m in keys if m[3] == "timestamp"]
        if ts_lines:
            for (i, _kind, indent, _k, v) in ts_lines:
                if not _is_placeholder(v):
                    continue  # 数字が在る = 触らない (家老 12:02 の裁)
                lines[i] = f"{' ' * indent}timestamp: '{now_str}'"
                records.append({"doc": doc_no, "task_id": tid,
                                "action": "replaced", "line": i + 1})
        else:
            anchor = next((m for m in keys if m[3] in STAMP_KEYS), None)
            if anchor is None:
                continue  # 目印が無い = 読み手からも見えぬ document ゆえ触らない
            inserts.append((anchor[0] + 1, f"{' ' * anchor[2]}timestamp: '{now_str}'"))
            records.append({"doc": doc_no, "task_id": tid,
                            "action": "inserted", "line": anchor[0] + 2})
    for pos, s in sorted(inserts, reverse=True):
        lines.insert(pos, s)
    return "\n".join(lines), records


def stamp_file(path: pathlib.Path, now_str: str | None = None,
               stamper=None) -> list[dict]:
    """report file へ刻を入れる。返り = 入れた先の記録 (空 = 何もしていない)。

    stamper = stamp_text を差し替える口。試験が「入れる口を止めた時に落ちるか」を
    撃つために要る (S4)。書き込みは temp を書いて os.replace = 途中で死んでも
    半端な file を残さない。失敗しても書き手は止めない (fail-OPEN・黙らない)。
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"[report_validate] WARN: 刻を入れる前に読めませんでした — 続けます: {exc}",
              file=sys.stderr)
        return []
    stamp_at = now_str or _now_naive_local().isoformat(timespec="seconds")
    try:
        new_text, records = (stamper or stamp_text)(text, stamp_at)
    except Exception as exc:  # fail-OPEN (loud)
        print(f"[report_validate] WARN: 刻を入れる口が落ちました — 続けます: {exc}",
              file=sys.stderr)
        return []
    if not records or new_text == text:
        return []
    tmp_name = None
    try:
        with tempfile.NamedTemporaryFile(
                "w", encoding="utf-8", dir=str(path.parent),
                prefix=path.name + ".", suffix=".tmp", delete=False) as f:
            tmp_name = f.name
            f.write(new_text)
        os.replace(tmp_name, path)
        tmp_name = None
    except Exception as exc:  # fail-OPEN (loud) — 書けなければ元のまま残す
        print(f"[report_validate] WARN: 刻を書き込めませんでした — 元のまま続けます: {exc}",
              file=sys.stderr)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
        return []
    for r in records:
        r["value"] = stamp_at
    return records


def render_stamp(path: pathlib.Path, records: list[dict]) -> str:
    """入れた事を書き手の画面へ出す。黙って書き換えない (家老 19:52 の条件)。"""
    head = (f"[report_validate] 報告の刻を機械が入れました — {path}\n"
            "timestamp は書き手が書く欄ではありません。入れた先は次のとおりです。")
    body = [
        "  document[{doc}] task_id={tid!r} {how} ({line}行目) → timestamp: '{val}'".format(
            doc=r["doc"], tid=r.get("task_id"), line=r["line"], val=r.get("value"),
            how=("欄が無かったので挿しました" if r["action"] == "inserted"
                 else "AUTO を置き換えました"))
        for r in records
    ]
    tail = ("  意図しない document へ入っていたら、その場で直してください。\n"
            "  数字が既に書いてある欄には触っていません (家老 12:02 の裁)。")
    return "\n".join([head] + body + [tail])


# ══════════════════════════════════════════════════════════════════════════
# 数を残す (cmd_1567) — 門が止めた回数を積み上げる
#
# なぜ要るか (軍師二号の指摘・現物で確かめた)
#   これまで残っていたのは心拍 file 1本だけで、中身は「最後に走った刻と pid」。
#   走ったかは分かるが、何回 止めたかは分からない。2026-08-01 に「3人が踏んだ」を
#   家老が知れたのは、3人が自分から申告したからである。申告しなければ誰も知らない。
#
# 数えられる物と、数えられない物
#   数えられる = 鳴った回数 (どの規則が・誰の書き込みで) と、機械が刻を入れた回数
#   数えられない = 「直った」回数。鳴ったのは書き込みの瞬間で、その後 書き手が
#     直したかは別の事象である。ここでは数えない。残しておけば後から数え直せる。
# ══════════════════════════════════════════════════════════════════════════
JOURNAL_NAME = "queue/.report_guard_journal.jsonl"
_RULE_CODE_RE = re.compile(r"^\[([A-Za-z0-9]+)\]")


def journal_path() -> pathlib.Path:
    return _SCRIPTS_DIR.parent / JOURNAL_NAME


def rule_codes(messages: list[str]) -> list[str]:
    """名指しの文面から規則の名 (R1・R5e など) だけを採る。"""
    out = []
    for m in messages:
        hit = _RULE_CODE_RE.match(m.strip())
        if hit and hit.group(1) not in out:
            out.append(hit.group(1))
    return out


def journal_append(entry: dict, path=None) -> bool:
    """追記のみ。失敗しても書き手は止めない (fail-OPEN・黙らない)。"""
    p = pathlib.Path(path) if path else journal_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        return True
    except Exception as exc:
        print(f"[report_validate] WARN: 数を残せませんでした — 続けます: {exc}",
              file=sys.stderr)
        return False


def stats(path=None) -> int:
    """積み上げた数を読む。file が無い事と 0件 は分けて出す。"""
    p = pathlib.Path(path) if path else journal_path()
    print(f"=== report_validate が止めた数 ({p}) ===")
    if not p.is_file():
        print("  まだ1行も在りません (file 自体が無い = 0件とは違います)。")
        print("  配線した後、誰かが報告を書けば1行目が入ります。")
        return 1
    rows = []
    broken = 0
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            broken += 1
    if not rows:
        print(f"  0件です (file は在りますが、読める行が在りません。読めない行={broken})。")
        return 0
    by_rule: dict[str, int] = {}
    by_writer: dict[str, int] = {}
    stamped_docs = 0
    stamped_writes = 0
    for r in rows:
        for code in r.get("rules") or []:
            by_rule[code] = by_rule.get(code, 0) + 1
        w = r.get("writer") or "?"
        if r.get("rules"):
            by_writer[w] = by_writer.get(w, 0) + 1
        n = len(r.get("stamped") or [])
        if n:
            stamped_writes += 1
            stamped_docs += n
    fired = sum(1 for r in rows if r.get("rules"))
    print(f"  書き込み {len(rows)} 回 (最初={rows[0].get('at')} / 最後={rows[-1].get('at')})"
          + (f" / 読めない行={broken}" if broken else ""))
    print(f"  門が鳴った書き込み = {fired} 回")
    for code, n in sorted(by_rule.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"    {code}: {n} 回")
    if by_writer:
        print("  書き手ごと: " + " / ".join(
            f"{w}={n}" for w, n in sorted(by_writer.items(), key=lambda kv: -kv[1])))
    print(f"  機械が刻を入れた書き込み = {stamped_writes} 回 (document {stamped_docs} 個)")
    print("  これは鳴った回数であって、直った回数ではありません。")
    print("  鳴ったのは書き込みの瞬間で、その後 書き手が直したかは別の事象です。")
    return 0


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


# ══════════════════════════════════════════════════════════════════════════
# ★差し替えを一切せぬ試験 (cmd_1450 乙)★ — 門への【配線】を現物の盤で撃つ
#
# ★何ゆえ要るか (軍師一号 2026-07-28 06:52 の検分・二号が 06:5x に再現)★
#   B3 は current_task を ★直に★ 呼んで撃ち、W5 系は task_lookup を ★差し替えて★ 撃つ。
#   ゆえに ★warn_text が current_task を現に呼び、其れが現物の帳面を現に読む★ 経路は
#   一度も走っておらぬ。実測 = 次の二つの変異が ★selftest 全緑のまま生き残った★:
#     (B) warn_text の中の (task_lookup or current_task) を常に None を返す物へ替える
#     (C) current_task の既定の在処を queue/tasks 以外へ向ける
#   ★出力は 1 byte も動かなんだ★ (N3 の数さえ動かぬ = 現物 9 本が今 R5 を鳴らさぬゆえ)。
#
# ★形★= 報告の本文は【文字列として】渡す = ★queue/reports/ へ 0 byte★。
#        帳面は【読むだけ】= ★queue/tasks/ へ 0 byte★ (条C)。
#        task_lookup も path_exists も ★渡さぬ★ = 既定の配線がそのまま走る。
#
# ★黙る時は緑にせぬ★= 現物の盤が anchor を持たねば ★UNDETERMINED★ と名乗る。
#   SKIP=FAIL の規ゆえ「撃てなんだ物」を緑に混ぜぬ。而して ★UNDETERMINED 単体では
#   赤にせぬ★ = 他人の帳面が直れば赤くなる門は外される (条C「外されにくさ」)。
#   ★一つも determined が無い時だけ赤にする★ = 其の時は配線が現に試験されておらぬ。
# ══════════════════════════════════════════════════════════════════════════
LIVE_PROBE_ID = "subtask_zz_live_wiring_probe"  # ★どの帳面にも無い id★


def _live_report_text(task_id: str, timestamp: str) -> str:
    """現物の盤へ撃つ報告の本文。★file には書かぬ (文字列のまま warn_text へ渡す)★。"""
    return f"task_id: {task_id}\nstatus: done\ntimestamp: '{timestamp}'\n"


def is_self_ledger(target_path, self_path: pathlib.Path | None = None) -> bool:
    """其の帳面は【此の file 自身】を指しておるか (条C = 己を母数から外す)。

    ★何ゆえ独立の口にしたか (cmd_1450 丙)★=
      除外が live_ledgers の中に埋まっておった間、★除外を外す変異は緑のまま生き残った★。
      因は「今 此の file を指す帳面が現に無い」ゆえの偶然であって、守りが試験された
      からではない。★口を分ければ、盤に何が在ろうと両方向で撃てる★。
    """
    if not (target_path and looks_like_path(target_path)):
        return False
    me = (self_path or pathlib.Path(__file__)).resolve()
    try:
        return (_SCRIPTS_DIR.parent / str(target_path).strip()).resolve() == me
    except OSError:
        return False


def live_ledgers(tasks_dir=None, self_path: pathlib.Path | None = None) -> tuple[list[tuple], int]:
    """現物の queue/tasks/ から anchor に使える帳面を集める。(帳面 list, 現に在る yaml の数)。

    ★current_task を差し替えずに呼ぶ★= 之が撃ちたい当の配線である。
    ★己の帳面は外す (条C)★= target_path が ★此の file 自身★ を指す帳面は、
      今 此の門を書いておる者の物ゆえ、書いておる間に動く。anchor にせぬ。

    tasks_dir / self_path は ★試験が除外そのものを撃つ★ ためだけの口である
    (既定 = 現物)。之を渡す試験は差し替えの試験ゆえ、★差し替えなしの L0〜L4 と
    併せて読め★ = 片方だけでは配線を証さぬ。
    """
    base = pathlib.Path(tasks_dir) if tasks_dir else _SCRIPTS_DIR.parent / "queue" / "tasks"
    if not base.is_dir():
        return [], 0
    files = sorted(base.glob("*.yaml"))
    out = []
    for p in files:
        stem = f"{p.stem}_report"
        tid, upd, prev, tgt = current_task(stem, tasks_dir=tasks_dir)
        if not (tid and isinstance(upd, str) and reader_can_parse_time(upd)):
            continue
        if is_self_ledger(tgt, self_path):
            continue  # ★己を母数から外す★
        out.append((stem, tid, upd, prev, tgt))
    return out, len(files)


def live_wiring() -> tuple[bool, list[str]]:
    """★差し替えを一切せぬ試験★。返り = (赤でないか, 印字する行)。"""
    lines: list[str] = []
    ok = True
    determined = 0

    # ── L5 / L6 = ★己の除外 (条C) そのものを撃つ★ (cmd_1450 丙) ──
    #   ★何ゆえ足したか★= 除外を外す変異は 07:0x 時点で ★緑のまま生き残った★。
    #   因は「今 此の file を指す帳面が現に無い」= ★偶然 無害★であって、守りが
    #   試験されておったからではない。⇒ 盤に依らず撃てる形へ改めた。
    me_rel = "scripts/" + pathlib.Path(__file__).name
    if is_self_ledger(me_rel) and not is_self_ledger("plans/cmd_9999_not_me.md"):
        determined += 1
        lines.append(f"  ok  L5 己の除外が両方向で効く ({me_rel} → 外す / 他人の路 → 外さぬ)")
    else:
        ok = False
        lines.append(f"  NG  L5 ★己の除外が壊れておる★ 己={is_self_ledger(me_rel)} "
                     f"(True の筈) / 他人={is_self_ledger('plans/cmd_9999_not_me.md')} (False の筈)")

    #   L6 = ★除外が live_ledgers に現に配線されておるか★。
    #   砂場の帳面で撃つ ⇒ ★現物の queue/tasks/ へ 0 byte★。
    with tempfile.TemporaryDirectory() as _td6:
        _d6 = pathlib.Path(_td6)
        (_d6 / "zzself.yaml").write_text(
            "task:\n  task_id: subtask_9460\n  updated_at: '2026-07-28T05:00:00'\n"
            f"  target_path: '{me_rel}'\n", encoding="utf-8")
        (_d6 / "zzother.yaml").write_text(
            "task:\n  task_id: subtask_9461\n  updated_at: '2026-07-28T05:00:00'\n"
            "  target_path: 'plans/cmd_9999_not_me.md'\n", encoding="utf-8")
        got6, n6 = live_ledgers(tasks_dir=_d6)
        stems6 = {s for s, *_ in got6}
        if n6 == 2 and stems6 == {"zzother_report"}:
            determined += 1
            lines.append("  ok  L6 帳面 2 本のうち ★己を指す 1 本だけが母数から落ちた★ "
                         "(除外が live_ledgers に現に配線されておる)")
        else:
            ok = False
            lines.append(f"  NG  L6 ★除外が配線されておらぬ★ 帳面 {n6} 本 → 残った={sorted(stems6)} "
                         "(期待 = {'zzother_report'} のみ)")

    ledgers, n_files = live_ledgers()
    lines.append(f"  ── L0 現物の帳面 {n_files} 本のうち anchor に使えるもの = {len(ledgers)} 本 "
                 f"(★差し替えなし・読むだけ★)")
    if not ledgers:
        if n_files == 0:
            lines.append("  ??  L0 UNDETERMINED 現物の帳面が 1 本も無い = 配線を撃てぬ")
            return ok, lines
        ok = False
        lines.append(f"  NG  L0 ★帳面が {n_files} 本 在るのに 1 本も読めておらぬ★ = "
                     "current_task が現物の queue/tasks/ を読めておらぬ公算が高い (変異 C の顔)")
        return ok, lines

    stem, tid, upd, _prev, _tgt = ledgers[0]

    # ── L1 = R5c の配線 (陽性)。★どの帳面にも無い id で完遂を名乗れば鳴る筈★ ──
    got = warn_text(_live_report_text(LIVE_PROBE_ID, upd), stem)
    if any("[R5c]" in g for g in got):
        determined += 1
        lines.append(f"  ok  L1 現物の帳面 ({stem}) を現に読み、R5c が鳴った "
                     f"= ★warn_text → current_task → queue/tasks/ の配線が生きておる★")
    else:
        ok = False
        lines.append(f"  NG  L1 ★配線が死んでおる★ {stem} の現任 = {tid!r} と食い違う完遂を "
                     f"撃ったが R5c が鳴らなんだ (出た警告={[g.split(chr(10))[0] for g in got] or '無し'})")

    # ── L1n = 負の対照。★現物の id をそのまま名乗れば黙る筈★ ──
    got_n = warn_text(_live_report_text(tid, upd), stem)
    if not any("[R5c]" in g for g in got_n):
        determined += 1
        lines.append(f"  ok  L1n 現物の id ({tid}) を名乗れば R5c は黙る (負の対照)")
    else:
        ok = False
        lines.append(f"  NG  L1n 現物の id を名乗ったのに R5c が鳴った = ★常に鳴る門になっておる★")

    # ── L2 = R5d の配線。★帳面の target_path と現物の在否を、門とは別の手で照らす★ ──
    #   期待は repo_path_exists ではなく ★素の pathlib★ で立てる = 其の口が壊れても気付く。
    root = _SCRIPTS_DIR.parent
    fire_cases, silent_cases, mismatched = 0, 0, []
    n_fire_expected, n_silent_expected = 0, 0
    for st, t_id, t_upd, _pv, tgt in ledgers:
        if not (tgt and looks_like_path(tgt)):
            continue
        want_fire = not (root / tgt.strip()).exists()
        if want_fire:
            n_fire_expected += 1
        else:
            n_silent_expected += 1
        fired = any("[R5d]" in g for g in warn_text(_live_report_text(t_id, t_upd), st))
        if fired != want_fire:
            mismatched.append((st, tgt, want_fire, fired))
        elif want_fire:
            fire_cases += 1
        else:
            silent_cases += 1
    if mismatched:
        ok = False
        for st, tgt, want_fire, fired in mismatched:
            lines.append(f"  NG  L2 {st}: 現物 {'無し' if want_fire else '在り'} なのに R5d は "
                         f"{'鳴った' if fired else '鳴らなんだ'} (target_path={tgt!r})")
    #   ★UNDETERMINED と NG を混ぜぬ★= 「撃てる盤が無い」と「撃ったが違った」は別物である。
    if fire_cases:
        determined += 1
        lines.append(f"  ok  L2 帳面の指す先に物が無い帳面 {fire_cases} 本で R5d が現に鳴った")
    elif n_fire_expected == 0:
        lines.append("  ??  L2 UNDETERMINED ★現物の盤に「帳面の指す先が無い」帳面が今 1 本も無い★ "
                     "= 陽性側を撃てておらぬ (盤が変われば撃てる)")
    if silent_cases:
        determined += 1
        lines.append(f"  ok  L2n 帳面の指す先に物が在る帳面 {silent_cases} 本で R5d は黙った (負の対照)")
    elif n_silent_expected == 0:
        lines.append("  ??  L2n UNDETERMINED 現物の盤に「指す先が在る」帳面が今 1 本も無い")

    # ── L3 = R5d2 の配線。★路として読めぬ target_path を持つ帳面で撃つ★ ──
    # ★門と同じ見分けを使う★= 門が「ディレクトリは読める」と判ずるのに
    #   此処が拡張子だけで数えると、配線の試験が門と食い違う盤面を作る。
    unreadable = [(st, t_id, t_upd, tgt) for st, t_id, t_upd, _pv, tgt in ledgers
                  if tgt is not None
                  and not (looks_like_path(tgt) or repo_path_is_dir(tgt))]
    if not unreadable:
        lines.append("  ??  L3 UNDETERMINED ★路として読めぬ target_path を持つ帳面が今 無い★ "
                     "= R5d2 の配線を現物では撃てておらぬ (七号の帳面が直れば此処へ来る)")
    else:
        bad = [st for st, t_id, t_upd, _t in unreadable
               if not any("[R5d2]" in g for g in warn_text(_live_report_text(t_id, t_upd), st))]
        if bad:
            ok = False
            lines.append(f"  NG  L3 路として読めぬ target_path を持つ帳面 {bad} で R5d2 が鳴らなんだ")
        else:
            determined += 1
            lines.append(f"  ok  L3 路として読めぬ target_path の帳面 {len(unreadable)} 本で "
                         f"R5d2 が現に鳴った ({[t for _s, _i, _u, t in unreadable][0][:40]}…)")

    # ── L7 (cmd_1469) = ★R5e の【時計】の配線を、差し替えずに撃つ★ ──
    #   ★何ゆえ要るか★= W5e 系は now を差し替えて撃つゆえ、★既定の時計を読む口
    #   (_now_naive_local) は一度も走っておらぬ★。cmd_1450 で変異4 が
    #   「読む口を切って常に None を返す」形のまま selftest 全緑で生き残った、
    #   ★あの形そのものである★ (CLAUDE.md 条5 の実例2)。
    #   ⇒ 現物の時計から見て確実に未来／確実に過去の刻を作り、両方向で撃つ。
    #     刻は現物の時計から作る = ★どの日に撃っても答が変わらぬ★ (条G-2)。
    _real = _now_naive_local()
    _future = (_real + datetime.timedelta(hours=4)).isoformat(timespec="seconds")
    _past = (_real - datetime.timedelta(hours=4)).isoformat(timespec="seconds")
    _stem_l7 = "ashigaru3_report"
    _mk = (lambda ts: f"task_id: subtask_9469\nstatus: done\ntimestamp: '{ts}'\n")
    _no_task = lambda _s: (None, None, set(), None)  # noqa: E731  R5c/R5d を黙らせる
    hit_f = any("[R5e]" in g for g in
                warn_text(_mk(_future), _stem_l7, task_lookup=_no_task))
    hit_p = any("[R5e]" in g for g in
                warn_text(_mk(_past), _stem_l7, task_lookup=_no_task))
    if hit_f and not hit_p:
        determined += 1
        lines.append("  ok  L7 既定の時計で R5e が両方向に効く "
                     f"(4 時間 先 → 鳴る / 4 時間 前 → 黙る・許す幅 {FUTURE_TOLERANCE_SEC} 秒)")
    else:
        ok = False
        lines.append(f"  NG  L7 ★既定の時計を読む口が壊れておる★ "
                     f"未来で鳴ったか={hit_f} (True の筈) / 過去で鳴ったか={hit_p} (False の筈)")

    if determined == 0:
        ok = False
        lines.append("  NG  L4 ★determined が 1 つも無い★ = 現物の盤では配線を一度も撃てておらぬ。"
                     "★之を緑と読むな★")
    else:
        lines.append(f"  ── L4 determined = {determined} 方向 (UNDETERMINED は緑に数えておらぬ)")
    return ok, lines


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


# ★B4 が要求する検めの族★ (cmd_1450 丙)
#   ★何ゆえ要るか★= 07:0x 実測 = ★L 系の呼び出しを selftest から消す変異が、緑のまま
#   生き残った★。門はいつでも外せ、外したことを誰も名指さなんだ。
#   ⇒ 「族がここに在るべし」を ★data として宣言し、走った後に照合する★。
#   ★之で消えるのは【黙って消える形】だけである★= 下の表から名を消せば依然として外せる。
#   而して其の時は ★何を捨てたかを明示して消す★ことになる (条6 = 射程を名乗る)。
REQUIRED_FAMILIES = ("B1", "B2", "B3", "B3n", "B6", "L0", "L5", "L6", "L7", "N3",
                     "S1", "S1n", "S2", "S3", "S4", "S5", "S6")


# ══════════════════════════════════════════════════════════════════════════
# S 系 (cmd_1567) = 刻を入れる口を、壊して落ちるか検める
#
# 本体は S4 である。入れる口を止めた時に S1/S2 が落ちなければ、この試験は
# 何も証していないので捨てる。
#
# 現物の queue/reports/ へは 1 byte も書かない。file が要る検め (S6) は temp dir で
# 撃ち、stem も現物の帳面に無い名を使う (条C = 試験の作り物を門の母数へ入れない)。
#
# この試験が見ないもの (射程を名乗る)
#   ・S4 が止めるのは stamp_text ごと差し替える変異までである。stamp_text の中の
#     置換1行だけを消す変異は、S1/S2 が現に落ちるので捕まるが、S4 の名では出ない
#   ・hook_main が stamp_file を呼ぶ配線そのものは S6 が順序で撃つ
# ══════════════════════════════════════════════════════════════════════════
_S_NOW = "2026-08-01T20:00:00"
_S_AUTO = "report:\n  task_id: subtask_9567\n  status: done\n  timestamp: AUTO\n"
_S_REAL = ("report:\n  task_id: subtask_9567\n  status: done\n"
           "  timestamp: '2026-08-01T10:00:00'\n")
_S_NONE = "report:\n  task_id: subtask_9567\n  status: done\n"
# 本文の中に "timestamp:" と "task_id:" を持つ block scalar。ここを触れば S3 が赤くなる。
#
# ★本文の行は「timestamp: AUTO」そのものにする★ (2026-08-01・私が現に踏んだ)
#   初版の本文は「timestamp: AUTO と本文に書いてあります」であった。この形だと
#   値が AUTO 単体でないので、block scalar を飛ばす口を殺す変異 (V4) を撃っても
#   置き換えが起きず、S3 は緑のまま生き残った。
#   = 試験が「本文を鍵と読む」と「本文を書き換える」を区別できていなかった。
#   足軽四号 15:33 の学び (試験そのものが区別すべき2つを同じ物にしている) と同じ形である。
_S_BLOCK = ("report:\n  task_id: subtask_9567\n  timestamp: AUTO\n"
            "  headline: |\n    timestamp: AUTO\n"
            "    task_id: にせもの\n")


def _stamp_checks(stamper) -> list[tuple[str, bool, str]]:
    """S1/S2 の判定を1つの口へ集める。★S4 が同じ口を no-op で撃つために要る★。"""
    out = []

    new_auto, rec_auto = stamper(_S_AUTO, _S_NOW)
    ok1 = (len(rec_auto) == 1 and rec_auto[0]["action"] == "replaced"
           and f"timestamp: '{_S_NOW}'" in new_auto and "AUTO" not in new_auto)
    out.append(("S1", ok1,
                f"AUTO の欄へ刻が入った (記録={len(rec_auto)}件)" if ok1 else
                f"AUTO の欄へ刻が入っていない (記録={len(rec_auto)}件)"))

    new_none, rec_none = stamper(_S_NONE, _S_NOW)
    view = reader_view(new_none) or []
    ok2 = (len(rec_none) == 1 and rec_none[0]["action"] == "inserted"
           and bool(view) and view[0].get("timestamp") == _S_NOW
           and "  timestamp:" in new_none)
    out.append(("S2", ok2,
                "欄が無い document へ挿さり、読み手の高さから見えた" if ok2 else
                f"挿さっていない/読み手から見えない (記録={len(rec_none)}件・"
                f"読み手が見た刻={view[0].get('timestamp') if view else None!r})"))
    return out


def stamp_selftest() -> tuple[bool, list[str]]:
    """S1〜S6。返り = (赤でないか, 印字する行)。"""
    lines: list[str] = []
    ok = True

    # ── S1 / S2 = 入れる口が現に効くか (陽性) ──
    for name, passed, why in _stamp_checks(stamp_text):
        ok = ok and passed
        lines.append(f"  {'ok ' if passed else 'NG '} {name} {why}")

    # ── S1n = 数字が既に在る時は 1 byte も動かさない (負の対照・今の裁の要) ──
    new_real, rec_real = stamp_text(_S_REAL, _S_NOW)
    passed = (not rec_real) and new_real == _S_REAL
    ok = ok and passed
    lines.append(f"  {'ok ' if passed else 'NG '} S1n 数字が在る欄は触らない "
                 + ("(本文が 1 byte も動いていない)" if passed else
                    f"★上書きしている★ (記録={len(rec_real)}件)"))

    # ── S3 = block scalar の中身を鍵と読み違えない ──
    new_block, rec_block = stamp_text(_S_BLOCK, _S_NOW)
    body_kept = ("    timestamp: AUTO\n" in new_block
                 and "    task_id: にせもの" in new_block)
    passed = (len(rec_block) == 1 and body_kept
              and new_block.count(f"timestamp: '{_S_NOW}'") == 1)
    ok = ok and passed
    lines.append(f"  {'ok ' if passed else 'NG '} S3 block scalar の中身は触らない "
                 + ("(本文の 2 行はそのまま・入れたのは鍵の 1 箇所だけ)" if passed else
                    f"★本文を触った/数が合わない★ (記録={len(rec_block)}件・本文保存={body_kept})"))

    # ── S4 = ★本体★ 入れる口を止めれば S1/S2 が落ちるか ──
    #   落ちなければ S1/S2 は何も証していないので、その時は試験ごと捨てる。
    def _noop(text, _now):
        return text, []
    survived = [n for n, passed, _w in _stamp_checks(_noop) if passed]
    passed = not survived
    ok = ok and passed
    lines.append(f"  {'ok ' if passed else 'NG '} S4 入れる口を止めると S1/S2 が落ちる "
                 + ("(変異で現に赤くなった)" if passed else
                    f"★{survived} が緑のまま生き残った = S1/S2 は何も証していない★"))

    # ── S5 = 数を残せない時でも書き手を止めない ──
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        good = d / "j.jsonl"
        wrote = journal_append({"at": _S_NOW, "probe": True}, path=good)
        n_lines = len(good.read_text(encoding="utf-8").splitlines()) if good.is_file() else 0
        blocked = d / "notadir"
        blocked.write_text("file であってディレクトリではありません\n", encoding="utf-8")
        failed = journal_append({"at": _S_NOW}, path=blocked / "j.jsonl")
    passed = (wrote and n_lines == 1 and failed is False)
    ok = ok and passed
    lines.append(f"  {'ok ' if passed else 'NG '} S5 数は 1 行 増え、書けない時は False を返して落ちない "
                 + (f"(書けた={wrote}/行={n_lines}/書けない時={failed})" if passed else
                    f"★{wrote=} {n_lines=} {failed=}★"))

    # ── S6 = 順序。刻を入れてから検める (逆なら R5b が鳴る) ──
    #   現物の queue/reports/ へは書かない。stem も現物の帳面に無い名を使う。
    with tempfile.TemporaryDirectory() as td:
        p = pathlib.Path(td) / "zz_stamp_probe_report.yaml"
        p.write_text(_S_NONE, encoding="utf-8")
        before = warn_file(p)
        recs = stamp_file(p, now_str=_S_NOW)
        after = warn_file(p)
    hit_before = any("[R5b]" in g for g in before)
    hit_after = any("[R5b]" in g for g in after)
    passed = hit_before and not hit_after and len(recs) == 1
    ok = ok and passed
    lines.append(f"  {'ok ' if passed else 'NG '} S6 入れる前は R5b が鳴り、入れた後は黙る "
                 + (f"(file へ現に書き込めた・記録={len(recs)}件)" if passed else
                    f"★入れる前={hit_before}(True の筈) / 入れた後={hit_after}(False の筈) / "
                    f"記録={len(recs)}件★"))
    return ok, lines


def selftest() -> int:
    ok = True
    emitted: list[str] = []

    def say(*parts) -> None:
        """印字しつつ ★何を撃ったかを控える★ (B4 が後で照合する)。"""
        msg = " ".join(str(x) for x in parts)
        emitted.append(msg)
        print(msg)

    say("=== report_validate --selftest (変異=赤 / 無改変=緑) ===")
    # ★門の不調を、門の側で捕える★= R2 は slim_yaml から借りた表に依る。借り損ねれば
    #   R2 は黙って消える (書き手には何も見えぬ) ゆえ、機械が此処で名指す。
    if CANONICAL_REPORTS is None:
        ok = False
        say(f"  NG  B1 slim_yaml の除外表を借りられなんだ = ★R2 が黙って消えておる★: {BORROW_ERROR}")
    else:
        say(f"  ok  B1 除外表を借りられた ({len(CANONICAL_REPORTS)} 件)")

    # ★B6 (cmd_1461) = 【完了語の写し】が【読み手】から離れておらぬかを機械で照合する★
    #   ★何ゆえ要るか★= 此処は元々 手写しで、★読み手が一度も持たなんだ語を持っておった★
    #   (借りる前の実測 = 読み手に success / 写しに complete・finished)。
    #   借りる形にしたので ★同じ物であること自体は構造で決まる★。ゆえに B6 が見るのは
    #   ★構造が外れる二つの道★ である:
    #     (1) 借り損ねて黙って倒れる — 倒れた先は別の語彙ゆえ、判定が静かに変わる
    #     (2) 倒す先の手書き定数が、読み手から離れる — 借り損ねた日に初めて牙を剥く
    #   ★(2) を見るのが要である★= 借りられておる間は倒す先が一度も使われず、
    #   ★誰も間違いに気づけぬまま寝ておる★形になる (「使われぬ守り」は腐る)。
    if COMPLETION_BORROW_ERROR is not None:
        ok = False
        say(f"  NG  B6 読み手の完了語を借りられなんだ = ★R5c/R5d が読み手と別の語彙で判じておる★"
            f": {COMPLETION_BORROW_ERROR}")
    elif set(COMPLETION_WORDS) != set(COMPLETION_WORDS_FALLBACK):
        ok = False
        say(f"  NG  B6 ★倒す先が読み手から離れておる★ = 借り損ねた日に別の語彙で判ずる"
            f" (読み手={sorted(COMPLETION_WORDS)} / 倒す先={sorted(COMPLETION_WORDS_FALLBACK)}"
            f" / 差={sorted(set(COMPLETION_WORDS) ^ set(COMPLETION_WORDS_FALLBACK))})"
            f" ⇒ {READER} に合わせて COMPLETION_WORDS_FALLBACK を直せ")
    else:
        say(f"  ok  B6 完了語を読み手から借り、倒す先も一致 ({sorted(COMPLETION_WORDS)})")

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
            say(f"  NG  B2 {label} の stem を立てられなんだ = ★M2/M2n の前提が崩れておる★: {why}")
            continue
        inside = CANONICAL_REPORTS is not None and stem in CANONICAL_REPORTS
        if inside != want_inside:
            ok = False
            say(f"  NG  B2 {label} を撃つ筈の stem '{stem}' が ★実際には表の"
                  f"{'中' if inside else '外'}に在る★ = ★前提が反対側へ移っておる★"
                  f" (cmd_1397-B で現に起きた型・{why})")
        else:
            say(f"  ok  B2 {label} の stem を表から立て、表へ当て直して確かめた: {why}")

    # ★B3 (cmd_1450) = 【帳面を読む口】そのものを撃つ★
    #   ★何ゆえ要るか★= W5 系は task_lookup を差し替えて撃つゆえ、★current_task が
    #   target_path を読む所は一度も走っておらぬ★。現に変異4 (読む口を切って常に None を
    #   返す) が ★selftest 全緑のまま生き残った★ (2026-07-28 06:4x 実測)。
    #   = ★門の判定は試験されており、門への配線は試験されておらなんだ★。
    #   帳面は tempfile へ作る = ★現物の queue/tasks/ へ 1 byte も書かぬ★ (条C)。
    with tempfile.TemporaryDirectory() as _td:
        _tdir = pathlib.Path(_td)
        (_tdir / "zz_probe.yaml").write_text(
            "task:\n  task_id: subtask_9450\n  updated_at: '2026-07-28T05:00:00'\n"
            "  prev_task_id: subtask_9449\n  target_path: 'plans/cmd_9450_draft.md'\n",
            encoding="utf-8")
        (_tdir / "zz_notarget.yaml").write_text(
            "task:\n  task_id: subtask_9451\n  updated_at: '2026-07-28T05:00:00'\n",
            encoding="utf-8")
        got = current_task("zz_probe_report", tasks_dir=_tdir)
        want = ("subtask_9450", "2026-07-28T05:00:00", {"subtask_9449"}, "plans/cmd_9450_draft.md")
        if got == want:
            say("  ok  B3 帳面から (task_id/updated_at/前任/target_path) を現に読めた")
        else:
            ok = False
            say(f"  NG  B3 ★帳面を読む口が壊れておる★ 期待={want} / 実際={got}")
        got2 = current_task("zz_notarget_report", tasks_dir=_tdir)
        if got2[3] is None:
            say("  ok  B3n target_path の無い帳面では None を返す = ★R5d は黙る★ (負の対照)")
        else:
            ok = False
            say(f"  NG  B3n target_path が無いのに {got2[3]!r} を返した")

    # ★L 系 (cmd_1450 乙) = 差し替えを一切せぬ試験★
    #   B3 は current_task を直に撃ち、W5 系は task_lookup を差し替えて撃つ。
    #   ★どちらも「warn_text が現物の帳面を現に読む」経路は走らせておらぬ★ ゆえ、
    #   変異 (B)(C) が全緑のまま生き残った (2026-07-28 07:0x 二号が再現)。
    live_ok, live_lines = live_wiring()
    ok = ok and live_ok
    for _line in live_lines:
        say(_line)

    # ★S 系 (cmd_1567) = 刻を入れる口を壊して検める★ (本体は S4)
    stamp_ok, stamp_lines = stamp_selftest()
    ok = ok and stamp_ok
    for _line in stamp_lines:
        say(_line)

    for name, text, stem, needle in _cases():
        if stem is None:
            ok = False
            say(f"  NG  {name} / ★前提の stem を立てられず撃てなんだ★ (B2 を見よ)")
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
        say(f"  {'ok ' if passed else 'NG '} {name}{detail}")

    # ── R5 (cmd_1407) = ★鍵を消せば赤・正しい物では静か★ を両方向で ──
    #   ★試験の前提を焼き付けぬ★= task YAML は差し替え可能な口 (task_lookup) から与える。
    _NO_TASK = lambda _stem: (None, None, set())  # noqa: E731  R5c を黙らせる (R5a/R5b だけを撃つ)
    #   ★R5d の試験は path_exists も差し替える★= 現物の plans/ へ 1 byte も作らぬ
    #     (条C = 門の試験が門の数える盤面を動かす形にせぬ)。
    _NO_FILE = lambda _p: False   # noqa: E731  「其の路に物は無い」
    _HAS_FILE = lambda _p: True   # noqa: E731  「其の路に物が在る」
    #   ★ディレクトリか否かも差し替える★ (cmd_1395)。既定は「どれもディレクトリでない」。
    #     此処を既定のままにすると、試験が現物の repo を見に行き、
    #     ★盤面が動けば試験の答も動く★形になる (条G-2)。
    _NOT_DIR = lambda _p: False   # noqa: E731  「其の路はディレクトリでない」
    _IS_DIR = lambda _p: True     # noqa: E731  「其の路は現に在るディレクトリ」
    #   ★今の刻も差し替える★ (cmd_1469)。実時計で撃つと、試験の答が撃った刻で変わる。
    #     ここを既定のままにすると、W5e 系は ★盤面 (時計) が動けば答も動く★形になる (条G-2)。
    _NOW = lambda: datetime.datetime(2026, 7, 28, 12, 0, 0)  # noqa: E731
    _T = "plans/cmd_9450_draft.md"           # 帳面が指す綴り (現物には存在せぬ名)
    _T_OTHER = "plans/cmd_9450_written.md"   # 書き手が己で付けた別の名
    _T_DIR = "plans/cmd_9450_scan"           # 拡張子を持たぬ = 旧い門はここで誤って鳴った
    for case in [
        (
            "W1 任意名の下へ入れた task_id (三号の現物と同じ形) = 読み手から見えぬ",
            "cmd1426_two_writers:\n  task_id: subtask_1426\n  status: done\n"
            "  timestamp: '2026-07-27T20:42:00'\n",
            "ashigaru3_report", _NO_TASK, "[R5a]",
        ),
        (
            # ★軍師一号 22:4x「警告は出るが読む者が居らぬ」への手当て★=
            #   R5a が鳴る其の場で ★据え置きの理由と、赤へ上げる条件★ を門が名乗る。
            #   (負の対照は W1n/W1n2 = 正しい report では此の行も出ぬ)
            "W1r R5a は ★いつ赤へ変えるか★ を己の口で名乗る",
            "cmd1426_two_writers:\n  task_id: subtask_1426\n  status: done\n"
            "  timestamp: '2026-07-27T20:42:00'\n",
            "ashigaru3_report", _NO_TASK, "いつ赤へ変えるか",
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
        # ── R5d (cmd_1450) = 帳面の名と現に在る物の食い違い ──
        (
            "W5 完遂を名乗るが帳面の指す稿が無い (軍師二号 cmd_1442 と同じ形)",
            f"task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n"
            f"deliverable: {_T_OTHER}\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(), _T),
            "[R5d]", _NO_FILE,
        ),
        (
            "W5h R5d は ★書き手が己で名乗った別の名★ を手掛かりに出す",
            f"task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n"
            f"deliverable: {_T_OTHER}\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(), _T),
            _T_OTHER, _NO_FILE,
        ),
        (
            "W5n 帳面の指す稿が現に在る = ★緑★",
            f"task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n"
            f"deliverable: {_T}\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(), _T),
            None, _HAS_FILE,
        ),
        (
            "W5n2 未だ走行中 (完遂を名乗っておらぬ) = ★緑★ "
            "(2026-07-28 06:34 実測 = 完遂の条件が無ければ 5/5 の任が鳴る)",
            "task_id: subtask_9450\nstatus: in_progress\n"
            "timestamp: '2026-07-28T06:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(), _T),
            None, _NO_FILE,
        ),
        (
            "W5n3 書いてあるのは前任の完遂だけ = ★緑★ (R5d は現任の完遂しか見ぬ)",
            "task_id: subtask_OLD\nstatus: done\ntimestamp: '2026-07-28T04:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", {"subtask_OLD"}, _T),
            None, _NO_FILE,
        ),
        (
            "W5p 帳面の target_path が路として読めぬ (七号の現物と同じ形) = 黙って捨てぬ",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(),
                        "queue/reports/x_report.yaml (調査報告・実装なし)"),
            "[R5d2]", _NO_FILE,
        ),
        (
            # ★陽性側★ = 直しが現に効いておるか。
            # 旧い門は拡張子だけを見たので、ここで必ず [R5d2] を出しておった。
            # 読み手は is_dir() を扱うので、現に在るディレクトリは【読める】。
            "W5d1 target_path が ★現に在るディレクトリ★ = R5d2 も R5d も ★黙る★ (cmd_1395)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(), _T_DIR),
            None, _HAS_FILE, _IS_DIR,
        ),
        (
            # ★陰性側 その一★ = 直しが門を殺しておらぬか。
            # 同じ綴りでも、現物が無ければ今までどおり鳴らねばならぬ。
            # ★之が鳴らねば、拡張子の無い路が悉く素通りする門になっておる。★
            "W5d2 同じ綴りだが ★現物が無い★ = R5d2 は今までどおり ★鳴る★ (陰性の対照)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(), _T_DIR),
            "[R5d2]", _NO_FILE, _NOT_DIR,
        ),
        (
            # ★陰性側 その二★ = ディレクトリの口が、註釈の抜け道にならぬか。
            # 七号の現物と同じ「路 + 日本語の註」は、ディレクトリでもないので鳴り続ける。
            "W5d3 註つきの target_path は ★ディレクトリの口が在っても鳴る★ (抜け道にせぬ)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set(),
                        "plans/cmd_9450_scan (調査報告・実装なし)"),
            "[R5d2]", _HAS_FILE, _NOT_DIR,
        ),
        (
            "W5c 古い 3 つ組を返す task_lookup では R5d は ★黙る★ (後方互換)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T06:00:00'\n",
            "ashigaru3_report",
            lambda _s: ("subtask_9450", "2026-07-28T05:00:00", set()),
            None, _NO_FILE,
        ),
        # ── R5e (cmd_1469) = ★未来の刻★ を両方向で撃つ ──
        #   ★刻は差し替える★= 実時計で撃てば、試験の答が撃った刻で変わる (条G-2)。
        (
            "W5e 刻が ★4 時間 先★ (家老が現に書いた形) = 鳴る",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T16:00:00'\n",
            "ashigaru3_report", _NO_TASK, "[R5e]", _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            "W5e2 刻が ★2 分 16 秒 先★ (軍師二号が現に書いた形) = 鳴る",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T12:02:16'\n",
            "ashigaru3_report", _NO_TASK, "[R5e]", _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            "W5en 刻が ★過去★ = 黙る (陰性側・之が鳴れば門を殺しておる)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T11:00:00'\n",
            "ashigaru3_report", _NO_TASK, None, _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            "W5en2 刻が ★今そのもの★ = 黙る (陰性側)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T12:00:00'\n",
            "ashigaru3_report", _NO_TASK, None, _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            "W5en3 刻が ★許す幅ちょうど (120 秒 先)★ = 黙る (境の内側)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T12:02:00'\n",
            "ashigaru3_report", _NO_TASK, None, _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            "W5en4 tz つきの刻でも引き算が落ちぬ (過去ゆえ黙る)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: '2026-07-28T11:00:00+09:00'\n",
            "ashigaru3_report", _NO_TASK, None, _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            # ★家老 12:02 の枷3★=「刻が無い/読めぬ時に何が起きるか」を決めて書け。
            #   家老の推しは「鳴る」側。★R5b が現に鳴る★ゆえ R5e は其処を重ねて見ぬ。
            "W5eb 刻が ★無い★ = R5e でなく ★R5b★ が鳴る (枷3 = 無いを正しいと読まぬ)",
            "task_id: subtask_9450\nstatus: done\n",
            "ashigaru3_report", _NO_TASK, "[R5b]", _NO_FILE, _NOT_DIR, _NOW,
        ),
        (
            "W5eb2 刻が ★読めぬ★ = 同じく R5b が鳴る (枷3)",
            "task_id: subtask_9450\nstatus: done\ntimestamp: 'きのう'\n",
            "ashigaru3_report", _NO_TASK, "[R5b]", _NO_FILE, _NOT_DIR, _NOW,
        ),
    ]:
        name, text, stem, lookup, needle, *rest = case
        # rest[0] = path_exists の差し替え / rest[1] = path_is_dir の差し替え
        # rest[2] = 今の刻の差し替え (R5e 用・cmd_1469)。
        # ★どれも現物へ触れぬための口である★ (条C = 試験の作り物を門の母数へ入れぬ)。
        # ★刻を差し替える理由★= 実時計で撃つと、試験の答が撃った刻で変わる (条G-2)。
        got = warn_text(text, stem, task_lookup=lookup,
                        path_exists=(rest[0] if rest else None),
                        path_is_dir=(rest[1] if len(rest) > 1 else _NOT_DIR),
                        now=(rest[2] if len(rest) > 2 else None))
        if needle is None:
            passed = not got
            detail = "" if passed else " / 出た警告=" + "; ".join(g.split("\n")[0] for g in got)
        else:
            passed = any(needle in g for g in got)
            detail = (" / " + "; ".join(g.split("\n")[0] for g in got)) if got else \
                     " / ★警告が1つも出ておらぬ★"
        ok = ok and passed
        say(f"  {'ok ' if passed else 'NG '} {name}{detail}")

    # ★盤面の側の負例★= 現に在る report が悉く緑であること (門が狼少年でない証)。
    #   ★本数を焼かぬ★ = agent が増減すれば動く数ゆえ (CLAUDE.md 条F の族)。
    #   走らせれば下の N3 の行が、其の刻に何本 見たかを己で刷る。
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
        say(f"  {mark}N2 現物 {p.name} = 緑であるべき{detail}")
    if not live:
        say("  -- N2 現物の report が見当たらぬ (skip)")
    # ★N3 = 母数の印字★ (judge には効かせぬ)。R5 は警告ゆえ現物が赤くとも FAIL にせぬが、
    #   ★数を黙らせぬ★= 「R1-R4 は全部 緑、なれど読み手には見えておらぬ」を一目で出す。
    say(f"  ── N3 現物 {len(live)} 本のうち ★R5 が名指す物 = {len(r5_hit)} 本★ "
          f"(judge には効かせぬ = 警告ゆえ)")
    for nm, rules in r5_hit:
        say(f"       {nm}: {'+'.join(sorted(set(rules)))}")

    # ── B4 (cmd_1450 丙) = ★宣言した族が現に走ったか★ ──
    #   ★守る物★= 検めを selftest から【黙って外す】形。外せば族の名が出ぬゆえ此処が名指す。
    #   ★守らぬ物 (条6 = 緑の射程)★=
    #     ・REQUIRED_FAMILIES から名を消す形は止められぬ (明示の一行になるだけ)
    #     ・B4 自身を消す形も止められぬ (★之が「一段 外側」の止め所である★)
    #     ・族が【走った】ことしか見ぬ = 中身が正しいかは各族の判定に委ねる
    seen_fams = set()
    for _l in emitted:
        _m = re.match(r"\s*(?:ok|NG|\?\?|--|──)\s+([A-Z][A-Za-z0-9]*)\b", _l)
        if _m:
            seen_fams.add(_m.group(1))
    missing = [f for f in REQUIRED_FAMILIES if f not in seen_fams]
    if missing:
        ok = False
        say(f"  NG  B4 ★宣言した検めが走っておらぬ★ 欠け = {missing} "
            f"(REQUIRED_FAMILIES={list(REQUIRED_FAMILIES)} / 現に走った族={sorted(seen_fams)})")
        say("      ★之は『検めを黙って外した』の顔である★ = 外すなら "
            "REQUIRED_FAMILIES からも名を消し、何を捨てたかを書け")
    else:
        say(f"  ok  B4 宣言した {len(REQUIRED_FAMILIES)} 族が現に走った "
            f"({'/'.join(REQUIRED_FAMILIES)})")

    # ── B5 (cmd_1450 丙) = ★赤い行を刷りながら総judge が PASS になる形を禁ずる★ ──
    #   ★何ゆえ要るか★= B4 は「族が走ったか」しか見ぬ。ゆえに
    #   ★検めは走らせるが、其の赤を ok へ混ぜ忘れる (или 握り潰す) 変異★ が擦り抜けた
    #   (2026-07-28 変異F2 で実測)。之は「見たのに数えぬ」形である。
    #   ⇒ ★印字と判定の食い違い★を、判定の最後に照合する。
    red_lines = [l for l in emitted if re.match(r"\s*NG\b", l.strip()[:3]) or l.lstrip().startswith("NG ")]
    if red_lines and ok:
        ok = False
        say(f"  NG  B5 ★赤を {len(red_lines)} 行 刷りながら総judge が PASS になっておった★ "
            "= 検めは走ったが其の赤が judge へ混ざっておらぬ")
        for _r in red_lines[:5]:
            say(f"      刷った赤: {_r.strip()[:110]}")
    elif red_lines:
        say(f"  ── B5 赤 {len(red_lines)} 行 / 総judge={'PASS' if ok else 'FAIL'} "
            f"({'★食い違っておる★' if ok else '食い違っておらぬ'})")
    else:
        say("  ok  B5 赤い行は 1 つも刷られておらぬ (印字と判定が食い違っておらぬ)")

    say("=== 総judge:", "PASS" if ok else "FAIL", "===")
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

    # ★刻は検める前に入れる★ (cmd_1567) = 入れた後の姿を R5b/R5e が見る。
    #   逆順にすると、機械が入れた刻について R5b が鳴る (S6 が此の順序を撃つ)。
    stamped = stamp_file(path)

    problems = validate_file(path)
    warnings = warn_file(path)

    # ★数を残す★ (cmd_1567) = 鳴った回数が積み上がる。書き手の申告に依らない。
    try:
        rel = str(path.relative_to(_SCRIPTS_DIR.parent))
    except ValueError:
        rel = str(path)
    journal_append({
        "at": _now_naive_local().isoformat(timespec="seconds"),
        "writer": path.stem.replace("_report", ""),
        "path": rel,
        "rules": rule_codes(problems) + rule_codes(warnings),
        "stamped": [{"doc": r["doc"], "task_id": r.get("task_id"),
                     "action": r["action"], "value": r.get("value")} for r in stamped],
    })

    if not problems and not warnings and not stamped:
        return 0
    out = []
    if stamped:
        out.append(render_stamp(path, stamped))
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
    if "--stats" in args:
        return stats()
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
        # ★但し --selftest だけは fail-OPEN にせぬ★ (cmd_1469・軍師二号が実測で見つけた)
        #   何が起きたか = R5e を tz つきの刻で落とす変異を撃った所、selftest が
        #   ★W5en4 の行で止まり、B4/B5/総judge を一度も刷らぬまま rc=0 を返した★。
        #   ⇒ ★試験が途中で死んだのに「PASS」と読める★形であった。
        #   B5 (赤い行を刷りながら PASS を禁ずる) も B4 (宣言した族が走ったか) も、
        #   ★己が走る前に死んでおれば何も言えぬ★。
        #   fail-OPEN が守りたいのは「門の不調で全 agent の Write が止まる」ことだけで、
        #   ★己を検める走行を緑に見せることではない★。ゆえに此処で分ける。
        if "--selftest" in sys.argv[1:]:
            print(f"[report_validate] NG: ★selftest が途中で落ちた★ — 之を緑と読むな: "
                  f"{type(exc).__name__}: {exc}", file=sys.stderr)
            sys.exit(1)
        print(f"[report_validate] WARN: 内部異常 — 通す (fail-OPEN): {exc}", file=sys.stderr)
        sys.exit(0)
