#!/usr/bin/env python3
"""★牙の【域】を数える口★ — 「覆いの上限」の分母を、機械が毎回 数え直す (cmd_1394・足軽三号)

■ ★何故 此の口が要るか★
  2026-07-27 未明、殿の問い (項14 = 「守りの何割に牙が在るか」) へ答えようとして、
  ★数え手が三度 誤った★:
    ・三号 = web を「牙 0」と数えた   ⇒ ★己が据えた牙 (ref:MUT-1358-001) を己で数え落とした★
    ・三号 = engine を「一意 27」と数えた ⇒ ★重複 6 を見ておらなんだ (真は 21)★
    ・三号 = 各冊の分母を「台帳が名指す標的の検」に限りながら、★其の外に在る検を数えなんだ★
  ⇒ ★数を報告に焼いたゆえ腐った★。★ゆえに数でなく【数え直す口】を残す★ (本夜の規律)。

■ ★★本口が答える問いは二つ。混ぜてはならぬ★★
    (A) ★域内★ = ★台帳が名指す標的の中に在る検★  … 「覆いの上限」の分母
    (B) ★域外★ = ★同じ木に在るが、台帳が 1 本も名指しておらぬ検★ … ★覆い 0 が確定しておる域★
  ★(B) を名乗らねば覆い率は実際より良く見える★ =
  ★分母を小さく取るほど率は上がるゆえ、率を出す者は必ず【分母の外】を併記せよ★。

■ ★「一意」の定義 (家老 03:19 の求め)★
    ★一意 = 牙が名指す先 (red_needle の綴り) の【異なり数】★。
    ・★牙の数と一致せぬ★= 複数の牙が同じ札を名指せば、其の分だけ少なくなる。
    ・★重複は咎ではない★ (同じ検を別の角度から縛るのは正しい形も在る) =
      ★然れど「覆いの上限」を牙の数で読めば、重複の分だけ甘くなる★ゆえ上限は一意で数える。
    ・★★一意 needle ≠ 一意の検★★ (射程を先に名乗る) =
      red_needle は ★赤い出力に現れる綴り★であって検の識別子ではない。
      ・engine の如く「NG C1」等の短い符牒を使う冊では、★別の検が同じ札を出しうる★
      ・逆に 1 本の検が複数の札を出す形も在る
      ⇒ ★一意 needle は【上限の上限】である★。★之を「検の数」と読むな★。

■ ★検の数え方 = 規則を宣言し、当たらぬ物は 0 でなく【数えられぬ】と出す★
  ★冊ごとに試験の形が違う★ (pytest / bats / PHPUnit / gate 内蔵 selftest) ゆえ、
  ★一つの規則で全部を数えると、当たらぬ形が黙って 0 になる★ = ★之が偽陰性の作り方である★。
  ⇒ 本口は ★規則が当たった file のみ数え、当たらぬ file は名指して別勘定★ とする。

■ ★台帳へは 1 byte も書かぬ (読むのみ)★。★数を本 file へ焼かぬ★。

使い方:
    python3 scripts/fang_domain_census.py            # 点呼
    python3 scripts/fang_domain_census.py --selftest # ★負の主張を一度 偽にして赤を見る★
"""
from __future__ import annotations

import argparse
import collections
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GATE_NIGHTLY = REPO_ROOT / "scripts" / "gate_nightly.sh"

# 掃く時に入らぬ場所 (★third-party と生成物★)。★除いた物は出力で名乗る★。
SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", ".mypy_cache",
    ".pytest_cache", "dist", "build", ".next", "vendor", "site-packages",
    "test_helper",           # bats-assert / bats-support = 借り物
    ".dvc", "wandb",
}

# ★検の数え方の規則★ = (種, 当たり判定, 数える綴り)。★宣言してあるゆえ後から検められる★。
KIND_PYTEST = "pytest"
KIND_BATS = "bats"
KIND_PHPUNIT = "phpunit"
UNCOUNTABLE = "★数えられぬ★"

KIND_CHECK = "selftest(check)"
KIND_VITEST = "vitest"

