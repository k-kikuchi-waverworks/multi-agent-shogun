#!/usr/bin/env python3
"""gate_mutation_replay.py — gate-2: 「既に赤を確認した変異」の静かな無効化を塞ぐ (cmd_1352)

何を守るか:
  変異試験は「わざと壊せば test が赤くなる」ことを一度は確認する。だが仕様を変えると、
  以前赤くなった変異が【誰にも知られず】素通りするようになる (test は緑のまま=沈黙)。
  実例 = cmd_1330 W0-2 (足軽五号): G2 を二段化した際、G2 を守っておった背骨 test を
  撃ち直さず、実機で 8002 が上がると細工が素通り =「gate 全 PASS = 何も守らぬ test」。
  本 gate は「この変異を当てれば、この試験は必ず赤くなる」を台帳 (config/mutation_registry.yaml)
  に機械可読で登録し、全件を再走して、赤くならなくなった変異を【名指しで】報告する。
  経緯の詳細: docs/content/ops/cmd_1352_silent_pitfall_gates.md

台帳 (出所はこの 1 file のみ — 二重管理禁):
  mutations:
    - id: MUT-xxxx-nnn          # 一意 (重複は UNDETERMINED)
      desc: 何を折るとどの試験が赤くなるべきか
      origin: cmd_xxxx          # 任意
      paths: [scripts]          # repo root からコピーする対象 (この外は scratch に持ち込まぬ)
      mutate: |                 # bash・cwd=scratch。★repo 実体には一切触れぬ (コピーへ当てる)★
        sed -i '...' scripts/foo.sh
      test: |                   # bash・cwd=scratch。変異後に【赤くなるべき】試験
        bash scripts/foo.sh --selftest
      expect: nonzero           # 既定。整数を書けば厳密一致 (例 1)
      timeout: 180              # 任意 (秒)

判定 (三値 — 0件/未判定を緑にせぬ):
  PASS         = baseline 緑 かつ 変異後に赤 (契約どおり)
  FAIL         = ★変異後も緑 = 変異が静かに無効化された★ (名指しで報告)
  UNDETERMINED = baseline が赤 / mutate 失敗 / ★mutate 空振り (何も変えておらぬ=sed の
                 当たり損ねも沈黙する★) / 台帳 0 件 / schema 不備 / timeout
exit: 0 PASS / 1 FAIL あり / 2 UNDETERMINED あり (FAIL 優先)

使い方:
  python3 scripts/gate_mutation_replay.py               # 台帳全件を再走
  python3 scripts/gate_mutation_replay.py --sanity      # 台帳の形だけ検分 (実行なし・pre-commit 用)
  python3 scripts/gate_mutation_replay.py --selftest    # 変異試験つき自己検分
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = REPO_ROOT / "config" / "mutation_registry.yaml"
DEFAULT_TIMEOUT = 180

# CONTRACT: 「変異を当てたのに test が緑」は FAIL である (これを False にすると gate は飾りになる)
GREEN_AFTER_MUTATION_IS_FAIL = True

# CONTRACT: 台帳 0 件は PASS ではない (真空 PASS 禁 — cmd_1342 Phase1d の流儀)
EMPTY_REGISTRY_IS_UNDETERMINED = True

PASS, FAIL, UNDET = "PASS", "FAIL", "UNDETERMINED"
_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc")


def load_registry(path: Path):
    """(entries, error) を返す。error が非 None なら UNDETERMINED。"""
    import yaml
    if not path.is_file():
        return None, f"台帳が無い: {path}"
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as e:  # parse 不能は「0件」ではなく「未判定」
        return None, f"台帳が parse 不能: {e}"
    if not isinstance(data, dict) or not isinstance(data.get("mutations"), list):
        return None, "台帳に mutations: リストが無い"
    entries = data["mutations"]
    if len(entries) == 0 and EMPTY_REGISTRY_IS_UNDETERMINED:
        return None, "台帳が 0 件 (空である・0件は PASS ではない)"
    ids = [e.get("id") for e in entries if isinstance(e, dict)]
    dupes = {i for i in ids if i and ids.count(i) > 1}
    if dupes:
        return None, f"id 重複 (出所が割れておる): {sorted(dupes)}"
    return entries, None


def validate_entry(e) -> str | None:
    if not isinstance(e, dict):
        return "entry が mapping でない"
    for k in ("id", "desc", "paths", "mutate", "test"):
        if not e.get(k):
            return f"必須 field 欠落: {k}"
    if not isinstance(e["paths"], list) or not e["paths"]:
        return "paths が空"
    return None


def copy_paths(repo: Path, paths: list[str], dst: Path) -> str | None:
    for rel in paths:
        src = repo / rel
        if src.is_dir():
            shutil.copytree(src, dst / rel, ignore=_IGNORE)
        elif src.is_file():
            (dst / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst / rel)
        else:
            return f"paths の実体が無い: {rel}"
    return None


def tree_digest(root: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for p in sorted(root.rglob("*")):
        if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc":
            out[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def run_sh(script: str, cwd: Path, timeout: int):
    try:
        r = subprocess.run(["bash", "-c", script], cwd=cwd, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return None, f"timeout {timeout}s"


def evaluate_entry(e, repo: Path, work: Path):
    """1 entry を評価し (verdict, 理由) を返す。repo 実体には触れぬ (コピーの上でのみ壊す)。"""
    err = validate_entry(e)
    if err:
        return UNDET, f"schema 不備: {err}"
    timeout = int(e.get("timeout", DEFAULT_TIMEOUT))
    expect = str(e.get("expect", "nonzero"))

    pristine, base, mut = work / "pristine", work / "base", work / "mut"
    for d in (pristine, base, mut):
        d.mkdir(parents=True)
        err = copy_paths(repo, e["paths"], d)
        if err:
            return UNDET, err

    # ① baseline: 変異前に test は緑であること (赤なら検出力を測れぬ)
    rc, _ = run_sh(e["test"], base, timeout)
    if rc is None:
        return UNDET, "baseline test が timeout"
    if rc != 0:
        return UNDET, f"baseline が赤 (exit {rc}) = 変異前から落ちており検出力を測れぬ"

    # ② mutate をコピーへ当てる
    rc, out = run_sh(e["mutate"], mut, timeout)
    if rc is None:
        return UNDET, "mutate が timeout"
    if rc != 0:
        return UNDET, f"mutate 自体が失敗 (exit {rc}): {out.strip()[:200]}"

    # ③ ★空振り検知★: mutate が 1 byte も変えておらねば「赤くなるか」を測っておらぬ
    #    (sed の当たり損ねは沈黙する — これ自体が本 gate が塞ぐ「沈黙する落とし穴」の一種)
    if tree_digest(pristine) == tree_digest(mut):
        return UNDET, "mutate 空振り (何も変えておらぬ) = pattern の当たり損ね。mutate を直せ"

    # ④ 変異後に test は赤くなるべき
    rc, _ = run_sh(e["test"], mut, timeout)
    if rc is None:
        return UNDET, "変異後 test が timeout"
    if expect == "nonzero":
        if rc != 0:
            return PASS, f"変異後 exit {rc} (赤) = 契約どおり"
        if GREEN_AFTER_MUTATION_IS_FAIL:
            return FAIL, "★変異後も緑 = この変異は静かに無効化された。仕様変更が試験の牙を折っておる★"
        return PASS, "(契約無効化中)"
    else:
        if rc == int(expect):
            return PASS, f"変異後 exit {rc} = 期待 {expect} と一致"
        return FAIL, f"変異後 exit {rc} ≠ 期待 {expect} (赤の出方が契約とずれた)"


def run_all(registry: Path, repo: Path) -> int:
    entries, err = load_registry(registry)
    if err:
        print(f"[gate-2] UNDETERMINED: {err}")
        print("  処方: 台帳 config/mutation_registry.yaml を検めよ。空にする変更をしたなら、その変更こそ疑え。")
        return 2
    n_pass = n_fail = n_undet = 0
    for e in entries:
        eid = e.get("id", "?") if isinstance(e, dict) else "?"
        with tempfile.TemporaryDirectory(prefix="mutreplay_") as w:
            verdict, why = evaluate_entry(e, repo, Path(w))
        mark = {PASS: "ok  ", FAIL: "★NG★", UNDET: "未定 "}[verdict]
        print(f"  {mark} {verdict:12s} {eid}: {why}")
        if verdict == PASS:
            n_pass += 1
        elif verdict == FAIL:
            n_fail += 1
        else:
            n_undet += 1
    total = n_pass + n_fail + n_undet
    if n_fail:
        print(f"[gate-2] FAIL: {total} 件中 ★無効化された変異 {n_fail} 件★ (PASS {n_pass} / UNDETERMINED {n_undet})")
        print("  処方: 名指しされた変異の test を仕様変更へ追随させ、再び赤くなることを確認して台帳を維持せよ。")
        print("        変異が正当に不要になったのなら、台帳から【理由を commit log に書いて】外せ (黙って外すな)。")
        return 1
    if n_undet:
        print(f"[gate-2] UNDETERMINED: {total} 件中 未判定 {n_undet} 件 (PASS {n_pass}) — ★未判定は緑ではない★")
        return 2
    print(f"[gate-2] PASS: 台帳 {total} 件すべて『壊せば落ちる』を維持 (registry={registry})")
    return 0


def sanity(registry: Path) -> int:
    """実行なしの軽量検分 (pre-commit 用): 台帳が在り・0件でなく・schema が立っておるか。"""
    entries, err = load_registry(registry)
    if err:
        print(f"[gate-2 sanity] UNDETERMINED: {err}")
        return 2
    bad = [(e.get("id", "?") if isinstance(e, dict) else "?", validate_entry(e))
           for e in entries if validate_entry(e)]
    if bad:
        for eid, why in bad:
            print(f"[gate-2 sanity] UNDETERMINED: {eid}: {why}")
        return 2
    print(f"[gate-2 sanity] OK: 台帳 {len(entries)} 件・schema 健全 (実行は cron 側で行う)")
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# selftest — 小さな遊び場 repo + 台帳を組み、runner 自身を subprocess で撃つ。
# T2 が cmd_1330 W0-2 の実事故 (変異の静かな無効化) の再現である。
# ─────────────────────────────────────────────────────────────────────────────
def _mk_playground(root: Path, victim_exit: int = 0) -> Path:
    repo = root / "repo"
    repo.mkdir(parents=True)
    (repo / "tool.sh").write_text(f"#!/bin/bash\n# MARKER_LINE\nexit {victim_exit}\n")
    (repo / "check.sh").write_text("#!/bin/bash\nbash tool.sh\n")
    return repo


def _entry(eid: str, mutate: str, test: str = "bash check.sh", expect: str = "nonzero"):
    return {"id": eid, "desc": eid, "paths": ["tool.sh", "check.sh"],
            "mutate": mutate, "test": test, "expect": expect}


def _write_reg(path: Path, entries: list) -> None:
    import yaml
    path.write_text(yaml.safe_dump({"mutations": entries}, allow_unicode=True))


def _invoke(args: list[str]) -> tuple[int, str]:
    r = subprocess.run([sys.executable, str(Path(__file__).resolve())] + args,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return r.returncode, r.stdout


def selftest() -> int:
    ok = ng = 0

    def expect(name: str, want_rc: int, got_rc: int, needle: str = "", output: str = ""):
        nonlocal ok, ng
        if got_rc != want_rc:
            print(f"  NG {name}: exit {got_rc} (期待 {want_rc})")
            ng += 1
            return
        if needle and needle not in output:
            print(f"  NG {name}: 出力に「{needle}」が無い")
            ng += 1
            return
        print(f"  ok {name}")
        ok += 1

    with tempfile.TemporaryDirectory(prefix="mutreplay_selftest_") as td:
        T = Path(td)

        # T1: 健全な台帳 (変異→赤) → PASS
        repo = _mk_playground(T / "t1")
        reg = T / "t1reg.yaml"
        _write_reg(reg, [_entry("MUT-T1", "sed -i 's/exit 0/exit 1/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T1 健全な変異契約=PASS", 0, rc, "PASS", out)

        # T2: ★実事故の再現★ 変異が牙を失っておる (無関係な行しか変えぬ) → FAIL + 名指し
        repo = _mk_playground(T / "t2")
        reg = T / "t2reg.yaml"
        _write_reg(reg, [_entry("MUT-T2-NEUTERED", "sed -i 's/MARKER_LINE/MARKER_MOVED/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T2 静かな無効化=FAIL", 1, rc, "MUT-T2-NEUTERED", out)
        expect("T2b 無効化の文言", 1, rc, "静かに無効化", out)

        # T3: ★台帳 0 件 → UNDETERMINED (0件を緑にせぬ)★
        repo = _mk_playground(T / "t3")
        reg = T / "t3reg.yaml"
        _write_reg(reg, [])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T3 台帳0件=UNDETERMINED", 2, rc, "0 件", out)

        # T4: 台帳 file 不在 → UNDETERMINED
        rc, out = _invoke(["--registry", str(T / "ghost.yaml"), "--repo-root", str(repo)])
        expect("T4 台帳不在=UNDETERMINED", 2, rc)

        # T5: baseline が赤 → UNDETERMINED (緑と数えぬ)
        repo = _mk_playground(T / "t5", victim_exit=1)
        reg = T / "t5reg.yaml"
        _write_reg(reg, [_entry("MUT-T5", "sed -i 's/exit 1/exit 2/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T5 baseline赤=UNDETERMINED", 2, rc, "baseline が赤", out)

        # T6: ★mutate 空振り (sed が何にも当たらぬ) → UNDETERMINED★
        repo = _mk_playground(T / "t6")
        reg = T / "t6reg.yaml"
        _write_reg(reg, [_entry("MUT-T6", "sed -i 's/NO_SUCH_PATTERN_XYZ/zzz/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T6 mutate空振り=UNDETERMINED", 2, rc, "空振り", out)

        # T7: expect 厳密一致とずれる → FAIL
        repo = _mk_playground(T / "t7")
        reg = T / "t7reg.yaml"
        _write_reg(reg, [_entry("MUT-T7", "sed -i 's/exit 0/exit 1/' tool.sh", expect="3")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T7 期待コード不一致=FAIL", 1, rc, "MUT-T7", out)

        # T8: id 重複 → UNDETERMINED (出所を1つに)
        repo = _mk_playground(T / "t8")
        reg = T / "t8reg.yaml"
        _write_reg(reg, [_entry("MUT-DUP", "sed -i 's/exit 0/exit 1/' tool.sh"),
                         _entry("MUT-DUP", "sed -i 's/exit 0/exit 2/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T8 id重複=UNDETERMINED", 2, rc, "重複", out)

        # T9: --sanity は 0 件を緑にせぬ
        rc, out = _invoke(["--sanity", "--registry", str(T / "t3reg.yaml")])
        expect("T9 sanityも0件=UNDETERMINED", 2, rc)
        rc, out = _invoke(["--sanity", "--registry", str(T / "t1reg.yaml")])
        expect("T9b sanity健全台帳=OK", 0, rc)

    print("----")
    if ng == 0:
        print(f"[gate-2 selftest] {ok}/{ok} ALL PASS")
        return 0
    print(f"[gate-2 selftest] FAIL: ok={ok} ng={ng}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    ap.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    ap.add_argument("--sanity", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.sanity:
        return sanity(a.registry)
    return run_all(a.registry, a.repo_root)


if __name__ == "__main__":
    sys.exit(main())
