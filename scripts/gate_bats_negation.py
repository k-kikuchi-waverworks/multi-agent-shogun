#!/usr/bin/env python3
"""gate_bats_negation.py — cmd_1401: ★刃を持たぬ負の主張★を bats file から名指す門.

★何を止めるか★
  bats の test 本文に書いた `! cmd` は ★bash の set -e から明示的に免除される★
  ("the command's return value is being inverted with !") =
  ★grep が当たっても (= 出てはならぬ物が現に出ておっても) test は緑のまま★。
  ★牙が折れたのではない。牙が最初から刃を持っておらなんだ★。

★由来 (2026-07-27・bats 1.13.0 で実測)★
  五号が cmd_1394 で己の負の主張 5 本が無効であったと掴んだ (変異 MUT-1394-005 が
  緑のまま生き残って露見)。★repo 全数 73 file に 94 箇所★・うち中途 52 箇所が無効で、
  ★配達層 (send_wakeup / inbox_watcher) に 50 本 集中★しておった =
  ★「撃ってはならぬ時に撃っておらぬ」を守る側の主張が丸ごと無効★であった。

★末尾に在る形も捕える★
  末尾の `! cmd` は test の戻り値そのものゆえ【今は】効く。★但し明日 1 行 足された
  瞬間に、音もなく死ぬ★。「末尾なら良い」を覚えておける者は居らぬゆえ形を一つに倒す。

★正しい書き方★
  `if <cmd>; then return 1; fi`   (bats が失敗行を印字するゆえ診断の言葉は要らぬ)

★門の限界 (先に名乗る)★
  ・★本門は行を見るだけで、shell の quote を判じておらぬ★= 引用符の中に置いた
    fixture の文字列も同じ形に見える (本門自身の試験が現に其れを踏み、fixture を
    printf の引数へ組み替えて避けた)。★偽陽性の側であり、見逃しの側ではない★。
  ・★ヒアドキュメントの中身も同じく区別できぬ★。
  ・★見ておるのは @test 本文のみ★= setup/teardown/helper 関数の中の `! cmd` は
    通す (helper で return 1 しても test は落ちぬゆえ、別の書き方が要る領分)。

Usage:
  python3 scripts/gate_bats_negation.py [ROOT]     # 既定 ROOT = repo root
  exit 0 = 0 箇所 / exit 1 = 1 箇所以上 (file:line で名指す)
"""

import os
import re
import sys
from pathlib import Path

# ★第三者管理の vendored suite は走査せぬ★ (彼らは彼らの規律で書いておる)。
EXCLUDE_PARTS = ("test_helper/bats-assert", "test_helper/bats-support")

# ★歩かぬ木★ (2026-07-27 刈込み): .bats が原理的に在り得ぬのに舐めておった枝。
#   ★之は【見なくする】刈込みではない★= 実測で ★此の下に .bats は 0 本★ を確かめた上で
#   歩くのを止めておる (.git 60MB / .venv 18MB を毎回 舐めて 2 秒 掛かっておった)。
#   ★危うさを先に名乗る★= 名で刈るゆえ、将来 此の名の下へ .bats を置けば黙って見落とす。
#   ⇒ ★守りは T-NEG-001 の canary (走査 file 数の下限) が持つ★ =
#     ★数が減れば、其れは【速くなった】のでなく【見なくなった】である★。
PRUNE_DIRS = frozenset({
    ".git", ".venv", "venv", "node_modules",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache",
})

# 行頭の否定: `! cmd`
LEAD = re.compile(r"^\s*!\s+\S")
# 行の途中の否定: `... && ! cmd` / `... || ! cmd` / `; ! cmd` / `then ! cmd`
# ★本夜の実測★= 此の形も免除に掛かり、当たっても緑であった (test_stop_hook.bats:130)。
INLINE = re.compile(r"(?:&&|\|\||;|\bthen\b)\s+!\s+\S")


def _walk_bats(root: Path):
    """★歩く枝を刈った rglob★ = PRUNE_DIRS を root から辿らぬ (中身も見ぬ)."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        for fn in filenames:
            if fn.endswith(".bats"):
                yield Path(dirpath) / fn


def scan(root: Path):
    hits = []
    files = [p for p in _walk_bats(root)
             if not any(x in p.as_posix() for x in EXCLUDE_PARTS)]
    for p in sorted(files):
        try:
            lines = p.read_text(encoding="utf-8").split("\n")
        except OSError as e:
            print(f"[gate_bats_negation] WARN: 読めぬ file: {p}: {e}", file=sys.stderr)
            continue
        in_test = False
        for i, line in enumerate(lines, start=1):
            if re.match(r"^@test\s", line):
                in_test = True
            elif line.startswith("}"):
                in_test = False
            if not in_test:
                continue
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if LEAD.match(line) or INLINE.search(line):
                hits.append((p, i, stripped))
    return files, hits


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent
    files, hits = scan(root)
    # ★0 を報ずる前に分母を名乗る★ (走査 0 file の緑と、現に 0 箇所の緑を混ぜぬ =
    #  2026-07-27 に全軍で潰した「分母0の検知層は全PASSと区別がつかぬ」の同族)。
    print(f"[gate_bats_negation] 走査 {len(files)} file (root={root})")
    if not hits:
        print("[gate_bats_negation] OK: 刃を持たぬ負の主張は 0 箇所")
        return 0
    print(f"[gate_bats_negation] ★NG★ 刃を持たぬ負の主張 {len(hits)} 箇所:")
    for p, i, text in hits:
        try:
            rel = p.relative_to(root)
        except ValueError:
            rel = p
        print(f"  {rel}:{i}: {text}")
    print("  ⇒ ★bats の `! cmd` は set -e から免除され、当たっても緑である★")
    print("  ⇒ 直し方: `! <cmd>` を  if <cmd>; then return 1; fi  へ倒せ")
    print("  ⇒ ★据える其の場で一度 偽にし、現に赤が出ることを見よ★ (家老 02:12 の規律)")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