RE_PYTEST_DEF = re.compile(r"^\s*(?:async\s+)?def\s+test_\w*\s*\(", re.M)
RE_BATS_TEST = re.compile(r"^\s*@test\b", re.M)
RE_PHP_TEST = re.compile(r"^\s*(?:public\s+)?function\s+test\w*\s*\(", re.M)
# ★gate 内蔵の selftest★ = 1 行 1 検の呼出 (engine の .sh / shogun の一部 .py が此の形)。
RE_CHECK_CALL = re.compile(r"^\s*check\(", re.M)
RE_CHECK_LABEL = re.compile(r"^\s*check\(\s*[\"']([^\"']+)[\"']", re.M)
RE_NOTES_APPEND = re.compile(r"^\s*notes\.append\(", re.M)
# ★vitest / jest★ = TS/JS の木の検。★之を持たぬ初版は engine の域外を 0 と出した★
#   (実測 03:32 = engine の .ts 試験 116 file が掃きから丸ごと落ちておった) =
#   ★0 を疑うて canary を撃たねば、偽の 0 が「域外に検が無い」の顔で通っておった★。
RE_VITEST = re.compile(r"^\s*(?:it|test)(?:\.\w+)?\s*\(", re.M)


def count_checks(path: Path) -> tuple[str, int | None]:
    """(種, 検の数) を返す。★規則が当たらねば (UNCOUNTABLE, None)★ = ★0 を返さぬ★。

    ★0 と『数えられぬ』を同じ数で返すのが、本夜 三度 我らを誤らせた形ゆえ、型で分ける★。
    ★check 形の数は【下限】である★= 自称の数が之を上回る gate が現に在る
    (実測 = shogun の gate_ntfy_alive は 機械 20 / 自称 26)。★上限として読むな★。
    """
    try:
        txt = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return UNCOUNTABLE, None
    suf = path.suffix
    if suf == ".bats":
        return KIND_BATS, len(RE_BATS_TEST.findall(txt))
    if suf == ".php":
        n = len(RE_PHP_TEST.findall(txt))
        return (KIND_PHPUNIT, n) if n else (UNCOUNTABLE, None)
    if suf in (".py", ".sh", ".bash", ".ts", ".tsx", ".js", ".mjs"):
        n = len(RE_PYTEST_DEF.findall(txt)) if suf == ".py" else 0
        if n:
            return KIND_PYTEST, n
        if suf in (".ts", ".tsx", ".js", ".mjs"):
            n = len(RE_VITEST.findall(txt))
            if n:
                return KIND_VITEST, n
        n = len(RE_CHECK_CALL.findall(txt))
        if n:
            return KIND_CHECK, n
        n = len(RE_NOTES_APPEND.findall(txt))
        if n:
            return KIND_CHECK, n
        # ★形は selftest と名乗るが数える綴りが見つからぬ★= ★0 と言わず名指す★
        return UNCOUNTABLE, None
    return UNCOUNTABLE, None


def unique_check_labels(path: Path) -> int | None:
    """check("札", …) 形の★札の異なり数★。★総数と食い違えば其れ自体が徴である★
    (engine 実測 = 総 77 / 一意 73 ⇒ ★4 本は同じ札を二度 使うておる★)。"""
    try:
        txt = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    labs = RE_CHECK_LABEL.findall(txt)
    return len(set(labs)) if labs else None


def is_test_bearing(path: Path) -> bool:
    """★掃く対象の綴り★ (中身でなく名で決める = 掃く前に決まるゆえ再現できる)。"""
    n = path.name
    if path.suffix == ".bats":
        return True
    if path.suffix == ".py":
        return n.startswith("test_") or n.endswith("_test.py") or "/tests/" in str(path)
    if path.suffix == ".php":
        return n.endswith("Test.php") or n.startswith("test") or "/tests/" in str(path)
    if path.suffix in (".ts", ".tsx", ".js", ".mjs"):
        return (".test." in n or ".spec." in n
                or "__tests__" in str(path) or "/tests/" in str(path))
    return False


# ★木ごとに除く場所 (相対 path で名指す)★ = ★借り物の置き場★。
#   ★名で一律に除くと、他の木の同名の現役 dir まで消える★ゆえ相対 path で名指す。
SKIP_REL = {
    "public/library",   # web = bootstrap 等の借り物 JS (★実測 715 検・我らの持ち物でない★)
}


