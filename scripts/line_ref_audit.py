#!/usr/bin/env python3
"""註に焼かれた行番号を数える走査器 (cmd_1469)。

何を数えるか:
  scripts/ 配下の .py / .sh のコメント・docstring の中に書かれた
  「ファイル名:行番号」の形の指し先を全部 拾い、その行番号が
  現物のどこを指しているかを並べる。当たり外れの判定は人がする。
  ここが出すのは「指し先の現物は何か」までである。

なぜ要るか:
  行番号は、次に誰かがそのファイルを直した瞬間に別の行を指す。
  註だけが古い行を指したまま残り、読む者を誤らせる (CLAUDE.md 条F)。

自分を母数から外している:
  この走査器そのものが例として行番号を書くと、自分の数を自分で動かす
  ことになる (CLAUDE.md 条C)。ゆえに既定でこのファイルを走査から外す。
  外さずに数えたい時は --include-self を付ける。

使い方:
  python3 scripts/line_ref_audit.py                  # 指し先の一覧
  python3 scripts/line_ref_audit.py --only-broken    # 外れている物だけ
  python3 scripts/line_ref_audit.py --counts         # 動く数 (N本/N件) の一覧
  python3 scripts/line_ref_audit.py --canary         # 探し方が生きているかを先に示す
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve()

# 「ファイル名:行番号」または「ファイル名:行番号-行番号」
REF = re.compile(
    r"(?P<path>[A-Za-z0-9_][A-Za-z0-9_./-]*\.(?:py|sh|md|yaml|yml|kt|ts|tsx|js|json|bats|txt))"
    r":(?P<start>\d+)(?:-(?P<end>\d+))?"
)
# 註に焼かれた「動く数」= 「N本」「N件」「N個」「N行」
COUNTS = re.compile(r"(?<![0-9])(?P<n>\d+)\s*(?P<unit>本|件|個|行)(?![0-9])")


def scan_files(include_self: bool) -> list[Path]:
    """走査の母数を返す。scripts/ 配下の .py と .sh。"""
    out = []
    for p in sorted((REPO / "scripts").rglob("*")):
        if not p.is_file() or p.suffix not in (".py", ".sh"):
            continue
        if not include_self and p.resolve() == SELF:
            continue
        out.append(p)
    return out


def comment_lines(path: Path) -> list[tuple[int, str, str]]:
    """(行番号, 種別, 行の中身) を返す。種別 = comment / docstring / code。

    docstring は三重引用符の開閉を数えて判る範囲で拾う。完全な構文解析ではない。
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    out = []
    in_doc = False
    doc_q = ""
    for i, line in enumerate(text.splitlines(), start=1):
        kind = "code"
        if in_doc:
            kind = "docstring"
            if doc_q in line:
                in_doc = False
        else:
            for q in ('"""', "'''"):
                pos = line.find(q)
                if pos >= 0 and line.count(q) % 2 == 1:
                    in_doc = True
                    doc_q = q
                    kind = "docstring"
                    break
            if kind == "code":
                hidx = line.find("#")
                if hidx >= 0:
                    kind = "comment"
        out.append((i, kind, line))
    return out


def resolve(ref: str) -> Path | None:
    """註に書かれた指し先を、現物のファイルへ解く。

    註はファイル名だけを書いていることが多い (例 `gate_nightly.sh:300`)。
    そのまま repo 直下から探すと見つからず、「指し先なし」と誤って出る。
    ゆえに ①そのまま ②scripts/ の下 ③repo 全体で同じ名前を探す、の順に当たる。
    同じ名前が複数 在る時は解けたことにしない (どれを指しているか決まらないため)。
    """
    direct = REPO / ref
    if direct.is_file():
        return direct
    if "/" not in ref:
        cand = REPO / "scripts" / ref
        if cand.is_file():
            return cand
        hits = [
            p
            for p in REPO.rglob(ref)
            if p.is_file() and ".git" not in p.parts
        ]
        if len(hits) == 1:
            return hits[0]
    return None


def line_at(ref: str, n: int) -> str | None:
    """指されたファイルの n 行目を返す。解けない/行が無ければ None。"""
    target = resolve(ref)
    if target is None:
        return None
    try:
        lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    if 1 <= n <= len(lines):
        return lines[n - 1]
    return None


