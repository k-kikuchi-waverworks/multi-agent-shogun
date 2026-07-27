#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""anchor_shrink.py — ★錨を【意味の単位で、行末に接せぬ最短】へ絞るための口★ (cmd_1387 系統・cmd_1413)

★何ゆえ此の口が在るか (2026-07-27 12:55 の実害)★:
  六号が gate_nightly.sh の一行の ★後ろへ条件を足しただけ★ で、
  ★己の牙 2 本 (MUT-1409-NA5/NA6) の錨が hit=0 へ落ちた★ = ★己の commit が己の牙を鈍らせた★。
  ★機序★= 二本とも ★錨が行末まで含んでおった★ =
    ★同じ行の後ろへ誰かが 1 語 足した其の瞬間に、錨の綴りは盤面から消える★。
  ⇒ ★族の芯は【錨の長さ】に在る★ (家老 13:11 の裁で cmd_1387 の系統へ据えられた)。

★家老の裁 (13:11・13:12)★:
  ・★一斉置換はせぬ★ = ★73 本を一度に触れば、其の commit が他人の牙を鈍らせる (12:55 の形の 73 倍)★
  ・規は二つ = ①新しく書く時は最小の一意な綴りへ ②鈍った時は gate-3 が其の場で名指す
  ・★★足す物は一つ = 「触れる者が其の場で絞る」時に機械へ問える口★★ ← 本 script が之である

★★機械の最短を其のまま採るな (六号 13:09 の実測)★★:
  台帳 shogun の行末錨 57 本の「一意になる最短」は ★最小 2 字・中央 13 字★ =
  ★2 字の綴りは【今日の file の中でだけ】一意である★ ⇒ ★file が育てば黙って非一意へ転じる★
  = ★★鈍りの穴を塞いで【誤爆の穴】を開ける形★★。
  ⇒ 本 script は ★機械の最短★ と ★推し (語の切れ目で切った物)★ の ★両方★ を出し、
    ★推しを既定として名乗る★。★選ぶのは人である★。

usage:
  # 台帳の entry ひとつを診る
  python3 scripts/anchor_shrink.py --id MUT-1409-NA5
  # 冊ぜんたいを数える (家老へ渡す母数)
  python3 scripts/anchor_shrink.py --census
  # 別冊を診る
  python3 scripts/anchor_shrink.py --census --registry <path> --repo-root <path>
  # 素の綴りを診る (台帳に無い錨)
  python3 scripts/anchor_shrink.py --file scripts/foo.sh --anchor-file /tmp/a.txt
