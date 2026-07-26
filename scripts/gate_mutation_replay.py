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
      suspected_by: ashigaru5   # 任意。★この変異は誰の疑いを写したものか★ (全軍規律 2026-07-26
                                # 「己で作った変異は、己が疑うた場所しか撃たぬ」— 五号の申し出を
                                # 家老が採った)。自作の疑いだけの台帳は盲点が残る = 他者の変異を
                                # 通した場所と、誰の疑いも通っておらぬ場所を数えられる形にする
  coverage_positive_control: <relpath>   # 任意 (top-level)。--coverage の陽性対照の差し替え。
                                         # 既定は本 file 自身ゆえ、本 file を持たぬ repo の台帳
                                         # (cmd_1355 backend 延長) では必須になる

判定 (三値 — 0件/未判定を緑にせぬ):
  PASS         = baseline 緑 かつ 変異後に赤 (契約どおり・red_needle があれば名指しまで確認)
  FAIL         = ★変異後も緑 = 変異が静かに無効化された★ (名指しで報告) /
                 赤いが red_needle 不在 = 別の理由で偶然赤い疑い
  UNDETERMINED = baseline が赤 / mutate 失敗 / ★mutate 空振り (何も変えておらぬ=sed の
                 当たり損ねも沈黙する★) / 台帳 0 件 / schema 不備 / timeout /
                 ★出力に skip 痕跡 (scratch で試験が見張っておらぬ=SKIP=FAIL は harness
                 内でも成り立つ — 四号の申し送り 2026-07-26)★
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
# ★綴りの一般形★ (cmd_1370): 旧版は「変異試験|変異を当て」と★語句★で綴りを固定しておったゆえ、
# 「★変異★= …を戻せば赤」の様に記号装飾つきで書いた file が【候補にすら挙がらなんだ】
# (軍師一号が cmd_1366 検分で実測・該当0件)。日本語側は一般形「変異」1語へ寄せ、
# 照合前に装飾記号を落とす (_norm_for_kw)。★英語側は "mutation" のまま広げぬ★ =
# "mutat" まで広げると "does not mutate" / "mutate 可能な stub" 等のデータ変異の意を拾い、
# 実測 2026-07-26 で backend に誤検知 2 件が増えた (誤検知は無視されて検知を殺す)。
COVERAGE_MUT_KEYWORDS = r"変異|わざと壊|壊して赤|壊せば落ち|mutation"
# 照合前に落とす装飾記号 (本 repo の全軍が強調に使う。綴りの揺れの実体はほぼこれである)
COVERAGE_DECORATION = r"[★☆◆◇■□●○▲△【】《》〔〕｜|]"
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

# ─────────────────────────────────────────────────────────────────────────────
# gate-2 付帯2: harness 内 SKIP=FAIL (四号の申し送り 2026-07-26 09:45・台帳所有者が受領)
# scratch は entry の paths だけのコピーゆえ、.gitignore'd な依存 (corpus 等) は付いて来ぬ。
# 依存を欠いた test が skip して緑を返すと【見張っておらぬ番人が「異常なし」と報告する形】
# になる — 実例 = 四号の STT 署名 canary (backend 台帳): scratch に corpus が付いて来ず
# 番人が skip → 変異を撃っても緑に見えた。四号は DB の口を開けて撃ち直し赤を実測した。
# 掟 = CLAUDE.md Test Rules 1「SKIP=FAIL」は変異試験の harness 内でも成り立つ。
# 検知は出力の機械痕跡のみ:
#   ・TAP/bats の「ok N … # skip」 (skip した test は ok に見える = 緑の顔をした不在)
#   ・TAP 空計画「1..0」 (bats --filter の空振り = 1 本も走っておらぬのに exit 0)
#   ・pytest 要約の「N skipped」 (N≥1。0 skipped は skip 無しゆえ拾わぬ)
# ★限界 (正直に)★: bash selftest が内部 guard で黙って何もせず exit 0 する無痕跡形は
# 拾えぬ — その全滅形は「変異後も緑=FAIL」が捕まえる。残余は【痕跡を出さぬ部分 skip】のみ。
# ─────────────────────────────────────────────────────────────────────────────
_SKIP_EVIDENCE = re.compile(
    r"(?im)^(?:not )?ok\s+\d+[^\n]*#\s*skip"  # TAP/bats: ok N … # skip
    r"|^\s*1\.\.0\s*$"                        # TAP 空計画: 1 本も走っておらぬ
    r"|\b[1-9]\d*\s+skipped\b"                # pytest 要約: N skipped (N≥1)
)


