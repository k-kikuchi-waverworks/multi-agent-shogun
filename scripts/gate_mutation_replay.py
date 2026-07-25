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
      red_needle: "not ok 1 X"  # 任意。★赤の理由が変異を名指ししておるか★の検分 (原理(iii)):
                                # 変異後の test 出力にこの文字列が無ければ「別の理由で偶然赤い」
                                # 疑いとして FAIL (cmd_1350 五号の教訓 = 実効は【失敗出力が
                                # 変異内容を名指しするか】で取る。行移動型変異は diff 目視に効かぬ)
      timeout: 180              # 任意 (秒)
  coverage_positive_control: <relpath>   # 任意 (top-level)。--coverage の陽性対照の差し替え。
                                         # 既定は本 file 自身ゆえ、本 file を持たぬ repo の台帳
                                         # (cmd_1355 backend 延長) では必須になる

判定 (三値 — 0件/未判定を緑にせぬ):
  PASS         = baseline 緑 かつ 変異後に赤 (契約どおり・red_needle があれば名指しまで確認)
  FAIL         = ★変異後も緑 = 変異が静かに無効化された★ (名指しで報告) /
                 赤いが red_needle 不在 = 別の理由で偶然赤い疑い
  UNDETERMINED = baseline が赤 / mutate 失敗 / ★mutate 空振り (何も変えておらぬ=sed の
                 当たり損ねも沈黙する★) / 台帳 0 件 / schema 不備 / timeout
exit: 0 PASS / 1 FAIL あり / 2 UNDETERMINED あり (FAIL 優先)

使い方:
  python3 scripts/gate_mutation_replay.py               # 台帳全件を再走
  python3 scripts/gate_mutation_replay.py --sanity      # 台帳の形だけ検分 (実行なし・pre-commit 用)
  python3 scripts/gate_mutation_replay.py --coverage    # 台帳登録検知 (cmd_1352b): 変異testらしき
                                                        #   file が台帳に無ければ名指しで警告
  python3 scripts/gate_mutation_replay.py --selftest    # 変異試験つき自己検分
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
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

# ─────────────────────────────────────────────────────────────────────────────
# gate-2 付帯: 台帳登録検知 (--coverage) — cmd_1352b (caveat C4 への家老裁定)
# 「変異testらしきものが在るのに台帳に無い」を検知して警告する層。強制はせぬ
# (登録必須化は形骸化を生む) — cmd_1336 の detect→warn 流儀に倣う。
# 検出規則の正本はここ (出所を1つに)。人向けの定義・限界・誤検知実測は
# docs/content/ops/cmd_1352_silent_pitfall_gates.md「台帳登録検知」節。
# ─────────────────────────────────────────────────────────────────────────────
COVERAGE_EXTS = {".sh", ".bash", ".py", ".bats"}  # 実行可能な test の宿る拡張子のみ (prose/YAML 対象外)
COVERAGE_MUT_KEYWORDS = r"変異試験|変異を当て|わざと壊|壊して赤|壊せば落ち|mutation"
COVERAGE_SELFTEST_MARKERS = r"--selftest|def selftest|selftest\(\)"
COVERAGE_D1_NEGATIVE = r"(?:without|no|not)\s+mutation"  # データ変異の意 ("without mutation" 等) を除く
# D3 (cmd_1355 backend 台帳延長): pytest 型の変異test (backend の test_cmd_1350_* 等) は
# bats でも selftest 宣言でもないゆえ D1/D2 の網に掛からぬ = backend を見ても常に 0 件だった。
# 実測 2026-07-26: この規則で backend 7 件 / shogun 0 件 (既存運用の誤検知増はゼロ)。
COVERAGE_D3_PYTEST_DEF = r"(?m)^\s*def test_\w+"
# 陽性対照: 既定は本 file 自身 (selftest T2 = 変異試験を永続内蔵)。これが検出されねば検出規則の
# 牙が折れておる = 0件検出もここへ畳んで UNDETERMINED (真空 PASS 禁・対照を必ず置く流儀)。
# ★他 repo の台帳 (cmd_1355 backend 延長) では本 file が存在せぬため、台帳側 top-level key
# `coverage_positive_control:` で対照を差し替えられる (出所は台帳 = 1つ)★
COVERAGE_POSITIVE_CONTROL = "scripts/gate_mutation_replay.py"

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
    rc, out = run_sh(e["test"], base, timeout)
    if rc is None:
        return UNDET, "baseline test が timeout"
    if rc != 0:
        # 尻尾を添える: repo 跨ぎ entry (cmd_1355) では「venv 不在」「rubric 不在」等の
        # 空振り理由がここに出る。exit code だけでは家老が原因へ辿れぬ
        tail = " / ".join(out.strip().splitlines()[-2:])[:200] if out.strip() else ""
        return UNDET, f"baseline が赤 (exit {rc}) = 変異前から落ちており検出力を測れぬ" + (
            f" | {tail}" if tail else "")

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
    rc, out = run_sh(e["test"], mut, timeout)
    if rc is None:
        return UNDET, "変異後 test が timeout"
    red = (rc != 0) if expect == "nonzero" else (rc == int(expect))
    if not red:
        if expect != "nonzero":
            return FAIL, f"変異後 exit {rc} ≠ 期待 {expect} (赤の出方が契約とずれた)"
        if GREEN_AFTER_MUTATION_IS_FAIL:
            return FAIL, "★変異後も緑 = この変異は静かに無効化された。仕様変更が試験の牙を折っておる★"
        return PASS, "(契約無効化中)"
    # ⑤ 名指し検分 (red_needle・任意) — 原理(iii): 赤の理由が当てた変異を名指ししておるか。
    #    「別の理由で偶然赤い」を「変異が効いた」と誤認せぬため (cmd_1350 五号の教訓:
    #    行移動型変異は diff 目視に効かぬ。実効は【失敗出力が変異内容を名指しするか】で取る)
    needle = e.get("red_needle")
    if needle:
        if str(needle) not in out:
            return FAIL, f"赤いが名指しが無い (出力に「{needle}」不在) = 別の理由で偶然赤い疑い"
        return PASS, f"変異後 exit {rc} (赤) + 名指し「{needle}」確認 = 契約どおり"
    return PASS, f"変異後 exit {rc} (赤) = 契約どおり (red_needle 未設定=名指し検分なし)"


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