exit 0 = 診た / 1 = 診られなんだ (★見えぬは緑ではない★)
"""
from __future__ import annotations

import argparse
import ast
import pathlib
import re
import sys

import yaml

# ★錨の綴り★= old / a など、木に現に在る形を拾う (書き手ごとに違うゆえ)
OLD_RE = re.compile(r"^\s*(?:old|a)\s*=\s*(.+?)\s*$", re.M)
# ★対象 file★= pathlib.Path("…") 形と p = "…" 形の両方
PATH_RE = re.compile(r'pathlib\.Path\((["\'])(.+?)\1\)|^\s*p\s*=\s*(["\'])(.+?)\3\s*$', re.M)
SED_RE = re.compile(r"sed -i\s+(['\"])(.+?)\1", re.S)


def parse_entry(mut: str):
    """mutate から (錨, 対象 path) を解く。解けねば (None, 理由)。"""
    mo, mp = OLD_RE.search(mut or ""), PATH_RE.search(mut or "")
    if not mo or not mp:
        if SED_RE.search(mut or ""):
            return None, "sed 形 (本 script は python 形の錨のみ診る)"
        return None, "old= も Path( も読めぬ形"
    raw = mo.group(1)
    if raw.startswith("("):          # ★行を跨ぐ連結 literal★
        tail, depth = mut[mo.end():], raw.count("(") - raw.count(")")
        for line in tail.split("\n"):
            if depth <= 0:
                break
            raw += "\n" + line
            depth += line.count("(") - line.count(")")
    try:
        old = ast.literal_eval(raw)
    except Exception:
        try:
            old = ast.literal_eval("(" + raw + ")")
        except Exception:
            return None, f"literal を解けぬ: {raw[:40]}"
    return (old, mp.group(2) or mp.group(4)), None


def _is_word(ch: str) -> bool:
    return ch.isalnum() or ch == "_"


def analyze(text: str, anchor: str) -> dict:
    """★錨を診る★ — 戻り値は機械可読の dict (人向けの刷りは format_report が受け持つ)。"""
    i = text.find(anchor)
    if i < 0:
        return {"ok": False, "why": "錨が盤面に無い (hit=0) = ★既に鈍っておる★"}
    hits = text.count(anchor)
    if hits != 1:
        return {"ok": False, "why": f"錨が一意でない (hit={hits}) = ★狙うた場所へ当たらぬ★"}
    end = i + len(anchor)
    touches_eol = anchor.endswith("\n") or end >= len(text) or text[end] == "\n"

    machine = word = None
    for k in range(1, len(anchor) + 1):
        pre = anchor[:k]
        if text.count(pre) != 1:
            continue
        p_end = i + k
        if pre.endswith("\n") or p_end >= len(text) or text[p_end] == "\n":
            continue                      # ★行末に接する prefix は【同じ病】ゆえ採らぬ★
        if machine is None:
            machine = pre
        # ★語の切れ目★= 識別子の途中で切っておらぬ (前後のどちらかが語を成す字でない)
        if k >= len(anchor):
            at_boundary = True
        else:
            at_boundary = (not _is_word(pre[-1])) or (not _is_word(anchor[k]))
        if at_boundary:
            word = pre
            break
    return {
        "ok": True,
        "hits": hits,
        "len": len(anchor),
        "touches_eol": touches_eol,
        "machine_min": machine,
        "recommended": word or machine,
    }


def format_report(anchor: str, path: str, r: dict) -> list[str]:
    if not r["ok"]:
        return [f"★診られなんだ★ {path}: {r['why']}"]
    out = [
        f"対象   : {path}",
        f"今の錨 : {len(anchor)} 字 / 行末に接して{'おる ★之が鈍りの因である★' if r['touches_eol'] else 'おらぬ (★既に安全な形★)'}",
    ]
    if not r["touches_eol"]:
        out.append("⇒ ★絞る要は無い★ (行末に接しておらぬ錨は、其の行の後ろへ足されても消えぬ)")
        return out
    if r["recommended"] is None:
        out.append("⇒ ★★絞れぬ★★= 行末に接せぬ一意な prefix が無い = ★別の場所を錨に採れ★")
        return out
    out += [
        f"★推し★ : {len(r['recommended'])} 字 = {r['recommended']!r}",
        f"(機械の最短 = {len(r['machine_min'])} 字 = {r['machine_min']!r})",
        "★機械の最短を其のまま採るな★= ★今日の file の中でだけ一意な綴りは、file が育てば黙って非一意へ転じる★",
        "  = ★鈍りの穴を塞いで【誤爆の穴】を開ける★ ⇒ ★語の切れ目まで含めた【推し】を既定とせよ★",
    ]
    return out


def census(reg: str, root: pathlib.Path) -> int:
    d = yaml.safe_load(open(reg, encoding="utf-8")) or {}
    ents = d.get("mutations") or []
    eol, safe, shrinkable, stuck, unread = [], [], [], [], []
    for e in ents:
        parsed, why = parse_entry(e.get("mutate") or "")
        if parsed is None:
            unread.append((e["id"], why))
            continue
        anchor, rel = parsed
        f = root / rel
        if not f.exists():
            unread.append((e["id"], f"対象 file が此の木に無い ({rel})"))
            continue
        r = analyze(f.read_text(encoding="utf-8", errors="replace"), anchor)
        if not r["ok"]:
            unread.append((e["id"], r["why"]))
            continue
        if not r["touches_eol"]:
            safe.append(e["id"])
            continue
        eol.append(e["id"])
        (shrinkable if r["recommended"] else stuck).append(e["id"])
    print(f"★母数★= 台帳 {len(ents)} 本 (registry={reg} / root={root})")
    print(f"  ★行末に接する錨 = {len(eol)} 本★ / 接せぬ = {len(safe)} 本 "
          f"/ ★読めなんだ = {len(unread)} 本 (★数えられておらぬ = 0 ではない★)★")
    print(f"  └ うち ★絞れる = {len(shrinkable)} 本★ / ★★絞れぬ = {len(stuck)} 本★★")
    if stuck:
        print("  ── ★絞れぬ (別の場所を錨に採る要が在る)★ ──")
        for eid in stuck:
            print(f"     {eid}")
    if unread:
        print("  ── 読めなんだ ──")
        for eid, why in unread:
            print(f"     {eid:22s} {why}")
    return 0


def selftest() -> int:
    """★塞ぐ側と通す側の両方を撃つ★ (据えただけでは足りぬ)。"""
    cases = []
    text = 'if [ "$a" -eq 1 ]; then exit 1; fi\nif [ "$b" -ne 0 ]; then exit 2; fi\n'
    r = analyze(text, 'if [ "$a" -eq 1 ]; then exit 1; fi')
    cases.append(("行末に接する錨は其れと名乗る", r["ok"] and r["touches_eol"]))
    cases.append(("推しは行末に接せぬ", r["recommended"] is not None
                  and not r["recommended"].endswith("\n")))
    cases.append(("推しは一意", text.count(r["recommended"]) == 1))
    cases.append(("推しは機械の最短より短くない", len(r["recommended"]) >= len(r["machine_min"])))
    r2 = analyze(text, 'if [ "$a" -eq 1 ]')
    cases.append(("行末に接せぬ錨は【要無し】と名乗る", r2["ok"] and not r2["touches_eol"]))
    r3 = analyze(text, "no_such_anchor")
    cases.append(("盤面に無い錨は ok=False", r3["ok"] is False))
    r4 = analyze(text, "; then exit ")
    cases.append(("一意でない錨は ok=False", r4["ok"] is False))
    ng = [n for n, v in cases if not v]
    for n, v in cases:
        print(f"  {'OK ' if v else 'NG '} {n}")
    print(f"--- {len(cases) - len(ng)}/{len(cases)} PASS")
    if ng:
        print("NG が在る = ★此の口は信用できぬ★")
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--id", help="台帳の entry id (例 MUT-1409-NA5)")
    ap.add_argument("--registry", default="config/mutation_registry.yaml")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--file", help="素の対象 file (台帳を通さぬ時)")
    ap.add_argument("--anchor-file", help="錨の綴りを収めた file (shell を通さぬため)")
    ap.add_argument("--census", action="store_true", help="冊ぜんたいを数える")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    root = pathlib.Path(a.repo_root)

    if a.selftest:
        return selftest()
    if a.census:
        return census(a.registry, root)
    if a.file and a.anchor_file:
        anchor = pathlib.Path(a.anchor_file).read_text(encoding="utf-8")
        f = root / a.file
        if not f.exists():
            print(f"★対象 file が無い★: {f}", file=sys.stderr)
            return 1
        for line in format_report(anchor, str(f), analyze(f.read_text(encoding="utf-8"), anchor)):
            print(line)
        return 0
    if not a.id:
        ap.error("--id / --census / --selftest / (--file と --anchor-file) の何れかを与えよ")

    d = yaml.safe_load(open(a.registry, encoding="utf-8")) or {}
    ent = next((e for e in (d.get("mutations") or []) if e.get("id") == a.id), None)
    if ent is None:
        print(f"★台帳に {a.id} が居らぬ★ ({a.registry})", file=sys.stderr)
        return 1
    parsed, why = parse_entry(ent.get("mutate") or "")
    if parsed is None:
        print(f"★診られなんだ★ {a.id}: {why}", file=sys.stderr)
        return 1
    anchor, rel = parsed
    f = root / rel
    if not f.exists():
        print(f"★対象 file が此の木に無い★: {f}", file=sys.stderr)
        return 1
    print(f"[{a.id}] 疑い = {ent.get('suspected_by', '(名無し)')}")
    for line in format_report(anchor, str(f), analyze(f.read_text(encoding="utf-8"), anchor)):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