def walk_tests(root: Path) -> tuple[list[Path], list[str]]:
    """★find 相当を自前で歩く★ = ★再帰 grep も git ls-files も使わぬ★
    (どちらも【追跡下のみ】を見るゆえ、白名簿 repo で現役の file を黙って落とす — 家老 01:37)。

    返り値の第二は ★除いた場所★ = ★除いた事を黙って済ませぬ (分母を小さくする操作ゆえ)★。
    """
    out: list[Path] = []
    excluded: list[str] = []
    root = Path(root)
    for dirpath, dirnames, filenames in os.walk(root):
        keep = []
        for d in dirnames:
            rel = str((Path(dirpath) / d).relative_to(root))
            # ★木が己と同じ名の dir を内に抱えておる形 = 配布用の写し★
            #   (web の theme が現に己の写しを内に持ち、★同じ検を二度 数えた (03:33 実測)★)
            if d in SKIP_DIRS or rel in SKIP_REL or d == root.name:
                excluded.append(rel)
                continue
            keep.append(d)
        dirnames[:] = keep
        for f in filenames:
            p = Path(dirpath) / f
            if is_test_bearing(p):
                out.append(p)
    return sorted(out), sorted(set(excluded))


# ---------------------------------------------------------------------------
# 冊の見つけ方 — ★正本 (gate_nightly.sh) を己の目で解く★
#   ★六号の口 (registry_census.py) とは別実装である★ =
#   ★同じ道具を二人が持てば、独立に見えて独立でない★ (家老 03:19 の下命)。
# ---------------------------------------------------------------------------
def discover_books(gate_sh: Path) -> tuple[list[tuple[str, str, str]], str | None]:
    if not gate_sh.is_file():
        return [], f"正本が見えぬ ({gate_sh})"
    txt = gate_sh.read_text(encoding="utf-8", errors="replace")
    env = {"SCRIPT_DIR": str(REPO_ROOT), "HOME": os.environ.get("HOME", "")}
    for name, val in re.findall(r'^\s*([A-Z_][A-Z0-9_]*)="([^"]*)"', txt, re.M):
        if "$(" in val:
            continue
        v = re.sub(r"\$\{[A-Z_][A-Z0-9_]*:-([^}]*)\}", r"\1", val)
        v = re.sub(r"\$\{?([A-Z_][A-Z0-9_]*)\}?", lambda m: env.get(m.group(1), m.group(0)), v)
        if "$" in v:
            continue
        env[name] = v
    books: list[tuple[str, str, str]] = []
    # 自 repo (素の呼び出し = --registry を持たぬ形)
    if re.search(r"gate_mutation_replay\.py\"?\s+2>&1", txt):
        books.append(("shogun", str(REPO_ROOT / "config" / "mutation_registry.yaml"), str(REPO_ROOT)))
    for line in txt.splitlines():
        if "gate_mutation_replay.py" not in line or "--registry" not in line:
            continue
        m1 = re.search(r'--registry\s+"?\$?\{?([A-Za-z0-9_./-]+)\}?"?', line)
        m2 = re.search(r'--repo-root\s+"?\$?\{?([A-Za-z0-9_./-]+)\}?"?', line)
        if not m1 or not m2:
            continue
        reg, root = env.get(m1.group(1), m1.group(1)), env.get(m2.group(1), m2.group(1))
        if "$" in reg or "$" in root:
            continue
        name = re.sub(r"_(REG|ROOT)$", "", m1.group(1)).lower()
        if (name, reg, root) not in books:
            books.append((name, reg, root))
    if len(books) < 2:
        return books, (f"正本から読めた冊が {len(books)} 冊しかない = 綴りが変わって解読が外れた疑い。"
                       "★0 冊を『冊が無い』と読ませぬ★")
    return books, None


# ---------------------------------------------------------------------------
# 台帳を読む — ★牙 / 一意 / 標的★
# ---------------------------------------------------------------------------
RE_TEST_FILE = re.compile(r"[\w./-]+\.(?:bats|py|sh|php|ts|js)")


