#!/usr/bin/env python3
"""gate_registry_append.py — gate-4: ★「登録した」と「登録されておる」を分ける★ (cmd_1409)

━━ 何を塞ぐか = ★正しい YAML の顔をした壊れ方★ ただ一つ ━━
  ★五号 08:15 実測 (cmd_1409 の起票根拠)★:
    config/mutation_registry.yaml の ★末尾へ★ entry を追記すると、
    ★mutations: の下に入らず、最後の key の値として黙って呑まれる★。
      ・parse は通る (yaml.safe_load が例外を投げぬ)
      ・道具も何も申さぬ (--sanity も replay も coverage も鳴らぬ)
      ・★mutations の総数も動かぬ★
    ⇒ ★五号の名づけ = 「登録した」と「登録されておる」は同じ物ではない★
    ⇒ ★六号の名づけ = 「正しく壊れた」ゆえ【書いた当人にも見えぬ】★

  ★六号 09:33:14 の再実測 (本 file を書く前に己の手で確かめた)★:
    shogun 台帳 (mutations 116 件) の末尾へ MUT-9999-SWALLOW を継いだ写しを作り safe_load →
      parse: OK / mutations 総数: ★116 のまま★ / tree_census_waivers の値が
      ★[{'id': 'MUT-9999-SWALLOW', ...}] という list に化けておった★。
  ⇒ ★門を悉く緑にしても、台帳に載っておらねば何も守っておらぬ★ (本夜の北極星の【一段 手前】)。

━━ ★何故【冊の形】に依るのか = 人の記憶に置いてはならぬ理由★ ━━
  ★実測 09:34 (6 冊の top-level key の並び)★:
    shogun  : mutations → coverage_waivers → tree_census_waivers   ⇒ ★mutations が末尾でない★
    backend : coverage_positive_control → mutations → coverage_waivers ⇒ ★同上★
    app     : coverage_positive_control → mutations → coverage_waivers ⇒ ★同上★
    web/ml/engine : coverage_positive_control → mutations             ⇒ ★mutations が末尾★
  ⇒ ★同じ「末尾へ追記」が、冊によって【通る】か【呑まれる】かが変わる★。
  ⇒ ★★ゆえに「末尾へ書くな」を人が覚える形では守られぬ = 機械に数えさせる★★。

━━ ★二層で検める (層が違えば捕まる呑まれ方も違う)★ ━━
  ★層A1 (節点)★= ★entry らしき mapping が mutations: の【外】に居らぬか★
      = 末尾へ継いだ形 (五号が踏んだ実物) を捕える。yaml.compose の節点で見るゆえ、
        「行が何処に在るか」でなく「木の何処にぶら下がったか」で判ずる。
  ★層A2 (文字と節点の突合)★= ★"- id: MUT-…" と書いてある行の id が、節点として一つも存在せぬ★
      = ★block scalar (desc: | 等) の中へ落ちた形★を捕える。
        此の形は層A1 には見えぬ (文字列の中身は節点にならぬ)。
  ★層B (増分の一致・処方(2))★= ★HEAD と今を突き合わせ「足した entry の数」と
      「mutations の増分」が合うか★= ★家老の処方「diff の entry 数と総数の増分の一致」★。
      層A が捕える物は層B でも鳴るが、★層B は「消えた」側 (黙って落ちた entry) も見る★。

━━ ★止めぬ。名指して記録するだけである (既定)★ ━━
  gate-3 (gate_anchor_touched.py) と同じ流儀:
    ★返すのは 0 (鳴らず) か 2 (UNDETERMINED = 大声で警告するが通す) のみ★。
  ★2 を選ぶ理由★= 呑まれは「牙が折れた」ではなく ★「其の牙が台帳に載っておらぬ」★ であり、
    誤検知で commit を止める門は書き手を悪い道 (SHOGUN_GATE_SKIP 常用・門外し) へ逃がす。
  ★但し六号の具申 = 之は本来【落とすべき】性質の赤である★ (呑まれは推測でなく確定事実ゆえ)。
    ⇒ ★逃がし口でなく【昇格の口】を置いた★= 環境変数 ★REGISTRY_APPEND_STRICT=1★ で
      「呑まれ」のみ exit 1 (commit を止める) へ昇格する。★既定は 0 = 名乗るに留める★
      (家老の推す側を既定に置き、昇格は家老/殿の号令で。判断を先に名乗る枷 cmd_1409(3))。
    ★測れなんだ (parse 不能・mutations 欠落) は STRICT でも 2 のまま★ =
      ★測れておらぬは赤ではない = 名を混ぜぬ★。

使い方:
  python3 scripts/gate_registry_append.py                 # staged の台帳のみ検分 (pre-commit)
  python3 scripts/gate_registry_append.py --all           # 6 冊すべてを検分 (層A のみ・git 不要)
  python3 scripts/gate_registry_append.py --count [FILE…] # ★挿した直後に撃つ口 (処方(1))★ 総数と増分を機械に言わせる
  python3 scripts/gate_registry_append.py --registry F    # 冊を明示 (層A)
  python3 scripts/gate_registry_append.py --selftest      # ★負の主張を一度 偽にして赤を見る★
exit: 0 鳴らず / 2 呑まれ疑い・測れなんだ / 1 は既定では返さぬ (REGISTRY_APPEND_STRICT=1 の時のみ)
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent

# ★entry の id の綴り★ — MUT-<何か>-<何か>。ash4 の申し送り (MUT-1408-H1 の形) を含む。
ID_RE = re.compile(r"MUT-[0-9A-Za-z]+-[0-9A-Za-z]+")
# ★文字の層で "- id: X" と書いてある行★ (comment 行は除く)
TEXT_ID_RE = re.compile(r"^\s*-\s+id:\s*[\"']?(MUT-[0-9A-Za-z]+-[0-9A-Za-z]+)[\"']?\s*(?:#.*)?$")
# ★entry らしさ★ = id を持ち、且つ牙の骨 (mutate/test/expect) を一つ以上持つ
ENTRY_MARKERS = ("mutate", "test", "expect")

MUTATIONS_KEY = "mutations"
# ★挿入点の掟 (cmd_1409(3))★ — 台帳 docstring へも焼いてある。道具と文書で綴りを揃える。
INSERT_RULE = "★entry は【mutations: list の末尾 = coverage_waivers: の直前】へ挿せ。file の末尾へ継ぐな★"


# ─────────────────────────────────────────────────────────────────────────────
# 冊の在処 (出所を1つに = gate_nightly.sh を正本として読む)
# ─────────────────────────────────────────────────────────────────────────────
def known_books() -> tuple[list[Path], str | None]:
    """gate_nightly.sh が現に撃っておる冊の一覧を返す。★人の記憶で並べぬ★。

    registry_census.py の read_gate_pairs を借りる (測る術の出所は 1 つ)。
    借りられなんだ時は ★「借りられなんだ」と名乗って★ 自 repo の 3 冊のみへ落とす
    (★黙って少ない数で緑を出さぬ★ = 本夜ずっと狩ってきた族)。
    """
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import registry_census as C  # noqa: PLC0415

        pairs, err = C.read_gate_pairs(REPO_ROOT / "scripts" / "gate_nightly.sh")
        if err:
            return _fallback_books(), f"gate_nightly.sh を読めなんだ: {err}"
        # ★同じ冊を二度 数えぬ★ (cmd_1409・2026-07-27 10:31 実測で見つけた)=
        #   read_gate_pairs は gate_nightly.sh の ★註 (コメント) 行の --registry も拾う★ ゆえ、
        #   同じ file が ★絶対 path と相対 path の二つの顔★ で返りうる。
        #   ★綴りで数えれば 7 冊 265 件・実体で数えれば 6 冊 264 件★ =
        #   ★★母数を刷る道具が母数を誤る = 本朝ずっと狩ってきた形の、己の中の顔★★
        #   ⇒ ★実体 (resolve した path) で一意にする★。★読めぬ path は resolve せず綴りのまま残す★
        #     (= 不在を黙って消さぬ = 「冊が無い」と名乗る口は下流に在る)。
        books, seen = [], set()
        for reg, _root in pairs:
            p = Path(reg)
            key = p.resolve() if p.exists() else (REPO_ROOT / p).resolve() if (REPO_ROOT / p).exists() else p
            if key in seen:
                continue
            seen.add(key)
            books.append(p)
        if not books:
            return _fallback_books(), "gate_nightly.sh から冊を 1 つも拾えなんだ"
        return books, None
    except Exception as e:  # noqa: BLE001
        return _fallback_books(), f"registry_census を借りられなんだ: {e}"


def _fallback_books() -> list[Path]:
    return [
        REPO_ROOT / "config" / "mutation_registry.yaml",
        REPO_ROOT / "config" / "mutation_registry.web.yaml",
        REPO_ROOT / "config" / "mutation_registry.ml.yaml",
    ]


# ─────────────────────────────────────────────────────────────────────────────
# 層A — 呑まれの検出 (git を要さぬ)
# ─────────────────────────────────────────────────────────────────────────────
def _is_entry_node(node) -> bool:
    if not isinstance(node, yaml.MappingNode):
        return False
    keys = {k.value for k, _ in node.value if isinstance(k, yaml.ScalarNode)}
    if "id" not in keys:
        return False
    return any(m in keys for m in ENTRY_MARKERS)


def _node_id(node) -> str | None:
    for k, v in node.value:
        if isinstance(k, yaml.ScalarNode) and k.value == "id" and isinstance(v, yaml.ScalarNode):
            return v.value
    return None


def _walk(node):
    yield node
    if isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            yield from _walk(k)
            yield from _walk(v)
    elif isinstance(node, yaml.SequenceNode):
        for v in node.value:
            yield from _walk(v)


def scan_book(text: str, label: str) -> dict:
    """1 冊を層A1/A2 で検分する。

    返す dict:
      ok            … 検分できたか (False = ★測れなんだ★。0 件と混ぜぬ)
      why           … 測れなんだ理由
      registered    … mutations: の下に居る entry id の list (★之が「登録されておる」の定義★)
      swallowed     … 呑まれ [(id, 何処へ, 行), …]
      text_only     … 文字では書かれておるが節点に居らぬ id [(id, 行), …] (層A2)
    """
    out = {"label": label, "ok": False, "why": None, "registered": [], "swallowed": [], "text_only": []}
    try:
        root = yaml.compose(text)
    except yaml.YAMLError as e:
        out["why"] = f"parse 不能: {str(e).splitlines()[0][:160]}"
        return out
    if root is None:
        out["why"] = "空の台帳 (節点が無い)"
        return out
    if not isinstance(root, yaml.MappingNode):
        out["why"] = f"top-level が mapping でない ({type(root).__name__})"
        return out

    mutations_node = None
    for k, v in root.value:
        if isinstance(k, yaml.ScalarNode) and k.value == MUTATIONS_KEY:
            mutations_node = v
    if mutations_node is None:
        out["why"] = f"'{MUTATIONS_KEY}:' が無い = 台帳の形をしておらぬ"
        return out

    # ★登録されておる★ = mutations: の直下の list 要素
    if isinstance(mutations_node, yaml.SequenceNode):
        for item in mutations_node.value:
            i = _node_id(item) if isinstance(item, yaml.MappingNode) else None
            if i:
                out["registered"].append(i)
    elif isinstance(mutations_node, yaml.ScalarNode) and mutations_node.value in ("", "~", "null"):
        pass  # 空の台帳は 0 件 (0 件は PASS ではない、は replay 側の問い)
    else:
        out["why"] = f"'{MUTATIONS_KEY}:' が list でない ({type(mutations_node).__name__})"
        return out

    # 層A1 — mutations の【外】に居る entry らしき節点
    all_node_ids = set()
    for k, v in root.value:
        key = k.value if isinstance(k, yaml.ScalarNode) else "?"
        for node in _walk(v):
            if isinstance(node, yaml.MappingNode):
                i = _node_id(node)
                if i:
                    all_node_ids.add(i)
            if key == MUTATIONS_KEY:
                continue
            if _is_entry_node(node):
                out["swallowed"].append((_node_id(node) or "(id 無し)", key, node.start_mark.line + 1))

    # 層A2 — 文字では entry の頭に見えるが、節点として何処にも居らぬ (= 文字列の中へ落ちた)
    for lineno, line in enumerate(text.splitlines(), start=1):
        m = TEXT_ID_RE.match(line)
        if m and m.group(1) not in all_node_ids:
            out["text_only"].append((m.group(1), lineno))

    out["ok"] = True
    return out


# ─────────────────────────────────────────────────────────────────────────────
# 層B — 増分の一致 (HEAD と今の突合・処方(2))
# ─────────────────────────────────────────────────────────────────────────────
def _git(repo: Path, *args, text=True):
    try:
        r = subprocess.run(["git", "-C", str(repo), *args],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=text, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"git が走らぬ: {e}"
    if r.returncode != 0:
        return None, f"git {' '.join(args)} 失敗 (exit {r.returncode}): {r.stderr.strip()[:200]}"
    return r.stdout, None


def all_entry_ids(scan: dict) -> set:
    """★文字でも節点でも「書いてある」entry id★ = 登録済 + 呑まれ + 文字のみ。

    ★之が「書き手が足したつもりの数」である★ — 層B はこれと registered を突き合わせる。
    """
    return set(scan["registered"]) | {i for i, _, _ in scan["swallowed"]} | {i for i, _ in scan["text_only"]}


def delta_check(repo: Path, relpath: str, now_text: str) -> dict:
    """HEAD 版と今の版を突き合わせ、★足した数と登録の増分が合うか★を返す。"""
    out = {"ok": False, "why": None, "head_n": None, "now_n": None,
           "added_written": [], "added_registered": [], "lost": [], "mismatch": []}
    head_text, err = _git(repo, "show", f"HEAD:{relpath}")
    if err:
        out["why"] = f"HEAD 版を取れなんだ (新設 file か): {err}"
        return out
    a = scan_book(head_text, f"HEAD:{relpath}")
    b = scan_book(now_text, relpath)
    if not a["ok"] or not b["ok"]:
        out["why"] = f"突合できなんだ (HEAD={a['why'] or 'ok'} / 今={b['why'] or 'ok'})"
        return out
    out["head_n"], out["now_n"] = len(a["registered"]), len(b["registered"])
    written_added = all_entry_ids(b) - all_entry_ids(a)
    reg_added = set(b["registered"]) - set(a["registered"])
    reg_lost = set(a["registered"]) - set(b["registered"])
    out["added_written"] = sorted(written_added)
    out["added_registered"] = sorted(reg_added)
    out["lost"] = sorted(reg_lost)
    # ★書いたのに登録されておらぬ★ = 呑まれ。★登録から消えたのに文字は残っておる★も同じ族。
    out["mismatch"] = sorted(written_added - reg_added)
    out["ok"] = True
    return out


# ─────────────────────────────────────────────────────────────────────────────
# 出力
# ─────────────────────────────────────────────────────────────────────────────
def report_scan(scan: dict, lines: list, strict: bool) -> int:
    rc = 0
    if not scan["ok"]:
        lines.append(f"  ⚠ 測れなんだ: {scan['label']} — {scan['why']}")
        return 2
    n_bad = len(scan["swallowed"]) + len(scan["text_only"])
    if n_bad == 0:
        lines.append(f"  ok {scan['label']}: 登録 {len(scan['registered'])} 件 / 呑まれ 0")
        return 0
    for i, key, ln in scan["swallowed"]:
        lines.append(f"  ★呑まれ★ {scan['label']}:{ln} {i} は '{MUTATIONS_KEY}:' の下に居らぬ "
                     f"(top-level key '{key}' の値として呑まれておる)")
    for i, ln in scan["text_only"]:
        lines.append(f"  ★呑まれ★ {scan['label']}:{ln} {i} は文字では書かれておるが節点に居らぬ "
                     f"(block scalar か comment の中へ落ちておる)")
    lines.append(f"      {INSERT_RULE}")
    rc = 1 if strict else 2
    return rc


def report_delta(d: dict, label: str, lines: list, strict: bool) -> int:
    if not d["ok"]:
        lines.append(f"  ⚠ 増分を測れなんだ: {label} — {d['why']}")
        return 2
    lines.append(f"  {label}: 登録 {d['head_n']} → {d['now_n']} "
                 f"({d['now_n'] - d['head_n']:+d}) / 書いて足した entry {len(d['added_written'])} 件")
    rc = 0
    if d["mismatch"]:
        lines.append(f"  ★増分が合わぬ★ 書いたのに登録されておらぬ: {', '.join(d['mismatch'])}")
        lines.append(f"      {INSERT_RULE}")
        rc = 1 if strict else 2
    if d["lost"]:
        lines.append(f"  ⚠ 登録から消えた entry: {', '.join(d['lost'])} "
                     f"(意図した削除なら commit log に理由を書け — 台帳の掟)")
        rc = max(rc, 2) if rc != 1 else 1
    return rc


# ─────────────────────────────────────────────────────────────────────────────
# mode
# ─────────────────────────────────────────────────────────────────────────────
def is_registry_path(p: str) -> bool:
    n = Path(p).name
    return n.startswith("mutation_registry") and n.endswith(".yaml")


def mode_staged(strict: bool) -> int:
    out, err = _git(REPO_ROOT, "diff", "--cached", "--name-only", "-z")
    if err:
        print(f"[gate-4] ⚠ 測れなんだ — {err}")
        return 2
    staged = [f for f in filter(None, out.split("\0")) if is_registry_path(f)]
    if not staged:
        print("[gate-4] 台帳に触れておらぬ (検分する物が無い)")
        return 0
    worst, lines = 0, []
    tally = Tally()
    for rel in staged:
        blob, e2 = _git(REPO_ROOT, "show", f":{rel}")   # ★index の中身 = 現に commit される物★
        if e2:
            lines.append(f"  ⚠ 測れなんだ: {rel} — {e2}")
            tally.add(None)
            worst = max(worst, 2)
            continue
        scan = scan_book(blob, rel)
        tally.add(scan)
        rc_a = report_scan(scan, lines, strict)
        rc_b = report_delta(delta_check(REPO_ROOT, rel, blob), rel, lines, strict)
        for rc in (rc_a, rc_b):
            worst = 1 if 1 in (worst, rc) else max(worst, rc)
    _emit(worst, lines, tally.render("staged の台帳"))
    return worst


def mode_all(strict: bool, books: list[Path] | None = None) -> int:
    err = None
    if books is None:
        books, err = known_books()
    worst, lines = 0, []
    tally = Tally()
    if err:
        lines.append(f"  ⚠ 冊の一覧を正本から取れなんだ (自 repo の 3 冊のみ見た): {err}")
        worst = 2
    for b in books:
        if not b.exists():
            lines.append(f"  ⚠ 冊が無い: {b} (撃とうとした事実は残す)")
            tally.add(None)
            worst = max(worst, 2)
            continue
        scan = scan_book(b.read_text(encoding="utf-8"), str(b))
        tally.add(scan)
        rc = report_scan(scan, lines, strict)
        worst = 1 if 1 in (worst, rc) else max(worst, rc)
    _emit(worst, lines, tally.render("台帳"))
    return worst


def mode_count(paths: list[str]) -> int:
    """★挿した直後に撃つ口 (処方(1))★ — 総数と、HEAD からの増分を機械に言わせる。"""
    if not paths:
        books, err = known_books()
        if err:
            print(f"[gate-4 --count] ⚠ {err}")
        paths = [str(b) for b in books if b.exists()]
    worst = 0
    for p in paths:
        path = Path(p).resolve()
        if not path.exists():
            print(f"  ⚠ 無い: {p}")
            worst = max(worst, 2)
            continue
        scan = scan_book(path.read_text(encoding="utf-8"), str(path))
        lines: list[str] = []
        rc = report_scan(scan, lines, strict=False)
        try:
            rel = str(path.relative_to(REPO_ROOT))
        except ValueError:
            rel = None
        if rel:
            d = delta_check(REPO_ROOT, rel, path.read_text(encoding="utf-8"))
            if d["ok"]:
                lines.append(f"  {rel}: HEAD 登録 {d['head_n']} → 今 {d['now_n']} ({d['now_n'] - d['head_n']:+d}) "
                             f"/ 書いて足した {len(d['added_written'])} 件 / 合わぬ {len(d['mismatch'])} 件")
            else:
                lines.append(f"  (増分は測れなんだ: {d['why']})")
        for ln in lines:
            print(ln)
        worst = 1 if 1 in (worst, rc) else max(worst, rc)
    print(f"[gate-4 --count] {'★呑まれ在り★' if worst else 'PASS (呑まれ 0)'}")
    return worst


class Tally:
    """★母数を先に出す為の勘定★ (家老 09:54 の命・五号 09:54 の実測より)。

    ★「0 件 該当」より先に「N 件 走査」を出せ★= ★0/0 と 0/6 は別物である★。
    ★読めなんだ冊は【走査した】に数えるが【読めた】には数えぬ★= 不在と無音を分ける。
    """

    def __init__(self) -> None:
        self.scanned = self.readable = self.registered = self.swallowed = 0

    def add(self, scan: dict | None) -> None:
        self.scanned += 1
        if not scan or not scan.get("ok"):
            return
        self.readable += 1
        self.registered += len(scan["registered"])
        self.swallowed += len(scan["swallowed"]) + len(scan["text_only"])

    def render(self, what: str) -> str:
        unread = self.scanned - self.readable
        tail = f" / ★読めなんだ {unread} 冊★" if unread else ""
        return (f"走査 {what} {self.scanned} 冊 (読めた {self.readable} 冊){tail}"
                f" / 登録 {self.registered} 件 / 呑まれ {self.swallowed} 件")


def _emit(worst: int, lines: list, what: str) -> None:
    print(f"[gate-4] ★母数★ {what}")          # ★結果より先に母数を出す★ (0 件は分母と共にのみ意味を持つ)
    if worst == 0:
        print("[gate-4] PASS: 登録されておる (呑まれ 0)")
        for ln in lines:
            print(ln)
        return
    head = "★FAIL — 台帳へ書いたのに登録されておらぬ★" if worst == 1 else "⚠ UNDETERMINED — ★緑ではない★"
    print(f"[gate-4] {head} (cmd_1409)")
    for ln in lines:
        print(ln)
    print("  出所 = 五号 08:15 実測『台帳の末尾へ継ぐと mutations: に入らず別 key の値として黙って呑まれる』")
    print("  手検分: python3 scripts/gate_registry_append.py --count <台帳>")


# ─────────────────────────────────────────────────────────────────────────────
# selftest — ★負の主張を一度 偽にして赤を見る★ / ★正しい時に黙る事も縛る★
# ─────────────────────────────────────────────────────────────────────────────
ENTRY_TXT = """  - id: MUT-9999-{tag}
    origin: cmd_1409
    suspected_by: ashigaru6
    desc: |
      selftest の偽 entry
    paths: [scripts/gate_registry_append.py]
    mutate: |
      true
    test: |
      true
    expect: nonzero