def scan_mutation_test_candidates(repo: Path):
    """git 追跡下の「変異testらしき file」を検出し (候補 {relpath: 検出理由}, error) を返す。

    D1 = bats の @test 行が変異を名指し (負規則 COVERAGE_D1_NEGATIVE でデータ変異の意を除く)
    D2 = selftest 宣言 (COVERAGE_SELFTEST_MARKERS) と変異 keyword の【共起】
    D3 = pytest 型 test 定義 (def test_) と変異 keyword の【共起】(.py のみ・cmd_1355)
    対象は git ls-files (追跡済) かつ COVERAGE_EXTS の拡張子のみ。内容は worktree を読む
    (限界: 追跡済で disk に無い file は数えぬ・untracked の変異testは見えぬ — docs に明記)。
    """
    try:
        r = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"git ls-files が走らぬ: {e}"
    if r.returncode != 0:
        return None, f"git ls-files 失敗 (exit {r.returncode}): {r.stderr.strip()[:200]}"
    kw = re.compile(COVERAGE_MUT_KEYWORDS, re.IGNORECASE)
    st = re.compile(COVERAGE_SELFTEST_MARKERS)
    neg = re.compile(COVERAGE_D1_NEGATIVE, re.IGNORECASE)
    pyt = re.compile(COVERAGE_D3_PYTEST_DEF)
    cands: dict[str, str] = {}
    for rel in filter(None, r.stdout.split("\0")):
        if Path(rel).suffix not in COVERAGE_EXTS:
            continue
        p = repo / rel
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            return None, f"読めぬ追跡 file: {rel} ({e}) — 黙って飛ばさぬ (沈黙禁)"
        d1 = None
        for i, line in enumerate(text.splitlines(), 1):
            if "@test" in line and kw.search(line) and not neg.search(line):
                d1 = f"D1 (L{i}: @test 行が変異を名指し)"
                break
        if d1:
            cands[rel] = d1
        elif st.search(text) and kw.search(text):
            cands[rel] = "D2 (selftest 宣言と変異 keyword の共起)"
        elif Path(rel).suffix == ".py" and pyt.search(text) and kw.search(text):
            cands[rel] = "D3 (pytest test と変異 keyword の共起)"
    return cands, None