def read_book(reg: str, root: str) -> dict:
    import yaml
    p = Path(reg)
    if not p.is_file():
        return {"readable": False, "why": f"冊が見えぬ ({reg})"}
    try:
        doc = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except Exception as e:  # noqa: BLE001
        return {"readable": False, "why": f"{type(e).__name__}: {e}"}
    ents = [e for e in (doc.get("mutations") or []) if isinstance(e, dict)]
    needles = [str(e["red_needle"]) for e in ents if e.get("red_needle")]
    c = collections.Counter(needles)
    targets: set[str] = set()
    for e in ents:
        # ★標的は test: の綴り (現に走らせる物) から採る★=
        #   paths: は「変異を当てる先」ゆえ ★試験でない file も混じる★ (script 本体等)。
        # ★★ここで is_test_bearing で漉すな★★ =
        #   ★初版は漉しておった★ ⇒ engine の .sh gate と web の scripts/*.py が
        #   ★標的の集合から黙って消え、域内の検が 0 と出た★ (03:29 実測・己の計器の穴)。
        #   ⇒ ★現に走らせる物は、綴りの形に依らず標的である★。
        for m in RE_TEST_FILE.findall(str(e.get("test") or "")):
            cand = (Path(root) / m).resolve()
            if cand.is_file():
                targets.add(str(cand))
    return {
        "readable": True,
        "fangs": len(ents),
        "needles": len(needles),
        "unique": len(c),
        "dups": {k: v for k, v in c.items() if v > 1},
        "missing_needle": [e.get("id") for e in ents if not e.get("red_needle")],
        "targets": targets,
    }


def census(books: list[tuple[str, str, str]]) -> list[dict]:
    rows = []
    all_roots = [str(Path(r).resolve()) for _n, _g, r in books]
    for name, reg, root in books:
        b = read_book(reg, root)
        row = {"name": name, "reg": reg, "root": root, **b}
        if not b.get("readable") or not Path(root).is_dir():
            row["tree_ok"] = Path(root).is_dir()
            rows.append(row)
            continue
        row["tree_ok"] = True
        # ★★己の木の【中】に別の冊の木が入れ子で在れば、其れを己の域外へ数えるな★★ =
        #   app (~/aituber-project) は backend を内に抱えておる ⇒
        #   ★初版は backend の検を app の域外にも数え、二重に積んだ (03:29 実測)★。
        me = str(Path(root).resolve())
        nested = [r for r in all_roots if r != me and r.startswith(me.rstrip("/") + "/")]
        row["nested_excluded"] = nested
        inside_n = outside_n = 0
        inside_f: list[str] = []
        outside_f: list[str] = []
        unc_in: list[str] = []
        unc_out: list[str] = []
        swept_all, excluded_dirs = walk_tests(Path(root))
        row["excluded_dirs"] = excluded_dirs
        swept_paths = [f for f in swept_all
                       if not any(str(f.resolve()).startswith(x.rstrip("/") + "/") for x in nested)]
        # ★台帳が名指した標的で掃きの網に載らなんだ物も、必ず数の土俵へ載せる★
        for t in sorted(b["targets"]):
            tp = Path(t)
            if tp not in swept_paths and tp.is_file():
                swept_paths.append(tp)
        for f in swept_paths:
            kind, n = count_checks(f)
            named = str(f.resolve()) in b["targets"]
            if n is None:
                (unc_in if named else unc_out).append(str(f))
                continue
            if named:
                inside_n += n
                extra = ""
                if kind == KIND_CHECK:
                    u = unique_check_labels(f)
                    if u is not None and u != n:
                        extra = f" ★札の異なり {u} = 総数と食い違う (同じ札を二度)★"
                inside_f.append(f"{f} [{kind} {n}]{extra}")
            else:
                outside_n += n
                outside_f.append(f"{f} [{kind} {n}]")
        # ★台帳が名指した標的のうち【木の外】に在る物★= ★数えはする・然れど必ず名乗る★
        #   (web の冊が現に此の形 = ★冊と木が別の場所に在る唯一の冊★)。
        row.update({
            "inside_checks": inside_n, "inside_files": inside_f,
            "outside_checks": outside_n, "outside_files": outside_f,
            "uncountable_inside": unc_in, "uncountable_outside": unc_out,
            "targets_outside_tree": sorted(
                t for t in b["targets"] if not t.startswith(me.rstrip("/") + "/")),
        })
        rows.append(row)
    return rows


