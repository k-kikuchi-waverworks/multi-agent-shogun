#!/usr/bin/env python3
"""★焼けた事を後から必ず知る口★ (cmd_1394 追補・ashigaru3)

■ 何をする物か
  repo 全域の text file を走査し、★U+FFFD (byte 列 EF BF BD) を持つ箇所★を挙げ、
  ★名簿 (config/replacement_char_roster.yaml) に無い箇所だけを名指す★。

■ ★何ゆえ此の口が要るか (由来を消さぬ)★
  ・足軽四号が cmd_1400 で log を errors="replace" で読んで write_text で書き戻し、
    ★46 箇所の壊れた byte 列が 29 個の U+FFFD へ【恒久に】置き換わった★。元の byte は戻らぬ。
  ・★然れど当の実害は committed script でなく【手撃ちの one-liner】であった★
    ⇒ ★手を縛る門は作れぬ★。★作れるのは【焼けた事を後から必ず知る口】ただ一つ★である。
  ・ゆえに本 script は ★直さぬ★。★名指すだけ★である
    (★直す形が当の実害を生んだ★ — 之を道具の側で繰り返さぬ)。

■ ★造りの掟 (いずれも本夜の規律の実装である)★
  (1) ★数を焼くな。数え直す口を残せ★
      = 本 script は ★件数を何処にも保存せぬ★。名簿が持つのは【箇所の名指し】のみ。
        「増えたか」は ★毎回 数え直して名簿と突き合わせる★ことで判ずる。
  (2) ★除外は sha256 か path の名指しのみ。pattern で除くな★ (四号 cmd_1400 の設計を借りた)
      = pattern で黙らせれば ★将来の本物まで巻き添えで匿う道★ が開く。
        ★行 全体の sha256 なら 1 byte 違えば当たらぬ★ = 匿えるのは【既に在る其の行】だけ。
  (3) ★名簿が読めねば何も除かぬ★ = 除外は【足す】側の働きゆえ、読めねば安全側 (=名指す側) へ倒す。
  (4) ★拡張子で切らぬ★
      = ★6 拡張子で切った折、台帳の控え (.bak_cmd1099) と logs/ntfy_send.log が黙って外れておった★。
        binary は ★先頭 8KB の NUL★ で除く (拡張子ではない)。★除いた本数は必ず名乗る★。
  (5) ★canary を通さねば「0」も「PASS」も名乗らぬ★
      = 走査そのものが盲になっておらぬことを、判ずる前に ★同じ関数で★ 確かめる。
        ★canary が死ねば UNDETERMINED★ (★緑ではない★)。

■ 三値
  0 PASS          … 見つけた箇所が ★すべて名簿に在る★
  1 NG            … ★名簿に無い箇所が在る★ (= 新たに焼けた公算。★名指すのみ・直さぬ★)
  2 UNDETERMINED  … canary が死んだ / 走査できなんだ (★未検分を緑に混ぜぬ★)

■ 使い方
  python3 scripts/gate_replacement_char.py            # 判定
  python3 scripts/gate_replacement_char.py --list     # 見つけた箇所を全数列挙 (名簿の種)
  python3 scripts/gate_replacement_char.py --selftest # ★負の主張を偽にして赤を見る★
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
from pathlib import Path

PASS, NG, UNDET = 0, 1, 2

# ★本 script 自身は U+FFFD の実体を 1 個も持たぬ★
#   = 持てば ★己が己の分母を汚す★ (拙者は報告の初版で現に之を踏んだ)。
#   ⇒ byte 列で持ち、印字は ASCII の札 MARK で行う。
NEEDLE = b"\xef\xbf\xbd"
MARK = "<U+FFFD>"

PRUNE_DIRS = {".git", "node_modules", "__pycache__"}
HEAD_BYTES = 8192          # binary 判定に読む先頭
ROSTER_REL = "config/replacement_char_roster.yaml"

SHA_RE = re.compile(r"^\s*line_sha256:\s*([0-9a-f]{64})\s*$")
PATH_RE = re.compile(r"^\s*-\s*path:\s*(\S.*?)\s*$")


# ────────────────────────────────────────────────────────────── 走査

def is_binary(head: bytes) -> bool:
    """★NUL で判ずる。拡張子では判ぜぬ★ (png/jpg/mp3/pyc にも EF BF BD は偶然 当たる)。"""
    return b"\x00" in head


def scan(root: Path):
    """→ (sites, stat)。site = dict(path, line, sha256, occ, run_max, ctx)

    ★読めなんだ file は黙って飛ばさぬ★ = stat["unreadable"] に積んで呼び手へ返す。
    """
    sites: list[dict] = []
    stat = {"files": 0, "binary": 0, "unreadable": [], "bytes": 0}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        for name in sorted(filenames):
            p = Path(dirpath) / name
            try:
                with open(p, "rb") as fh:
                    head = fh.read(HEAD_BYTES)
                    if is_binary(head):
                        stat["binary"] += 1
                        continue
                    blob = head + fh.read()
            except OSError as e:
                stat["unreadable"].append(f"{p}: {e}")
                continue
            stat["files"] += 1
            stat["bytes"] += len(blob)
            if NEEDLE not in blob:
                continue
            rel = os.path.relpath(p, root)
            for i, line in enumerate(blob.split(b"\n"), 1):
                if NEEDLE not in line:
                    continue
                runs = [len(m.group(0)) // 3 for m in re.finditer(b"(?:" + NEEDLE + b")+", line)]
                sites.append({
                    "path": rel.replace(os.sep, "/"),
                    "line": i,
                    # ★hash は【行の byte】で採る★ = decode を経由せぬ
                    #   (decode を経由する形が当の実害を生んだゆえ、道具の側でも踏まぬ)
                    "sha256": hashlib.sha256(line).hexdigest(),
                    "occ": line.count(NEEDLE),
                    "run_max": max(runs),
                    "ctx": _ctx(line),
                })
    return sites, stat


def _ctx(line: bytes, span: int = 40) -> str:
    """★U+FFFD を実体で吐かぬ★ = 印字は MARK へ差し替える (読む者の分母を汚さぬため)。"""
    j = line.find(NEEDLE)
    s, e = max(0, j - span), min(len(line), j + span)
    return line[s:e].replace(NEEDLE, MARK.encode()).decode("utf-8", errors="replace")


# ────────────────────────────────────────────────────────────── 名簿

def load_roster(path: Path):
    """→ (entries, note)。entry = (path, sha256)

    ★yaml module に頼らぬ★ = 名簿が壊れておる時に ★例外で門ごと落ちて「未検分」が「緑」に化ける★
    のを避け、★読めた行だけを採る★ (読めねば除かぬ = 安全側)。
    ★pattern の欄は【元より無い】★ = 匿う術を構造で持たせておらぬ。
    """
    if not path.exists():
        return set(), f"名簿 {path} が無い = ★何も除いておらぬ★ (除外は足す側の働きゆえ)"
    try:
        raw = path.read_bytes().decode("utf-8", errors="replace")
    except OSError as e:
        return set(), f"名簿が読めぬ ({e}) = ★何も除いておらぬ★"
    entries: set[tuple[str, str]] = set()
    cur: str | None = None
    for line in raw.splitlines():
        m = PATH_RE.match(line)
        if m:
            cur = m.group(1).strip().strip('"').strip("'")
            continue
        m = SHA_RE.match(line)
        if m and cur:
            entries.add((cur, m.group(1)))
    return entries, ""


# ────────────────────────────────────────────────────────────── canary

def run_canary() -> tuple[bool, str]:
    """★判ずる前に、走査が盲でないことを同じ関数で確かめる★。

    ★三つ問う★= (a) 在る物を拾うか (b) 無い物を拾わぬか (c) ★拡張子の無い file も拾うか★
    (c) を入れたのは ★拡張子で切った射程が現に台帳の控えを取り零しておった★ ゆえ。
    """
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "has.md").write_bytes(b"plain\nbroken " + NEEDLE + b" here\n")
        (root / "none.md").write_bytes(b"plain only\n")
        (root / "noext").write_bytes(b"also " + NEEDLE + b"\n")
        sites, _ = scan(root)
        got = sorted({s["path"] for s in sites})
    want = ["has.md", "noext"]
    if got != want:
        return False, f"canary が期待どおり鳴らなんだ: 期待={want} 実測={got}"
    return True, f"canary OK (拾う {want} / 拾わぬ none.md)"


# ────────────────────────────────────────────────────────────── 判定

def judge(root: Path, roster_path: Path, canary=run_canary):
    out: list[str] = []

    ok, cnote = canary()
    if not ok:
        out.append(f"[FFFD-CANARY] UNDETERMINED: {cnote} = ★盲かも知れぬ道具の 0 は 0 ではない★")
        return UNDET, out
    out.append(f"[FFFD-CANARY] {cnote}")

    try:
        sites, stat = scan(root)
    except OSError as e:
        out.append(f"[FFFD-SCAN] UNDETERMINED: 走査できなんだ ({e})")
        return UNDET, out

    if stat["unreadable"]:
        out.append(f"[FFFD-SCAN] ★読めなんだ file {len(stat['unreadable'])} 本 (黙って飛ばさぬ)★")
        for u in stat["unreadable"][:5]:
            out.append(f"    {u}")

    entries, rnote = load_roster(roster_path)
    if rnote:
        out.append(f"[FFFD-ROSTER] {rnote}")

    seen = {(s["path"], s["sha256"]) for s in sites}
    unnamed = [s for s in sites if (s["path"], s["sha256"]) not in entries]
    stale = sorted(entries - seen)

    out.append(
        f"[FFFD-SCOPE] 読んだ text={stat['files']} 本 / {stat['bytes'] / 1048576:.1f}MB ・"
        f" ★binary として除いた={stat['binary']} 本 (NUL 判定・拡張子では切っておらぬ)★ ・"
        f" 見つけた箇所={len(sites)} 行 / 名簿={len(entries)} 件"
    )

    if stale:
        # ★rc は動かさぬ★= 名簿の腐りは【新たな焼けを匿えぬ】(照合は行 hash の完全一致ゆえ)。
        #   ★然れど黙れば名簿が腐る★ ⇒ 名指しはする (黙って減らさぬ)。
        out.append(f"[FFFD-STALE] ★名簿に在って盤面に無い={len(stale)} 件 (匿う力は無いが腐っておる)★")
        for p, h in stale[:10]:
            out.append(f"    {p}  {h[:16]}...")

    if unnamed:
        out.append(f"[FFFD-NEW] NG: ★名簿に無い箇所 {len(unnamed)} 行★ = ★新たに焼けた公算★")
        out.append("    ★直すな★= 直す形 (decode を経由した書き戻し) が当の実害を生んだ。★名指して家老へ返せ★。")
        for s in unnamed[:40]:
            out.append(
                f"    {s['path']}:{s['line']}  実体={s['occ']} 最長連={s['run_max']}  ...{s['ctx']}..."
            )
        if len(unnamed) > 40:
            out.append(f"    (他 {len(unnamed) - 40} 行 — --list で全数)")
        return NG, out

    out.append("[FFFD-OK] PASS: ★見つけた箇所はすべて名簿に在る★ = 新たに焼けた物は無い")
    out.append(
        "    ★但し此の緑が言うておらぬ事★= ★名簿に在る箇所が【壊れておらぬ】とは言うておらぬ★。"
        "名簿は【既に見た】の名指しであって、無罪の証ではない。"
    )
    return PASS, out


# ────────────────────────────────────────────────────────────── selftest

def _mk(root: Path, rel: str, body: bytes):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(body)
    return p


def _roster(root: Path, pairs) -> Path:
    p = root / "roster.yaml"
    lines = ["sites:"]
    for path, sha in pairs:
        lines += [f"  - path: {path}", f"    line_sha256: {sha}"]
    p.write_bytes(("\n".join(lines) + "\n").encode())
    return p


def _sha(line: bytes) -> str:
    return hashlib.sha256(line).hexdigest()


def selftest() -> int:
    """★負の主張は【一度 偽にして赤を見て】から名乗る★ (家老 02:12 の規律)。

    ★各検は「真の盤面で期待どおり」+「偽の盤面で現に色が変わる」の両方を撃つ★。
    ★片側しか撃たぬ検は、刃を持たぬまま緑を出しうる★ = 本夜 repo に 94 箇所 在った当の形。
    """
    ok = ng = 0

    def check(tid: str, got: int, want: int, note: str):
        nonlocal ok, ng
        mark = "OK " if got == want else "NG "
        if got == want:
            ok += 1
        else:
            ng += 1
        print(f"  {mark}{tid} (rc={got} 期待={want}) {note}")

    print("=== gate_replacement_char selftest ===")

    # ── S1: 名簿に在れば PASS / ★偽にして赤を見る★= 名簿を空にすれば NG
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        line = b"broken " + NEEDLE + b" here"
        _mk(root, "a.md", b"head\n" + line + b"\n")
        rc_t, _ = judge(root, _roster(root, [("a.md", _sha(line))]))
        check("S1-真 名簿に在る箇所は緑", rc_t, PASS, "")
        rc_f, out_f = judge(root, _roster(root, []))
        check("S1-偽 名簿を空にすれば赤", rc_f, NG, "")
        named = any("a.md:2" in l for l in out_f)
        check("S1-偽 赤が【名を出す】", 0 if named else 1, 0, "= 赤いだけでは足りぬ")

    # ── S2: ★1 byte 違えば当たらぬ★ (pattern でない事の証)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        line = b"broken " + NEEDLE + b" here"
        _mk(root, "a.md", line + b"\n")
        rc_t, _ = judge(root, _roster(root, [("a.md", _sha(line))]))
        check("S2-真 行 hash 一致で緑", rc_t, PASS, "")
        # 行を 1 byte 変える = 同じ file・同じ U+FFFD だが名簿は当たらぬ
        _mk(root, "a.md", b"brokeN " + NEEDLE + b" here\n")
        rc_f, _ = judge(root, _roster(root, [("a.md", _sha(line))]))
        check("S2-偽 1 byte 変えれば赤", rc_f, NG, "= 匿えるのは【其の行】だけ")

    # ── S3: ★path も見る★ (同じ hash でも別 path は除かぬ)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        line = b"same " + NEEDLE
        _mk(root, "x/a.md", line + b"\n")
        rc_f, _ = judge(root, _roster(root, [("y/a.md", _sha(line))]))
        check("S3-偽 別 path の名指しでは除かぬ", rc_f, NG, "")
        rc_t, _ = judge(root, _roster(root, [("x/a.md", _sha(line))]))
        check("S3-真 同 path なら除く", rc_t, PASS, "")

    # ── S4: ★binary は NUL で除く / 同じ byte 列でも text なら拾う★
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _mk(root, "img.png", b"\x89PNG\x00\x00" + NEEDLE + b"tail")
        rc_t, out_t = judge(root, _roster(root, []))
        check("S4-真 binary は拾わぬ", rc_t, PASS, "= 偶然の byte 一致で赤を出さぬ")
        _mk(root, "img.png", b"\x89PNG" + NEEDLE + b"tail")   # NUL を抜く = text 扱い
        rc_f, _ = judge(root, _roster(root, []))
        check("S4-偽 NUL を抜けば拾う", rc_f, NG, "= 拡張子で切っておらぬ事の証")

    # ── S5: ★canary が死ねば PASS と名乗らぬ★ (本 selftest の本命)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _mk(root, "clean.md", b"nothing here\n")
        rc_t, _ = judge(root, _roster(root, []))
        check("S5-真 綺麗な盤面は緑", rc_t, PASS, "")
        rc_f, out_f = judge(root, _roster(root, []), canary=lambda: (False, "偽装した死"))
        check("S5-偽 canary が死ねば緑を名乗らぬ", rc_f, UNDET, "★0 件でも緑にせぬ★")
        undet_named = any("FFFD-CANARY" in l and "UNDETERMINED" in l for l in out_f)
        check("S5-偽 未検分が【名を出す】", 0 if undet_named else 1, 0, "")

    # ── S6: ★名簿が読めねば何も除かぬ★ (黙って緑にならぬ)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        line = b"broken " + NEEDLE
        _mk(root, "a.md", line + b"\n")
        rc_f, out_f = judge(root, root / "no_such_roster.yaml")
        check("S6-偽 名簿が無ければ除かぬ", rc_f, NG, "")
        noted = any("FFFD-ROSTER" in l for l in out_f)
        check("S6-偽 除いておらぬ事を名乗る", 0 if noted else 1, 0, "")
        # 壊れた名簿 (yaml として不正) でも門は落ちず、除かぬ側へ倒れる
        bad = root / "bad.yaml"
        bad.write_bytes("sites: [これは: 壊れて: おる\n".encode("utf-8"))
        rc_b, _ = judge(root, bad)
        check("S6-偽 壊れた名簿でも門は落ちず赤", rc_b, NG, "= 例外で門ごと死なぬ")

    # ── S7: ★名簿の腐り (stale) を名指す★
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _mk(root, "clean.md", b"nothing\n")
        rc, out = judge(root, _roster(root, [("gone.md", "0" * 64)]))
        check("S7-真 stale が在っても rc は動かさぬ", rc, PASS, "= 匿う力が無いゆえ")
        staled = any("FFFD-STALE" in l for l in out)
        check("S7-真 stale を【名指す】", 0 if staled else 1, 0, "= 黙れば名簿が腐る")

    # ── S8: ★拡張子で切っておらぬ★ (.bak / .log / 拡張子無し)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        for rel in ("ledger.yaml.bak_cmd1099", "logs/ntfy_send.log", "noext"):
            _mk(root, rel, b"x " + NEEDLE + b"\n")
        rc, out = judge(root, _roster(root, []))
        check("S8-偽 3 本とも赤で挙がる", rc, NG, "")
        n = sum(1 for l in out if l.strip().startswith(("ledger.yaml.bak", "logs/ntfy_send.log", "noext")))
        check("S8-偽 3 本すべてが名を出す", 0 if n == 3 else 1, 0, f"実測={n}")

    # ── S9: ★連の長さを出す★ (二族を混ぜぬための材料)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _mk(root, "a.md", b"one " + NEEDLE + b" / three " + NEEDLE * 3 + b"\n")
        _, out = judge(root, _roster(root, []))
        got3 = any("最長連=3" in l for l in out)
        check("S9-偽 最長連を名乗る", 0 if got3 else 1, 0, "= 連長 1 と 2〜3 は別の事故")

    print(f"=== selftest: OK={ok} NG={ng} ===")
    return PASS if ng == 0 else NG


# ────────────────────────────────────────────────────────────── main

def main() -> int:
    ap = argparse.ArgumentParser(description="U+FFFD を持つ箇所のうち名簿に無い物を名指す (直さぬ)")
    ap.add_argument("--root", default=None, help="走査の根 (既定 = 本 script の親の親)")
    ap.add_argument("--roster", default=None, help=f"名簿 (既定 = {ROSTER_REL})")
    ap.add_argument("--list", action="store_true", help="見つけた箇所を全数列挙 (名簿の種)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()

    root = Path(a.root).resolve() if a.root else Path(__file__).resolve().parent.parent
    roster = Path(a.roster).resolve() if a.roster else root / ROSTER_REL

    if a.list:
        ok, cnote = run_canary()
        print(f"[FFFD-CANARY] {cnote}")
        if not ok:
            return UNDET
        sites, stat = scan(root)
        entries, rnote = load_roster(roster)
        if rnote:
            print(f"[FFFD-ROSTER] {rnote}")
        for s in sites:
            tag = "名簿済" if (s["path"], s["sha256"]) in entries else "★未名指し★"
            print(f"{tag}  {s['path']}:{s['line']}  実体={s['occ']} 最長連={s['run_max']}")
            print(f"        sha256: {s['sha256']}")
            print(f"        ...{s['ctx']}...")
        print(f"# text={stat['files']} binary除外={stat['binary']} 箇所={len(sites)}")
        return PASS

    rc, out = judge(root, roster)
    for line in out:
        print(line)
    return rc


if __name__ == "__main__":
    sys.exit(main())
