#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""customs_lint.py — cmd_1330: 本日できた作法のうち、機械で守れる分だけを機械に落とす道具。

なぜあるか:
  2026-07-27 にできた作法はすべて散文である。散文は腐る。
  契約をテストにしておけば、後から来る別の条にもそのまま答えられる。これがこの道具の全部である。

これはゲートではない。落とさない (終了コードは常に 0)。
  人の報告文を機械で採点する形に寄せると、作法を守らせる道具になってしまう。
  欲しいのは、作法が腐ったときに気付く道具である。だから名指すところで止める。
  CI に置いても赤くならない。赤くしたい呼び手は、出力の数を自分で読むこと。

見ているもの:
  C1  ps 由来の時刻 (lstart / /proc/<pid>/stat / starttime / btime) を書いた行に、
      「いつ測った値か」が併記されているか。btime は後から動く (本日の実測で +14 分 43 秒、
      経過時間の約 9.2〜9.7%)。測定時刻のない ps 由来の時刻は、後から検め直せない。
  C2  第七条の札 (a/b/c) の前に「何の判定について」の一語があるか。
      同じ一つの「言えない」が、問いを替えると別の札になるため。
      例: 「筆の違いか effort の違いか分からない」は、b16 の採否については c、cmd_1416 については b。
  C3  同じ数の直書きが一つのファイルに二度以上出る形。数えるだけで判定はしない。
      理由: 該当がリポジトリのほぼ全ファイルに及ぶ。何でも赤くなるので建てず、数だけ報せる。
      現況の数はこの道具を実行すれば出る。ここには書き写さない (手書きの数を二つ作らないため)。