"""

BOOK_TXT = """# 冊の頭
mutations:
""" + ENTRY_TXT.format(tag="BASE") + """
coverage_waivers: []

tree_census_waivers:
  # comment のみ
"""


def selftest() -> int:
    ok = ng = 0

    def check(name: str, cond: bool, evidence: str = "") -> None:
        nonlocal ok, ng
        if cond:
            ok += 1
            print(f"  ok   {name}")
        else:
            ng += 1
            print(f"  NG   {name} {evidence}")

    with tempfile.TemporaryDirectory() as td:
        t = Path(td)

        # T1 ★呑まれ★ = 末尾へ継いだ盤面で、口が現に「呑まれた」と名指すか (五号が踏んだ実物の形)
        swallowed = BOOK_TXT + "\n" + ENTRY_TXT.format(tag="SWALLOW")
        s = scan_book(swallowed, "T1")
        check("T1 末尾へ継ぐと『呑まれ』と名指す",
              s["ok"] and [i for i, _, _ in s["swallowed"]] == ["MUT-9999-SWALLOW"]
              and s["registered"] == ["MUT-9999-BASE"], f"→ {s['swallowed']} / {s['registered']}")
        lines: list[str] = []
        check("T1b rc=2 (既定は commit を止めぬ)", report_scan(s, lines, strict=False) == 2)
        check("T1c STRICT=1 なら rc=1 へ昇格", report_scan(s, [], strict=True) == 1)

        # T2 ★常に鳴る門を作るな★ = 正しく挿した盤面では黙る (負例で縛る)
        correct = BOOK_TXT.replace("coverage_waivers: []", ENTRY_TXT.format(tag="OK") + "\ncoverage_waivers: []")
        s2 = scan_book(correct, "T2")
        check("T2 coverage_waivers の直前へ挿せば鳴らぬ",
              s2["ok"] and not s2["swallowed"] and not s2["text_only"]
              and s2["registered"] == ["MUT-9999-BASE", "MUT-9999-OK"], f"→ {s2}")
        check("T2b rc=0", report_scan(s2, [], strict=False) == 0)
        check("T2c STRICT でも rc=0 (正しい挿入は STRICT でも黙る)", report_scan(s2, [], strict=True) == 0)

        # T3 ★block scalar の中へ落ちた形★ = 層A2 でしか見えぬ呑まれ
        #   ★block scalar の字下げ (6) より深く継げば、YAML から見れば【ただの文字列】である★
        #   = 節点にならぬゆえ層A1 には見えぬ。文字の層 (A2) だけが捕える。
        deep = "".join("    " + ln + "\n" for ln in ENTRY_TXT.format(tag="INSIDE").splitlines())
        inside = BOOK_TXT.replace("      selftest の偽 entry\n", "      selftest の偽 entry\n" + deep)
        s3 = scan_book(inside, "T3")
        check("T3 desc の block scalar へ落ちた entry を層A2 が名指す",
              s3["ok"] and [i for i, _ in s3["text_only"]] == ["MUT-9999-INSIDE"]
              and not s3["swallowed"], f"→ {s3['text_only']} / {s3['swallowed']}")

        # T4 ★測れなんだ★ を 0 件と混ぜぬ (mutations: が無い冊)
        s4 = scan_book("coverage_waivers: []\n", "T4")
        check("T4 mutations: が無い冊は『測れなんだ』", not s4["ok"] and "mutations" in (s4["why"] or ""))
        check("T4b rc=2 (黙って PASS にせぬ)", report_scan(s4, [], strict=False) == 2)
        check("T4c 測れなんだは STRICT でも 2 (赤と名を混ぜぬ)", report_scan(s4, [], strict=True) == 2)

        # T5 parse 不能も黙らぬ
        s5 = scan_book("mutations:\n  - id: [unclosed\n", "T5")
        check("T5 parse 不能は理由つきで『測れなんだ』", not s5["ok"] and "parse" in (s5["why"] or ""))

        # T6 ★層B (増分の一致)★ — 実物の git 盤面で両向きを撃つ
        repo = t / "repo"
        (repo / "config").mkdir(parents=True)
        book = repo / "config" / "mutation_registry.yaml"
        book.write_text(BOOK_TXT, encoding="utf-8")
        for cmd in (["init", "-q"], ["add", "config/mutation_registry.yaml"],
                    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base"]):
            subprocess.run(["git", "-C", str(repo), *cmd], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        d_ok = delta_check(repo, "config/mutation_registry.yaml", correct)
        check("T6 正しく挿せば増分が一致 (書いた 1 件 = 登録 +1)",
              d_ok["ok"] and d_ok["now_n"] - d_ok["head_n"] == 1
              and d_ok["added_written"] == ["MUT-9999-OK"] and not d_ok["mismatch"], f"→ {d_ok}")
        d_ng = delta_check(repo, "config/mutation_registry.yaml", swallowed)
        check("T6b 末尾へ継げば増分が合わぬと名指す (書いた 1 件 = 登録 +0)",
              d_ng["ok"] and d_ng["now_n"] - d_ng["head_n"] == 0
              and d_ng["mismatch"] == ["MUT-9999-SWALLOW"], f"→ {d_ng}")
        check("T6c 増分の不一致は rc=2 (既定)", report_delta(d_ng, "x", [], strict=False) == 2)
        check("T6d 増分が合えば rc=0 (常に鳴る門でない)", report_delta(d_ok, "x", [], strict=False) == 0)

        # T7 ★黙って消えた entry★ も見る (層B の逆向き)
        removed = BOOK_TXT.replace(ENTRY_TXT.format(tag="BASE"), "")
        d_rm = delta_check(repo, "config/mutation_registry.yaml", removed)
        check("T7 登録から消えた entry を名乗る", d_rm["ok"] and d_rm["lost"] == ["MUT-9999-BASE"], f"→ {d_rm}")

        # T8 ★canary★ = 現物の冊を読めておるか (道具が空を撃っておらぬ証)
        real = REPO_ROOT / "config" / "mutation_registry.yaml"
        s8 = scan_book(real.read_text(encoding="utf-8"), "canary") if real.exists() else {"ok": False, "registered": []}
        check("T8 canary: 現物 shogun 台帳を読み 100 件以上を数える",
              s8["ok"] and len(s8["registered"]) >= 100, f"→ {len(s8.get('registered', []))} 件")

    print(f"[gate_registry_append selftest] {'ALL PASS' if ng == 0 else 'FAIL'}: ok={ok} ng={ng}")
    return 0 if ng == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="台帳へ追記した entry が黙って呑まれておらぬかを検める (cmd_1409)")
    ap.add_argument("--all", action="store_true", help="6 冊すべてを層A で検分 (git 不要)")
    ap.add_argument("--registry", action="append", default=[], help="冊を明示 (複数可)")
    ap.add_argument("--count", nargs="*", default=None, help="★挿した直後に撃つ口★ 総数と増分を機械に言わせる")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    strict = os.environ.get("REGISTRY_APPEND_STRICT", "0") == "1"
    if a.selftest:
        return selftest()
    if a.count is not None:
        return mode_count([str(Path(p).resolve()) for p in a.count])
    if a.registry:
        return mode_all(strict, books=[Path(p).resolve() for p in a.registry])
    if a.all:
        return mode_all(strict)
    return mode_staged(strict)


if __name__ == "__main__":
    sys.exit(main())
