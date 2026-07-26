#!/usr/bin/env python3
"""★牙台帳の冊を【人の記憶でなく機械】で数え直す口★ (cmd_1396 系・2026-07-27 六号)

■ ★何故 此の口が要るか (起こりの実話)★
  2026-07-27 の夜、★三者 (足軽六号・軍師二号・家老) が別々に台帳の冊数を数え、三者とも誤った★:
    ・六号 = 「4 冊 177 件」と数えた   ⇒ web を落としておった
    ・六号 = 「5 冊 178 件」へ正した   ⇒ 正しかった
    ・軍師二号 = 「実在は 4 冊」と申した ⇒ ★web を落とした★ (木の中を探したゆえ)
    ・家老 = 軍師の数を継いだ          ⇒ ★同じ穴★
    ・足軽三号 = census で「web 牙 0」  ⇒ ★己が据えた牙 (MUT-1358-001) を己で数え落とした★
  ★誰も怠けておらぬ★。★皆が【木の中を探す】という同じ形の計器を使うたゆえ、同じ物が同じく見えなんだ★。

■ ★★本件の芯 = 冊 (台帳 file) と 木 (repo-root) は 1 対 1 だが【同じ場所に在るとは限らぬ】★★
  web の冊は ★shogun 側★ (config/mutation_registry.web.yaml) に在り、木は /mnt/c/Users 配下に在る。
  理由は設計に書いてある (scripts/gate_nightly.sh:107-115) =
    ★web repo は殿の変更禁止領域ゆえ、そこへ機構を置かず runner を --repo-root で跨がせる★。
  ⇒ ★木の中を `git ls-files | grep mutation` で探す計器は、此の冊を【原理的に】見つけられぬ★。
  ⇒ ★「探して出なんだ」は「無い」ではない★= ★探した場所の外は、探した者の射程の外である★。

■ ★本口が守る三つの区別 (之を混ぜると上の事故が再演する)★
    (1) ★冊が無い★          … 其の木に牙の仕組みが一つも無い
    (2) ★木の中に無い★      … 冊は在るが木の外に置かれておる (web 型)
    (3) ★木が見えぬ★        … repo-root の実体が無い (path 違い / disk 喪失)
  ★(1) と (2) を同じ「0」で報ずるのが、本夜 三者を誤らせた当の形にござる★。

■ ★数え方は二段 (どちらか片方では落ちる)★
    段A ★glob★  = 各木の config/mutation_registry*.yaml を名で拾う (★名の変わり .web.yaml を含める★)
    段B ★正本★  = scripts/gate_nightly.sh が現に撃っておる (冊, 木) の対を読む
  ⇒ ★段A だけでは web が落ちる (木の外ゆえ)★ / ★段B だけでは gate へ未配線の冊が落ちる★
  ⇒ ★両方を突き合わせ、片側にしか居らぬ物を名指す★。

■ ★数を焼かぬ★= 本 file に「211」等の数を書かぬ。★数え直す口を残すのが本旨ゆえ★。
  ★出力には必ず【採取時刻】と【撃った command】を添える★ (本夜の規律)。

■ ★台帳へは1 byte も書かぬ (読むのみ)★。

使い方:
    python3 scripts/registry_census.py             # 点呼
    python3 scripts/registry_census.py --selftest  # ★負の主張を一度 偽にして赤を見る★
"""
from __future__ import annotations

import argparse
import collections
import datetime
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GATE_NIGHTLY = REPO_ROOT / "scripts" / "gate_nightly.sh"
PROJECTS = REPO_ROOT / "config" / "projects.yaml"

# 冊の名の形 (★.web.yaml の如き変わりを取り落とさぬ★)。
BOOK_GLOB = "mutation_registry*.yaml"

# 段B の解読が壊れておらぬかの下限。gate_nightly.sh の書換で対が読めなくなった時、
# ★0 対を「gate が何も撃っておらぬ」と読ませぬ★ = 読めぬは緑ではない。
GATE_PAIRS_FLOOR = 2