def render(rows: list[dict], err: str | None, cmd: str) -> int:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    rc = 0
    print(f"[牙の域の点呼] 採取時刻 = ★{now}★ / 撃った command = `{cmd}`")
    print("[牙の域の点呼] ★一意 = 牙が名指す先 (red_needle の綴り) の異なり数★ / "
          "★一意 needle は【上限の上限】= 検の数ではない★")
    if err:
        print(f"  ★UNDETERMINED★ {err}")
        rc = 2
    t_f = t_u = t_in = t_out = 0
    print(f"\n{'冊':<10} {'牙':>5} {'一意':>5} {'域内の検':>9} {'上限':>7} {'★域外の検★':>11}")
    print("-" * 60)
    detail = []
    for r in rows:
        if not r.get("readable"):
            print(f"{r['name']:<10} ★読めぬ★ {r.get('why','')}")
            rc = max(rc, 2)
            continue
        if not r.get("tree_ok"):
            print(f"{r['name']:<10} ★木が見えぬ★ ({r['root']})")
            rc = max(rc, 2)
            continue
        cap = (f"{r['unique'] / r['inside_checks'] * 100:.1f}%"
               if r["inside_checks"] else "★分母0★")
        print(f"{r['name']:<10} {r['fangs']:>5} {r['unique']:>5} {r['inside_checks']:>9}"
              f" {cap:>7} {r['outside_checks']:>11}")
        t_f += r["fangs"]; t_u += r["unique"]
        t_in += r["inside_checks"]; t_out += r["outside_checks"]
        detail.append(r)
    tot_cap = f"{t_u / t_in * 100:.1f}%" if t_in else "★分母0★"
    print("-" * 60)
    print(f"{'★合計★':<10} {t_f:>5} {t_u:>5} {t_in:>9} {tot_cap:>7} {t_out:>11}")
    print(f"\n★上限 = 一意 ÷ 域内の検★ = ★【牙の届く範囲の中での】覆いの天井★ = "
          "★実測の覆いではない (走らせるまで判らぬ)★")
    print(f"★域外の検 ★{t_out}★ = 台帳が 1 本も名指しておらぬ検 = ★覆い 0 が確定しておる域★★")

    for r in detail:
        print(f"\n■ 冊 = {r['name']}  ({r['reg']})")
        print(f"    木 = {r['root']}")
        if r["dups"]:
            print(f"    ★重複 needle★ = {sum(v - 1 for v in r['dups'].values())} 本 "
                  "(★咎ではない・然れど上限は其の分 甘くなるゆえ一意で数える★)")
            for k, v in sorted(r["dups"].items(), key=lambda x: -x[1]):
                print(f"      ・{k!r} x{v}")
        if r["missing_needle"]:
            print(f"    ★needle 欠★ = {r['missing_needle']} = ★赤の出所を名指せぬ牙★")
        print(f"    域内の標的 file = {len(r['inside_files'])} 本 / 検 {r['inside_checks']}")
        for f in r["inside_files"]:
            print(f"      ・{f}")
        if r["uncountable_inside"]:
            print(f"    ★域内だが数えられぬ★ = {len(r['uncountable_inside'])} 本 "
                  "(★0 ではない = 規則が当たらぬゆえ数を名乗らぬ★)")
            for f in r["uncountable_inside"]:
                print(f"      ・{f}")
            rc = max(rc, 1)
        if r["targets_outside_tree"]:
            print(f"    ★台帳が名指す標的のうち【木の外】に在る物★ = {r['targets_outside_tree']}"
                  " (★数えてはおる・然れど木を掃くだけの計器では原理的に見えぬ形★)")
        if r.get("nested_excluded"):
            print(f"    ★己の木の中に在る別の冊の木は域外から除いた★ = {r['nested_excluded']}"
                  " (★除かねば二重に積む★)")
        if r.get("excluded_dirs"):
            print(f"    ★掃きから除いた場所★ = {r['excluded_dirs'][:6]}"
                  f"{' …計 ' + str(len(r['excluded_dirs'])) + ' 箇所' if len(r['excluded_dirs']) > 6 else ''}"
                  " (★借り物・生成物・己の写し = 分母を小さくする操作ゆえ名乗る★)")
        print(f"    ★域外の検★ = {r['outside_checks']} (file {len(r['outside_files'])} 本)")
        if r["uncountable_outside"]:
            print(f"    ★域外だが数えられぬ★ = {len(r['uncountable_outside'])} 本 "
                  "= ★此の数は上の『域外の検』に入っておらぬ★")
    print("\n[牙の域の点呼] ★此の数を写して持ち歩くな★ = ★数え直すには上の command を撃て★")
    return rc


