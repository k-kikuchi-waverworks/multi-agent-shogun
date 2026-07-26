#!/usr/bin/env python3
"""gate_anchor_touched.py — gate-3: ★牙が鈍った其の場で名指す★ (cmd_1387)

━━ 何を塞ぐか = ★時差★ ただ一つ ━━
  ★anchor の一意性は【牙の性質】ではない。【今の盤面の性質】である★ (cmd_1382・六号 実測)。
  ⇒ ★他人の commit が、他人の牙を黙って鈍らせうる★。

  ★実例 (本 gate の存在理由。推測ではなく実物)★:
    MUT-1355-001 の anchor は綴り「"session limit",」であり、
    台帳へ書かれた 2026-07-26 昼、repo に ★1 箇所★ であった。
    ★同日 21:11 の 7d35e40 (cmd_1385) が別の目的で 2 本目を足した其の瞬間に非一意へ転じた★。
      7d35e40^ : scripts/idle_revive_scan.py:142 のみ            = 1 箇所
      7d35e40  : 同 150 行目 + 170 行目 (UPSTREAM_TIMED_HEAD_PATTERNS) = 2 箇所
    mutate は `sed -i '/"session limit",/d'` = 行削除ゆえ ★2 行とも消える★。
    ⇒ ★7d35e40 を書いた者は、己が他人の牙を鈍らせたことを知る術を持たなんだ★。

━━ ★既に在る物を先に認めよ (Chesterton's Fence)★ ━━
  ★機械は既に見ておる★= gate_mutation_replay.py の全数 replay が
  「申告 (anchor_sites) vs 実測着弾」を★両方向★で突合し、食い違えば UNDETERMINED を返す。
  ⇒ ★鈍った牙は【翌朝】必ず名指される★。本 gate は其れを置き換えるものではない。
  ⇒ ★本 gate が埋めるのは【翌朝まで】の時差だけである★。

━━ ★最も早く知り得る点は何処か (実測で決めた)★ ━━
  非一意化は「盤面 (file の中身) が変わった」ことで起こる。ゆえに知り得る最も早い点は
  ★中身が変わった瞬間 = 書き込みの其の時★である。然れど:
    ・editor の保存を捉える仕掛けは本 repo に無く、agent は tool 経由で書くゆえ捕捉口が無い。
    ・書きかけの途中で鳴らせば ★正しい作業の最中に鳴り続ける門★ になる = 必ず外される。
  ⇒ ★実務上 最も早く、かつ意味の在る点 = pre-commit★ (「此の形で残す」と書き手が決めた瞬間)。
    ★本 repo には既に pre-commit gate が在る (scripts/gate_precommit.sh)★ゆえ其処へ相乗りする
    = ★機構を増やさぬ★。push 時では遅い (殿手番ゆえ commit から時が空く)。

━━ ★止めぬ。名指して記録するだけである★ ━━
  ★誤検知で commit を止める門は、書き手を悪い道へ逃がす★ (SHOGUN_GATE_SKIP=1 の常用・
  gate を外す・変更を分割して隠す)。ゆえに本 gate は ★決して exit 1 を返さぬ★ =
  返すのは 0 (鳴らず) か ★2 = UNDETERMINED (大声で警告するが通す)★ のみ。
  ★2 を選ぶ理由★= 鈍りは「牙が折れた (FAIL)」ではなく「其の牙が何を守っておるか言えなくなった」
  であり、全数 replay 自身も anchor 問題を UNDETERMINED と判じておる。判定の名を揃える。

━━ ★何故【触った file に限る】のが【手抜きでなく正しい】のか★ ━━
  replay は entry の `paths` だけを scratch へ写して撃つ = ★盤面は paths の中身のみで決まる★。
  ⇒ ★paths に 1 file も変化が無い entry は、着弾数が変わりようが無い★。
  ⇒ 触った file を持つ entry へ絞るのは ★近似ではなく、同値な絞り込みである★。
  (「重いゆえ間引いた」のではない。★見る要が無い所を見ておらぬだけ★。)

━━ ★何故【物差しA を走らせぬ】のか — 数で決めた★ ━━
  ★実測 2026-07-27 (MUT-1355-001・scripts/idle_revive_scan.py = 2107 行)★:
      物差しA (anchor_firings / char 単位 SequenceMatcher) = ★45.0 秒★
      物差しB (_diff_shape   / 行単位)                     = ★0.00 秒★
      copy_paths + mutate + probe + 第2射 の全て            = ★0.03 秒★
  ★選抜 11 件なら物差しA だけで 8 分★。既存 pre-commit gate の全所要は ★0.75 秒★ である
  (実測)。★0.75 秒の門へ 8 分を足せば、其の門は必ず外される★ ⇒ 物差しB のみで撃つ。

  ★残余を正直に名乗る★= ★同一行に複数箇所在る形は物差しB には 1 に見える★
    (実測: `FLAG = 0; OTHER = 0` へ 0→1 を当てると 物差しA=2 / 物差しB=1)
  ⇒ ★其の形は本 gate では鳴らぬ。翌朝の全数 replay (物差しA 併走) が捕える★。
  ★本 gate は【早さ】を買い、【網の広さ】は買っておらぬ★= 二層は役割が違い、代用ではない。
  (逆向きの実測も添える = MUT-1355-001 は 物差しA=1 / 物差しB=2 ゆえ ★本件を捕えるのは物差しB
   の側である★。鈍りの実物が本 gate の網に掛かることは、下の負例 S2 が縛っておる。)

使い方:
  python3 scripts/gate_anchor_touched.py                    # staged file から自動で絞る (pre-commit)
  python3 scripts/gate_anchor_touched.py --changed-file F   # 検分対象を明示 (複数可・試験/手検分用)
  python3 scripts/gate_anchor_touched.py --selftest         # 変異試験つき自己検分
exit: 0 鳴らず / ★2 鈍り疑い または 測れなんだ★ / ★1 は決して返さぬ (commit を止めぬ)★
"""
from __future__ import annotations