def skip_evidence(out: str):
    """test 出力中の skip 痕跡を返す (無ければ None)。"""
    m = _SKIP_EVIDENCE.search(out or "")
    return m.group(0).strip() if m else None


# ─────────────────────────────────────────────────────────────────────────────
# gate-2 付帯3: 幽霊 ID 検分 (--coverage に相乗り・四号 M9 型 2026-07-26)
# docstring が台帳 ID を「実射で確認済」と名指すのに台帳に実在せぬ = 申告と実在の食い違い。
# 四号は M6 で同じ抜けをやっており M9 で二度目 — 人の注意力では二度破れた。機械で拾う。
# 対象は tracked COVERAGE_EXTS file 中の完全形 ID 言及のみ。★限界 (正直に)★: 「M9」の
# ような略記の申告は拾えぬ (完全形で書く規律とセットで効く)。照合先は本 repo の台帳のみ
# (repo 跨ぎ言及は 2026-07-26 実測ゼロ)。
# ─────────────────────────────────────────────────────────────────────────────
REGISTRY_ID_RE = re.compile(r"MUT-\d{3,4}-[A-Za-z0-9]+")

# ─────────────────────────────────────────────────────────────────────────────
# gate-2 付帯4: ★視野計★ (--coverage に相乗り・cmd_1370)
# 何を塞ぐか = ★「候補 N 件すべて登録済 = PASS」は【候補に挙がった物】しか数えておらぬ★。
# 候補に挙がらなんだ牙は最初から分母の外に在り、検知器は静かに盲になる (軍師一号 R5)。
# ★測り方 = 台帳そのものを物差しにする★: 台帳が名指しする file のうち test 本体であるものは、
# 定義により変異試験である (綴りに一切依らぬ独立の証拠)。それを D1/D2/D3 が見えておるかで
# ★検知規則の recall★ を毎朝印字し、見えておらぬ file を名指しする。
# ★分母0と全員健全を区別する★ (cmd_1364 の流儀) = 台帳既知が0件なら「測れておらぬ」と言う。
# ★限界 (正直に)★: 本計は【台帳に載っておる物】しか物差しにできぬゆえ、
# 「未登録かつ綴りでも見えぬ」file は本計にも映らぬ (残余。docs に明記)。
# ─────────────────────────────────────────────────────────────────────────────
_PATHLIKE_RE = re.compile(r"[\w./-]+\.(?:py|sh|bash|bats)")
# test 本体の印 (実装 file を分母へ入れぬため。mutate の的にされる実装は変異試験ではない)
_TEST_BODY_RE = re.compile(r"(?m)^\s*def test_\w+|^\s*@test\s|--selftest|def selftest")


def _norm_for_kw(s: str) -> str:
    """変異 keyword 照合の前処理: 強調の装飾記号を落とす (「★変異★=」を「変異=」に)。"""
    return re.sub(COVERAGE_DECORATION, "", s)


def ls_files(repo: Path):
    """(tracked relpath list, error) を返す。git 追跡下のみを見る掟の唯一の口。"""
    try:
        r = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"git ls-files が走らぬ: {e}"
    if r.returncode != 0:
        return None, f"git ls-files 失敗 (exit {r.returncode}): {r.stderr.strip()[:200]}"
    return list(filter(None, r.stdout.split("\0"))), None


