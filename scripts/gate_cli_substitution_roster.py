#!/usr/bin/env python3
"""置換が触れる行の名簿門 (cmd_1455 / ashigaru1)

■ 何をする物か
  `scripts/build_instructions.sh` は CLAUDE.md を正本として他 CLI 向けの文書を生成する時、
  `s|Claude Code|<別の CLI 名>|g` を撃つ。この門は「その置換が触れる行」を全部 数え上げ、
  名簿 (config/cli_substitution_roster.yaml) に無い行だけを名指す。

■ 何ゆえ要るか
  置換は文字を替えるだけで、意味は見ない。ゆえに Claude Code で1つ測った事実が、
  生成物では「誰も測っていない3つの断定」に化ける。
  実例 = CLAUDE.md の「Claude Code rejects Write/Edit on unread files.」が
  AGENTS.md では「Codex CLI rejects ...」になる。Codex は一度も測っていない。
  (cmd_1455 で 2 行を直した。この門は「次に書かれた時」を捕まえる側である)

■ 造りの考え
  ・意味を判じない。「置換が触れた」「名簿に載っていない」しか言わない。
    意味 (断定か呼称か) を機械が判じれば必ず誤検知が出て、門は外される (条C)。
  ・そのかわり誤検知 0 の代償として「名簿が古びる」という別の壊れ方を買っている。
    これは cmd_1447 で六号が見つけた形 (白名簿が指す先を失っても何も鳴らず 26 日 気付かれぬ) と同族。
    ⇒ ★死んだ札を rc=1 で鳴らす★ = 名簿が古びたら黙らせない。これが古びへの手当てである。
  ・射程も名簿も、この script には焼かない。毎回 build_instructions.sh から読み直す。
    置換の綴りが変われば pairs が 0 になり、UNDETERMINED になる (緑にはならない)。

■ 三値
  0 PASS          … 触れる行が すべて名簿に在り、名簿に死んだ札も無い
  1 NG            … 名簿に無い行が在る / 名簿に死んだ札が在る
  2 UNDETERMINED  … 置換を読めなかった・射程の file が無い・canary が死んだ

■ 使い方
  python3 scripts/gate_cli_substitution_roster.py            # 判定
  python3 scripts/gate_cli_substitution_roster.py --list     # 触れる行を全数列挙 (名簿の種)
  python3 scripts/gate_cli_substitution_roster.py --selftest # 陽性と陰性を対で撃つ
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tempfile
from pathlib import Path

PASS, NG, UNDET = 0, 1, 2

BUILDER_REL = "scripts/build_instructions.sh"
ROSTER_REL = "config/cli_substitution_roster.yaml"

# build_instructions.sh の置換行  ->  -e 's|左|右|g'
SED_RE = re.compile(r"-e\s+'s\|([^|]+)\|([^|]+)\|g'")
# sed の入力になる正本  ->  local <var>="$ROOT_DIR/<path>"
SRC_RE = re.compile(r'^\s*local\s+\w+="\$ROOT_DIR/([^"]+)"\s*$')
# 置換の左辺のうち「CLI 名そのもの」だけを採る。
# path 系 (CLAUDE.md -> AGENTS.md 等) は呼称の付け替えであって、断定へ化ける道が無い。
CLI_NEEDLE_RE = re.compile(r"^[A-Z][A-Za-z0-9]*(?: [A-Za-z0-9.+#]+)* Code$|^Claude Code$")

PATH_KEY_RE = re.compile(r"^\s*-\s*path:\s*(\S.*?)\s*$")
SHA_KEY_RE = re.compile(r"^\s*line_sha256:\s*([0-9a-f]{64})\s*$")
TEXT_KEY_RE = re.compile(r"^\s*text:\s*(.*?)\s*$")

BACKWARD_WINDOW = 60   # sed 行から正本の宣言まで遡る行数


def sha(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


# ────────────────────────────────────────────────── 置換の読み取り (射程を焼かない)

def read_substitutions(builder: Path):
    """build_instructions.sh から (needle, [replacement...], [正本 path...]) を読む。

    見つからなければ (None, [], []) を返す。呼び手は UNDETERMINED へ倒す。
    「置換が消えた」と「置換の綴りが変わった」を区別する術は無いが、
    どちらも人が見るべき事なので、黙って緑にしない側へ倒せば足りる。
    """
    try:
        lines = builder.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as e:
        return None, [], [], f"置換の元 ({builder}) が読めぬ: {e}"

    needles: dict[str, list[str]] = {}
    sources: set[str] = set()
    for i, line in enumerate(lines):
        m = SED_RE.search(line)
        if not m:
            continue
        left, right = m.group(1), m.group(2)
        if not CLI_NEEDLE_RE.match(left):
            continue
        needles.setdefault(left, []).append(right)
        # この sed の入力になっている正本を、上へ遡って探す
        for j in range(i - 1, max(-1, i - BACKWARD_WINDOW) - 1, -1):
            sm = SRC_RE.match(lines[j])
            if sm:
                sources.add(sm.group(1))
                break

    if not needles:
        return None, [], [], (
            f"{builder} に CLI 名を替える置換が 1 件も無い = "
            "置換が消えたか綴りが変わった。どちらも人が見る事ゆえ緑にせぬ"
        )
    if len(needles) > 1:
        # 左辺が複数 = 想定していない形。数え方が合っている保証が無いので緑にしない。
        return None, [], [], f"置換の左辺が複数 ({sorted(needles)}) = 想定外の形ゆえ緑にせぬ"
    if not sources:
        return None, [], [], "置換は在るが、その入力になる正本を辿れなんだ = 射程が測れぬ"

    needle = next(iter(needles))
    return needle, sorted(needles[needle]), sorted(sources), ""


# ────────────────────────────────────────────────── 走査

def scan(root: Path, needle: str, sources: list[str]):
    """射程の正本を読み、needle を含む行を挙げる。→ (rows, stat)"""
    rows: list[dict] = []
    stat = {"files": 0, "missing": [], "lines": 0}
    for rel in sources:
        p = root / rel
        if not p.is_file():
            stat["missing"].append(rel)
            continue
        try:
            body = p.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            stat["missing"].append(f"{rel} ({e})")
            continue
        stat["files"] += 1
        for i, line in enumerate(body.splitlines(), 1):
            stat["lines"] += 1
            if needle in line:
                text = line.rstrip()
                rows.append({"path": rel, "line": i, "text": text, "sha256": sha(text)})
    return rows, stat


# ────────────────────────────────────────────────── 名簿

def load_roster(path: Path):
    """→ (entries, notes)。entry = dict(path, sha256, text)

    yaml module に頼らない。名簿が壊れていても門ごと落ちないため
    (落ちれば「未検分」が「緑」に化ける)。読めた札だけを採る = 読めなければ除かない。
    """
    notes: list[str] = []
    if not path.exists():
        return [], [f"名簿 {path} が無い = 何も除いておらぬ (除外は足す側の働きゆえ)"]
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        return [], [f"名簿が読めぬ ({e}) = 何も除いておらぬ"]

    entries: list[dict] = []
    cur: dict | None = None
    for line in raw.splitlines():
        m = PATH_KEY_RE.match(line)
        if m:
            cur = {"path": m.group(1).strip().strip('"').strip("'"), "sha256": None, "text": None}
            entries.append(cur)
            continue
        if cur is None:
            continue
        m = SHA_KEY_RE.match(line)
        if m:
            cur["sha256"] = m.group(1)
            continue
        m = TEXT_KEY_RE.match(line)
        if m:
            cur["text"] = _unquote(m.group(1))

    good = [e for e in entries if e["sha256"]]
    if len(good) != len(entries):
        notes.append(f"札 {len(entries) - len(good)} 件は line_sha256 を持たぬゆえ採っておらぬ (除かぬ側へ倒した)")

    # text: は人が読むための欄。照合には使わぬが、hash と食い違えば人の直し漏れゆえ名乗る。
    for e in good:
        if e["text"] is not None and sha(e["text"]) != e["sha256"]:
            notes.append(
                f"札 {e['path']} の text と line_sha256 が食い違う = "
                "人が本文だけ直して hash を置き去りにした形 (照合は hash 側で行う)"
            )
    return good, notes


def _unquote(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        inner = s[1:-1]
        if s[0] == '"':
            return inner.replace('\\"', '"').replace("\\\\", "\\")
        return inner
    return s


# ────────────────────────────────────────────────── canary

def run_canary() -> tuple[bool, str]:
    """判ずる前に、置換の読み取りと走査が生きている事を同じ関数で確かめる。

    三つ問う = (a) 置換を読めるか (b) 触れる行を拾うか (c) 触れぬ行を拾わぬか
    """
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "scripts").mkdir()
        (root / "scripts" / "build_instructions.sh").write_text(
            'gen() {\n'
            '    local src="$ROOT_DIR/CANON.md"\n'
            '    sed \\\n'
            "        -e 's|CANON\\.md|OTHER.md|g' \\\n"
            "        -e 's|Claude Code|Canary CLI|g' \\\n"
            '        "$src" > out\n'
            '}\n',
            encoding="utf-8",
        )
        (root / "CANON.md").write_text(
            "touched: Claude Code rejects things\nuntouched: plain sentence\n", encoding="utf-8"
        )
        needle, repl, sources, err = read_substitutions(root / "scripts" / "build_instructions.sh")
        if err:
            return False, f"canary が置換を読めなんだ: {err}"
        if needle != "Claude Code" or sources != ["CANON.md"]:
            return False, f"canary の読み取りがずれた: needle={needle!r} 射程={sources}"
        rows, _ = scan(root, needle, sources)
        got = [(r["path"], r["line"]) for r in rows]
    if got != [("CANON.md", 1)]:
        return False, f"canary が期待どおり拾わなんだ: 実測={got}"
    return True, "canary OK (置換を読む・触れる 1 行を拾う・触れぬ行は拾わぬ)"


# ────────────────────────────────────────────────── 判定

def judge(root: Path, roster_path: Path, canary=run_canary):
    out: list[str] = []

    ok, cnote = canary()
    if not ok:
        out.append(f"[CLISUB-CANARY] UNDETERMINED: {cnote} = 盲かも知れぬ道具の 0 は 0 ではない")
        return UNDET, out
    out.append(f"[CLISUB-CANARY] {cnote}")

    needle, repl, sources, err = read_substitutions(root / BUILDER_REL)
    if err:
        out.append(f"[CLISUB-SUBST] UNDETERMINED: {err}")
        return UNDET, out
    out.append(
        f"[CLISUB-SUBST] 置換 = 「{needle}」→ {len(repl)} 通り ({'・'.join(repl)}) / 射程の正本 = {'・'.join(sources)}"
    )

    rows, stat = scan(root, needle, sources)
    if stat["missing"]:
        out.append(
            f"[CLISUB-SCOPE] UNDETERMINED: 射程の正本 {len(stat['missing'])} 本が読めぬ "
            f"({'・'.join(stat['missing'])}) = 測れておらぬは緑ではない"
        )
        return UNDET, out

    entries, rnotes = load_roster(roster_path)
    for n in rnotes:
        out.append(f"[CLISUB-ROSTER] {n}")

    named = {(e["path"], e["sha256"]) for e in entries}
    seen = {(r["path"], r["sha256"]) for r in rows}
    unknown = [r for r in rows if (r["path"], r["sha256"]) not in named]
    stale = sorted({(e["path"], e["sha256"]) for e in entries} - seen)

    out.append(
        f"[CLISUB-SCOPE] 読んだ正本 = {stat['files']} 本 / {stat['lines']} 行 ・"
        f" 置換が触れる行 = {len(rows)} ・ 名簿 = {len(entries)} 札"
    )

    rc = PASS
    if unknown:
        rc = NG
        out.append(f"[CLISUB-NEW] NG: 名簿に無い行 {len(unknown)} 行 = 正本に CLI 名が新しく書かれた")
        out.append(
            "    この門は意味を判じておらぬ。人が読んで判ぜよ = "
            "呼称だけなら名簿へ足す。働きを断ずる文なら CLI 名を書かぬ形へ直す。"
        )
        for r in unknown[:40]:
            out.append(f"    {r['path']}:{r['line']}  {r['text'][:130]}")
            out.append(f"        line_sha256: {r['sha256']}")
        if len(unknown) > 40:
            out.append(f"    (他 {len(unknown) - 40} 行 — --list で全数)")

    if stale:
        rc = NG
        # ここが名簿の古びへの手当て。cmd_1447 の白名簿は指す先を失っても黙り、26 日 気付かれなかった。
        # 同じ黙り方をせぬよう、死んだ札は鳴らす。直し方は「札を消す」だけで安い。
        out.append(f"[CLISUB-STALE] NG: 名簿に在って盤面に無い札 {len(stale)} 件 = 名簿が古びておる")
        out.append(
            "    その行が直されたか消えたかである。人が確かめて札を消せ。"
            "黙らせれば cmd_1447 の白名簿と同じ形 (指す先を失っても何も鳴らぬ) になる。"
        )
        for p, h in stale[:20]:
            hit = next((e for e in entries if e["path"] == p and e["sha256"] == h), None)
            out.append(f"    {p}  {h[:16]}...  {(hit or {}).get('text') or '(text 欄なし)'}"[:160])

    if rc == PASS:
        out.append("[CLISUB-OK] PASS: 触れる行はすべて名簿に在り、死んだ札も無い")
    out.append(
        "    この緑が言うておらぬ事 = 名簿に在る行が「置換されて正しい」とは言うておらぬ。"
        "名簿は人が一度 判じた印であって、正しさの証ではない。"
        f"また射程は {'・'.join(sources)} だけで、置換の掛からぬ instructions/*.md は見ておらぬ。"
    )
    return rc, out


# ────────────────────────────────────────────────── selftest

def _tree(root: Path, canon_body: str, cli_lines=("Claude Code|Codex CLI",)):
    (root / "scripts").mkdir(parents=True, exist_ok=True)
    seds = "".join(f"        -e 's|{p}|g' \\\n" for p in cli_lines)
    (root / "scripts" / "build_instructions.sh").write_text(
        'gen() {\n'
        '    local claude_md="$ROOT_DIR/CLAUDE.md"\n'
        '    sed \\\n'
        "        -e 's|CLAUDE\\.md|AGENTS.md|g' \\\n"
        f"{seds}"
        '        "$claude_md" > out\n'
        '}\n',
        encoding="utf-8",
    )
    (root / "CLAUDE.md").write_text(canon_body, encoding="utf-8")
    return root


def _roster(root: Path, pairs) -> Path:
    p = root / "roster.yaml"
    lines = ["entries:"]
    for path, s, text in pairs:
        lines += [f"  - path: {path}", f"    line_sha256: {s}"]
        if text is not None:
            lines.append(f"    text: {text}")
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


def selftest() -> int:
    """陽性 (鳴るべき盤面で現に鳴る) と陰性 (黙るべき盤面で黙る) を対で撃つ。"""
    ok = ng = 0

    def check(tid: str, got: int, want: int, note: str = ""):
        nonlocal ok, ng
        if got == want:
            ok += 1
            mark = "OK "
        else:
            ng += 1
            mark = "NG "
        print(f"  {mark}{tid} (rc={got} 期待={want}) {note}")

    print("=== gate_cli_substitution_roster selftest ===")

    CALL = "desc: Claude Code + tmux platform"
    ASSERT = "Claude Code rejects Write/Edit on unread files."

    # ── 陰性1: 触れる行が名簿に在れば黙る
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\nplain line\n")
        rc, _ = judge(root, _roster(root, [("CLAUDE.md", sha(CALL), None)]))
        check("陰性1 名簿に在る行は黙る", rc, PASS)

    # ── 陰性2: CLI 名を含まぬ行を足しても黙る
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n新しい行。CLI 名は書いておらぬ\n")
        rc, _ = judge(root, _roster(root, [("CLAUDE.md", sha(CALL), None)]))
        check("陰性2 CLI 名を書かねば足しても黙る", rc, PASS, "= 置換の射程に入らぬゆえ")

    # ── 陽性1: 正本へ CLI 名を新しく書けば鳴り、その行を名指す
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n{ASSERT}\n")
        rc, out = judge(root, _roster(root, [("CLAUDE.md", sha(CALL), None)]))
        check("陽性1 新しい CLI 名の行で鳴る", rc, NG)
        check("陽性1 鳴った行を名指す", 0 if any("CLAUDE.md:3" in l for l in out) else 1, 0)

    # ── 陽性2: 名簿の札を消せば鳴る (名簿が守りである事の証)
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        rc, _ = judge(root, _roster(root, []))
        check("陽性2 名簿を空にすれば鳴る", rc, NG)

    # ── 陽性3: 名簿が古びれば鳴る (cmd_1447 と同じ黙り方をせぬ事の証)
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), "head\nplain only\n")
        rc, out = judge(root, _roster(root, [("CLAUDE.md", sha(CALL), CALL)]))
        check("陽性3 死んだ札が在れば鳴る", rc, NG, "= 名簿の古びを黙らせぬ")
        check("陽性3 STALE と名乗る", 0 if any("CLISUB-STALE" in l for l in out) else 1, 0)

    # ── 陽性4: 1 byte でも違えば札は当たらぬ (pattern でない事の証)
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        rc, _ = judge(root, _roster(root, [("CLAUDE.md", sha(CALL + " "), None)]))
        check("陽性4 1 byte 違えば当たらぬ", rc, NG, "= 匿えるのは其の行だけ")

    # ── 陽性5: path も見る (同じ hash でも別 path の札では除かぬ)
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        rc, _ = judge(root, _roster(root, [("OTHER.md", sha(CALL), None)]))
        check("陽性5 別 path の札では除かぬ", rc, NG)

    # ── 陽性6: 置換が消えれば緑にせぬ (射程が動いた事に気付く口)
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n", cli_lines=())
        rc, out = judge(root, _roster(root, []))
        check("陽性6 置換が消えれば UNDETERMINED", rc, UNDET, "= 0 件を緑と読ませぬ")
        check("陽性6 理由を名乗る", 0 if any("CLISUB-SUBST" in l for l in out) else 1, 0)

    # ── 陽性7: 正本が消えれば緑にせぬ
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        (root / "CLAUDE.md").unlink()
        rc, _ = judge(root, _roster(root, []))
        check("陽性7 正本が読めねば UNDETERMINED", rc, UNDET)

    # ── 陽性8: canary が死ねば緑を名乗らぬ
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        rst = _roster(root, [("CLAUDE.md", sha(CALL), None)])
        rc_t, _ = judge(root, rst)
        check("陰性3 canary 健在なら黙る", rc_t, PASS)
        rc_f, out_f = judge(root, rst, canary=lambda: (False, "偽装した死"))
        check("陽性8 canary が死ねば UNDETERMINED", rc_f, UNDET)
        check("陽性8 未検分が名を出す", 0 if any("UNDETERMINED" in l for l in out_f) else 1, 0)

    # ── 陽性9: 名簿が壊れていても門ごと落ちず、除かぬ側へ倒れる
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        bad = root / "bad.yaml"
        bad.write_text("entries: [これは: 壊れて: おる\n", encoding="utf-8")
        rc, _ = judge(root, bad)
        check("陽性9 壊れた名簿でも落ちず鳴る", rc, NG, "= 例外で門ごと死なぬ")

    # ── 陰性4: 射程は置換の掛かる正本だけ (掛からぬ file は見ぬ)
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        (root / "instructions").mkdir()
        (root / "instructions" / "karo.md").write_text(ASSERT + "\n", encoding="utf-8")
        rc, out = judge(root, _roster(root, [("CLAUDE.md", sha(CALL), None)]))
        check("陰性4 置換の掛からぬ file は射程外", rc, PASS)
        check(
            "陰性4 見ておらぬ範囲を名乗る",
            0 if any("見ておらぬ" in l for l in out) else 1, 0, "= 条6 (緑の射程を名乗る)",
        )

    # ── 陰性5/陽性10: text 欄は照合に使わぬが、hash と食い違えば名乗る
    with tempfile.TemporaryDirectory() as td:
        root = _tree(Path(td), f"head\n{CALL}\n")
        rc, out = judge(root, _roster(root, [("CLAUDE.md", sha(CALL), "人が書き替えた別の文")]))
        check("陰性5 text がずれても照合は hash で通る", rc, PASS)
        check("陽性10 text と hash の食い違いを名乗る", 0 if any("食い違う" in l for l in out) else 1, 0)

    print(f"=== selftest: OK={ok} NG={ng} SKIP=0 ===")
    return PASS if ng == 0 else NG


# ────────────────────────────────────────────────── main

def main() -> int:
    ap = argparse.ArgumentParser(
        description="CLI 名の置換が触れる行のうち、名簿に無い物を名指す (直さぬ)"
    )
    ap.add_argument("--root", default=None, help="repo の根 (既定 = 本 script の親の親)")
    ap.add_argument("--roster", default=None, help=f"名簿 (既定 = {ROSTER_REL})")
    ap.add_argument("--list", action="store_true", help="触れる行を全数列挙 (名簿の種)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    root = Path(a.root).resolve() if a.root else Path(__file__).resolve().parent.parent
    roster = Path(a.roster).resolve() if a.roster else root / ROSTER_REL

    if a.list:
        ok, cnote = run_canary()
        print(f"[CLISUB-CANARY] {cnote}")
        if not ok:
            return UNDET
        needle, repl, sources, err = read_substitutions(root / BUILDER_REL)
        if err:
            print(f"[CLISUB-SUBST] UNDETERMINED: {err}")
            return UNDET
        rows, stat = scan(root, needle, sources)
        entries, _ = load_roster(roster)
        named = {(e["path"], e["sha256"]) for e in entries}
        for r in rows:
            tag = "名簿済 " if (r["path"], r["sha256"]) in named else "未名指し"
            print(f"{tag}  {r['path']}:{r['line']}")
            print(f"        line_sha256: {r['sha256']}")
            print(f"        text: {r['text']}")
        print(f"# 正本={stat['files']} 本 / {stat['lines']} 行 / 触れる行={len(rows)} / 名簿={len(entries)} 札")
        return PASS

    rc, out = judge(root, roster)
    for line in out:
        print(line)
    return rc


if __name__ == "__main__":
    sys.exit(main())