def collect_refs(include_self: bool, include_code: bool = False):
    """註の中の「ファイル名:行番号」を全部 拾う。"""
    found = []
    for src in scan_files(include_self):
        for lineno, kind, line in comment_lines(src):
            if kind == "code" and not include_code:
                continue
            for m in REF.finditer(line):
                # コメント記号より前 (= コードの側) に在る物は註ではない
                if kind == "comment":
                    hidx = line.find("#")
                    if m.start() < hidx:
                        continue
                found.append(
                    {
                        "src": str(src.relative_to(REPO)),
                        "src_line": lineno,
                        "kind": kind,
                        "ref_path": m.group("path"),
                        "start": int(m.group("start")),
                        "end": int(m.group("end")) if m.group("end") else None,
                        "note": line.strip(),
                    }
                )
    return found


def collect_counts(include_self: bool):
    """註に焼かれた「N本」「N件」等の動く数を拾う。"""
    found = []
    for src in scan_files(include_self):
        for lineno, kind, line in comment_lines(src):
            if kind == "code":
                continue
            body = line
            if kind == "comment":
                body = line[line.find("#") :]
            for m in COUNTS.finditer(body):
                found.append(
                    {
                        "src": str(src.relative_to(REPO)),
                        "src_line": lineno,
                        "num": m.group("n"),
                        "unit": m.group("unit"),
                        "note": line.strip(),
                    }
                )
    return found


# cmd_1469 で行番号から綴りへ替えた指し先の一覧。
#   (指された file, 註が書いている綴り) の組。
#   これを機械で撃てる形に残すのは、綴りへ替えた側も動きうるためである。
#   綴りが消えれば、行番号と同じく「別の物を指す註」に戻る。
ANCHORS = [
    ("tests/unit/test_stop_hook.bats", "行途中の否定も set -e 免除"),
    # 行頭で錨を打つ。BROKEN_ID_RE も同じ綴りを内に含むため、行頭を見ないと 2 箇所 出る。
    # 註が読む者へ示している探し方 (`grep -n "^ID_RE"`) と同じ道を通す。
    ("scripts/ledger_id_census.py", "\nID_RE = re.compile"),
    ("scripts/gate_nightly.sh", r"grep -vE '^\s*ok\s'"),
    ("scripts/gate_mutation_replay.py", "verdict:12s"),
    ("scripts/gate_nightly.sh", "waverworks web repo 台帳延長"),
    ("scripts/idle_revive_scan.py", "def report_completion_state"),
    ("scripts/stall_watchdog_scan.py", "def parse_report_latest"),
    ("scripts/slim_yaml.py", "def load_yaml"),
    ("scripts/idle_revive_scan.py", 'inner = doc["report"]'),
    ("first_setup.sh", "STEP 7: 設定ファイル初期化"),
    ("first_setup.sh", 'if [ ! -f "$SCRIPT_DIR/config/settings.yaml" ]'),
    ("scripts/gpu_sidecar_stop.sh", "pkill で迂回するのは"),
    ("instructions/common/task_flow.md", "`queue/ntfy_inbox.yaml`: `pending`, `processed`"),
]

# 陰性対照 = 在りもせぬ綴り。0 で無ければ数え方が壊れている。
ANCHORS_NEGATIVE = [
    ("scripts/idle_revive_scan.py", "def report_completion_state_NOT_REAL"),
    ("scripts/slim_yaml.py", "def load_yaml_NOT_REAL"),
    ("scripts/gate_nightly.sh", "waverworks web repo 台帳延長 NOT_REAL"),
]


def check_anchors() -> int:
    """綴りで指した先が現に在るかを、陽性と陰性の両方で撃つ (CLAUDE.md 条4)。

    陽性 = 註が書いている綴りが、指された file に現に在ること。
    陰性 = 在りもせぬ綴りは現に見つからないこと (探し方が生きている証)。
    """
    rc = 0
    print(f"# 陽性 {len(ANCHORS)} 本 / 陰性 {len(ANCHORS_NEGATIVE)} 本 を撃つ")
    for rel, needle in ANCHORS:
        target = REPO / rel
        if not target.is_file():
            print(f"[NG] file が無い  {rel}")
            rc = 1
            continue
        n = target.read_text(encoding="utf-8", errors="replace").count(needle)
        if n >= 1:
            print(f"[ok] {n} 箇所  {rel}  ← {needle[:56]}")
        else:
            print(f"[NG] 0 箇所  {rel}  ← {needle[:56]}")
            rc = 1
    for rel, needle in ANCHORS_NEGATIVE:
        target = REPO / rel
        n = target.read_text(encoding="utf-8", errors="replace").count(needle) if target.is_file() else 0
        if n == 0:
            print(f"[ok] 陰性 0 箇所  {rel}  ← {needle[:56]}")
        else:
            print(f"[NG] 陰性なのに {n} 箇所 出た  {rel}")
            rc = 1
    if not ANCHORS:
        print("# 母数 0 = 見る物が一つも無い。緑と読むな")
        rc = 2
    return rc


