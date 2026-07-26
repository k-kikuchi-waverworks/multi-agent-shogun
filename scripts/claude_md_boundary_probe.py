#!/usr/bin/env python3
"""★CLAUDE.md が名乗る「関所の境界」と、関所の実装が現に一致しておるかを撃つ器★ (cmd_1398 O-1)

★守るのは文言ではない。【docs と実装の一致】である★ =
  ・docs から語を1つ抜けば落ちる (CLAUDEMD-TEXT)
  ・★実装の境界を動かせば落ちる (CLAUDEMD-BOUNDARY)★ ← 之が本器の芯

★★例の選び方が本器の設計の芯にござる (2026-07-27 の教訓)★★
  初版は `--content-file "$HOME/x"` を「引数位置は通る」の例に据えた。
  ★之は【二つの理由】で ALLOW になる★ =
    (甲) 散文位置でない (= 守りたい当の性質)
    (乙) 展開を除いた残りが "/x" ゆえ、そもそも散文に見えぬ
  ⇒ ★(乙) が単独で緑を支えるゆえ、(甲) を壊しても緑のまま★ = ★狙うた側を一つも見ておらなんだ★。
  ★家老が之を【多重支持の緑】と名付けた (02:15)★。
  ⇒ ★ゆえに例は「残りも散文である」物を選ぶ★ = ★位置だけが ALLOW を支える形★。

★己の在処から関所を引く★ = 変異試験は複写した木で走るゆえ、
★絶対 path で本物を引けば【複写に当てた変異が見えぬ】= 器自身が偽の緑を返す★。
"""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GUARD = ROOT / "scripts" / "shell_expansion_guard.py"
CLAUDE_MD = ROOT / "CLAUDE.md"

IW = "bash scripts/inbox_write.sh"
NT = "bash scripts/ntfy.sh"

# (名, 撃つ command, 期待)
CLAIMS = [
    # ★主張1 = backtick はどの引数位置でも止める★
    ("主張1 backtick / 本文位置", f'{IW} karo "本文 `id`" progress ashigaru6', "DENY"),
    ("主張1 backtick / path位置", f'{IW} karo --content-file "`pwd`/x" progress ashigaru6', "DENY"),
    ("主張1 backtick / 宛先位置", f'{IW} "`echo karo`" --body-stdin progress ashigaru6', "DENY"),
    ("主張1 backtick / ntfy題位置", f'{NT} "題 `id`" "本文"', "DENY"),
    # ★主張2 = 散文位置の展開は止める★
    ("主張2 $VAR / 散文位置", f'{IW} karo "本文 $UNDEF じゃ" progress ashigaru6', "DENY"),
    # ★主張3 = 散文位置でない引数は通す★
    #   ★残りも散文である例を据える★ = 位置だけが ALLOW を支える形 (多重支持の緑を避ける)
    ("主張3 path位置・残りも散文", f'{IW} karo --content-file "$HOME/わしの 書付.txt" progress ashigaru6', "ALLOW"),
    ("主張3 宛先位置・残りも散文", f'{IW} "$T なる者" --body-stdin progress ashigaru6', "ALLOW"),
]

# ★docs が此の三主張を名乗っておるか★ = 語を抜けば落ちる
TEXT_MARKERS = [
    "どの引数位置でも",          # 主張1
    "散文位置 (inbox_write の本文 / ntfy の題と本文) に限って",  # 主張2/3 の境界
    "までしか意味せぬ",          # 「通った」が何を意味せぬか
]


def main() -> int:
    bad = 0

    # ── ★実装の側★ ──────────────────────────────────────────
    spec = importlib.util.spec_from_file_location("guard_under_test", GUARD)
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    for name, cmd, expect in CLAIMS:
        got = g.analyze(cmd)["verdict"]
        if got != expect:
            bad += 1
            print(f"★NG★ CLAUDEMD-BOUNDARY: {name} — CLAUDE.md は {expect} と名乗るが実装は {got}")
        else:
            print(f"  ok  {name} = {expect}")

    # ── ★docs の側★ ──────────────────────────────────────────
    text = CLAUDE_MD.read_text(encoding="utf-8")
    for marker in TEXT_MARKERS:
        if marker not in text:
            bad += 1
            print(f"★NG★ CLAUDEMD-TEXT: CLAUDE.md から境界の名乗りが消えておる — 「{marker}」不在")
        else:
            print(f"  ok  CLAUDE.md が名乗っておる: 「{marker}」")

    total = len(CLAIMS) + len(TEXT_MARKERS)
    print(f"\n{'PASS' if not bad else 'FAIL'}: 境界の突合 {total - bad}/{total} 一致")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