def registry_named_test_bodies(entries, repo: Path):
    """台帳が名指しする tracked file のうち【test 本体】を {relpath: [entry id]} で返す。

    ★綴りを一切見ぬ★ = paths / test / mutate の中の path らしき文字列を拾い、
    追跡下・COVERAGE_EXTS・test 本体の印を持つものだけを残す。
    """
    tracked, err = ls_files(repo)
    if err:
        return None, err
    tset = set(tracked)
    out: dict[str, list[str]] = {}
    for e in entries:
        eid = str(e.get("id", "?"))
        blob = " ".join([str(e.get("test", "")), str(e.get("mutate", ""))]
                        + [str(p) for p in (e.get("paths") or [])])
        for m in _PATHLIKE_RE.finditer(blob):
            rel = m.group(0).lstrip("./")
            if rel not in tset or Path(rel).suffix not in COVERAGE_EXTS:
                continue
            p = repo / rel
            if not p.is_file():
                continue
            try:
                if not _TEST_BODY_RE.search(p.read_text(encoding="utf-8", errors="replace")):
                    continue
            except OSError as ex:
                return None, f"読めぬ追跡 file: {rel} ({ex}) — 黙って飛ばさぬ (沈黙禁)"
            out.setdefault(rel, [])
            if eid not in out[rel]:
                out[rel].append(eid)
    return out, None


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
    # ①b ★skip 痕跡検分★: 緑でも skip 混じりなら「見張っておらぬ番人が異常なしと報告する形」
    #     (SKIP=FAIL は harness 内でも成り立つ — 四号の申し送り 2026-07-26)
    ev = skip_evidence(out)
    if ev:
        return UNDET, (f"baseline が skip 混じりの緑 (痕跡「{ev}」) = scratch で試験が"
                       "見張っておらぬ。paths に依存を足すか test の口を開けよ (SKIP=FAIL)")

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
    # ④b skip 痕跡は赤緑どちらの顔をしておっても判定を汚す (skip した試験の赤は
    #     「当てた変異の赤」の保証にならず、緑は「異常なし」の保証にならぬ)
    ev = skip_evidence(out)
    if ev:
        return UNDET, (f"変異後の出力に skip 痕跡 (「{ev}」) = 見張っておらぬ試験が混じり"
                       "判定を保証できぬ (SKIP=FAIL は harness 内でも成り立つ)")
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
        who = e.get("suspected_by") if isinstance(e, dict) else None
        tag = f" [疑い:{who}]" if who else ""
        print(f"  {mark} {verdict:12s} {eid}:{tag} {why}")
        if verdict == PASS:
            n_pass += 1
        elif verdict == FAIL:
            n_fail += 1
        else:
            n_undet += 1
    total = n_pass + n_fail + n_undet
    # ★この台帳は誰の疑いを写したものか★ (全軍規律 2026-07-26): 自作の疑いしか無い台帳は
    # 「己が疑うた場所」しか撃てておらぬ = 未記名も含め出所を数えて可視化する (強制はせぬ)
    by_who: dict[str, int] = {}
    for e in entries:
        if isinstance(e, dict):
            k = str(e.get("suspected_by") or "(未記名)")
            by_who[k] = by_who.get(k, 0) + 1
    if any(k != "(未記名)" for k in by_who):
        print("  [疑いの出所] " + " / ".join(f"{k}={v}" for k, v in sorted(by_who.items())))
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
    tracked, err = ls_files(repo)
    if err:
        return None, err
    kw = re.compile(COVERAGE_MUT_KEYWORDS, re.IGNORECASE)
    st = re.compile(COVERAGE_SELFTEST_MARKERS)
    neg = re.compile(COVERAGE_D1_NEGATIVE, re.IGNORECASE)
    pyt = re.compile(COVERAGE_D3_PYTEST_DEF)
    cands: dict[str, str] = {}
    for rel in tracked:
        if Path(rel).suffix not in COVERAGE_EXTS:
            continue
        p = repo / rel
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            return None, f"読めぬ追跡 file: {rel} ({e}) — 黙って飛ばさぬ (沈黙禁)"
        # ★装飾を落としてから照合★ (cmd_1370): 「★変異★=」の様な強調綴りで牙が落ちるのを塞ぐ
        norm = _norm_for_kw(text)
        d1 = None
        for i, line in enumerate(text.splitlines(), 1):
            if "@test" in line and kw.search(_norm_for_kw(line)) and not neg.search(line):
                d1 = f"D1 (L{i}: @test 行が変異を名指し)"
                break
        if d1:
            cands[rel] = d1
        elif st.search(text) and kw.search(norm):
            cands[rel] = "D2 (selftest 宣言と変異 keyword の共起)"
        elif Path(rel).suffix == ".py" and pyt.search(text) and kw.search(norm):
            cands[rel] = "D3 (pytest test と変異 keyword の共起)"
    return cands, None