def canary(include_self: bool) -> int:
    """探し方が生きているかを先に示す (CLAUDE.md 条2)。

    陽性 = 在ると分かっている綴りを、同じ道で数えて現に出ること。
    陰性 = 在りもせぬ綴りを同じ道で数えて、現に 0 であること。
    """
    rc = 0
    refs = collect_refs(include_self)
    print(f"[canary] 走査した file = {len(scan_files(include_self))} 本")
    print(f"[canary] 拾った指し先 = {len(refs)} 件")

    # 陽性: 正規表現が現に「名前:数字」を掴むか
    probe = "# 見よ scripts/foo_bar.py:123 のところ"
    hit = REF.search(probe)
    if hit and hit.group("path") == "scripts/foo_bar.py" and hit.group("start") == "123":
        print("[canary] 陽性 OK = 作った1行から指し先を掴んだ")
    else:
        print("[canary] 陽性 NG = 探し方が死んでいる")
        rc = 1

    # 陰性: 行番号の付かない綴りは拾わないこと
    probe2 = "# 見よ scripts/foo_bar.py のところ (行番号なし)"
    if REF.search(probe2) is None:
        print("[canary] 陰性 OK = 行番号の無い綴りは拾わない")
    else:
        print("[canary] 陰性 NG = 拾ってはいけない物を拾った")
        rc = 1

    if len(refs) == 0:
        print("[canary] 母数 0 = 見る物が一つも無い。緑と読むな")
        rc = 2
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only-broken", action="store_true", help="指し先が無い物だけ出す")
    ap.add_argument("--counts", action="store_true", help="註に焼かれた動く数を出す")
    ap.add_argument("--canary", action="store_true", help="探し方が生きているかを先に示す")
    ap.add_argument("--anchors", action="store_true", help="綴りで指した先が現に在るかを撃つ")
    ap.add_argument("--include-self", action="store_true", help="この走査器も母数へ入れる")
    args = ap.parse_args()

    if args.canary:
        return canary(args.include_self)

    if args.anchors:
        return check_anchors()

    if args.counts:
        rows = collect_counts(args.include_self)
        print(f"# 走査 file = {len(scan_files(args.include_self))} 本 / 拾った動く数 = {len(rows)} 件")
        for r in rows:
            print(f"{r['src']}:{r['src_line']}\t{r['num']}{r['unit']}\t{r['note'][:110]}")
        return 0

    rows = collect_refs(args.include_self)
    files = scan_files(args.include_self)
    print(f"# 走査 file = {len(files)} 本 / 註の中の指し先 = {len(rows)} 件")
    if not rows:
        print("# 母数 0。見る物が一つも無い側かを先に疑え")
        return 2
    unresolved = 0
    for r in rows:
        target = resolve(r["ref_path"])
        body = line_at(r["ref_path"], r["start"])
        if target is None:
            state = "★指し先のファイルが解けぬ (在らぬか、同じ名が複数)★"
            unresolved += 1
        elif body is None:
            state = f"★その行が無い (現物は {len(target.read_text(errors='replace').splitlines())} 行)★"
        else:
            state = "現物: " + body.strip()[:90]
        if args.only_broken and body is not None:
            continue
        span = f"{r['start']}" + (f"-{r['end']}" if r["end"] else "")
        print(f"\n{r['src']}:{r['src_line']} [{r['kind']}]")
        print(f"  指し   {r['ref_path']}:{span}"
              + (f"  → {target.relative_to(REPO)}" if target else ""))
        print(f"  註     {r['note'][:120]}")
        print(f"  {state}")
    if unresolved:
        print(f"\n# 解けなかった指し先 = {unresolved} 件 (数え落としではない。人が当たれ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