def coverage(registry: Path, repo: Path) -> int:
    """gate-2 付帯 (cmd_1352b): 変異testらしき file が台帳に登録されておるかの検知層。

    FAIL は「block」でなく「家老へ警告」を意味する (gate_nightly が既存の家老 inbox
    警告経路へ相乗りする)。免除は coverage_waivers (同じ台帳 file 内・理由必須) のみ =
    免除は可視 (WAIVED 表示)・黙って外す道は無い。
    """
    import yaml
    if not registry.is_file():
        print(f"[gate-2 coverage] UNDETERMINED: 台帳が無い: {registry}")
        return 2
    try:
        data = yaml.safe_load(registry.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"[gate-2 coverage] UNDETERMINED: 台帳が parse 不能: {e}")
        return 2
    if not isinstance(data, dict) or not isinstance(data.get("mutations"), list):
        print("[gate-2 coverage] UNDETERMINED: 台帳に mutations: リストが無い")
        return 2
    entries = [e for e in data["mutations"] if isinstance(e, dict)]
    wmap: dict[str, str] = {}
    for w in (data.get("coverage_waivers") or []):
        if not isinstance(w, dict) or not w.get("path") or not w.get("reason"):
            print(f"[gate-2 coverage] UNDETERMINED: coverage_waivers に path/reason を欠く entry: {w!r}"
                  " (曖昧な免除は免除でない)")
            return 2
        wmap[str(w["path"])] = str(w["reason"])
    cands, err = scan_mutation_test_candidates(repo)
    if err:
        print(f"[gate-2 coverage] UNDETERMINED: {err}")
        return 2
    # 陽性対照は台帳側 key で差し替え可 (cmd_1355: backend 等、本 file を持たぬ repo の台帳延長)
    control = str(data.get("coverage_positive_control") or COVERAGE_POSITIVE_CONTROL)
    if control not in cands:
        print(f"[gate-2 coverage] UNDETERMINED: 陽性対照 {control} が検出されぬ"
              f" (候補 {len(cands)} 件) = 検出規則の牙が折れておる (0件検出もここへ畳む・真空 PASS 禁)")
        return 2
    unregistered: list[str] = []
    n_waived = 0
    for rel in sorted(cands):
        eid = next((e.get("id", "?") for e in entries
                    if rel in (e.get("paths") or [])
                    or rel in str(e.get("test", "")) or rel in str(e.get("mutate", ""))), None)
        if eid:
            print(f"  ok   REGISTERED    {rel} ← {eid}")
        elif rel in wmap:
            n_waived += 1
            print(f"  免除 [WAIVED]      {rel}: {wmap[rel]}")
        else:
            unregistered.append(rel)
            print(f"  ★NG★ [UNREGISTERED] {rel}: {cands[rel]}")
    for wp in sorted(set(wmap) - set(cands)):
        print(f"  注   免除の空撃ち   {wp} (候補に居らぬ = file 削除/規則変更済か。waiver を掃除せよ)")
    if unregistered:
        print(f"[gate-2 coverage] FAIL: 候補 {len(cands)} 件中 ★台帳に無い変異test {len(unregistered)} 件★")
        print("  処方: 「赤を一度確認した」変異を config/mutation_registry.yaml へ登録せよ")
        print("        (登録の書式は本 file 冒頭 docstring)。登録すべきでない正当な理由が在るなら")
        print("        coverage_waivers へ【理由つきで】免除を書け (黙って外す道は無い)。")
        return 1
    print(f"[gate-2 coverage] PASS: 変異testらしき候補 {len(cands)} 件すべて台帳登録済"
          f" (免除 {n_waived} 件・免除は可視)")
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


def _write_reg(path: Path, entries: list, waivers: list | None = None,
               control: str | None = None) -> None:
    import yaml
    data: dict = {"mutations": entries}
    if waivers is not None:
        data["coverage_waivers"] = waivers
    if control is not None:
        data["coverage_positive_control"] = control
    path.write_text(yaml.safe_dump(data, allow_unicode=True))