# 状態 (★混ぜてはならぬ三つ★)
IN_TREE = "冊が木の中に在る"
OUTSIDE_TREE = "★木の中に無いが冊は在る★ (木の外に置かれておる)"
NO_BOOK = "★冊が無い★ (牙の仕組みが一つも無い)"
TREE_MISSING = "★木が見えぬ★ (path 違い / disk 喪失)"


# ---------------------------------------------------------------------------
# path の解き方 — ★projects.yaml は Windows 綴りで書かれておる★
# ---------------------------------------------------------------------------
def win_to_wsl(p: str) -> str:
    """C:/foo → /mnt/c/foo。★之を忘れると木が丸ごと「見えぬ」へ落ちる★ (静かな取り落とし)。"""
    m = re.match(r"^([A-Za-z]):[/\\](.*)$", p)
    if m:
        return f"/mnt/{m.group(1).lower()}/" + m.group(2).replace("\\", "/")
    return p


# ---------------------------------------------------------------------------
# 段B — ★gate_nightly.sh が現に撃っておる (冊, 木) の対★ を読む
# ---------------------------------------------------------------------------
def read_gate_pairs(gate_sh: Path) -> tuple[list[tuple[str, str]], str | None]:
    """(冊 path, 木 path) の対を返す。読めねば (…, 理由) を返す = ★読めぬを緑へ倒さぬ★。

    ★綴りを解く形であって、gate を走らせておるのではない★ =
    ★ゆえに「gate が現に撃った」ことまでは証しておらぬ (射程の名乗り)★。
    """
    if not gate_sh.is_file():
        return [], f"正本が見えぬ ({gate_sh})"
    txt = gate_sh.read_text(encoding="utf-8", errors="replace")
    # 変数の既定値を集める: FOO="${GATE_FOO:-<既定>}" / FOO="$SCRIPT_DIR/xxx" / FOO="$FOO/yyy"
    # ★環境の変数も種に入れる★= APP_ROOT の既定は "$HOME/aituber-project" ゆえ、
    #   ★$HOME を解けねば木が丸ごと『見えぬ』へ落ちる★ (六号が己の初版で現に踏んだ穴・03:20)。
    import os
    env: dict[str, str] = {"SCRIPT_DIR": str(REPO_ROOT)}
    for k in ("HOME", "USER"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    for name, val in re.findall(r'^\s*([A-Z_][A-Z0-9_]*)="([^"]*)"', txt, re.M):
        if "$(" in val:
            continue  # 実行を要する形は解かぬ (推測で埋めるより「読めぬ」を出す)
        v = re.sub(r'\$\{[A-Z_][A-Z0-9_]*:-([^}]*)\}', r"\1", val)
        v = re.sub(r'\$\{([A-Z_][A-Z0-9_]*)\}', lambda m: env.get(m.group(1), m.group(0)), v)
        v = re.sub(r'\$([A-Z_][A-Z0-9_]*)', lambda m: env.get(m.group(1), m.group(0)), v)
        if "$" in v:
            continue
        env.setdefault(name, v)
        env[name] = v
    # 呼び出し行から (--registry X, --repo-root Y) の対を拾う
    pairs: list[tuple[str, str]] = []
    for line in txt.splitlines():
        if "gate_mutation_replay.py" not in line:
            continue
        # ★素の呼び出し (--registry を持たぬ) は【既定の冊 = 自 repo】を撃っておる★。
        #   ★之を落とすと、自分の冊が「毎朝 誰も見ておらぬ」と誤って名指される★
        #   = ★六号が己の初版で現に踏んだ二つ目の穴 (03:21)★。
        if "--registry" not in line:
            if "--tree-census" in line or "--selftest" in line:
                continue
            pair = (str(REPO_ROOT / "config" / "mutation_registry.yaml"), str(REPO_ROOT))
            if pair not in pairs:
                pairs.append(pair)
            continue
        m1 = re.search(r'--registry\s+"?\$?\{?([A-Za-z0-9_./-]+)\}?"?', line)
        m2 = re.search(r'--repo-root\s+"?\$?\{?([A-Za-z0-9_./-]+)\}?"?', line)
        if not m1:
            continue
        reg = env.get(m1.group(1), m1.group(1))
        root = env.get(m2.group(1), m2.group(1)) if m2 else str(REPO_ROOT)
        if "$" in reg or "$" in root:
            continue
        pair = (reg, root)
        if pair not in pairs:
            pairs.append(pair)
    if len(pairs) < GATE_PAIRS_FLOOR:
        return pairs, (f"正本から読めた対が {len(pairs)} 対しかない (下限 {GATE_PAIRS_FLOOR})"
                       " = 綴りが変わって解読が外れた疑い。★0 対を『撃っておらぬ』と読ませぬ★")
    return pairs, None


# ---------------------------------------------------------------------------
# 段A — ★木の中を glob で探す★
# ---------------------------------------------------------------------------
def read_trees(projects: Path) -> list[str]:
    """点呼の分母となる木。projects.yaml + 自 repo + 各木の submodule。"""
    import yaml
    trees: list[str] = [str(REPO_ROOT)]
    if projects.is_file():
        doc = yaml.safe_load(projects.read_text(encoding="utf-8")) or {}
        for p in (doc.get("projects") or []):
            if not isinstance(p, dict) or not p.get("path"):
                continue
            t = win_to_wsl(str(p["path"]))
            if t not in trees:
                trees.append(t)
    # submodule (★backend の台帳は submodule の中に在る = 之を落とすと 96 牙が消える★)
    for t in list(trees):
        gm = Path(t) / ".gitmodules"
        if not gm.is_file():
            continue
        for sp in re.findall(r"^\s*path\s*=\s*(.+?)\s*$", gm.read_text(encoding="utf-8",
                                                                       errors="replace"), re.M):
            sub = str(Path(t) / sp)
            if sub not in trees:
                trees.append(sub)
    return trees


def glob_books(tree: str) -> list[str]:
    d = Path(tree) / "config"
    if not d.is_dir():
        return []
    return sorted(str(p) for p in d.glob(BOOK_GLOB) if p.is_file())


# ---------------------------------------------------------------------------
# 冊の中身を数える (★読むだけ★)
# ---------------------------------------------------------------------------
def count_book(book: str) -> dict:
    import yaml
    try:
        doc = yaml.safe_load(Path(book).read_text(encoding="utf-8")) or {}
    except Exception as e:  # noqa: BLE001
        return {"readable": False, "why": f"{type(e).__name__}: {e}"}
    if not isinstance(doc, dict):
        return {"readable": False, "why": "最上位が mapping でない"}
    ents = doc.get("mutations") or []
    needles = [e.get("red_needle") for e in ents if isinstance(e, dict)]
    have = [n for n in needles if n]
    c = collections.Counter(have)
    dups = {k: v for k, v in c.items() if v > 1}
    # ★★needle が無い牙は二種在り、混ぜてはならぬ★★ (六号が己の初版で現に混ぜた・03:25)
    #   (1) ★負の対照 (expect: 0)★ = ★赤が期待値でない★ゆえ ★名指す赤が原理的に無い★ = 正しい姿
    #   (2) ★赤を期待しておるのに出所を名指せぬ★             = ★之が咎むべき側★
    #  ★本夜 我らが繰り返し掘った形と同じ = 「探して出なんだ」と「元より無い」を同じ札で呼ぶな★。
    def _expect_zero(e: dict) -> bool:
        v = e.get("expect")
        return str(v).strip() in ("0", "None") if v is not None else False
    no_needle = [e for e in ents if isinstance(e, dict) and not e.get("red_needle")]
    return {
        "readable": True,
        "entries": len(ents),
        "missing_needle": [e.get("id") for e in no_needle if not _expect_zero(e)],
        "negative_controls": [e.get("id") for e in no_needle if _expect_zero(e)],
        "unique_needles": len(c),
        "dups": dups,
    }


# ---------------------------------------------------------------------------
# 点呼の核 (★selftest が此処を直に撃てるよう、path を引数で受ける★)
# ---------------------------------------------------------------------------
def census(trees: list[str], gate_pairs: list[tuple[str, str]]) -> list[dict]:
    """木ごとに 1 行を返す。★三つの区別を混ぜぬ★。"""
    by_root: dict[str, list[str]] = {}
    for reg, root in gate_pairs:
        by_root.setdefault(str(Path(root)), []).append(str(Path(reg)))
    # ★★「撃たれておるか」は【冊】の性質であって【木】の性質ではない★★ =
    #   web の冊は shogun 木の中に在るが、撃たれる時の repo-root は web 木である。
    #   ⇒ ★木ごとに照合すると、現に撃たれておる冊を「誰も見ておらぬ」と誤って名指す★
    #     (六号が己の初版で踏んだ穴・03:21)。
    fired_any: set[str] = {str(Path(reg)) for reg, _root in gate_pairs}

    rows: list[dict] = []
    for t in trees:
        t = str(Path(t))
        inside = glob_books(t)
        fired = [b for b in by_root.get(t, []) if Path(b).is_file()]
        outside = [b for b in fired if not b.startswith(t.rstrip("/") + "/")]
        books = list(dict.fromkeys(inside + fired))
        if not Path(t).is_dir():
            state = TREE_MISSING
        elif not books:
            state = NO_BOOK
        elif not inside and outside:
            state = OUTSIDE_TREE
        else:
            state = IN_TREE
        rows.append({
            "tree": t,
            "state": state,
            "books": books,
            "outside": outside,
            # ★段A/段B のどちらが拾うたかを残す★= 片側だけの物が次の穴になるゆえ
            "glob_only": [b for b in inside if b not in fired_any],
            "gate_only": [b for b in fired if b not in inside],
            "counts": {b: count_book(b) for b in books},
        })
    return rows


def render(rows: list[dict], gate_err: str | None, cmd: str) -> int:
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    rc = 0
    print(f"[台帳の点呼] 採取時刻 = ★{now}★ / 撃った command = `{cmd}`")
    print(f"[台帳の点呼] 分母 = 木 {len(rows)} 本 (projects.yaml + 自repo + submodule)")
    if gate_err:
        print(f"  ★UNDETERMINED★ 正本 (gate_nightly.sh) の解読: {gate_err}")
        rc = 2
    tot_e = tot_u = tot_b = 0
    # ★★同じ冊を二度 数えぬ★★ = web の冊は【shogun 木の中】にも【web 木の外の冊】にも現れる。
    #   ★六号の初版は之で 216 を 217 と数えた (03:20:22)★ =
    #   ★★分母を直す口が、己で分母を水増しした★★ = 本夜 三度目の同型ゆえ、機械の側で塞ぐ。
    counted: set[str] = set()
    for r in rows:
        print(f"\n  木 = {r['tree']}")
        print(f"    状態 = {r['state']}")
        if r["state"] == TREE_MISSING:
            rc = max(rc, 2)
            continue
        if r["state"] == NO_BOOK:
            # ★之は「0 件」ではない★= 冊そのものが無い。数の欄を空にして其れを示す。
            print("    冊 = ★無し★ (★『entry 0 件』とは別物ゆえ、数の欄は空にしておる★)")
            continue
        for b in r["books"]:
            c = r["counts"][b]
            dup_book = b in counted
            counted.add(b)
            where = "★木の外★" if b in r["outside"] else "木の中"
            if not c["readable"]:
                print(f"    冊 = {b} [{where}] ★読めぬ★: {c['why']}")
                rc = max(rc, 2)
                continue
            if not dup_book:
                tot_b += 1
                tot_e += c["entries"]
                tot_u += c["unique_needles"]
            print(f"    冊 = {b} [{where}]"
                  + ("  ★合計には数えぬ (別の木の欄で既に数えた同じ冊)★" if dup_book else ""))
            print(f"      牙 = {c['entries']} / 一意 needle = {c['unique_needles']}"
                  f" / 重複 = {sum(v - 1 for v in c['dups'].values())}"
                  f" / needle 欠 = {len(c['missing_needle'])}")
            for k, v in c["dups"].items():
                # ★★重複は咎ではない★★ (家老 03:30 の裁定) =
                #   ★同じ検を二つの角度から縛るのは正しい形も在る★。
                #   ⇒ ★「重複が在る」と「上限が下がる」を分けて名乗る★ = 前者は事実・後者は帰結。
                print(f"        ・重複 needle {k!r} x{v}"
                      f"  … ★事実★ = 同じ検を {v} 本の牙が名指しておる (★異常ではない★)")
                print(f"          → ★帰結★ = 覆いの上限を牙の数で読めば、此の 1 件につき {v - 1} 本 甘くなる"
                      "  (★上限は【一意 needle】で数えよ★)")
            for i in c["missing_needle"]:
                print(f"        ★needle 欠★ {i} = ★赤を期待しておるのに其の出所を名指せぬ牙★")
                rc = max(rc, 1)
            for i in c.get("negative_controls") or []:
                print(f"        ・負の対照 {i} = ★expect: 0 ゆえ名指す赤が原理的に無い★"
                      "  (★needle 欠とは別物・咎ではない★)")
        if r["gate_only"]:
            print(f"    ★段A (glob) では出ぬが正本が撃っておる冊★ = {r['gate_only']}"
                  " = ★木の中を探す計器では原理的に見えぬ形★")
        if r["glob_only"]:
            print(f"    ★冊は在るが正本 (gate_nightly.sh) が撃っておらぬ★ = {r['glob_only']}"
                  " = ★毎朝 誰も見ておらぬ牙の疑い★")
            rc = max(rc, 1)
    print(f"\n[台帳の点呼] 冊 ★{tot_b}★ / 牙 ★{tot_e}★ / 一意 needle ★{tot_u}★ "
          f"(採取 {now})")
    print("[台帳の点呼] ★此の数を写して持ち歩くな★ = ★数え直すには上の command を撃て★")
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
        base = Path(td)
        # 木を三つ作る: 中に冊が在る / 冊が無い / 冊は外に在る (web 型)
        t_in = base / "tree_in"
        t_none = base / "tree_none"
        t_web = base / "tree_web"
        for t in (t_in, t_none, t_web):
            (t / "config").mkdir(parents=True)
        book_in = t_in / "config" / "mutation_registry.yaml"
        book_in.write_text(
            "mutations:\n"
            "  - {id: A, red_needle: n1}\n"
            "  - {id: B, red_needle: n1}\n"   # ★重複★
            "  - {id: C}\n",                   # ★needle 欠★
            encoding="utf-8")
        # web 型: 冊は t_in 側に置き、木は t_web
        book_web = t_in / "config" / "mutation_registry.web.yaml"
        book_web.write_text("mutations:\n  - {id: W, red_needle: nw}\n", encoding="utf-8")
        (t_none / "config").mkdir(exist_ok=True)

        trees = [str(t_in), str(t_none), str(t_web)]
        pairs = [(str(book_in), str(t_in)), (str(book_web), str(t_web))]
        rows = {r["tree"]: r for r in census(trees, pairs)}

        # T1 ★冊が無い木は「冊が無い」と名乗る★
        check("T1 冊が無い木を NO_BOOK と名乗る", rows[str(t_none)]["state"] == NO_BOOK)
        # T1b ★偽にする★= 其の木へ冊を置けば NO_BOOK でなくなるか
        (t_none / "config" / "mutation_registry.yaml").write_text(
            "mutations: []\n", encoding="utf-8")
        rows_f = {r["tree"]: r for r in census(trees, pairs)}
        check("T1b ★偽にして赤★ 冊を置けば NO_BOOK が消える",
              rows_f[str(t_none)]["state"] != NO_BOOK)
        # ★且つ「entry 0 件」と「冊が無い」が別物として出ておること★
        check("T1c ★entry 0 件の冊は NO_BOOK ではない★ (本件の芯)",
              rows_f[str(t_none)]["counts"][
                  str(t_none / "config" / "mutation_registry.yaml")]["entries"] == 0
              and rows_f[str(t_none)]["state"] != NO_BOOK)
        (t_none / "config" / "mutation_registry.yaml").unlink()

        # T2 ★web 型 = 木の中に無いが冊は在る★
        check("T2 web 型を OUTSIDE_TREE と名乗る", rows[str(t_web)]["state"] == OUTSIDE_TREE)
        check("T2b web 型の冊を段B のみが拾うたと名指す",
              rows[str(t_web)]["gate_only"] == [str(book_web)])
        # T2c ★偽にする★= 段B (正本) を外せば web 型は「冊が無い」へ落ちる
        #     = ★木の中を探す計器だけでは見えぬ★ことを、機械が現に示す
        rows_g = {r["tree"]: r for r in census(trees, [(str(book_in), str(t_in))])}
        check("T2c ★偽にして赤★ 正本を外すと web 型は NO_BOOK へ落ちる"
              " (= 段A だけでは原理的に見えぬ)",
              rows_g[str(t_web)]["state"] == NO_BOOK)

        # T3 ★名の変わり (.web.yaml) を glob が拾う★
        check("T3 .web.yaml を段A が拾う",
              str(book_web) in rows[str(t_in)]["books"])
        # T3b ★偽にする★= glob を厳密名にすれば拾えなくなる筈
        import builtins  # noqa: F401
        saved = globals()["BOOK_GLOB"]
        globals()["BOOK_GLOB"] = "mutation_registry.yaml"
        rows_h = {r["tree"]: r for r in census(trees, pairs)}
        check("T3b ★偽にして赤★ glob を厳密名へ狭めると .web.yaml が落ちる",
              str(book_web) not in rows_h[str(t_in)]["books"])
        globals()["BOOK_GLOB"] = saved

        # T4 ★数の勘定★
        c = rows[str(t_in)]["counts"][str(book_in)]
        check("T4 牙 3 / 一意 1 / needle 欠 1 を数える",
              c["entries"] == 3 and c["unique_needles"] == 1 and len(c["missing_needle"]) == 1)
        check("T4b 重複 needle を名指す", c["dups"] == {"n1": 2})

        # T5 ★正本が撃っておらぬ冊を名指す★
        rows_i = {r["tree"]: r for r in census([str(t_in)], [])}
        check("T5 正本が撃っておらぬ冊を glob_only として名指す",
              set(rows_i[str(t_in)]["glob_only"]) == {str(book_in), str(book_web)})

        # T6 ★読めぬ冊を緑へ倒さぬ★
        bad = t_in / "config" / "mutation_registry.bad.yaml"
        bad.write_text("mutations: [\n", encoding="utf-8")
        rows_j = {r["tree"]: r for r in census([str(t_in)], [])}
        check("T6 壊れた冊は readable=False (★読めぬは緑ではない★)",
              rows_j[str(t_in)]["counts"][str(bad)]["readable"] is False)
        bad.unlink()

        # T7 ★木が見えぬ★
        rows_k = {r["tree"]: r for r in census([str(base / "nope")], [])}
        check("T7 実体の無い木を TREE_MISSING と名乗る",
              rows_k[str(base / "nope")]["state"] == TREE_MISSING)

    # T8 ★正本の解読が壊れた時、0 対を『撃っておらぬ』と読ませぬ★
    with tempfile.TemporaryDirectory() as td:
        fake = Path(td) / "gate.sh"
        fake.write_text("echo hello\n", encoding="utf-8")
        pairs, err = read_gate_pairs(fake)
        check("T8 解読が 0 対なら理由つきで UNDETERMINED", pairs == [] and err is not None)
    # T8b ★偽にして赤★= 現物の正本なら対が読めること (canary = 道具の生存)
    pairs, err = read_gate_pairs(GATE_NIGHTLY)
    check("T8b ★canary★ 現物の gate_nightly.sh からは対が読める",
          err is None and len(pairs) >= GATE_PAIRS_FLOOR)

    # T10 ★★重複は「異常」ではない★★ (家老 03:30 の裁定を機械で縛る)
    #     ★重複が在るだけで赤へ倒す形にすると、正しい二重の縛りが咎められる★。
    import io
    import contextlib
    import tempfile as _tf
    with _tf.TemporaryDirectory() as td:
        t = Path(td) / "t"
        (t / "config").mkdir(parents=True)
        b = t / "config" / "mutation_registry.yaml"
        b.write_text("mutations:\n  - {id: A, red_needle: n}\n  - {id: B, red_needle: n}\n",
                     encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc_dup = render(census([str(t)], [(str(b), str(t))]), None, "test")
        out = buf.getvalue()
        check("T10 重複が在っても rc は上がらぬ (★咎ではない★)", rc_dup == 0)
        check("T10b ★事実★ と ★帰結★ を分けて名乗る", "★事実★" in out and "★帰結★" in out)
        # T10c ★偽にして赤★= 重複が無ければ「帰結」の行は出ぬ筈
        b.write_text("mutations:\n  - {id: A, red_needle: n}\n  - {id: B, red_needle: m}\n",
                     encoding="utf-8")
        buf2 = io.StringIO()
        with contextlib.redirect_stdout(buf2):
            render(census([str(t)], [(str(b), str(t))]), None, "test")
        check("T10c ★偽にして赤★ 重複を消せば帰結の行も消える", "★帰結★" not in buf2.getvalue())

    # T11 ★★同じ冊が二つの木の欄に出ても、合計は一度しか数えぬ★★
    #     ★六号の初版が現に 217 と数えた穴 (03:20:22) を機械で縛る★
    with _tf.TemporaryDirectory() as td:
        base = Path(td)
        t_own, t_far = base / "own", base / "far"
        (t_own / "config").mkdir(parents=True)
        t_far.mkdir(parents=True)
        b = t_own / "config" / "mutation_registry.web.yaml"
        b.write_text("mutations:\n  - {id: W, red_needle: nw}\n", encoding="utf-8")
        rows_d = census([str(t_own), str(t_far)], [(str(b), str(t_far))])
        buf3 = io.StringIO()
        with contextlib.redirect_stdout(buf3):
            render(rows_d, None, "test")
        out3 = buf3.getvalue()
        check("T11 二つの木に現れる同じ冊を合計で 1 冊 1 牙と数える",
              "冊 ★1★ / 牙 ★1★" in out3)
        check("T11b 二度目の欄では『合計には数えぬ』と名乗る",
              "★合計には数えぬ" in out3)

    # T13 ★★別の木を repo-root として撃たれる冊を「誰も見ておらぬ」と呼ばぬ★★
    with _tf.TemporaryDirectory() as td:
        base = Path(td)
        t_own, t_far = base / "own", base / "far"
        (t_own / "config").mkdir(parents=True)
        t_far.mkdir(parents=True)
        b = t_own / "config" / "mutation_registry.web.yaml"
        b.write_text("mutations:\n  - {id: W, red_needle: nw}\n", encoding="utf-8")
        rows_e = {r["tree"]: r for r in census([str(t_own), str(t_far)], [(str(b), str(t_far))])}
        check("T13 別の木で撃たれる冊は glob_only に落ちぬ",
              rows_e[str(t_own)]["glob_only"] == [])
        # T13b ★偽にして赤★= 其の対を外せば「誰も見ておらぬ」と名指す筈
        rows_f2 = {r["tree"]: r for r in census([str(t_own), str(t_far)], [])}
        check("T13b ★偽にして赤★ 対を外せば glob_only へ現れる",
              rows_f2[str(t_own)]["glob_only"] == [str(b)])

    # T14 ★素の呼び出し (--registry 無し) を「既定の冊を撃っておる」と読む★
    with _tf.TemporaryDirectory() as td:
        g = Path(td) / "g.sh"
        g.write_text('out=$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" 2>&1)\n'
                     'out2=$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --coverage 2>&1)\n'
                     'x=$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py" --tree-census)\n',
                     encoding="utf-8")
        prs, _e = read_gate_pairs(g)
        check("T14 素の呼び出しを既定の冊 = 自 repo として拾う",
              prs == [(str(REPO_ROOT / "config" / "mutation_registry.yaml"), str(REPO_ROOT))])
        check("T14b ★tree-census は冊を撃つ呼び出しではない★ゆえ対にせぬ", len(prs) == 1)

    # T12 ★正本の既定に $HOME が居ても解ける★ (★解けねば木が丸ごと『見えぬ』へ落ちる★)
    with _tf.TemporaryDirectory() as td:
        g = Path(td) / "g.sh"
        g.write_text(
            'APP_ROOT="${GATE_APP_ROOT:-$HOME/aituber-project}"\n'
            'APP_REG="$APP_ROOT/config/mutation_registry.yaml"\n'
            'out=$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py"'
            ' --registry "$APP_REG" --repo-root "$APP_ROOT")\n'
            'X_REG="$SCRIPT_DIR/config/mutation_registry.web.yaml"\n'
            'out2=$(python3 "$SCRIPT_DIR/scripts/gate_mutation_replay.py"'
            ' --registry "$X_REG" --repo-root "/tmp")\n',
            encoding="utf-8")
        prs, e = read_gate_pairs(g)
        roots = [r for _b, r in prs]
        check("T12 $HOME を含む既定から木の実 path が解ける",
              e is None and any("$" not in r and r.endswith("/aituber-project") for r in roots))

    # T15 ★★負の対照 (expect: 0) を「needle 欠」と呼ばぬ★★
    #     ★六号の初版は MUT-1381-208 (実物の負の対照) を「赤の出所を名指せぬ牙」と名指しておった★
    #     = ★赤が期待値でない牙に「赤の出所」を求めた形★ = 本夜の「二つの違う物を一つの札で呼ぶな」の族。
    with _tf.TemporaryDirectory() as td:
        t = Path(td) / "t"
        (t / "config").mkdir(parents=True)
        b = t / "config" / "mutation_registry.yaml"
        b.write_text("mutations:\n"
                     "  - {id: NEG, expect: 0}\n"        # ★負の対照 = 赤が期待値でない★
                     "  - {id: BAD}\n",                  # ★赤を期待するのに出所を名指せぬ★
                     encoding="utf-8")
        cc = count_book(str(b))
        check("T15 負の対照を needle 欠から外す", cc["missing_needle"] == ["BAD"])
        check("T15b 負の対照を其れとして名指す", cc["negative_controls"] == ["NEG"])
        buf4 = io.StringIO()
        with contextlib.redirect_stdout(buf4):
            rc15 = render(census([str(t)], [(str(b), str(t))]), None, "test")
        o4 = buf4.getvalue()
        check("T15c ★赤を期待する側★ が在れば rc が上がる", rc15 >= 1)
        check("T15d 二つを別の語で名乗る",
              "赤を期待しておるのに" in o4 and "原理的に無い" in o4)
        # T15e ★偽にして赤★= 負の対照から expect: 0 を外せば「needle 欠」へ転ずる筈
        b.write_text("mutations:\n  - {id: NEG}\n", encoding="utf-8")
        check("T15e ★偽にして赤★ expect: 0 を外せば needle 欠へ転ずる",
              count_book(str(b))["missing_needle"] == ["NEG"]
              and count_book(str(b))["negative_controls"] == [])
        # T15f ★逆も撃つ★= expect: 0 を足せば needle 欠が消える (★片道でなく両道★)
        b.write_text("mutations:\n  - {id: NEG, expect: 0}\n", encoding="utf-8")
        check("T15f expect: 0 を足せば needle 欠が消える",
              count_book(str(b))["missing_needle"] == [])

    # T9 ★Windows 綴りを解く★ (★之を落とすと木が丸ごと消える★)
    check("T9 C:/x → /mnt/c/x", win_to_wsl("C:/x/y") == "/mnt/c/x/y")
    check("T9b 既に POSIX の物は触らぬ", win_to_wsl("/home/a") == "/home/a")

    if ng == 0:
        print(f"[registry_census selftest] {ok}/{ok} ALL PASS")
        return 0
    print(f"[registry_census selftest] FAIL: ok={ok} ng={ng}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--projects", type=Path, default=PROJECTS)
    ap.add_argument("--gate-nightly", type=Path, default=GATE_NIGHTLY)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    pairs, err = read_gate_pairs(a.gate_nightly)
    trees = read_trees(a.projects)
    # ★正本が名指す木で、分母に居らぬ物を足す★ = ★冊が在るのに点呼に載らぬ木を作らぬ★
    for _reg, root in pairs:
        r = str(Path(root))
        if r not in [str(Path(t)) for t in trees]:
            trees.append(r)
    cmd = "python3 scripts/registry_census.py"
    return render(census(trees, pairs), err, cmd)


if __name__ == "__main__":
    sys.exit(main())