見ていないもの:
  ・中身の正しさ。機械が見るのは形である。
    - C1 は「測定時刻らしき語が同じ行にあるか」だけを見る。併記された時刻が正しいかは判定できない。
    - C2 は「判定対象らしき語が札の手前 40 字にあるか」だけを見る。それが当の対象かは判定できない。
  ・行をまたいだ併記。同一行しか見ないので、前後の行に測定時刻を書いた形は取りこぼす。
  ・引用と主張の別。条そのものを引いた説明文も、書き手の主張と同じ形に見える。
  ・リポジトリ全体が緑だとは主張しない。作法は 2026-07-27 17:30 にできたので、
    それ以前の文書はほぼすべて違反の顔になる。赤として据えれば毎朝鳴るチェックになる。
    本来の使い方は「今書いた自分の文書」に当てること (パスを指して呼ぶ)。
    据えた時点の実測は plans/cmd_1330_customs_to_tests.md に一箇所だけある。
  ・走査対象は queue/reports/*.yaml と plans/*.md のみ。docs/ instructions/ は見ていない。

使い方:
  python3 scripts/customs_lint.py <path> [<path> ...]   # 数を報せる (終了コード 0)
  python3 scripts/customs_lint.py --name <path>          # file:line で名指す (終了コード 0)
  python3 scripts/customs_lint.py --scope                # 射程だけ印字して終わる
"""
from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

TAG = "[customs_lint]"

# ── C1: ps 由来の刻 ──────────────────────────────────────────────────────────
# 再現しない計器 (btime を土台にするので、互いの検算にならない族)
# 語頭の境界だけを課す。test_idle_revive_proc_age.bats のような道具の名は語頭が _ なので外れ、
# btime_drift_rate: のような測りの名は拾える (2026-07-27 の実測で 16 行の差が出た)。
PS_CLOCK_RE = re.compile(r"lstart|/proc/\d+/stat|\bstarttime\w*|\bbtime\w*|\bproc_age\w*|\bps -o\b")
# 測定時刻の併記とみなす語 (形だけを見る。語があれば足りるとする)
MEASURED_RE = re.compile(r"測定刻|測定時|測定|採取|計測|measured_at|measured-at|as-of|時点で測")

# ── C2: ⑦-x の札 ────────────────────────────────────────────────────────────
TAG7_RE = re.compile(r"⑦-[abc]")
# 「何の判定について」とみなす語 (札の手前 SUBJ_WINDOW 字を見る)
SUBJ_RE = re.compile(r"については|について|に対して|の採否|の判定|判定は|判定に")
SUBJ_WINDOW = 40

# ── C3: 同じ数 literal の再掲 (数えるのみ・判定せぬ) ─────────────────────────
NUM_RE = re.compile(r"(?<![\w.])\d{2,}(?![\w.])")

DEFAULT_GLOBS = ("queue/reports/*.yaml", "plans/*.md")


def collect(paths: list[Path]) -> list[Path]:
    out: list[Path] = []
    for p in paths:
        if p.is_dir():
            for g in DEFAULT_GLOBS:
                out.extend(sorted(p.glob(g)))
        elif p.is_file():
            out.append(p)
    return out


def scan(files: list[Path]):
    lines_total = 0
    c1_total = c2_total = c2_undecidable = 0
    c1_hits: list[tuple[str, int, str]] = []
    c2_hits: list[tuple[str, int, str]] = []
    c3_files = 0
    for f in files:
        nums: Counter[str] = Counter()
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:  # 読めないファイルは数から外し、その旨を名乗る
            print(f"{TAG} 読めなかった (数から外した): {f} — {exc}", file=sys.stderr)
            continue
        for no, line in enumerate(text.splitlines(), start=1):
            lines_total += 1
            if PS_CLOCK_RE.search(line):
                c1_total += 1
                if not MEASURED_RE.search(line):
                    c1_hits.append((str(f), no, line.strip()[:120]))
            is_table_row = line.lstrip().startswith("|")
            for m in TAG7_RE.finditer(line):
                c2_total += 1
                head = line[max(0, m.start() - SUBJ_WINDOW):m.start()]
                if SUBJ_RE.search(head):
                    continue
                if is_table_row:
                    # 表の行は判定できない。判定対象が別の列 (見出し) にあり得るため。
                    # 17:14 に自分が書いた表が実際にその形だった。名指さず、数だけ別に持つ。
                    c2_undecidable += 1
                    continue
                c2_hits.append((str(f), no, line.strip()[:120]))
            nums.update(set(NUM_RE.findall(line)))
        if any(v >= 2 for v in nums.values()):
            c3_files += 1
    return dict(
        files=len(files), lines=lines_total,
        c1_total=c1_total, c1_hits=c1_hits,
        c2_total=c2_total, c2_hits=c2_hits, c2_undecidable=c2_undecidable,
        c3_files=c3_files,
    )


SCOPE_TEXT = """\
{tag} 射程 (この道具が自分で名乗るもの)
{tag}   見る       = 形のみ (C1 測定時刻らしき語の有無 / C2 判定対象らしき語の有無)
{tag}   見ない     = 中身の正しさ、行をまたいだ併記、引用と主張の別、2026-07-27 17:30 以前の文書
{tag}   落とさない = 終了コードは常に 0 (守らせる道具ではなく、腐ったときに気付く道具)
{tag}   走査対象   = queue/reports/*.yaml と plans/*.md (docs/ instructions/ は見ていない)
""".format(tag=TAG)


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:]]
    if "--scope" in args:
        sys.stdout.write(SCOPE_TEXT)
        return 0
    name = "--name" in args
    args = [a for a in args if not a.startswith("--")]
    paths = [Path(a) for a in args] or [Path(".")]
    files = collect(paths)

    # 母数を先に出す。「0 件該当」より先に「N 件走査」。0/0 と 0/8 は別物である。
    print(f"{TAG} 走査 {stats_files(files)} file / ", end="")
    r = scan(files)
    print(f"{r['lines']} 行")
    print(f"{TAG} C1 ps由来の時刻: 母数 {r['c1_total']} 行 → 測定時刻の併記なし {len(r['c1_hits'])} 行")
    print(f"{TAG} C2 第七条の札 : 母数 {r['c2_total']} 箇所 → 判定対象の一語なし {len(r['c2_hits'])} 箇所"
          f" (別に「判定できない (表の行)」 {r['c2_undecidable']} 箇所 = 名指さない)")
    print(f"{TAG} C3 同一数の再掲 (数のみ・判定しない): {r['c3_files']}/{r['files']} file")
    if name:
        for label, hits, why in (
            ("C1", r["c1_hits"], "ps 由来の時刻に測定時刻の併記がない (btime は後から動く)"),
            ("C2", r["c2_hits"], "第七条の札に「何の判定について」の一語がない"),
        ):
            for path, no, snippet in hits:
                print(f"{TAG} {label} {path}:{no}: {why}")
                print(f"{TAG}      | {snippet}")
    print(f"{TAG} 落とさない (終了コード 0) — これは名指しであって判定ではない。射程は --scope で出る。")
    return 0


def stats_files(files: list[Path]) -> int:
    return len(files)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
