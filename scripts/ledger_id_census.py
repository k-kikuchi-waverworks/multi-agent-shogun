#!/usr/bin/env python3
"""台帳の id を数える物差し (cmd_1386)。

★何故 別に script を立てたか★ =
拙者 (足軽三号) が cmd_1386 の測定で使うた id 正規表現は、
`ref:MUT-1330-R3-M1〜M5` を **1 件へ潰しておった** (id を `ref:MUT-1330-R3` までしか読まなんだ)。
(ref: = 他の木 (backend) の実例を引いておるだけの印。cmd_1387・家老 18:10 の裁2)
= ★枷1「id を 1 本も失わぬ」を破ったのは案ではなく拙者の物差しであった★。

手2 (実際の分割) では **同じ物差しで 178/178 を突合する**。
ゆえに ★物差しそのものを、対照つきで検める道具★ を残す。

使い方:
  python3 scripts/ledger_id_census.py --selftest
      ★物差しの検分★ (対照つき = 壊れた旧物差しを当てて【落ちること】まで確かめる)
  python3 scripts/ledger_id_census.py --census <台帳path> [...]
      台帳の id 全数・族の内訳・重複を出す (単一 file / .d 群 の両形)
  python3 scripts/ledger_id_census.py --compare <旧台帳path> <新台帳path>
      2 つの盤面の id 集合を突合する (手2 の分割前後で 178/178 を示す用)

★真空 PASS 禁★ = 台帳が無い / id が 0 件 は「OK」でなく ★FAIL★ を返す。
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

# ★是正後の物差し★ — 末尾の枝 (-M1 / -R3-M1 / -W2-001) まで読み切る。
#   (?<![A-Za-z0-9]) = 長い綴りの途中を拾わぬ。
ID_RE = re.compile(r"(?<![A-Za-z0-9])MUT-[0-9]+[A-Za-z]*(?:-[A-Za-z0-9]+)+")

# ★族★ = MUT-<cmd>-… の <cmd> 部 (1369E の様な英字つきも読む)
FAMILY_RE = re.compile(r"^MUT-([0-9]+[A-Za-z]*)-")

# ★壊れた旧物差し (対照専用・実務では使わぬ)★ =
#   枝を 1 つしか読まぬゆえ ref:MUT-1330-R3-M1〜M5 が全て "ref:MUT-1330-R3" へ潰れる。
BROKEN_ID_RE = re.compile(r"(?<![A-Za-z0-9])MUT-[0-9]+[A-Za-z]*-[A-Za-z0-9]+")


def _load_gate_module():
    """gate_mutation_replay を読み込む (台帳の読み方を ★gate と 1 本に揃える★ ため)。"""
    p = SCRIPT_DIR / "gate_mutation_replay.py"
    spec = importlib.util.spec_from_file_location("gmr_for_census", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ids_from_ledger(path: Path):
    """(ids, error) — 台帳 (単一 file / .d 群) の id を ★YAML を正として★ 読む。"""
    gmr = _load_gate_module()
    doc, err, present = gmr.resolve_registry_doc(path)
    if err:
        return None, err
    if not present:
        return None, f"台帳が無い: {path}"
    if not isinstance(doc, dict) or not isinstance(doc.get("mutations"), list):
        return None, "台帳に mutations: リストが無い"
    ids = []
    for e in doc["mutations"]:
        if not isinstance(e, dict):
            return None, "entry が mapping でない"
        if not e.get("id"):
            return None, "id を欠く entry が在る (数えられぬ)"
        ids.append(str(e["id"]))
    if not ids:
        return None, "id が 0 件 (0 件は PASS ではない)"
    return ids, None


def family_of(mid: str) -> str | None:
    m = FAMILY_RE.match(mid)
    return m.group(1) if m else None


def census(paths: list[Path]) -> int:
    rc = 0
    for p in paths:
        ids, err = ids_from_ledger(p)
        if err:
            print(f"[id census] ★FAIL★ {p}: {err}")
            rc = 1
            continue
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        fams = collections.Counter()
        unreadable = []
        for i in ids:
            f = family_of(i)
            if f is None:
                unreadable.append(i)
            else:
                fams[f] += 1
        # ★物差しの自己検分★: YAML を正として読んだ id が、
        #   是正後の正規表現でも 1 本残らず読めるか (読めねば物差しが欠けておる)
        unmatched = [i for i in ids if not ID_RE.fullmatch(i)]
        print(f"[id census] {p}")
        print(f"    id 全数 = {len(ids)} / 族 = {len(fams)}")
        print(f"    族の内訳 = {dict(sorted(fams.items()))}")
        if dupes:
            print(f"    ★FAIL★ id 重複 = {dupes}")
            rc = 1
        if unreadable:
            print(f"    ★FAIL★ 族が読めぬ id = {unreadable}")
            rc = 1
        if unmatched:
            print(f"    ★FAIL★ 物差し (正規表現) が読み切れぬ id = {unmatched}")
            rc = 1
        if not dupes and not unreadable and not unmatched:
            print("    ok (重複なし・族すべて読めた・物差しが全 id を読み切った)")
    return rc


def compare(old: Path, new: Path) -> int:
    a, ea = ids_from_ledger(old)
    b, eb = ids_from_ledger(new)
    if ea:
        print(f"[id compare] ★FAIL★ 旧 {old}: {ea}")
        return 1
    if eb:
        print(f"[id compare] ★FAIL★ 新 {new}: {eb}")
        return 1
    sa, sb = set(a), set(b)
    lost, gained = sorted(sa - sb), sorted(sb - sa)
    print(f"[id compare] 旧 {len(a)} 件 / 新 {len(b)} 件")
    print(f"    失った id = {lost}")
    print(f"    増えた id = {gained}")
    if lost or gained:
        print("    ★FAIL★ id 集合が一致せぬ")
        return 1
    if len(a) != len(b):
        print(f"    ★FAIL★ 集合は同じだが件数が違う (重複の疑い): {len(a)} vs {len(b)}")
        return 1
    print("    ok (id 集合・件数とも一致)")
    return 0


# ────────────────────────────────────────────────────────────────
# selftest — ★対照つき★
#   「緑が何も証明しておらぬ」を避ける = ★壊れた物差しを当てて【落ちること】まで見る★
# ────────────────────────────────────────────────────────────────
# ★見本の id は予約帯 (MUT-9999-*) を使う★ (cmd_1387・家老 18:10 の裁1)
#   何故か = 実在の id をそのまま見本に置くと、幽霊 ID 検分が「此の木の申告」と数える。
#   実測 = 本 file だけで 11 件を幽霊 A に数えさせておった。見本が本物の顔をしておった形である。
#   予約帯は台帳に載せられぬ (載せようとすれば schema が拒む) ゆえ、見本と本物が綴りで分かれる。
#   ★枝の形は保つ★ = R3-M1〜M5 (枝つき) と 9999E (英字つき cmd) が本検の要ゆえ、
#   綴りだけ替えて試験の意味は 1 bit も変えておらぬ。
FIXTURE = """
mutations:
  - id: MUT-9999-R3-M1
  - id: MUT-9999-R3-M2
  - id: MUT-9999-R3-M3
  - id: MUT-9999-R3-M4
  - id: MUT-9999-R3-M5
  - id: MUT-9999E-001
  - id: MUT-9999-105
  - id: MUT-9999-W2-001