# ---------------------------------------------------------------------------
# ★selftest — 負の主張を一度 偽にして赤を見る★ (家老 02:12 の全軍規律)
# ---------------------------------------------------------------------------
def selftest() -> int:
    import tempfile
    ok = ng = 0

    def check(name: str, cond: bool) -> None:
        nonlocal ok, ng
        if cond:
            ok += 1
        else:
            ng += 1
            print(f"  ★NG★ {name}")

    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "tree"
        (root / "tests").mkdir(parents=True)
        (root / "config").mkdir()
        named = root / "tests" / "test_named.py"
        named.write_text("def test_a():\n    pass\ndef test_b():\n    pass\n", encoding="utf-8")
        far = root / "tests" / "test_far.py"
        far.write_text("def test_c():\n    pass\n", encoding="utf-8")
        bats = root / "tests" / "t.bats"
        bats.write_text("@test \"x\" {\n  true\n}\n@test \"y\" {\n  true\n}\n", encoding="utf-8")
        gate = root / "tests" / "test_gate.py"   # ★selftest 形 = 数えられぬ★
        gate.write_text("import sys\nif '--selftest' in sys.argv:\n    pass\n", encoding="utf-8")
        reg = root / "config" / "mutation_registry.yaml"
        reg.write_text(
            "mutations:\n"
            "  - {id: A, red_needle: n1, test: 'pytest tests/test_named.py'}\n"
            "  - {id: B, red_needle: n1, test: 'pytest tests/test_named.py'}\n"
            "  - {id: C, test: 'bats tests/t.bats'}\n",
            encoding="utf-8")
        rows = census([("t", str(reg), str(root))])
        r = rows[0]

        # T1 ★牙と一意は別の数★ (重複が在る冊では一致せぬ)
        check("T1 牙 3 / 一意 1 (重複 1・needle 欠 1)",
              r["fangs"] == 3 and r["unique"] == 1 and len(r["missing_needle"]) == 1)
        # T1b ★偽にして赤★= 重複を解けば一意が増える筈
        reg.write_text(
            "mutations:\n"
            "  - {id: A, red_needle: n1, test: 'pytest tests/test_named.py'}\n"
            "  - {id: B, red_needle: n2, test: 'pytest tests/test_named.py'}\n"
            "  - {id: C, test: 'bats tests/t.bats'}\n", encoding="utf-8")
        r2 = census([("t", str(reg), str(root))])[0]
        check("T1b ★偽にして赤★ 重複を解くと一意が 1→2 へ増える", r2["unique"] == 2)

        # T2 ★域内と域外を取り違えぬ★
        check("T2 域内 = 名指された 2 本 (test_named 2 + t.bats 2)", r2["inside_checks"] == 4)
        check("T2b ★域外★ = 名指されておらぬ test_far の 1 本", r2["outside_checks"] == 1)
        # T2c ★偽にして赤★= 台帳から標的を外せば、其の検は域外へ移る筈
        reg.write_text("mutations:\n  - {id: A, red_needle: n1, test: 'bats tests/t.bats'}\n",
                       encoding="utf-8")
        r3 = census([("t", str(reg), str(root))])[0]
        check("T2c ★偽にして赤★ 標的を外すと域内 4→2・域外 1→3 へ移る",
              r3["inside_checks"] == 2 and r3["outside_checks"] == 3)

        # T3 ★★0 と『数えられぬ』を分ける★★ (本口の芯)
        check("T3 selftest 形の py は域外の検に数えず、別勘定へ落ちる",
              str(gate) in r3["uncountable_outside"])
        check("T3b ★数えられぬ物を 0 として合算しておらぬ★",
              r3["outside_checks"] == 3)  # gate の 0 が混ざれば此処は 3 のまま = 混入は下で見る
        # T3c ★偽にして赤★= 数えられる形 (def test_) にすれば域外の数が増える筈
        gate.write_text("def test_z():\n    pass\n", encoding="utf-8")
        r4 = census([("t", str(reg), str(root))])[0]
        check("T3c ★偽にして赤★ 数えられる形にすると域外が 3→4 へ増える",
              r4["outside_checks"] == 4 and str(gate) not in r4["uncountable_outside"])
        gate.write_text("import sys\nif '--selftest' in sys.argv:\n    pass\n", encoding="utf-8")

        # T4 ★台帳が名指した標的が掃きの網から落ちたら名指す★
        outside_tree = Path(td) / "outside.bats"
        outside_tree.write_text("@test \"q\" {\n  true\n}\n", encoding="utf-8")
        reg.write_text("mutations:\n  - {id: A, red_needle: n, test: 'bats ../outside.bats'}\n",
                       encoding="utf-8")
        r5 = census([("t", str(reg), str(root))])[0]
        check("T4 木の外の標的も【数えた上で】名指される (web が現に此の形)",
              len(r5["targets_outside_tree"]) == 1 and r5["inside_checks"] == 1)
        # T4b ★偽にして赤★= 木の中へ移せば「木の外」の名指しは消える筈
        moved = root / "moved.bats"
        moved.write_text("@test \"q\" {\n  true\n}\n", encoding="utf-8")
        reg.write_text("mutations:\n  - {id: A, red_needle: n, test: 'bats moved.bats'}\n",
                       encoding="utf-8")
        r5b = census([("t", str(reg), str(root))])[0]
        check("T4b ★偽にして赤★ 木の中へ移すと『木の外』の名指しが消える",
              r5b["targets_outside_tree"] == [] and r5b["inside_checks"] == 1)

        # T5 ★borrowed の木 (test_helper) を掃かぬ★
        (root / "tests" / "test_helper").mkdir()
        (root / "tests" / "test_helper" / "borrowed.bats").write_text(
            "@test \"b\" {\n  true\n}\n", encoding="utf-8")
        r6 = census([("t", str(reg), str(root))])[0]
        check("T5 借り物 (test_helper) は分母へ入らぬ",
              not any("test_helper" in f for f in r6["outside_files"]))

        # T5b ★★木が己と同じ名の dir を内に抱える形 (配布用の写し) を二度 数えぬ★★
        #     ★web の theme が現に此の形であった (03:33 実測 = 域外が二重に膨れた)★
        selfcopy = root / root.name / "tests"
        selfcopy.mkdir(parents=True)
        (selfcopy / "test_copy.py").write_text("def test_dup():\n    pass\n", encoding="utf-8")
        r6b = census([("t", str(reg), str(root))])[0]
        check("T5b 己と同じ名の入れ子 dir は掃かぬ",
              not any(f"/{root.name}/{root.name}/" in f for f in r6b["outside_files"]))
        check("T5c ★除いた事を黙らぬ★ = 除いた場所を名乗る",
              any(x == root.name for x in r6b["excluded_dirs"]))

    # T7 ★★試験の綴りをしておらぬ標的を、標的の集合から落とさぬ★★
    #    ★初版は落としており、engine (.sh gate) と web (scripts/*.py) が域内 0 と出た★
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "t"
        (root / "scripts").mkdir(parents=True)
        (root / "config").mkdir()
        gate = root / "scripts" / "mutation_gate_x.sh"
        gate.write_text('check("A", 1)\ncheck("B", 1)\ncheck("A", 1)\n', encoding="utf-8")
        reg = root / "config" / "r.yaml"
        reg.write_text("mutations:\n  - {id: A, red_needle: n, "
                       "test: 'bash scripts/mutation_gate_x.sh'}\n", encoding="utf-8")
        r7 = census([("t", str(reg), str(root))])[0]
        check("T7 試験の綴りでない標的 (.sh gate) も域内の検として数える",
              r7["inside_checks"] == 3)
        check("T7b 札の異なり (2) が総数 (3) と食い違う旨を名指す",
              any("札の異なり 2" in f for f in r7["inside_files"]))
        # T7c ★偽にして赤★= 台帳から外せば域内 3→0 かつ域外にも現れぬ (掃きの網の外ゆえ)
        reg.write_text("mutations: []\n", encoding="utf-8")
        r7c = census([("t", str(reg), str(root))])[0]
        check("T7c ★偽にして赤★ 台帳から外すと域内が 3→0 へ落ちる", r7c["inside_checks"] == 0)

    # T8 ★★入れ子の木を域外へ二重に数えぬ★★
    with tempfile.TemporaryDirectory() as td:
        outer = Path(td) / "outer"
        inner = outer / "inner"
        for d in (outer / "tests", inner / "tests", outer / "config", inner / "config"):
            d.mkdir(parents=True)
        (outer / "tests" / "test_o.py").write_text("def test_o():\n    pass\n", encoding="utf-8")
        (inner / "tests" / "test_i.py").write_text("def test_i():\n    pass\n", encoding="utf-8")
        ro = outer / "config" / "r.yaml"; ro.write_text("mutations: []\n", encoding="utf-8")
        ri = inner / "config" / "r.yaml"; ri.write_text("mutations: []\n", encoding="utf-8")
        both = census([("outer", str(ro), str(outer)), ("inner", str(ri), str(inner))])
        o, i = both[0], both[1]
        check("T8 入れ子の木の検を外側の域外に数えぬ (outer=1 / inner=1)",
              o["outside_checks"] == 1 and i["outside_checks"] == 1)
        # T8b ★偽にして赤★= 入れ子を知らせねば outer が 2 を数える筈
        alone = census([("outer", str(ro), str(outer))])[0]
        check("T8b ★偽にして赤★ 入れ子を除かねば outer は 2 を数える",
              alone["outside_checks"] == 2)

    # T9 ★★TS/JS の木 (vitest) を掃きから落とさぬ★★
    #    ★初版は落としており engine の域外が 0 と出た = ★偽の 0★ (03:32 実測)★
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "t"
        (root / "src" / "__tests__").mkdir(parents=True)
        (root / "config").mkdir()
        (root / "src" / "__tests__" / "a.test.ts").write_text(
            'it("x", () => {})\ntest("y", () => {})\nit.each([1])("z", () => {})\n',
            encoding="utf-8")
        reg = root / "config" / "r.yaml"
        reg.write_text("mutations: []\n", encoding="utf-8")
        r9 = census([("t", str(reg), str(root))])[0]
        check("T9 vitest の it/test を域外の検として数える", r9["outside_checks"] == 3)
        # T9b ★偽にして赤★= 綴りを .test.ts から外せば掃きに載らず 0 になる筈
        (root / "src" / "__tests__" / "a.test.ts").rename(root / "src" / "plain.ts")
        r9b = census([("t", str(reg), str(root))])[0]
        check("T9b ★偽にして赤★ 試験の綴りを外すと 3→0 へ落ちる",
              r9b["outside_checks"] == 0)

    # T6 ★正本の解読が壊れた時、0 冊を『冊が無い』と読ませぬ★
    with tempfile.TemporaryDirectory() as td:
        fake = Path(td) / "g.sh"
        fake.write_text("echo hi\n", encoding="utf-8")
        bs, e = discover_books(fake)
        check("T6 解読 0 冊なら理由つきで UNDETERMINED", bs == [] and e is not None)
    # T6b ★canary★= 現物の正本からは冊が読める (★道具の生存を先に見てから 0 を報ずる★)
    bs, e = discover_books(GATE_NIGHTLY)
    check("T6b ★canary★ 現物の gate_nightly.sh からは冊が 5 つ読める",
          e is None and len(bs) >= 5)

    if ng == 0:
        print(f"[fang_domain_census selftest] {ok}/{ok} ALL PASS")
        return 0
    print(f"[fang_domain_census selftest] FAIL: ok={ok} ng={ng}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--gate-nightly", type=Path, default=GATE_NIGHTLY)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    books, err = discover_books(a.gate_nightly)
    return render(census(books), err, "python3 scripts/fang_domain_census.py")


if __name__ == "__main__":
    sys.exit(main())