def scan_registry_id_refs(repo: Path):
    """tracked COVERAGE_EXTS file 中の台帳 ID 完全形言及 ([(rel, line_no, id)], error) を返す。

    幽霊 ID 検分 (四号 M9 型) の材料。読めぬ追跡 file は沈黙せず error (coverage scan と同じ掟)。
    """
    tracked, err = ls_files(repo)
    if err:
        return None, err
    refs: list[tuple[str, int, str]] = []
    for rel in tracked:
        if Path(rel).suffix not in COVERAGE_EXTS:
            continue
        p = repo / rel
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            return None, f"読めぬ追跡 file: {rel} ({e}) — 黙って飛ばさぬ (沈黙禁)"
        for i, line in enumerate(text.splitlines(), 1):
            for m in REGISTRY_ID_RE.finditer(line):
                refs.append((rel, i, m.group(0)))
    return refs, None


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
    # 幽霊 ID 検分 (付帯3・四号 M9 型): docstring の申告と台帳の実在の食い違いを名指し
    refs, rerr = scan_registry_id_refs(repo)
    if rerr:
        print(f"[gate-2 coverage] UNDETERMINED: {rerr}")
        return 2
    known = {str(e.get("id")) for e in entries}
    ghosts = [(rel, ln, mid) for rel, ln, mid in refs if mid not in known]
    for rel, ln, mid in ghosts:
        print(f"  ★NG★ [GHOST-ID]     {rel}:{ln} が {mid} を名指すが台帳に実在せぬ"
              " (docstring 申告と台帳の食い違い = 四号 M9 型。登録するか申告を消せ)")

    # ── ★視野計★ (付帯4・cmd_1370): 検知規則の recall を台帳で測り、盲を数字で言わせる ──
    named, nerr = registry_named_test_bodies(entries, repo)
    if nerr:
        print(f"[gate-2 coverage] UNDETERMINED: {nerr}")
        return 2
    blind = {rel: ids for rel, ids in named.items() if rel not in cands}
    for rel in sorted(blind):
        print(f"  注   [RULE-BLIND]    {rel}: 台帳 {'/'.join(blind[rel])} が名指す変異試験だが"
              " ★検知規則 D1/D2/D3 には見えておらぬ★ (台帳が在るゆえ守られてはおる。"
              "同じ形の【未登録】は検知できぬ = 検知規則の視野の外)")
    n_named, n_seen = len(named), len(named) - len(blind)
    # ★物差しの長さを先に言う★: 対照は必ず当たる fixture ゆえ分母から除く。
    #   除いた残りが 0 件なら【recall を測れておらぬ】= 「全部見えておる」ではない
    #   (分母0と全員健全を区別する — cmd_1364 の流儀を検知器自身へ当てたもの)
    non_ctl = sorted(set(named) - {control})
    seen_non_ctl = [rel for rel in non_ctl if rel in cands]
    if not non_ctl:
        vision = ("★視野は測れておらぬ★ = 台帳が名指す test 本体が対照のみ"
                  f" ({n_named} 件) ゆえ recall の物差しが無い")
    elif not seen_non_ctl:
        # 対照以外を1件も見えておらぬ = 対照が当たるだけで規則は実質死んでおる疑い。
        # ★これは対照1件の検分より広い牙★ (対照は fixture ゆえ規則の生存を証明せぬ)
        print(f"[gate-2 coverage] UNDETERMINED: ★検知規則が陽性対照 ({control}) 以外を"
              f" 1 件も見えておらぬ★ = 台帳が名指す変異試験 {len(non_ctl)} 件"
              f" ({'/'.join(non_ctl[:3])}…) がことごとく規則の外に在る"
              " = 検出規則が死んでおる疑い (対照は必ず当たる fixture ゆえ生存を証明せぬ)")
        return 2
    else:
        vision = (f"台帳既知の変異試験 {n_named} 件中 ★規則が見えるのは {n_seen} 件"
                  f"・盲 {len(blind)} 件★")
    print(f"  [視野] {vision} — 下の候補件数は【規則に見えた物】の勘定である")

    if unregistered or ghosts:
        print(f"[gate-2 coverage] FAIL: 候補 {len(cands)} 件中 ★台帳に無い変異test"
              f" {len(unregistered)} 件★ / ID言及 {len(refs)} 件中 ★幽霊 {len(ghosts)} 件★"
              f" (視野: {vision})")
        print("  処方: 「赤を一度確認した」変異を config/mutation_registry.yaml へ登録せよ")
        print("        (登録の書式は本 file 冒頭 docstring)。登録すべきでない正当な理由が在るなら")
        print("        coverage_waivers へ【理由つきで】免除を書け (黙って外す道は無い)。")
        print("        幽霊 ID は台帳へ登録するか docstring の申告を消せ (申告≠実在を残すな)。")
        return 1
    # ★PASS の文言に視野を刻む★ = 「候補すべて登録済」を【全部検査した】と読ませぬための限定
    #   (cmd_1364 の「検査した と 全部検査した を混同させぬ」を、検知器自身へ当てたもの)
    print(f"[gate-2 coverage] PASS: ★規則に見えた★候補 {len(cands)} 件すべて台帳登録済"
          f" (免除 {n_waived} 件・免除は可視・ID言及 {len(refs)} 件に幽霊なし)"
          f" — ★但し視野は全域でない: {vision}★")
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
# ★cmd_1370 素材★: 記号装飾つきの綴り = 実在の書き方 (backend の cmd_1366 test の写し)。
# 旧 keyword (「変異試験|変異を当て|…」の語句固定) では ★1件も当たらぬ★ = 候補にすら挙がらぬ。
_COV_DECORATED_PY = (
    "# ★変異★= guard を戻せば ★本 test は赤★\n"
    "def test_guard_is_alive():\n    pass\n"
)
# ★cmd_1370 素材2★: 変異語彙を一切持たぬ test 本体 (台帳が名指すゆえ変異試験と判る形)。
# 実測 2026-07-26: 台帳既知 25 件中 8 件がこの形 = 綴りでは原理的に届かぬ族である。
_COV_SILENT_PY = "def test_plain_contract():\n    assert True\n"


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

        # ── 付帯2/3 selftests: harness 内 SKIP=FAIL + 幽霊 ID (四号の申し送り 2026-07-26) ──

        # T19: ★scratch で skip する番人 = UNDETERMINED★ (四号の署名 canary の再現:
        #      依存が scratch に付いて来ず skip → 緑の顔をした「見張っておらぬ」)
        repo = _mk_playground(T / "t19")
        (repo / "check.sh").write_text(
            "#!/bin/bash\necho '1..1'\necho 'ok 1 canary # skip corpus missing in scratch'\nexit 0\n")
        reg = T / "t19reg.yaml"
        _write_reg(reg, [_entry("MUT-T19", "sed -i 's/exit 0/exit 1/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T19 scratchでskip=UNDETERMINED (緑にせぬ)", 2, rc, "skip 混じり", out)

        # T20: ★TAP 空計画 1..0 (bats --filter 空振り = 1本も走らず exit 0) = UNDETERMINED★
        repo = _mk_playground(T / "t20")
        (repo / "check.sh").write_text("#!/bin/bash\necho '1..0'\nexit 0\n")
        reg = T / "t20reg.yaml"
        _write_reg(reg, [_entry("MUT-T20", "sed -i 's/exit 0/exit 1/' tool.sh")])
        rc, out = _invoke(["--registry", str(reg), "--repo-root", str(repo)])
        expect("T20 filter空振り1..0=UNDETERMINED", 2, rc, "1..0", out)

        # T21: ★幽霊 ID 言及 (台帳に実在せぬ ID を「確認済」と申告) = FAIL + 名指し★
        #      ID は動的に組む — literal を書くと本 file 自身が幽霊言及になる (自縄自縛)
        ghost_id = "MUT-" + "9999-999"
        real_id = "MUT-" + "1111-001"
        repo = _mk_git_repo(T / "t21", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# 実射で確認済: {ghost_id}\n"})
        reg = T / "t21reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-ROGUE", ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T21 幽霊ID言及=FAIL+名指し (四号M9型)", 1, rc, ghost_id, out)

        # ── cmd_1370 selftests: 綴りの一般化 + 視野計 ──

        # T23: ★記号装飾つきの綴り (「★変異★= …を戻せば赤」) を候補に挙げる★
        #      = 軍師一号が cmd_1366 検分で見つけた実物の形。旧 keyword では候補にすら挙がらぬ
        repo = _mk_git_repo(T / "t23", {ctl: _COV_CONTROL_BODY,
                                        "tests/decorated_mutation.py": _COV_DECORATED_PY})
        reg = T / "t23reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T23 装飾つき綴り=検出+FAIL名指し", 1, rc, "tests/decorated_mutation.py", out)

        # T24: ★視野計★ = 台帳が名指す test 本体を規則が見えておらぬ時、[RULE-BLIND] で名指す
        #      (盲は【印字して数える】= FAIL にはせぬ。永久に赤い gate は無視されて死ぬゆえ)
        repo = _mk_git_repo(T / "t24", {ctl: _COV_CONTROL_BODY,
                                        "tests/silent_body.py": _COV_SILENT_PY,
                                        "tests/decorated_mutation.py": _COV_DECORATED_PY})
        reg = T / "t24reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-SILENT", ["tests/silent_body.py"]),
                         _cov_entry("MUT-COV-DEC", ["tests/decorated_mutation.py"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T24 視野計=盲を名指し", 0, rc, "[RULE-BLIND]", out)
        expect("T24b 盲の file 名", 0, rc, "tests/silent_body.py", out)
        expect("T24c PASS 文言に視野の限定", 0, rc, "但し視野は全域でない", out)

        # T25: ★対照しか見えておらぬ = UNDETERMINED★ (対照は必ず当たる fixture ゆえ
        #      規則の生存を証明せぬ。従来の「対照1件の検分」より広い牙)
        repo = _mk_git_repo(T / "t25", {ctl: _COV_CONTROL_BODY,
                                        "tests/silent_body.py": _COV_SILENT_PY})
        reg = T / "t25reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-SILENT", ["tests/silent_body.py"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T25 対照しか見えぬ=UNDETERMINED", 2, rc, "陽性対照", out)

        # T26: ★台帳が (対照以外の) test 本体を名指さぬ = 【測れておらぬ】と言う★
        #      cmd_1364 で据えた「分母0と全員健全を区別せよ」の検知器版。
        #      ★verdict は動かさぬ★ = 物差しが短いだけで赤にすると永久に赤い gate になり
        #      無視されて死ぬ (家老の「登録したが永久に UNDETERMINED は免除より悪い」)。
        #      規則の死そのものは陽性対照検分 (T12) と T25 が受け持つ。
        repo = _mk_git_repo(T / "t26", {ctl: _COV_CONTROL_BODY})
        reg = T / "t26reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T26 物差し不足=測れておらぬと明言 (緑を装わぬ)", 0, rc, "視野は測れておらぬ", out)

        # T22: 実在 ID の言及は幽霊扱いせぬ (誤検知抑止の負例)
        repo = _mk_git_repo(T / "t22", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# 実射で確認済: {real_id}\n"})
        reg = T / "t22reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry(real_id, ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T22 実在ID言及=幽霊扱いせぬ", 0, rc, "幽霊なし", out)

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