def _mk_git_repo(root: Path, files: dict[str, str]) -> Path:
    """coverage selftest 用: git 追跡下の小さな repo を組む (add まで・commit 不要)。"""
    repo = root / "repo"
    for rel, content in files.items():
        p = repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
    for cmd in (["git", "init", "-q"], ["git", "add", "-A"]):
        subprocess.run(cmd, cwd=repo, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return repo


# coverage selftest 素材: 陽性対照 (D2 hit) / 未登録変異test (D1 hit) / データ変異の意 (非候補)
_COV_CONTROL_BODY = "# fake runner (陽性対照): --selftest 変異試験\n"
_COV_ROGUE_BATS = '@test "quorum breaks when neutered (mutation proof)" {\n  true\n}\n'
_COV_DATAMUT_BATS = '@test "previews stale branch without mutation" {\n  true\n}\n'
# D3 素材 (cmd_1355): pytest 型 = bats でも selftest 宣言でもない変異test
_COV_ROGUE_PY = "# 変異試験: 順序を壊せば赤くなることを検める\ndef test_order_mutation_detected():\n    pass\n"


def _cov_entry(eid: str, paths: list[str]):
    return {"id": eid, "desc": eid, "paths": paths, "mutate": "true", "test": "true"}


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

        # ── coverage (--coverage) selftests: cmd_1352b 台帳登録検知 ──
        ctl = COVERAGE_POSITIVE_CONTROL

        # T10: 変異testらしき file が台帳に無い → FAIL + 名指し
        repo = _mk_git_repo(T / "t10", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats": _COV_ROGUE_BATS})
        reg = T / "t10reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T10 未登録変異test=FAIL+名指し", 1, rc, "tests/rogue_mutation.bats", out)

        # T11: 台帳が全候補を覆う → PASS
        repo = _mk_git_repo(T / "t11", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats": _COV_ROGUE_BATS})
        reg = T / "t11reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-ROGUE", ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T11 全候補登録済=PASS", 0, rc, "REGISTERED", out)

        # T12: ★陽性対照が検出されぬ (0件検出を含む) → UNDETERMINED = 検出規則の死を緑にせぬ★
        repo = _mk_git_repo(T / "t12", {"tests/rogue_mutation.bats": _COV_ROGUE_BATS})
        rc, out = _invoke(["--coverage", "--registry", str(T / "t11reg.yaml"), "--repo-root", str(repo)])
        expect("T12 陽性対照不在=UNDETERMINED", 2, rc, "陽性対照", out)

        # T13: 理由つき免除 → PASS だが WAIVED として可視
        repo = _mk_git_repo(T / "t13", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats": _COV_ROGUE_BATS})
        reg = T / "t13reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats", "reason": "selftest fixture"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T13 理由つき免除=PASS+可視", 0, rc, "WAIVED", out)

        # T13b: 理由なし免除 → UNDETERMINED (曖昧な免除は免除でない)
        reg = T / "t13breg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T13b 理由なし免除=UNDETERMINED", 2, rc, "曖昧な免除", out)

        # T14: "without mutation" (データ変異の意) は候補にせぬ = 誤検知抑止 (D1 負規則)
        repo = _mk_git_repo(T / "t14", {ctl: _COV_CONTROL_BODY,
                                        "tests/branchy.bats": _COV_DATAMUT_BATS})
        reg = T / "t14reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T14 without mutation=非候補 (誤検知せぬ)", 0, rc)

        # T17: ★D3 = pytest 型の変異test も検出する (cmd_1355 backend 台帳延長)★
        #      backend の test_cmd_1350_* は bats でも selftest 宣言でもないゆえ、
        #      この規則が折れると backend を見ても常に 0 件 = 延長全体が真空になる
        repo = _mk_git_repo(T / "t17", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_pytest.py": _COV_ROGUE_PY})
        reg = T / "t17reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T17 pytest型変異test=D3検出+FAIL名指し", 1, rc, "tests/rogue_pytest.py", out)

        # T18: ★陽性対照は台帳 key で差し替え可 = runner を持たぬ repo でも対照が立つ★
        repo = _mk_git_repo(T / "t18", {"tests/rogue_pytest.py": _COV_ROGUE_PY})
        reg = T / "t18reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-PY", ["tests/rogue_pytest.py"])],
                   control="tests/rogue_pytest.py")
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T18 台帳側陽性対照=PASS", 0, rc, "REGISTERED", out)

        # T15: red_needle が赤出力に在る → PASS (名指し確認)
        repo = _mk_playground(T / "t15")
        reg = T / "t15reg.yaml"
        e15 = _entry("MUT-T15", "sed -i 's/exit 0/echo NG_GUARD_X; exit 1/' tool.sh")
        e15["red_needle"] = "NG_GUARD_X"
        _write_reg(reg, [e15])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T15 needle名指し=PASS", 0, rc, "名指し", out)

        # T16: ★赤いが needle 不在 = 別の理由で偶然赤い → FAIL (原理(iii))★
        repo = _mk_playground(T / "t16")
        reg = T / "t16reg.yaml"
        e16 = _entry("MUT-T16", "sed -i 's/exit 0/echo NG_GUARD_X; exit 1/' tool.sh")
        e16["red_needle"] = "NG_OTHER_GUARD"
        _write_reg(reg, [e16])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T16 needle不在=FAIL (偶然の赤を通さぬ)", 1, rc, "名指しが無い", out)

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
    ap.add_argument("--coverage", action="store_true",
                    help="cmd_1352b: 変異testらしき file が台帳に登録されておるかの検知層")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.sanity:
        return sanity(a.registry)
    if a.coverage:
        return coverage(a.registry, a.repo_root)
    return run_all(a.registry, a.repo_root)


if __name__ == "__main__":
    sys.exit(main())