import argparse
import datetime
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate_mutation_replay as R  # noqa: E402  (測る術の出所は 1 つ = 本 file は判断を写さぬ)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_HISTORY = REPO_ROOT / "queue" / "state" / "anchor_dulling_history.yaml"
HISTORY_MAX = 200          # 追記式ゆえ際限なく伸びる — 古い順に落とす (cmd_1385 の流儀に倣う)
PER_ENTRY_TIMEOUT = 20     # 1 件の mutate/第2射に許す秒数 (実測 0.00s ゆえ 桁で余裕を取る)
DEFAULT_BUDGET_SEC = 15.0  # 全体の所要上限 (実測 0.03s/件 ゆえ 桁で余裕。超えたら★名指して打ち切る★)

# CONTRACT: ★本 gate は commit を止めぬ★ = 1 を返さぬ。これを破ると「正当な作業を塞ぐ門」へ化ける。
NEVER_BLOCKS_COMMIT = True


def staged_files(repo: Path):
    """(staged relpath list, error) を返す。★commit されようとしておる file の一覧★。

    ★index を見る理由★= pre-commit の関心は「此の commit が何を残すか」である。
    ★但し測る盤面は作業ツリーである (下の注を見よ)★= 出所が違うことを承知の上で使う。
    """
    try:
        r = subprocess.run(["git", "-C", str(repo), "diff", "--cached", "--name-only", "-z"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"git diff --cached が走らぬ: {e}"
    if r.returncode != 0:
        return None, f"git diff --cached 失敗 (exit {r.returncode}): {r.stderr.strip()[:200]}"
    return list(filter(None, r.stdout.split("\0"))), None


def entry_touches(e, changed: set) -> list:
    """entry の paths と触った file の交わりを返す (空なら ★見る要が無い★)。

    paths には file も directory も書かれうる (実在例 = 'config' / 'lib' / 'scripts/lib')。
    ⇒ ★directory が挙がっておれば、其の下の file が触られた時も盤面が変わる★ゆえ拾う。
    """
    hit = []
    for p in (e.get("paths") or []):
        p = str(p).strip("/")
        if not p:
            continue
        for c in changed:
            if c == p or c.startswith(p + "/"):
                hit.append(c)
    return sorted(set(hit))


def screen_entry(e, repo: Path, work: Path):
    """1 件を ★物差しB のみ★ で検分し (理由 or None) を返す。★test は走らせぬ★。

    ★test を走らせぬ理由★= 本 gate の問いは「牙が何処へ当たるか」だけである。
    「牙が現に赤くなるか」は翌朝の全数 replay の問いであり、其方は分単位を要する。
    ★問いを絞ったゆえ速い。速さのために問いを曖昧にしたのではない★。
    """
    err = R.validate_entry(e)
    if err:
        return f"台帳の形が立っておらぬ: {err}"

    pristine, mut = work / "pristine", work / "mut"
    for d in (pristine, mut):
        d.mkdir(parents=True)
        cerr = R.copy_paths(repo, e["paths"], d)
        if cerr:
            return f"paths を写せぬ: {cerr}"
        R.purge_pycache(d)

    rc, out = R.run_sh(e["mutate"], mut, PER_ENTRY_TIMEOUT)
    if rc is None:
        return f"mutate が timeout ({PER_ENTRY_TIMEOUT}s) = 着弾を測れなんだ"
    if rc != 0:
        # ★mutate 自身が落ちた = 盤面が変わって anchor が【消えた】形もここに出る★
        #   (assert old in s 型の守りを持つ mutate は、綴りが消えれば己で落ちる)。
        #   ★之も鈍りである★ = 黙って通さぬ。
        return (f"mutate 自体が失敗 (exit {rc}) = ★anchor の綴りが盤面から消えた疑い★: "
                f"{out.strip()[:160]}")
    if R.tree_digest(pristine) == R.tree_digest(mut):
        return "mutate 空振り (1 byte も変えておらぬ) = ★anchor が盤面から消えた★"

    # ★測る術の出所は gate_mutation_replay ただ 1 つ★ = 判断を本 file へ写さぬ
    #   (写せば cmd_1382 が二度差し戻して磨いた規則が、此処で黙って古びる)。
    return R.check_anchor_uniqueness(e, pristine, mut, work, PER_ENTRY_TIMEOUT,
                                     spelling_measure=False)


def history_append(path: Path, records: list) -> str | None:
    """鳴った件を追記式台帳へ焼く。失敗しても commit は止めぬが ★黙らぬ★ (理由を返す)。

    ★何故 記録が要るか★= pre-commit の出力は流れる。commit は通る (止めぬ設計ゆえ)。
    ⇒ ★画面を見落とした者にとって、記録が無ければ本 gate は何も残さなんだのと同じ★。
    """
    import yaml
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = None
        if path.is_file():
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
        eps = data.get("dullings") if isinstance(data, dict) else None
        if not isinstance(eps, list):
            eps = []
        eps.extend(records)
        dropped = max(0, len(eps) - HISTORY_MAX)
        doc = {
            "# managed by": "scripts/gate_anchor_touched.py (cmd_1387) — append-only",
            "# 読み方": "鈍りの疑いを其の場で焼いた記録。翌朝の全数 replay が正本の判定である",
            "dropped_total": int((data or {}).get("dropped_total", 0)) + dropped,
            "dullings": eps[dropped:],
        }
        path.write_text(yaml.safe_dump(doc, allow_unicode=True, sort_keys=False),
                        encoding="utf-8")
        return None
    except Exception as ex:
        return f"{ex!r}"


def run(registry: Path, repo: Path, changed: list | None, history: Path,
        budget: float, now: str | None = None) -> int:
    import time
    t0 = time.monotonic()

    if changed is None:
        changed, err = staged_files(repo)
        if err:
            # ★測れなんだ時は「測れなんだ」と名乗る★ = 黙って 0 (緑) へ倒さぬ。
            print(f"[gate-3] UNDETERMINED: 触った file を数えられぬ — {err}")
            return 2
        src = "staged (git diff --cached)"
    else:
        src = "--changed-file (明示)"

    changed_set = {c.strip("/") for c in changed if c.strip()}
    if not changed_set:
        # ★0 件を緑と名乗らぬ★= 「見る物が無かった」と正直に書く (真空 PASS 禁の流儀)。
        print(f"[gate-3] 触った file が 0 件 ({src}) = 検分すべき牙は無い")
        return 0

    entries, rerr = R.load_registry(registry)
    if rerr:
        print(f"[gate-3] UNDETERMINED: 台帳が読めぬ ({registry}): {rerr}")
        return 2

    selected = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        hit = entry_touches(e, changed_set)
        if hit:
            selected.append((e, hit))

    if not selected:
        print(f"[gate-3] PASS: 触った {len(changed_set)} file を paths に持つ牙は 0 件"
              f" (台帳 {len(entries)} 件) = ★盤面が変わっておらぬ牙は着弾数も変わらぬ★")
        return 0

    rang, undet, skipped = [], [], []
    for e, hit in selected:
        if time.monotonic() - t0 > budget:
            # ★打ち切ったことを黙らぬ★= 黙れば「全部見て緑」と読まれる (silent cap 禁)。
            skipped.append(str(e.get("id", "?")))
            continue
        with tempfile.TemporaryDirectory(prefix="anchtouch_") as w:
            why = screen_entry(e, repo, Path(w))
        if why:
            rang.append({"id": str(e.get("id", "?")), "why": why, "touched": hit,
                         "declared": e.get("anchor_sites", R.ANCHOR_SITES_DEFAULT),
                         "suspected_by": e.get("suspected_by")})

    dt = time.monotonic() - t0
    # ★出所を必ず名乗る★= 鳴った時に「何を触ったと見做して測ったのか」が読めねば、
    #   読む者は己の変更と結び付けられぬ (src を鳴りの側にも載せる — 負例 S8 が縛っておる)。
    tail = (f" — 所要 {dt:.2f}s / 選抜 {len(selected)} 件"
            f" (台帳 {len(entries)} 件・触った file {len(changed_set)} 件・出所={src})")

    if not rang and not skipped:
        print(f"[gate-3] PASS: 触った file を持つ牙 {len(selected)} 件すべて"
              f" ★申告どおりの箇所へ着弾しておる★{tail}")
        return 0

    print("[gate-3] ⚠ UNDETERMINED — ★牙が鈍った疑い。commit は止めぬ★" + tail)
    for r in rang:
        who = f" [疑い:{r['suspected_by']}]" if r.get("suspected_by") else ""
        print(f"  ★鈍り疑い★ {r['id']}{who} (申告 {r['declared']} 箇所)")
        print(f"      触った file = {', '.join(r['touched'])}")
        print(f"      {r['why']}")
    if skipped:
        print(f"  ★未検分 {len(skipped)} 件 (所要 {budget}s を超えたゆえ打ち切った)★ ="
              f" {', '.join(skipped)} — ★未検分は緑ではない★")
    print("  ★読み方★= 貴殿の変更が【他人の牙】を鈍らせた公算がある。牙は折れておらぬが、"
          "赤が出た時に【何処の赤か】を名乗れなくなっておる。")
    print("  ★処方★= (a) 意図しての全置換なら台帳へ anchor_sites: 実測値 を書かせよ /"
          " (b) 意図でなければ牙の持ち主へ報せ、anchor を一意な綴りへ絞らせよ。")
    print("  ★台帳の書き手は 1 人である★ = 己で書き換えず、持ち主 (suspected_by) へ回せ。")
    print(f"  ★正本の判定は翌朝の全数 replay である★ (本 gate は物差しB のみ・"
          f"同一行に複数箇所在る形は見えぬ)")

    if rang:
        stamp = now or datetime.datetime.now().isoformat(timespec="seconds")
        herr = history_append(history, [dict(r, ts=stamp) for r in rang])
        if herr:
            print(f"  ⚠ 記録を焼けなんだ ({history}): {herr} = ★画面の外に何も残っておらぬ★")
        else:
            print(f"  記録 = {history} へ {len(rang)} 件 焼いた")
    return 2


# ─────────────────────────────────────────────────────────────────────────────
# selftest — 小さな遊び場で ★鈍らせた時に鳴るか / 鈍っておらぬ時に黙るか★ の両方を撃つ
# ─────────────────────────────────────────────────────────────────────────────
def _mk_repo(root: Path, body: str, git: bool = False) -> Path:
    repo = root / "repo"
    repo.mkdir(parents=True)
    (repo / "tool.py").write_text(body, encoding="utf-8")
    (repo / "check.sh").write_text("#!/bin/bash\npython3 -c 'import tool'\n", encoding="utf-8")
    if git:
        for cmd in (["git", "init", "-q"], ["git", "add", "-A"]):
            subprocess.run(cmd, cwd=repo, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return repo


def _reg(path: Path, anchor_sites=None, mutate: str | None = None) -> Path:
    import yaml
    e = {"id": "MUT-S-001", "desc": "遊び場の牙", "paths": ["tool.py", "check.sh"],
         "mutate": mutate or "sed -i 's/^FLAG = 0$/FLAG = 1/' tool.py",
         "test": "bash check.sh", "suspected_by": "ashigaru3"}
    if anchor_sites is not None:
        e["anchor_sites"] = anchor_sites
    path.write_text(yaml.safe_dump({"mutations": [e]}, allow_unicode=True), encoding="utf-8")
    return path


_UNIQUE = "FLAG = 0\nOTHER = 9\n"
# ★7d35e40 の写し★= 別の目的で 2 本目の同じ綴りが離れた所へ生えた形
_DULLED = "FLAG = 0\nOTHER = 9\n" + "PAD = 1\n" * 20 + "FLAG = 0\n"
# ★物差しB の盲点★= 同一行に 2 箇所 (物差しA なら 2 と数える)
_SAME_LINE = "FLAG = 0; MORE = 0\nOTHER = 9\n"


def _invoke(args: list[str]) -> tuple[int, str]:
    r = subprocess.run([sys.executable, str(Path(__file__).resolve())] + args,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                       env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    return r.returncode, r.stdout


def selftest() -> int:
    import time
    ok = ng = 0

    def expect(name: str, want_rc: int, got_rc: int, needle: str = "", out: str = ""):
        nonlocal ok, ng
        if got_rc != want_rc:
            print(f"  NG {name}: exit {got_rc} (期待 {want_rc})")
            print("     " + " / ".join(out.strip().splitlines()[-3:])[:300])
            ng += 1
            return
        if needle and needle not in out:
            print(f"  NG {name}: 出力に「{needle}」が無い")
            ng += 1
            return
        print(f"  ok {name}")
        ok += 1

    def refute(name: str, cond: bool, note: str = ""):
        nonlocal ok, ng
        if cond:
            print(f"  ok {name}")
            ok += 1
        else:
            print(f"  NG {name}: {note}")
            ng += 1

    with tempfile.TemporaryDirectory(prefix="anchtouch_selftest_") as td:
        T = Path(td)
        hist = T / "hist.yaml"

        # S1 ★鈍っておらぬ時は黙る★ (常に鳴る門は外される — 之が最も大事な負例)
        repo = _mk_repo(T / "s1", _UNIQUE)
        rc, out = _invoke(["--registry", str(_reg(T / "s1.yaml")), "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S1 一意なら黙る=PASS", 0, rc, "申告どおりの箇所へ着弾", out)

        # S2 ★★鈍らせた時に名指す (7d35e40 の写し)★★ — 本 gate の存在理由そのもの
        repo = _mk_repo(T / "s2", _DULLED)
        rc, out = _invoke(["--registry", str(_reg(T / "s2.yaml")), "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S2 非一意化を名指す=UNDETERMINED", 2, rc, "MUT-S-001", out)
        expect("S2b 鈍りと名乗る", 2, rc, "鈍り疑い", out)
        expect("S2c 実測箇所を数えて出す", 2, rc, "2 箇所で発火", out)
        refute("S2d ★commit を止めぬ (1 を返さぬ)★", rc != 1, f"exit {rc} = commit が止まる")
        refute("S2e 記録が焼かれた", hist.is_file() and "MUT-S-001" in hist.read_text(),
               "history file に何も残っておらぬ")

        # S3 ★触っておらぬ file の牙は選抜されぬ★ (絞り込みが同値であることの証)
        repo = _mk_repo(T / "s3", _DULLED)
        rc, out = _invoke(["--registry", str(_reg(T / "s3.yaml")), "--repo-root", str(repo),
                           "--changed-file", "docs/無縁.md", "--history", str(hist)])
        expect("S3 無縁の file なら選抜0件=PASS", 0, rc, "牙は 0 件", out)

        # S4 ★台帳が読めぬ時は fail-closed★ (読めぬを緑へ倒さぬ)
        repo = _mk_repo(T / "s4", _UNIQUE)
        bad = T / "s4bad.yaml"
        bad.write_text("mutations: [これは: 壊れて: おる\n", encoding="utf-8")
        rc, out = _invoke(["--registry", str(bad), "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S4 台帳が読めぬ=UNDETERMINED", 2, rc, "台帳が読めぬ", out)

        # S5 ★過大申告も鳴る★ (申告を飾りにさせぬ — cmd_1382 差し戻し (ii) の継承)
        repo = _mk_repo(T / "s5", _UNIQUE)
        rc, out = _invoke(["--registry", str(_reg(T / "s5.yaml", anchor_sites=99)),
                           "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S5 過大申告=UNDETERMINED", 2, rc, "過大申告", out)

        # S6 ★申告が実測に合うておれば黙る★ (S2 の鳴りが「申告との差」由来である証)
        repo = _mk_repo(T / "s6", _DULLED)
        rc, out = _invoke(["--registry", str(_reg(T / "s6.yaml", anchor_sites=2)),
                           "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S6 申告2で実測2なら黙る=PASS", 0, rc, "申告どおり", out)

        # S7 ★空振り (anchor が盤面から消えた) も鳴る★
        repo = _mk_repo(T / "s7", _UNIQUE)
        rc, out = _invoke(["--registry", str(_reg(T / "s7.yaml",
                                                  mutate="sed -i 's/^居らぬ綴り$/x/' tool.py")),
                           "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S7 空振り=UNDETERMINED", 2, rc, "盤面から消えた", out)

        # S8 ★staged file から自動で絞る道が現に動くか★ (pre-commit の実経路)
        repo = _mk_repo(T / "s8", _DULLED, git=True)
        rc, out = _invoke(["--registry", str(_reg(T / "s8.yaml")), "--repo-root", str(repo),
                           "--history", str(hist)])
        expect("S8 staged から絞って鳴る", 2, rc, "staged", out)

        # S9 ★名乗っておる盲点が、現に盲点である★ (docstring の申告と実物の一致)
        #    ★之は「直せ」の意ではない = 物差しB の性質ゆえ翌朝の replay が受け持つ★。
        #    此処に置く値打ち = ★docstring が嘘になった時に赤くなる★ (規律(6) = コメントは
        #    実装より強い嘘をつける)。
        repo = _mk_repo(T / "s9", _SAME_LINE)
        rc, out = _invoke(["--registry", str(_reg(T / "s9.yaml",
                                                  mutate="sed -i 's/0/1/g' tool.py")),
                           "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        expect("S9 同一行2箇所は本層では鳴らぬ (名乗り通り)", 0, rc, "", out)

        # S10 ★速さの契約★= 物差しA を呼べば桁で破れる budget に収まっておるか。
        #     ★実測根拠★= 物差しA は 2107 行の file 1 本で 45.0 秒 / 物差しB は 0.00 秒。
        #     ⇒ 2000 行級の盤面で本 gate が 10 秒に収まることは ★物差しA を走らせておらぬ証★
        #       であり、将来 誰かが此の層へ物差しA を配線したら此の試験が赤くなる。
        big = "FLAG = 0\n" + "PAD = 1\n" * 2000 + "FLAG = 0\n"
        repo = _mk_repo(T / "s10", big)
        t0 = time.monotonic()
        rc, out = _invoke(["--registry", str(_reg(T / "s10.yaml")), "--repo-root", str(repo),
                           "--changed-file", "tool.py", "--history", str(hist)])
        dt = time.monotonic() - t0
        expect("S10 2000行級でも鈍りを捕える", 2, rc, "鈍り疑い", out)
        refute(f"S10b ★速さの契約 ({dt:.2f}s < 10s)★", dt < 10.0,
               f"所要 {dt:.2f}s = 物差しA が配線された疑い (pre-commit へ置けぬ重さ)")

        # S11 ★1 を返す道が無いこと★を契約として置く
        refute("S11 NEVER_BLOCKS_COMMIT が立っておる", NEVER_BLOCKS_COMMIT is True,
               "止めぬ契約が降ろされておる")

    print(f"[gate-3 selftest] {'PASS' if ng == 0 else 'FAIL'}: ok={ok} ng={ng}")
    return 0 if ng == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", type=Path, default=R.DEFAULT_REGISTRY)
    ap.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    ap.add_argument("--changed-file", action="append", default=None,
                    help="検分対象の file (複数可)。既定は staged file から自動で絞る")
    ap.add_argument("--history", type=Path, default=DEFAULT_HISTORY)
    ap.add_argument("--budget-sec", type=float, default=DEFAULT_BUDGET_SEC)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    rc = run(a.registry, a.repo_root, a.changed_file, a.history, a.budget_sec)
    # ★最後の砦★= 万一 1 が漏れても commit は止めさせぬ (契約を code で押さえる)
    return 2 if (rc == 1 and NEVER_BLOCKS_COMMIT) else rc


if __name__ == "__main__":
    sys.exit(main())