"""


def selftest() -> int:
    ok = ng = 0

    def expect(name, want, got):
        nonlocal ok, ng
        if want == got:
            ok += 1
            print(f"  ok {name}")
        else:
            ng += 1
            print(f"  ★NG★ {name}: 期待 {want!r} / 実際 {got!r}")

    print("[id census selftest]")

    found = ID_RE.findall(FIXTURE)
    # T1 ★本件の穴そのもの★: 枝つき 5 本が 5 本のまま読めるか
    expect("T1 枝つき見本 5 本が 5 本として読める (1 本へ潰れぬ)",
           5, len({i for i in found if i.startswith("MUT-9999-R3-")}))
    # T2 ★対照 = 壊れた旧物差しを当てる★: 1 本へ潰れることを見る
    broken = {i for i in BROKEN_ID_RE.findall(FIXTURE) if i.startswith("MUT-9999-R3")}
    expect("T2 ★対照★ 壊れた旧物差しは 1 本へ潰れる (= 本検が差を見分ける証)",
           {"MUT-9999-R3"}, broken)
    # T3 ★是正後と旧物差しが違う答えを返す★ = 検が変異に反応する (壊せば落ちる)
    expect("T3 是正後 ≠ 旧物差し (物差しの変異が検に届く)",
           True, set(found) != set(BROKEN_ID_RE.findall(FIXTURE)))
    # T4 全 id が fullmatch する
    expect("T4 fixture の全 id を物差しが読み切る", 8, len(found))
    # T5 族の読み
    expect("T5 族: 枝つき見本 → 9999", "9999", family_of("MUT-9999-R3-M1"))
    expect("T6 族: 英字つき cmd の見本 → 9999E", "9999E", family_of("MUT-9999E-001"))
    # T7 長い綴りの途中を拾わぬ
    expect("T7 XMUT-9999-001 を拾わぬ (綴りの途中を拾わぬ)",
           [], ID_RE.findall("XMUT-9999-001"))
    # T8 枝の無い id は族 shard に載せられぬ = 読めぬこと自体を検知
    expect("T8 枝の無い MUT-9999 は id として読まぬ", [], ID_RE.findall(" MUT-9999 "))
    # T9 ★真空 PASS 禁★: 在らぬ台帳は FAIL
    _ids, err = ids_from_ledger(Path("/nonexistent/mutation_registry.yaml"))
    expect("T9 在らぬ台帳は FAIL (真空 PASS 禁)", True, err is not None)

    print("----")
    if ng == 0:
        print(f"[id census selftest] {ok}/{ok} ALL PASS")
        return 0
    print(f"[id census selftest] FAIL: ok={ok} ng={ng}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--census", nargs="+", type=Path)
    ap.add_argument("--compare", nargs=2, type=Path)
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.census:
        return census(a.census)
    if a.compare:
        return compare(a.compare[0], a.compare[1])
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
