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
  python3 scripts/gate_mutation_replay.py --negative-assertions
                                                        # 付帯5: ★負の主張に刃が在るか★
                                                        #   段1 = bats の `!` (刃を持たぬ形) を止める
                                                        #   段2 = 台帳 red_needle に名指されておらぬ
                                                        #         負の主張を数える (★分母★)
  python3 scripts/gate_mutation_replay.py --selftest    # 変異試験つき自己検分
  python3 scripts/gate_mutation_replay.py --tree-census --watched-file F
                                                        # ★木の点呼 (cmd_1374)★: 牙を持つのに
                                                        #   どの gate も見ておらぬ repo を名指す
"""
from __future__ import annotations

import argparse
import datetime
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


def _today() -> datetime.date:
    """本日 (GATE_TODAY=YYYY-MM-DD で差替可 — selftest を暦から独立させるため)。

    ★差替口を置く理由★: 期限つき免除の検分は「今日が何日か」に依る。selftest が暦で
    赤くなったり緑になったりする形にすると ★試験そのものが日付で黙る★ = 本 gate が
    塞ごうとしておる型そのものである。ゆえに試験は必ず日付を固定して撃つ。
    """
    ov = os.environ.get("GATE_TODAY")
    if ov:
        try:
            return datetime.date.fromisoformat(ov.strip())
        except ValueError:
            # ★黙って本日へ倒れぬ★ (家老 規律(3b) 2026-07-26): 道具が代用品へ落ちる時は
            # 必ず告げよ。黙って倒れると ★固定したはずの日付で試験が動いておらぬ★ のに
            # 緑が出る = 四号の style vector fallback と同じ型になる。
            raise SystemExit(f"[gate] GATE_TODAY が日付として読めぬ: {ov!r}"
                             " — 黙って本日へ倒れることはせぬ (YYYY-MM-DD で書け)")
    return datetime.date.today()

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


# ─────────────────────────────────────────────────────────────────────────────
# gate-2 付帯3: ★着弾の一意性★ (cmd_1382 — 家老 規律(8) 2026-07-26 の機械化)
#
# 何を塞ぐか: ★anchor が非一意なら、狙いは黙って別の場所へ着弾する★。
#   ★これは空振りではない = 撃ってはおる。撃つ場所が違う★ ⇒ byte 変化も赤も出るゆえ
#   既存の「mutate 空振り (byte 一致で UNDETERMINED)」の層では ★原理的に捕えられぬ★
#   (あの層は【当たったか】を見ておるが【狙った場所に当たったか】は見ておらぬ)。
#   実害 = 五号の変異が、旧い同名の関数を先に撃っておった (replace(old,new,1) が先頭を取る)。
#
# 症状は二種 (六号の census 2026-07-26 で両方 実在を確認):
#   (a) ★巻き込み型★ = sed に count 指定が無い形 → 狙い + 余所も同時に撃つ
#   (b) ★移動型★     = python replace(old,new,1) 形 → 着弾は 1 箇所だが、それが狙いとは限らぬ
#
# 測り方 (静的な anchor 解析はせぬ — 台帳の mutate は 113 通りの綴りで書かれており、
#          綴りを読む道は必ず取りこぼす。★実際に撃って数える★):
#   ・第1射 = pristine へ mutate → ★二つの独立した物差しで数え、多い方を採る★。
#     - 物差しA (綴り) = 文字単位の編集片を採り、★同一の (消えた綴り→現れた綴り) が
#       何度現れたか★ を数える。
#     - 物差しB (行の塊) = ★変わった行の【離れた塊】が幾つか★ を数える (cmd_1382 差し戻し)。
#       ※ 空白のみの組は両方の数から外す = 多行 block の字下げ直しが n 発火に見える
#          偽陽性を実測で潰した (物差しB は連続した塊を 1 と数えるゆえ字下げ直しに強い)。
#   ・残り候補の検分 = ★第1射が変えた行だけを空行に潰した pristine★ へ同じ mutate を当てる。
#     変われば ★第1射が撃たなんだ候補が残っておった★ = (b)。
#     己の守り (assert old in s 等) で落ちる / ★1 byte も変えぬ★ のが候補尽き = 一意の証。
#     ※ 行を消さず空行で潰すのは `sed -i '12s/…'` の類が ★行番号で狙う★ ゆえ。
#
# ★物差しBを足した理由 (cmd_1382 差し戻し・軍師一号の名指し)★:
#   物差しA は ★key の一致★ に頼るゆえ、同じ狙いでも difflib の文字整列が site ごとに
#   別の境界へ割れると ★key が別物になり、max が 1 しか見ぬ★ = ★少なく数える★。
#   六号の実測 = `0`→`1` を `aa0aa` / `a00aa` へ当てると ★現に2行へ着弾しておるのに
#   fired=1 で PASS★ (総当り 1,254,499 組中 1 件・稀ではあるが現に在る)。
#   ⇒ ★key に依らぬ物差しBを併走させ、多い方を採る★ = 片方が盲でも他方が数える。
#
# ★過大申告も咎める (cmd_1382 差し戻し・足軽二号の名指し)★:
#   旧版は `fired > declared` しか見ておらなんだゆえ ★anchor_sites: 99 と書けば門は黙った★
#   (六号 実測 rc=0 PASS)。★申告は【飾り】になってはならぬ★ ⇒ ★実測と一致せねば鳴る★。
#
# ★この網が答えぬ問い (名乗っておく — 消えたら赤くなる形で下の selftest が縛る)★:
#   ① ★一意であることは、其の1箇所が【狙った場所】である事を意味せぬ★。
#      「一意か」と「狙った場所か」は別の問いである (狙いは red_needle が別に縛る)。
#   ② ★一意でも波及が広ければ同じ穴★ (規律(8) 第三の型・軍師二号)。共有 helper を撃てば
#      anchor は一意でも赤の出所が絞れぬ。本層は ★波及の広さを測っておらぬ★。
#
# ★かつて②として名乗っておった「自食い型」は、cmd_1382 差し戻しで【塞いだ】★:
#   第1射が己の産物を食う形 (置換後の綴りが自分に当たる) では第2射が同じ行へ戻るゆえ
#   ★その先に第2候補が在っても見えなんだ★ (六号 実測: 第2候補が現に残っておるのに PASS)。
#   ⇒ ★盤面の側を変えて塞いだ★ = 第1射の変えた行を伏せた pristine へ当てるゆえ
#   ★己の産物が盤面に居らず、自食いが原理的に起こらぬ★。
#   ※ 初版は「第2射が第1射の触れた行へ戻ったら鳴らす」と書いたが、★これは誤りであった★ =
#     申告つきの全置換 (T41) まで巻き込んで赤くした。★常に鳴る門は外される★ ゆえ
#     「戻ったか」でなく ★「撃たれておらぬ候補が在るか」★ を直に問う形へ改めた。
#
# 宣言: entry に `anchor_sites: N` を書けば「N 箇所で発火するのが意図である」と申告できる
#       (既定 1)。★意図的な全置換を禁じてはおらぬ。黙って全置換することを禁じておる★。
#       ★N は実測と一致せねばならぬ (過大も過小も鳴る)★。
# ─────────────────────────────────────────────────────────────────────────────
ANCHOR_SITES_DEFAULT = 1


def _read_lines_safe(p: Path):
    try:
        return p.read_text(encoding="utf-8", errors="surrogateescape").split("\n")
    except Exception:
        return None


def _tree_text_files(root: Path) -> dict[str, Path]:
    return {str(p.relative_to(root)): p for p in sorted(root.rglob("*"))
            if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}


def anchor_firings(a_root: Path, b_root: Path) -> tuple[int, list]:
    """a→b で【同一の綴り置換】が最大何箇所で発火したかと、その内訳を返す。"""
    import difflib
    af, bf = _tree_text_files(a_root), _tree_text_files(b_root)
    rep: dict[tuple, int] = {}
    for rel in sorted(set(af) & set(bf)):
        al, bl = _read_lines_safe(af[rel]), _read_lines_safe(bf[rel])
        if al is None or bl is None or al == bl:
            continue
        a, b = "\n".join(al), "\n".join(bl)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
            if tag == "equal":
                continue
            old, new = a[i1:i2], b[j1:j2]
            if old.strip() == "" and new.strip() == "":
                continue  # 字下げ直し等 = 1 箇所の編集が n 発火に見える偽陽性を除く
            rep[(rel, old, new)] = rep.get((rel, old, new), 0) + 1
    if not rep:
        return 0, []
    worst = max(rep.values())
    detail = [{"file": k[0], "old": k[1][:60], "new": k[2][:60], "count": v}
              for k, v in sorted(rep.items(), key=lambda kv: -kv[1]) if v >= 2][:3]
    return worst, detail


def changed_line_hunks(a_root: Path, b_root: Path) -> int:
    """★物差しB (cmd_1382 差し戻し)★: 変わった行の【離れた塊】が幾つかを数える。

    物差しA (anchor_firings) は ★同一の (old→new) key★ に頼るゆえ、difflib の文字整列が
    site ごとに別境界へ割れると key が別物になり ★少なく数える★。本関数は key を見ず
    ★行の連続性★ だけを見るゆえ、其の盲を持たぬ。
    ★連続した塊は 1 と数える★ = 多行 block の字下げ直し (1 箇所の編集) を n 発火と誤らぬ。
    """
    return _diff_shape(a_root, b_root)[0]


def _diff_shape(a_root: Path, b_root: Path):
    """(塊の数, 純粋な挿入が在るか, 行の移動が在るか) を返す。

    ★形を知る必要が在る理由★= 下の「残り候補の検分」は ★置換型の変異にしか当てはまらぬ★。
    挿入/追記型と移動型では ★盤面を「消費済」に潰す術が無い★ ゆえ、当て直せば当然また動く
    (= 候補が残っておる証にならぬ)。★当てはまらぬ検分を当てれば、正しい牙を赤にする★。
    """
    import difflib
    af, bf = _tree_text_files(a_root), _tree_text_files(b_root)
    hunks = 0
    has_insert = False
    has_move = False
    for rel in sorted(set(af) & set(bf)):
        al, bl = _read_lines_safe(af[rel]), _read_lines_safe(bf[rel])
        if al is None or bl is None or al == bl:
            continue
        pieces = []
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
                None, al, bl, autojunk=False).get_opcodes():
            if tag == "equal":
                continue
            old, new = "".join(al[i1:i2]), "".join(bl[j1:j2])
            # ★空白だけが動いた塊は数から外す★ = 字下げ直しを着弾と誤らぬため。
            #   ※ 判ずるのは【中身が空白か】ではなく ★【動いたのが空白だけか】★ である
            #     (初版は前者で書いており、行末に空白を足すだけの変異を 1 発火と数えて
            #      おった = ★己の物差しが己の意図と食い違うておった★ — selftest T49 が捕えた)。
            if "".join(old.split()) == "".join(new.split()):
                continue
            pieces.append(("".join(old.split()), "".join(new.split())))

        # ★行の【移動】は 1 箇所と数える (cmd_1382 差し戻しの実測で判った偽陽性)★:
        #   ある所から消えた綴りが、余所へそのまま現れておるなら ★1 つの編集★ である。
        #   実例 = backend MUT-1350-M1 (五号) = 2 つの sed で ★行を移す★ 変異ゆえ
        #   「消す塊」と「入れる塊」の 2 つに割れ、★初版は之を 2 箇所着弾と誤って鳴らした★。
        #   ※ 限界 (名乗っておく): 突き合わせは ★同一 file の中★ のみ。file を跨ぐ移動は
        #     今も 2 と数える (跨ぐ移動を偶然の一致と見分ける術を持たぬゆえ、多く数える側へ倒す)。
        dels = [i for i, (o, n) in enumerate(pieces) if o and not n]
        adds = [i for i, (o, n) in enumerate(pieces) if n and not o]
        used = set()
        moved = 0
        for d in dels:
            for a in adds:
                if a not in used and pieces[d][0] == pieces[a][1]:
                    used.add(a)
                    moved += 1
                    break
        if moved:
            has_move = True
        if len(adds) > moved:
            has_insert = True   # 移動と対にならぬ挿入が残っておる = 純粋な挿入/追記
        hunks += len(pieces) - moved
    return hunks, has_insert, has_move


def _blank_changed_lines(pristine: Path, mut: Path, probe: Path) -> None:
    """pristine を写し、★第1射が変えた行だけを空行に潰した木★ を probe へ作る。

    ★狙い★= 「第1射が撃たなんだ候補が、まだ残っておるか」を直に問うための盤面。
    ★行を消さず空行で潰す★のは、`sed -i '12s/x/y/'` の類が ★行番号で狙う★ ゆえ
    行数を変えれば別の場所を撃ってしまうからである。
    """
    import difflib
    af, bf = _tree_text_files(pristine), _tree_text_files(mut)
    for rel, src in af.items():
        dst = probe / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        al = _read_lines_safe(src)
        if al is None or rel not in bf:
            shutil.copy2(src, dst)
            continue
        bl = _read_lines_safe(bf[rel])
        if bl is None:
            shutil.copy2(src, dst)
            continue
        out = list(al)
        for tag, i1, i2, _j1, _j2 in difflib.SequenceMatcher(
                None, al, bl, autojunk=False).get_opcodes():
            if tag != "equal":
                for k in range(i1, i2):
                    out[k] = ""
        dst.write_text("\n".join(out), encoding="utf-8", errors="surrogateescape")
        try:
            shutil.copystat(src, dst)
        except Exception:
            pass


def untouched_line_set(pristine: Path, shot1: Path) -> set:
    """第1射が【触れなかった】行の集合。第2射がここを撃てば別候補が在った証。"""
    import difflib
    af, bf = _tree_text_files(pristine), _tree_text_files(shot1)
    keep = set()
    for rel in sorted(set(af) & set(bf)):
        al, bl = _read_lines_safe(af[rel]), _read_lines_safe(bf[rel])
        if al is None or bl is None:
            continue
        for tag, i1, i2, _j1, _j2 in difflib.SequenceMatcher(
                None, al, bl, autojunk=False).get_opcodes():
            if tag == "equal":
                keep.update((rel, l) for l in al[i1:i2])
    return keep


def removed_lines(a_root: Path, b_root: Path) -> list:
    import difflib
    af, bf = _tree_text_files(a_root), _tree_text_files(b_root)
    out = []
    for rel in sorted(set(af) & set(bf)):
        al, bl = _read_lines_safe(af[rel]), _read_lines_safe(bf[rel])
        if al is None or bl is None or al == bl:
            continue
        for tag, i1, i2, _j1, _j2 in difflib.SequenceMatcher(
                None, al, bl, autojunk=False).get_opcodes():
            if tag != "equal":
                out += [(rel, l) for l in al[i1:i2]]
    return out


def check_anchor_uniqueness(e, pristine: Path, mut: Path, work: Path, timeout: int,
                            spelling_measure: bool = True):
    """着弾の一意性を検める。問題が無ければ None、在れば理由の文字列を返す。

    spelling_measure=False (cmd_1387 の pre-commit 層のみ) は ★物差しA を走らせぬ★:
      ★実測 2026-07-27 = 物差しA は 2107 行の file 1 本で 45.0 秒、物差しB は 0.00 秒★
      (char 単位 SequenceMatcher ゆえ file 長に対し二乗で伸びる)。commit の度に
      45 秒×選抜件数を払わせる門は ★必ず外される★ ゆえ、其の場で気付く層は物差しBのみで撃つ。
      ★残余は正直に名乗る = 同一行に複数箇所在る形は物差しBには 1 に見える★
      (実測: `FLAG = 0; OTHER = 0` へ 0→1 を当てると 物差しA=2 / 物差しB=1)。
      ⇒ ★其の形は翌朝の全数 replay (物差しA 併走) が捕える = 本層は【早さ】を買い、
        【網の広さ】は買っておらぬ★。二層の役割が違うのであって、片方は片方の代用ではない。
    """
    declared = e.get("anchor_sites", ANCHOR_SITES_DEFAULT)
    try:
        declared = int(declared)
    except (TypeError, ValueError):
        return f"anchor_sites が整数でない: {e.get('anchor_sites')!r}"

    if spelling_measure:
        by_spelling, detail = anchor_firings(pristine, mut)
        spell_note = f"綴り {by_spelling}"
    else:
        # ★0 と書けば「測って 0 であった」と読まれる★ = 未測を実測へ化かさぬため別に持つ。
        by_spelling, detail = -1, []
        spell_note = "綴り 未測 (pre-commit 層ゆえ省いた)"
    by_hunks, has_insert, has_move = _diff_shape(pristine, mut)
    # ★二つの物差しの多い方を採る★ = 片方が盲でも他方が数える (cmd_1382 差し戻し (i))
    fired = max(by_spelling, by_hunks)

    if fired > declared:
        d = "; ".join(f"{x['file']}「{x['old']}」→「{x['new']}」×{x['count']}" for x in detail)
        # ★どちらの物差しが鳴らしたかを必ず名乗る★ = 「綴りとしては 1 箇所に見える」形が
        #   現に在るゆえ、内訳が空でも読む者が惑わぬようにする。
        which = ("綴り+行の塊の双方" if by_spelling == by_hunks else
                 ("綴り" if by_spelling > by_hunks else
                  ("行の塊 (綴りは測っておらぬ)" if not spelling_measure else
                   f"行の塊 (綴りとしては {by_spelling} 箇所にしか見えぬ)")))
        return (f"★同一の綴り置換が {fired} 箇所で発火 (申告は {declared} 箇所)★ = 狙い+余所を"
                f"巻き込んでおる。赤が出ても【どの箇所の赤か】を名指しできぬ。"
                f" 数えた物差し = {which} ({spell_note} / 行の塊 {by_hunks})."
                + (f" 内訳: {d}." if d else "")
                + f" 処方 = anchor を一意な綴りへ絞る (前後の行を含める) か、全置換が意図なら"
                f" 台帳へ anchor_sites: {fired} と書け (黙って全置換するのを禁じておる)")

    if fired == 0:
        # 空白のみの変更 = 着弾を測る術が無い。★黙って通さぬ★ (未検分は緑ではない)。
        return ("★着弾を測れなんだ (変わったのは空白のみ)★ = 一意とは言えぬ。"
                " 処方 = 空白でなく【意味の在る綴り】を変える mutate にせよ")

    if declared > fired:
        # ★過大申告 = 申告が飾りになる道★ (cmd_1382 差し戻し (ii)・足軽二号の名指し)。
        # 旧版は fired > declared しか見ておらず、anchor_sites: 99 と書けば門は黙った。
        return (f"★anchor_sites の申告 {declared} 箇所に対し、実測は {fired} 箇所★ = 過大申告。"
                f" ({spell_note} / 行の塊 {by_hunks})"
                f" ★申告を大きく書けば門は黙る★ ゆえ、申告と実測の食い違いは両向きに咎める。"
                f" 処方 = 台帳の anchor_sites を {fired} へ直せ (実測に合わせよ)")

    # ★残り候補の検分 (cmd_1382 差し戻し (iii) で「第2射」から置き換えた)★
    #   ★旧版の第2射の穴★= 第1射の【結果】へもう一度当てておったゆえ、置換後の綴りが
    #   元の綴りを含む形 (guard→guardX→guardXX) では ★第2射が第1候補へ戻るだけ★ で、
    #   其の先に候補が在るか否かを一度も見ておらなんだ (★自食い型★・軍師一号の名指し。
    #   六号の実測 = 第2候補が現に残っておるのに rc=0 PASS)。
    #   ★今の形★= 第1射が【変えた行だけを空行に潰した pristine】へ当てる =
    #   ★己の産物が盤面に居らぬゆえ自食いが起こらぬ★。変われば ★撃たれなんだ候補が残っておった★。
    if has_insert or has_move:
        # ★此の検分は置換型にしか当てはまらぬ★ (上の _diff_shape の注を見よ)。
        #   挿入/追記型 = 消える行が無いゆえ盤面を消費済に潰せぬ。
        #   移動型     = difflib が「消す/入れる」のどちらを選ぶかで潰す行が変わり、
        #                潰し損ねた側を当て直しが再び撃つ。
        #   ★いずれも「また変わった」が候補の残存を意味せぬ★ ゆえ、当てずに退く。
        #   ★何箇所へ挿入/移動したかは 物差しA/B が既に数えておる★ゆえ穴にはならぬ。
        #   実例 (配線前の全数計数で捕えた偽陽性) = backend MUT-1350-M1 (移動) /
        #   M2 (追記) / M4 (挿入) = いずれも五号の正しい牙であった。
        return None

    probe = work / "probe"
    try:
        _blank_changed_lines(pristine, mut, probe)
    except Exception as ex:
        # ★黙って見送らぬ★ (規律(3b)): 測れなんだ時は「測れなんだ」と名乗る。
        # 黙って None を返せば ★検分しておらぬ物が「一意」の顔をして通る★。
        return f"着弾の検分ができなんだ (残り候補の盤面を作れず: {ex!r}) = 未検分。一意とは言えぬ"
    before = tree_digest(probe)
    if before == tree_digest(pristine):
        # ★伏せる物が無かった = 第1射は pristine から何も【消して】おらぬ★
        #   (純粋な挿入・追記型の変異。difflib では i1==i2 ゆえ潰す行が無い)。
        #   ⇒ ★この盤面は pristine と同じゆえ、当て直せば当然また挿入される★ =
        #   ★「また変わった」は候補が残っておる証にならぬ★。此の検分は【当てはまらぬ】。
        #   実例 = backend MUT-1350-M2 (追記型) / M4 (挿入型) = 五号。
        #   ★初版は之を「候補が残っておる」と誤って鳴らした★ (配線前の全数計数が捕えた)。
        #   挿入型の非一意は ★物差しA/B が【何箇所へ挿入したか】として既に数えておる★ゆえ
        #   此処を素通しても穴にはならぬ。
        return None
    rc2, _out2 = run_sh(e["mutate"], probe, timeout)
    if rc2 is None or rc2 != 0:
        return None  # 己の守り (assert old in s 等) で落ちた = 候補は尽きておった
    if before == tree_digest(probe):
        return None  # 1 byte も変えられなんだ = ★撃たれておらぬ候補は残っておらぬ★ = 一意

    return ("★第1射が撃たなんだ候補が、まだ残っておる★ = anchor が一意でない"
            " (第1射の変えた行を伏せた盤面へ同じ mutate を当てたら、別の場所が現に変わった)。"
            " replace(old,new,1) 型は先頭を取るゆえ ★狙いが黙って別所へ移りうる★。"
            " 処方 = anchor を一意な綴りへ絞る (前後の行を含める) か、"
            "mutate の中で assert s.count(old) == 1 を書け")


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


def registry_shard_dir(path: Path) -> Path:
    """台帳 file から、族 shard 置場の名を導く。

    config/mutation_registry.yaml     → config/mutation_registry.d
    config/mutation_registry.web.yaml → config/mutation_registry.web.d
    """
    return path.with_suffix(".d")


def resolve_registry_doc(path: Path):
    """★cmd_1386 手1★ 台帳の二形 (単一 file / 族 shard 群) を、読む側で吸収する。

    返り = (doc, error, present)
      doc     = YAML 最上位 mapping 相当 (旧形=そのまま / 新形=shard を束ねた結果)
      error   = 非 None なら UNDETERMINED (呼び手が己の接頭辞をつけて出す)
      present = 台帳が【在る】か (旧 file も .d も無ければ False)

    ★迷う形は全て UNDETERMINED へ倒す (fail-closed)★ =
    「読めぬ」を「0 件」や「緑」へ倒さぬ (EMPTY_REGISTRY_IS_UNDETERMINED の流儀)。
    """
    import yaml
    d = registry_shard_dir(path)
    has_file, has_dir = path.is_file(), d.is_dir()

    # ★新旧同時存在が最も危うい★ = どちらを正とするかを黙って選べば、
    #   人が開いた file の中身が実効値でなくなる (cmd_1350 の食い違いと同型の罠)。
    if has_file and has_dir:
        return None, (f"台帳が新旧 同時に存在する: {path} と {d} —"
                      " どちらを正とするかを黙って選ばぬ (移行が中途である疑い)"), True
    if not has_file and not has_dir:
        return None, None, False
    if has_file:
        try:
            return yaml.safe_load(path.read_text(encoding="utf-8")), None, True
        except Exception as e:  # parse 不能は「0件」ではなく「未判定」
            return None, f"台帳が parse 不能: {e}", True

    # ── 族 shard 形 ── ★1 つの shard が読めぬだけで全件を落とさぬ★ ではなく、
    #   束ねた結果を 1 つの台帳として扱う以上、読めぬ shard が在れば未判定を返す
    #   (どの shard かを必ず名指す = 家老が誰へ回すべきかが判る)。
    shards = sorted(d.glob("*.yaml"))
    if not shards:
        return None, (f"台帳の .d が空: {d}"
                      " (shard が 1 つも無い = 0 件ではなく未判定)"), True
    merged: dict = {}
    mutations: list = []
    saw_mutations = False
    origin: dict[str, str] = {}
    for s in shards:
        try:
            data = yaml.safe_load(s.read_text(encoding="utf-8"))
        except Exception as e:
            return None, f"shard が parse 不能: {s.name}: {e}", True
        if data is None:
            return None, f"shard が空: {s.name} (空の shard は 0 件ではなく未判定)", True
        if not isinstance(data, dict):
            return None, f"shard が mapping でない: {s.name}", True
        for k, v in data.items():
            if k == "mutations":
                if not isinstance(v, list):
                    return None, f"shard の mutations が list でない: {s.name}", True
                saw_mutations = True
                mutations.extend(v)
            elif isinstance(v, list):
                merged.setdefault(k, []).extend(v)
            else:
                # ★同じ key を 2 つの shard が別の値で名乗ったら、黙って片方を採らぬ★
                if k in origin and merged.get(k) != v:
                    return None, (f"shard 間で {k} が食い違う: {origin[k]} と {s.name}"
                                  " (黙って片方を採らぬ)"), True
                merged[k] = v
                origin[k] = s.name
    if saw_mutations:
        # ★id 重複の検分は束ねた後に行う★ (族を跨いだ重複を見逃さぬ) = load_registry 側
        merged["mutations"] = mutations
    return merged, None, True


def load_registry(path: Path):
    """(entries, error) を返す。error が非 None なら UNDETERMINED。"""
    data, rerr, present = resolve_registry_doc(path)
    if rerr:
        return None, rerr
    if not present:
        return None, f"台帳が無い: {path}"
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
    # cmd_1382: 着弾数の申告は整数のみ (綴り間違いを黙って既定 1 へ倒さぬ)
    if "anchor_sites" in e:
        try:
            n = int(e["anchor_sites"])
        except (TypeError, ValueError):
            return f"anchor_sites が整数でない: {e['anchor_sites']!r}"
        if n < 1:
            return f"anchor_sites は 1 以上であるべき: {n}"
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


def purge_pycache(root: Path) -> None:
    """★射の前に、走る物と測る物を揃える (規律(8) 第四の型 = (d))★

    ★何を塞ぐか★= ★file には当たったが interpreter に届かぬ★道。
    Python の .pyc は (source の mtime【秒】, size) だけで有効性を判ずるゆえ、
    ★同じ byte 数の変異を同じ秒に書けば、古い .pyc が有効と判ぜられ【変異前の code が走る】★
    (五号が cmd_1384 で 4 段で決定的に再現・2026-07-26)。
    ★束縛入替 (列の順を入れ替える等) は size 差が寸分違わぬゆえ、最も当たり易い★。

    ★今 此の runner が免れておる理由は _IGNORE (copytree が __pycache__ を写さぬ) である★=
    ★然れど其れは【遠くの一行に偶々乗った免疫】であり、写し方を変える者が黙って壊しうる★。
    ⇒ ★射の前に此処で消す = 免疫を意図として、撃つ場所の傍らに置く★。
    ★負例 T54 が此の処置を縛っておる (外せば赤くなる)★。
    """
    for d in sorted(root.rglob("__pycache__")):
        if d.is_dir():
            shutil.rmtree(d, ignore_errors=True)
    for p in sorted(root.rglob("*.pyc")):
        try:
            p.unlink()
        except OSError:
            pass


def run_sh(script: str, cwd: Path, timeout: int):
    env = dict(os.environ)
    # ★新たな .pyc を書かせぬ★ = 上の purge_pycache と対で (d) を閉じる。
    #   purge = 持ち込まれた古い物を消す / 本 env = 射の途中で新たに作らせぬ。
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        r = subprocess.run(["bash", "-c", script], cwd=cwd, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                           env=env)
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
        # ★写した直後に消す★ = paths が .pyc を名指して挙げておっても持ち込まれぬ
        purge_pycache(d)

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
    # ★変異を当てた【後】にもう一度消す★ = 変異前の code から作られた .pyc を残さぬ。
    #   ★baseline は別の木 (base) で撃つゆえ mut に古い .pyc は出来ぬ筈だが、
    #     「筈」を頼りにせぬ★ = mutate 自身が import する形も在りうる (python3 - <<PY 型)。
    purge_pycache(mut)

    # ③ ★空振り検知★: mutate が 1 byte も変えておらねば「赤くなるか」を測っておらぬ
    #    (sed の当たり損ねは沈黙する — これ自体が本 gate が塞ぐ「沈黙する落とし穴」の一種)
    if tree_digest(pristine) == tree_digest(mut):
        return UNDET, "mutate 空振り (何も変えておらぬ) = pattern の当たり損ね。mutate を直せ"

    # ③b ★着弾の一意性★ (cmd_1382・規律(8)): 上の空振り検知は【当たったか】しか見ておらぬ。
    #     ★非一意なら撃ってはおる = byte も変わり赤も出る。だが撃つ場所が違う★ ゆえ
    #     ここで測らねば ★「確かめた」と「運が良かった」が区別できぬ★。
    #     判定は UNDETERMINED = ★未検分は緑ではない (が、牙が折れた FAIL とも違う)★。
    why_anchor = check_anchor_uniqueness(e, pristine, mut, work, timeout)
    if why_anchor:
        return UNDET, why_anchor

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


def board_declaration(repo: Path, entries) -> str:
    """★本 gate が読んだ盤面を名乗る (事例15・軍師一号の名指し)★

    ★軍師一号の指摘★= evaluate_entry は copy_paths で ★worktree から写す★ ゆえ、
    ★毎朝の緑は【作業ツリーが壊せば落ちる】ことしか言うておらぬ★ =
    ★HEAD が・まして配られる物が同じ性質を持つとは言うておらぬ★。

    ★六号の判 = 之は【仕様】である (欠陥ではない)★:
      本 gate は pre-commit でも使われ、★其処では「これから commit する物」を検めるのが目的★ゆえ、
      HEAD を読めば ★門が用を成さぬ★ (未 commit の是正を検められぬ)。
    ★然れど【名乗っておらぬ】のは欠陥である★ = ★今は読む者が HEAD の話と読む (規律(6) の型)★。

    ⇒ ★静かな一文を毎回刷るのでなく、★食い違う其の時に名指す★形を採った★:
      ・作業ツリー = HEAD なら ★「今回は HEAD についても同じ事を言うておる」と積極的に言える★
      ・食い違えば ★何が食い違うかを列挙し、「此の緑は HEAD について何も言うておらぬ」と告げる★
    ★之なら【いつ効く警告か】が読む者に判る★ = 常に鳴る門にならぬ。
    """
    rels = sorted({str(p) for e in entries if isinstance(e, dict)
                   for p in (e.get("paths") or [])})
    if not rels:
        return "  [盤面] 台帳に paths が無い = 検分の対象を持たぬ"
    try:
        r = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "--"] + rels,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"  [盤面] ★作業ツリーと HEAD の異同を測れなんだ★ ({e!r}) = 未検分"
    if r.returncode != 0:
        tail = (r.stderr or "").strip().splitlines()[-1:] or [""]
        return f"  [盤面] ★git が答えず異同を測れなんだ★ ({tail[0][:80]}) = 未検分"
    dirty = [ln for ln in r.stdout.splitlines() if ln.strip()]
    if not dirty:
        return ("  [盤面] 本 gate は ★作業ツリー★ を読む。"
                "今回は台帳の paths について ★作業ツリー = HEAD★ ゆえ、"
                "★此の結果は HEAD についても同じ事を言うておる★")
    names = ", ".join(ln[3:] for ln in dirty[:6]) + (" ほか" if len(dirty) > 6 else "")
    return ("  [盤面] ★★本 gate は【作業ツリー】を読む。HEAD については何も言うておらぬ★★ = "
            f"台帳の paths のうち ★{len(dirty)} 件が HEAD と食い違う★ ({names})。"
            " ★未 commit の是正は fresh clone に無い★ ゆえ、"
            "配る物について断ずるなら commit してから撃ち直せ")


def run_all(registry: Path, repo: Path) -> int:
    entries, err = load_registry(registry)
    if err:
        print(f"[gate-2] UNDETERMINED: {err}")
        print("  処方: 台帳 config/mutation_registry.yaml を検めよ。空にする変更をしたなら、その変更こそ疑え。")
        return 2
    print(board_declaration(repo, entries))
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


def sanity(registry: Path, repo: Path) -> int:
    """実行なしの軽量検分 (pre-commit 用): 台帳が在り・0件でなく・schema が立っておるか。

    ★付帯5 (負の主張の刃) も此処で撃つ★ = 軍師一号の設計「新しい門を生やすな」に従い、
    ★既に在る gate-2 の中★ へ段1/段2 を据える (実行なし・数百ms の性質は保つ)。
    返り = 0 / 1 (段1 FAIL = commit を止める) / 2 (UNDETERMINED)。
    """
    worst = 0
    entries, err = load_registry(registry)
    if err:
        print(f"[gate-2 sanity] UNDETERMINED: {err}")
        worst = 2
    else:
        bad = [(e.get("id", "?") if isinstance(e, dict) else "?", validate_entry(e))
               for e in entries if validate_entry(e)]
        if bad:
            for eid, why in bad:
                print(f"[gate-2 sanity] UNDETERMINED: {eid}: {why}")
            worst = 2
        else:
            print(f"[gate-2 sanity] OK: 台帳 {len(entries)} 件・schema 健全 (実行は cron 側で行う)")
    rc_na, lines = negative_assertion_audit(registry, repo, touched_only=True)
    for ln in lines:
        print(f"[gate-2 負の主張] {ln}" if ln.startswith("[段") else ln)
    if rc_na == 1:
        worst = 1
    elif rc_na == 2 and worst != 1:
        worst = 2
    return worst


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
    import yaml  # noqa: F401  (免除簿の日付検分は datetime 側・yaml は下流の互換用)
    # ★cmd_1386 手1★: 単一 file / 族 shard 群 の二形を同じ口で読む
    data, rerr, present = resolve_registry_doc(registry)
    if not present:
        print(f"[gate-2 coverage] UNDETERMINED: 台帳が無い: {registry}")
        return 2
    if rerr:
        print(f"[gate-2 coverage] UNDETERMINED: {rerr}")
        return 2
    if not isinstance(data, dict) or not isinstance(data.get("mutations"), list):
        print("[gate-2 coverage] UNDETERMINED: 台帳に mutations: リストが無い")
        return 2
    entries = [e for e in data["mutations"] if isinstance(e, dict)]
    # ── 免除簿の読み取り (cmd_1374: ★いつ返すかを機械が持つ★) ──
    #   until: YYYY-MM-DD を書けば、その日を過ぎた免除は ★自動で FAIL へ戻る★。
    #   until 無しの免除は「無期限免除」として ★毎朝 名指しで数える★ (赤にはせぬ) =
    #   既存免除の所有者は他 agent ゆえ勝手に赤へ倒さぬが、★いつ返すか決まっておらぬ★
    #   ことを画面から隠さぬ。★免除は【いつ返すか】が決まって初めて免除である★ (家老下命)。
    wmap: dict[str, str] = {}
    w_until: dict[str, datetime.date] = {}
    for w in (data.get("coverage_waivers") or []):
        if not isinstance(w, dict) or not w.get("path") or not w.get("reason"):
            print(f"[gate-2 coverage] UNDETERMINED: coverage_waivers に path/reason を欠く entry: {w!r}"
                  " (曖昧な免除は免除でない)")
            return 2
        p = str(w["path"])
        wmap[p] = str(w["reason"])
        if w.get("until") is not None:
            raw = str(w["until"]).strip()
            try:
                w_until[p] = datetime.date.fromisoformat(raw)
            except ValueError:
                print(f"[gate-2 coverage] UNDETERMINED: 免除 {p} の until が日付として読めぬ: {raw!r}"
                      " (YYYY-MM-DD で書け — ★読めぬ期限は期限でない★)")
                return 2
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
    expired: list[str] = []
    n_waived = 0
    n_open_ended = 0
    today = _today()
    for rel in sorted(cands):
        eid = next((e.get("id", "?") for e in entries
                    if rel in (e.get("paths") or [])
                    or rel in str(e.get("test", "")) or rel in str(e.get("mutate", ""))), None)
        if eid:
            print(f"  ok   REGISTERED    {rel} ← {eid}")
        elif rel in wmap:
            due = w_until.get(rel)
            if due is not None and today > due:
                # ★期限切れ = 借金の取り立て★。免除は消えるのでなく【返る】。
                expired.append(rel)
                print(f"  ★NG★ [WAIVER-EXPIRED] {rel}: 免除の期限 {due} を過ぎた (本日 {today})"
                      f" — 理由「{wmap[rel]}」。登録するか、期限を延ばす理由を書き直せ"
                      " (★黙って延びる道は無い★)")
            elif due is None:
                n_waived += 1
                n_open_ended += 1
                print(f"  免除 [WAIVED・★無期限★] {rel}: {wmap[rel]}"
                      " ← ★いつ返すか決まっておらぬ★ (until: YYYY-MM-DD を書け)")
            else:
                n_waived += 1
                print(f"  免除 [WAIVED〜{due}] {rel}: {wmap[rel]}")
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

    if unregistered or ghosts or expired:
        print(f"[gate-2 coverage] FAIL: 候補 {len(cands)} 件中 ★台帳に無い変異test"
              f" {len(unregistered)} 件★ / ★期限切れ免除 {len(expired)} 件★"
              f" / ID言及 {len(refs)} 件中 ★幽霊 {len(ghosts)} 件★"
              f" (視野: {vision})")
        print("  処方: 「赤を一度確認した」変異を config/mutation_registry.yaml へ登録せよ")
        print("        (登録の書式は本 file 冒頭 docstring)。登録すべきでない正当な理由が在るなら")
        print("        coverage_waivers へ【理由つきで】免除を書け (黙って外す道は無い)。")
        print("        幽霊 ID は台帳へ登録するか docstring の申告を消せ (申告≠実在を残すな)。")
        return 1
    # ★PASS の文言に視野を刻む★ = 「候補すべて登録済」を【全部検査した】と読ませぬための限定
    #   (cmd_1364 の「検査した と 全部検査した を混同させぬ」を、検知器自身へ当てたもの)
    # ★「登録済」と「免除」を混ぜて言わぬ★ = 全件が免除の木で「すべて登録済」と出すのは
    #   画面の嘘である (cmd_1353b D-1 で直したのと同じ型 — 見出しが実態と食い違う)。
    n_reg = len(cands) - n_waived
    print(f"[gate-2 coverage] PASS: ★規則に見えた★候補 {len(cands)} 件 ="
          f" ★登録 {n_reg} 件 / 免除 {n_waived} 件 (うち★無期限 {n_open_ended} 件★)★"
          f" — 免除は可視・期限切れ 0 件・ID言及 {len(refs)} 件に幽霊なし"
          f" — ★但し視野は全域でない: {vision}★")
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# gate-2 付帯5: ★負の主張に【刃が在ること】を機械に検めさせる★
#   (軍師一号の設計 plans/negative_assertion_teeth_gate_design.md 段1/段2 の実装・
#    由来 = 足軽五号 cmd_1401「bats の `!` は set -e から免除ゆえ、当たっても緑」)
#
# ★何を塞ぐか★= ★負の主張は「書いた時点では、刃が在るか無いかを誰も見ておらぬ」★。
#   ★之は「牙が折れた」ではない = 牙が最初から刃を持っておらなんだ★形ゆえ、
#   既存の replay 層 (登録済の変異を毎朝 撃ち直す) では ★原理的に見えぬ★
#   — 登録されておらぬ物は replay の分母に居らぬ。
#
# ★段1 (静的・実行なし) = 刃を持ちうる形か★
#   走査の正本は ★scripts/gate_bats_negation.py (五号・cmd_1401)★ を ★呼ぶ★。
#   ★綴りの規則を二箇所に置かぬ★ = 二重管理は必ず割れる (cmd_1350 の族)。
#   本層の仕事は【呼び手】である = ★書いた者の画面で落ちる場所 (pre-commit) へ繋ぐ★。
#   ★実測 2026-07-27 02:5x★= 五号の門は建っておったが ★何処からも呼ばれておらなんだ★
#   (find|xargs で全木を走査・呼び手 0 件) = ★「据えた」と「効いておる」は別物★。
#
# ★段2 (台帳・実行なし) = 刃を持つ【証】が在るか★
#   負の主張を持つ試験のうち、★台帳の red_needle に一度も名指されておらぬ★ 物を数える。
#     登録済の負の主張 = ★「壊せば落ちる」を一度は見た物★
#     未登録の負の主張 = ★「壊せば落ちる」を誰も見ておらぬ物★
#   ⇒ ★之で【分母】が計算可能になる★ (軍師一号「分母を数えておらぬ」への答)。
#
# ★判定の強さ (設計どおり・家老 02:40 の枷)★
#   段1 で `!` が在る      → ★FAIL (1) = commit を止める★ (刃が無いことの【証明】ゆえ)
#   段2 で名指し無しが在る  → ★UNDETERMINED (2) = 大声で警告して通す★
#     = ★「未検証」であって「壊れておる」ではない★。全 agent が commit する repo ゆえ
#       一過性の未登録で全軍を塞がぬ (cmd_1342 の WARN-through の流儀)。
#     = ★家老が配った規律の第三項「書けぬなら【未検証】と名乗れ」が、そのまま三値の
#       UNDETERMINED へ一対一で落ちておる★。
#
# ★本層の射程 (必ず名乗る — 設計 §7・名乗らねば後から広げて検められぬ)★
#   ・見ておるのは ★.bats の @test 本文★ のみ = ★python/TS の木は見ておらぬ★
#   ・負の主張の見分けは ★下の NEG_SPELLINGS の綴り列挙★ に依る =
#     ★列挙に無い書き方は素通りする★ (型2 = 射程の穴。出力に綴り名を刷る)
#   ・名指しの逆引きは ★与えられた台帳 1 冊★ のみ = ★他 repo の台帳は見ておらぬ★
#   ・★quote / heredoc の中身を判じておらぬ★ (五号の門と同じ限界を継ぐ)
#
# ★走査の母集団は【追跡下に限らぬ】★ (設計 NA-4)
#   ls_files (git 追跡下) を使わぬ = ★本夜 我らは「再帰 grep は追跡下しか見ぬ」を学んだ★。
#   ★此の門が同じ盲点を持てば「未登録 0 件」という★偽の 0★ を毎 commit 産む★。
#   ⇒ os.walk で木を歩き、.git / node_modules だけを刈る (刈った物は出力で名乗る)。
# ─────────────────────────────────────────────────────────────────────────────
# ★負の主張の綴り★ (name, regex)。★出力に名を刷る = 射程を読む者が検められる形★。
NEG_SPELLINGS: list[tuple[str, re.Pattern]] = [
    # 五号の門と同じ形 (段1 が FAIL にする側)。段2 の分母にも入れる =
    # ★刃を持たぬ負の主張も「負の主張」である★ (数から落とせば直した数が判らぬ)
    ("bang", re.compile(r"(?:^|;|&&|\|\||\bthen\b)\s*!\s+\S")),
    # ★倒した後の正しい形★ = if <cmd>; then return 1; fi
    #   ※ `if ! <cmd>; then return 1` は【正の主張】ゆえ除く (否定の否定を数に入れぬ)
    ("if-then-return", re.compile(r"^\s*if\s+(?!!)\S.*;\s*then\s+return\s+1\b")),
    ("refute", re.compile(r"(?<![\w-])refute(?:_\w+)?\b")),
    ("assert_failure", re.compile(r"(?<![\w-])assert_failure\b")),
    ("assert-not", re.compile(r"(?<![\w-])assert\s+not\s")),
]
# @test 名の頭に置かれた試験 ID (例: T-QRM-001 / E2E-008-C / TC-NFR-008)。
# ★台帳の red_needle は此の ID で名指す★ (実測: "not ok 1 T-QRM-001" 等)
BATS_TEST_ID_RE = re.compile(r"^([A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+)")
BATS_TEST_DECL_RE = re.compile(r"""^@test\s+(?:"([^"]*)"|'([^']*)')\s*\{""")
# 第三者管理の vendored suite は走査せぬ (五号の門と同じ除外 — 彼らは彼らの規律で書く)
NEG_EXCLUDE_PARTS = ("test_helper/bats-assert", "test_helper/bats-support")
NEG_PRUNE_DIRS = {".git", "node_modules", "__pycache__", ".venv", "venv"}
NEG_GATE_SCRIPT = "scripts/gate_bats_negation.py"


def bats_files(repo: Path) -> list[Path]:
    """repo の .bats を ★追跡下に限らず★ 数える (設計 NA-4)。

    ★git ls-files を使わぬ★ = 未追跡の bats を見落とせば ★偽の 0 件★ を産む。
    刈るのは .git / node_modules 等の機械生成の木のみ (NEG_PRUNE_DIRS)。
    """
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames if d not in NEG_PRUNE_DIRS]
        for fn in filenames:
            if not fn.endswith(".bats"):
                continue
            p = Path(dirpath) / fn
            if any(x in p.as_posix() for x in NEG_EXCLUDE_PARTS):
                continue
            out.append(p)
    return sorted(out)


def bats_negative_assertion_tests(repo: Path):
    """(負の主張を持つ @test の一覧, 走査した .bats file 数) を返す。

    一覧の各要素 = {"file","line","name","id","spellings"}。
    ★@test 本文のみを見る★ = setup/teardown/helper の中は見ておらぬ (五号の門と同じ線)。
    """
    files = bats_files(repo)
    found: list[dict] = []
    for p in files:
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").split("\n")
        except OSError:
            # ★黙って飛ばさぬ★ = 読めなんだ file を 0 件へ畳めば、本層自身が
            #   本日の族 (沈黙を緑と読む) になる。呼び手が UNDETERMINED へ倒せるよう返す。
            found.append({"file": str(p), "line": 0, "name": "(読めぬ file)",
                          "id": None, "spellings": ["unreadable"]})
            continue
        cur: dict | None = None
        for i, line in enumerate(lines, start=1):
            m = BATS_TEST_DECL_RE.match(line)
            if m:
                name = m.group(1) if m.group(1) is not None else m.group(2)
                idm = BATS_TEST_ID_RE.match(name.strip())
                cur = {"file": str(p), "line": i, "name": name,
                       "id": idm.group(1) if idm else None, "spellings": []}
                continue
            if line.startswith("}"):
                if cur and cur["spellings"]:
                    found.append(cur)
                cur = None
                continue
            if cur is None or line.strip().startswith("#"):
                continue
            for sname, rx in NEG_SPELLINGS:
                if rx.search(line) and sname not in cur["spellings"]:
                    cur["spellings"].append(sname)
        if cur and cur["spellings"]:
            found.append(cur)
    return found, len(files)


def stage1_blade_shape(repo: Path):
    """段1 = ★刃を持ちうる形か★ (五号の門 gate_bats_negation.py を呼ぶ)。

    返り = (rc, 出力行) — rc は 0=緑 / 1=FAIL / 2=UNDETERMINED。
    ★走査の正本は五号の門である★ = 綴りの規則を写さぬ (二重管理禁)。
    """
    script = REPO_ROOT / NEG_GATE_SCRIPT
    if not script.is_file():
        return 2, [f"[段1] UNDETERMINED: 走査の正本が無い: {script}"
                   " — ★門が消えたことを緑へ倒さぬ★"]
    try:
        r = subprocess.run([sys.executable, str(script), str(repo)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 2, [f"[段1] UNDETERMINED: 走査が走らぬ: {e!r}"]
    body = [f"  {ln}" for ln in r.stdout.rstrip("\n").split("\n") if ln.strip()]
    if r.returncode == 0:
        return 0, ["[段1] OK: ★刃を持たぬ負の主張★ (bats の `!`) は 0 箇所"] + body[:2]
    if r.returncode == 1:
        return 1, ["[段1] ★FAIL★: ★刃を持たぬ負の主張★ = 当たっても緑になる書き方が在る"] + body
    return 2, [f"[段1] UNDETERMINED: 走査が exit {r.returncode} を返した"] + body[:6]


def staged_bats(repo: Path):
    """(此の commit が残そうとしておる .bats の relpath 集合, error) を返す。

    ★出所は gate-3 (gate_anchor_touched.py) と同じ index である★ = 流儀を割らぬ。
    """
    try:
        r = subprocess.run(["git", "-C", str(repo), "diff", "--cached", "--name-only", "-z"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"git diff --cached が走らぬ: {e}"
    if r.returncode != 0:
        return None, f"git diff --cached 失敗 (exit {r.returncode}): {r.stderr.strip()[:200]}"
    return {p for p in r.stdout.split("\0") if p.endswith(".bats")}, None


def stage2_blade_witness(registry: Path, repo: Path, verbose: bool = False,
                         touched_only: bool = False):
    """段2 = ★刃を持つ【証】が在るか★ (台帳 red_needle の逆引き)。

    返り = (rc, 出力行)。rc は 0=緑 / 2=UNDETERMINED (★FAIL にはせぬ★ — 家老 02:40 の枷)。

    ★touched_only (pre-commit) の理由を隠さず記す★:
      全数 (現況 = 未登録 80 本) を毎 commit 鳴らせば ★全 agent の commit が毎回 ⚠ を出す★ =
      ★常に鳴る門は外される★ (本 file の anchor 層が cmd_1382 で学んだ当のこと) ⇒
      ★gate-3 と同じ流儀 (触った file の分だけ見る) を採り、【新しく書けば其の場で鳴る】形にする★。
      ★分母の全数は殺しておらぬ★ = `--negative-assertions` が ★数え直す口★ である
      (★数を保存せず、数え直す口を保存する★ — 軍師一号 §7d の一般形)。
    """
    entries, err = load_registry(registry)
    if err:
        return 2, [f"[段2] UNDETERMINED: 台帳が読めぬ: {err}"]
    needles = "\n".join(str(e.get("red_needle", "")) for e in entries
                        if isinstance(e, dict))
    tests, n_files = bats_negative_assertion_tests(repo)
    spell_names = "/".join(n for n, _ in NEG_SPELLINGS)
    scope = (f"★射程★= .bats {n_files} file の @test 本文のみ・"
             f"綴り列挙 [{spell_names}]・台帳 1 冊 ({registry.name}) の red_needle のみ")
    if touched_only:
        staged, serr = staged_bats(repo)
        if serr:
            return 2, [f"[段2] UNDETERMINED: 触った file を数えられぬ: {serr}", f"  {scope}"]
        tests = [t for t in tests
                 if str(Path(t["file"]).relative_to(repo)
                        if Path(t["file"]).is_relative_to(repo) else t["file"]) in staged]
        scope = (f"★射程★= ★此の commit が触る .bats {len(staged)} file のみ★"
                 f" (木の全数 {n_files} file の分母は --negative-assertions で数え直せ)・"
                 f"綴り列挙 [{spell_names}]・台帳 1 冊 ({registry.name}) の red_needle のみ")
        if not staged:
            return 0, ["[段2] OK: ★此の commit は .bats を 1 file も触っておらぬ★ = "
                       "★本層は何も言うておらぬ (緑ではなく【対象なし】である)★", f"  {scope}"]
    elif n_files == 0:
        # ★分母 0 を緑にせぬ★ = 「走査 0 file の緑」と「現に 0 件の緑」を混ぜぬ
        return 2, [f"[段2] UNDETERMINED: ★測れておらぬ★ = .bats が 0 file "
                   f"(root={repo}) — ★分母 0 は「全部 検めた」ではない★", f"  {scope}"]
    unread = [t for t in tests if "unreadable" in t["spellings"]]
    if unread:
        return 2, ([f"[段2] UNDETERMINED: 読めぬ .bats が {len(unread)} 件 "
                    "(★黙って飛ばさぬ★)"]
                   + [f"  {t['file']}" for t in unread[:5]] + [f"  {scope}"])
    witnessed, unwitnessed = [], []
    for t in tests:
        tid = t["id"]
        if (tid and tid in needles) or (t["name"] and t["name"] in needles):
            witnessed.append(t)
        else:
            unwitnessed.append(t)
    head = (f"負の主張を持つ試験 ★{len(tests)} 本★ (分母) 中 "
            f"★台帳が刃を証しておるのは {len(witnessed)} 本★ / "
            f"★誰も証しておらぬ {len(unwitnessed)} 本★")
    if not unwitnessed:
        return 0, [f"[段2] OK: {head}", f"  {scope}"]
    lines = [f"[段2] UNDETERMINED: {head}",
             "  ⇒ ★未登録 = 「壊せば落ちる」を誰も見ておらぬ負の主張★ "
             "(★壊れておるという意味ではない★)"]
    shown = unwitnessed if verbose else unwitnessed[:5]
    for t in shown:
        try:
            rel = Path(t["file"]).relative_to(repo)
        except ValueError:
            rel = Path(t["file"])
        lines.append(f"    {rel}:{t['line']}: {t['name'][:70]}"
                     f"  [{'+'.join(t['spellings'])}]")
    if len(unwitnessed) > len(shown):
        lines.append(f"    … 他 {len(unwitnessed) - len(shown)} 本 "
                     "(全数は python3 scripts/gate_mutation_replay.py"
                     " --negative-assertions)")
    lines.append("  処方: 其の主張を ★一度 偽にして赤が出ること★ を見てから、"
                 "変異を config/mutation_registry.yaml へ登録せよ "
                 "(red_needle に試験 ID を書けば本層が名指しを読む)")
    lines.append(f"  {scope}")
    return 2, lines


def negative_assertion_audit(registry: Path, repo: Path, verbose: bool = False,
                             touched_only: bool = False):
    """段1+段2 をまとめて撃つ。返り = (worst rc, 出力行)。"""
    rc1, out1 = stage1_blade_shape(repo)
    rc2, out2 = stage2_blade_witness(registry, repo, verbose=verbose,
                                     touched_only=touched_only)
    worst = 1 if 1 in (rc1, rc2) else (2 if 2 in (rc1, rc2) else 0)
    return worst, out1 + out2


# ─────────────────────────────────────────────────────────────────────────────
# ★木の点呼 (--tree-census・cmd_1374)★
#
#   上の登録検知は「見ておる木の中で、台帳に無い牙」を数える = ★盲★ を塞ぐ層である。
#   本層はその ★一段外★ = 「そもそも どの gate も見ておらぬ木」を数える。
#   ★見ておらぬ場所には、盲であることすら分からぬ★ (cmd_1374 north_star)。
#
#   ■ 見ておる木をどう知るか = ★宣言でなく【実際に走った物】を数える★
#     gate_nightly が各 gate を撃つ度に repo-root を --watched-file へ書き足し、
#     その file を本層が読む。★gate の呼び出し行を消せば、その木は記録されぬ★ゆえ
#     「配線を消したのに watched のまま」という食い違いが ★構造的に起こり得ぬ★。
#     (cmd_1359 の「番人は書いただけでは番をせぬ」を、点呼自身へ当てたもの)
#
#   ■ 木の全数をどう知るか = ★system 自身が持つ独立の登録 (config/projects.yaml)★
#     + 見ておる木 + それらの submodule。★己の記憶を分母にせぬ★ (cmd_1370 の流儀)。
# ─────────────────────────────────────────────────────────────────────────────
def _win2wsl(p: str) -> str:
    """projects.yaml は Windows 表記ゆえ WSL path へ写す (C:/x → /mnt/c/x)。"""
    p = p.replace("\\", "/")
    if len(p) > 1 and p[1] == ":":
        return f"/mnt/{p[0].lower()}{p[2:]}"
    return p


def _git_toplevel(p: str) -> str | None:
    try:
        r = subprocess.run(["git", "-C", p, "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=60)
        return r.stdout.strip() or None if r.returncode == 0 else None
    except Exception:
        return None


def _submodule_paths(top: str) -> list[str]:
    gm = Path(top) / ".gitmodules"
    if not gm.is_file():
        return []
    out = []
    for line in gm.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.startswith("path"):
            out.append(s.split("=", 1)[1].strip())
    return out


def tree_census(registry: Path, watched_file: Path | None, projects: Path,
                attempted_file: Path | None = None) -> int:
    """牙を持つのに どの gate も見ておらぬ repo を名指す。0 PASS / 1 FAIL / 2 UNDETERMINED。"""
    import yaml
    # ── 見ておる木 (実際に走った物) ──
    watched: set[str] = set()
    if watched_file and watched_file.is_file():
        for line in watched_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            t = _git_toplevel(line)
            if t is None:
                # gate が撃った先が git repo でない = 記録の取り違え/path 崩れ。
                # ★黙って代用の path を watched へ入れぬ★ (それをすると照合が外れた事に
                #   気付かぬまま「見ておることになっておる木」が生まれる)。
                print(f"[木の点呼] UNDETERMINED: gate が撃った先が git repo でない: {line}"
                      " = 記録の取り違え / path 崩れの疑い (黙って読み替えはせぬ)")
                return 2
            watched.add(t)
    if not watched:
        print("[木の点呼] UNDETERMINED: ★見ておる木が 0 本★ = 点呼の分母が立たぬ"
              " (--watched-file が空/不在 = gate が1つも走っておらぬか配線が切れた疑い)。"
              " ★0 件は PASS ではない★")
        return 2

    # ── ★撃とうとした木 (cmd_1374b ③・軍師一号の差し戻し)★ ──────────────────
    # ★穴★: watched は各 gate の【成功の枝の中】でしか記録されぬ (gate_nightly の
    #   `if [ -f "$REG" ]; then … watched "$ROOT"; else rc=2; fi`)。
    #   ⇒ ★gate が黙って撃てなんだ木は「未監視」ではなく【存在せぬ】として点呼から消える★。
    #   軍師一号の実測 (fresh clone の素の姿 = projects.yaml が first_setup 既定・backend 台帳不在):
    #   ★点呼は PASS rc0 を返し、app 牙12 と backend 牙14 は分母に一度も現れなんだ★。
    #   ★鳴らぬのではない = 点呼の行だけが PASS と名乗る★ =
    #   これは本 gate の初版が踏んだ【分母にすら入らぬ】の、一段外の再演である。
    # ★塞ぎ方★: 「撃とうとした」も実績である (宣言ではない — 呼び出し行が在った事実)。
    #   撃とうとして撃てなんだ木は ★UNDETERMINED として名指す★ = 決して緑にせぬ。
    unfired: list[tuple[str, str]] = []   # (path, なぜ撃てなんだか)
    if attempted_file and attempted_file.is_file():
        for line in attempted_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            t = _git_toplevel(line)
            if t is None:
                unfired.append((line, "実体が git repo として見えぬ (未 init / path 違い / disk 喪失)"))
            elif t not in watched:
                unfired.append((t, "実体は在るのに gate が撃っておらぬ (台帳不在 等で黙って飛ばされた疑い)"))

    # ── 免除簿 (期限つき・登録検知の免除と同じ掟) ──
    wmap: dict[str, str] = {}
    w_until: dict[str, datetime.date] = {}
    # ★cmd_1386 手1★: 単一 file / 族 shard 群 の二形を同じ口で読む
    _doc, _rerr, _present = resolve_registry_doc(registry)
    if _rerr:
        print(f"[木の点呼] UNDETERMINED: {_rerr}")
        return 2
    if _present:
        data = _doc or {}
        if not isinstance(data, dict):
            print("[木の点呼] UNDETERMINED: 台帳の最上位が mapping でない"
                  " (免除簿を読めぬ = 読めぬを緑へ倒さぬ)")
            return 2
        for w in (data.get("tree_census_waivers") or []):
            if not isinstance(w, dict) or not w.get("path") or not w.get("reason"):
                print(f"[木の点呼] UNDETERMINED: tree_census_waivers に path/reason を欠く entry: {w!r}"
                      " (曖昧な免除は免除でない)")
                return 2
            p = str(w["path"])
            wmap[p] = str(w["reason"])
            if w.get("until") is not None:
                try:
                    w_until[p] = datetime.date.fromisoformat(str(w["until"]).strip())
                except ValueError:
                    print(f"[木の点呼] UNDETERMINED: 免除 {p} の until が日付として読めぬ"
                          f" ({w['until']!r}) — YYYY-MM-DD で書け")
                    return 2

    # ── 木の全数 (projects.yaml ∪ 見ておる木 ∪ submodule) ──
    universe: dict[str, list[str]] = {}   # toplevel → 由来 label 群
    missing: list[tuple[str, str]] = []   # (label, path) = 登録されておるのに実在せぬ
    def add(label: str, path: str) -> str | None:
        top = _git_toplevel(path)
        if not top:
            missing.append((label, path))
            return None
        universe.setdefault(top, []).append(label)
        return top

    if projects.is_file():
        try:
            pdata = yaml.safe_load(projects.read_text(encoding="utf-8")) or {}
        except Exception as e:
            print(f"[木の点呼] UNDETERMINED: projects.yaml が parse 不能: {e}")
            return 2
        for e in (pdata.get("projects") or []):
            if isinstance(e, dict) and e.get("path"):
                add(f"projects.yaml:{e.get('id', '?')}", _win2wsl(str(e["path"])))
    else:
        print(f"[木の点呼] UNDETERMINED: 木の登録簿が見えぬ: {projects}"
              " = 分母を system の登録から採れぬ (己の記憶を分母にはせぬ)")
        return 2
    for w in sorted(watched):
        add("gate が見ておる木", w)
    # ★見ておる木の【親】も分母に入れる (cmd_1374 の自己適用で判った要衝)★
    #   本 cmd の穴そのものが ★子 (backend submodule) は見ておるが親 (app 本体) は
    #   見ておらぬ★ という形であった。親を辿らねば、点呼の分母は
    #   「projects.yaml に載っておる木」+「既に見ておる木」に留まり、
    #   ★未監視の親は分母にすら入らぬ = 点呼が【常に緑】になる★。
    #   実際、初版はこの穴を持っており ★app 本体を watched から外しても PASS を返した★
    #   = 検知すべき当のものを検知できぬ試験であった (自己適用で捕えた)。
    for w in sorted(watched):
        cur = Path(w).resolve()
        for parent in cur.parents:
            top = _git_toplevel(str(parent))
            if top and top != str(cur):
                add(f"{cur.name} の親", top)
                break
    for top in list(universe):
        for sub in _submodule_paths(top):
            add(f"submodule of {Path(top).name}", str(Path(top) / sub))

    # ── 点呼 ──
    today = _today()
    unwatched_fanged: list[str] = []
    expired: list[str] = []
    n_watched = n_fangless = n_waived = 0
    for top in sorted(universe):
        labels = "/".join(sorted(set(universe[top])))
        cands, err = scan_mutation_test_candidates(Path(top))
        if err:
            print(f"[木の点呼] UNDETERMINED: {top} を走査できぬ: {err}")
            return 2
        n = len(cands)
        if top in watched:
            n_watched += 1
            print(f"  ok   [WATCHED]      {top} (牙 {n} 件) ← {labels}")
        elif n == 0:
            n_fangless += 1
            print(f"  注   [牙なし・未監視] {top} ← {labels}"
                  " (今は失う物が無い。★牙が生えても誰も見ぬ★ゆえ点呼には残す)")
        elif top in wmap:
            due = w_until.get(top)
            if due is not None and today > due:
                expired.append(top)
                print(f"  ★NG★ [免除期限切れ]  {top} (牙 {n} 件): 期限 {due} を過ぎた"
                      f" (本日 {today}) — 理由「{wmap[top]}」")
            elif due is None:
                n_waived += 1
                print(f"  免除 [★無期限★]     {top} (牙 {n} 件): {wmap[top]}"
                      " ← ★いつ返すか決まっておらぬ★")
            else:
                n_waived += 1
                print(f"  免除 [〜{due}]  {top} (牙 {n} 件): {wmap[top]}")
        else:
            unwatched_fanged.append(top)
            print(f"  ★NG★ [UNWATCHED]    {top}: ★牙 {n} 件を持つのに どの gate も見ておらぬ★"
                  f" ← {labels}")
            for rel in sorted(cands):
                print(f"          - {rel}")
    # ★撃とうとして撃てなんだ木 (cmd_1374b ③)★ = 点呼から消させぬ。
    for path, why in unfired:
        print(f"  ★未検分★ [撃てておらぬ] {path}: {why}"
              " = ★この木は【未監視】ですらなく点呼から消えかけておった★"
              " (牙を数えられておらぬゆえ「牙なし」とも言えぬ)")
    for label, path in missing:
        print(f"  注   [登録が古い]    {path} ← {label}"
              " = 登録されておるのに repo として実在せぬ。★登録が実体を指さぬ間、"
              "その木は点呼に載らぬ = 見えぬ穴になりうる★")
    for wp in sorted(set(wmap) - set(universe)):
        print(f"  注   免除の空撃ち   {wp} (点呼に居らぬ = path 変更/消滅。waiver を掃除せよ)")

    total = len(universe)
    # ★真空 PASS 禁 (家老 規律(3) 2026-07-26: 道具の exit code でなく【成果物の実数】を数えよ)★
    #   git が全滅する / 登録簿が空 / path が総崩れ ⇒ 木 0 本 でも「未監視 0 本」ゆえ
    #   PASS が出てしまう。★数えた木が 0 本なのは「全部見えておる」ではない★。
    if total == 0:
        print("[木の点呼] UNDETERMINED: ★点呼できた木が 0 本★ = 登録簿も実地も空"
              " (git 不通 / path 総崩れの疑い)。★0 本は PASS ではない★")
        return 2
    print(f"  [点呼] 木 {total} 本 = 見ておる {n_watched} / 免除 {n_waived}"
          f" / ★見ておらぬが牙あり {len(unwatched_fanged)}★ / 牙なし未監視 {n_fangless}"
          f" / 登録が古い {len(missing)}")
    if unwatched_fanged or expired:
        print(f"[木の点呼] FAIL: ★どの gate も見ておらぬ牙持ちの木 {len(unwatched_fanged)} 本★"
              f" / ★免除期限切れ {len(expired)} 本★")
        print("  処方: その木を gate_nightly の監視下へ入れる (台帳を置き coverage を撃つ) か、")
        print("        tree_census_waivers へ ★理由と until (いつ返すか) をつけて★ 免除せよ。")
        return 1
    if unfired:
        print(f"[木の点呼] UNDETERMINED: ★撃とうとして撃てておらぬ木 {len(unfired)} 本★"
              " = その木の牙は一度も数えられておらぬ。★数えておらぬ物を「牙なし」とも"
              "「監視下」とも名乗れぬゆえ緑にはせぬ★")
        print("  処方: その木を実在させる (submodule init / path 是正) か、gate 側の"
              " 呼び出しを外して ★撃とうとしておらぬ★ ことを明示せよ (黙って飛ばすな)。")
        return 2
    # ★cmd_1376 で此処の但し書きを実測で書き直した★:
    #   旧文は「TS/JS の木では成り立たぬ」で止まっており、★次の者は拡張子を足せば直ると読む★。
    #   実測 = ★.ts/.tsx を COVERAGE_EXTS へ足しても engine の候補は 0 件のまま★ =
    #   D1/D2/D3 は @test / --selftest / def test_ を見ており ★vitest の it( はどれにも当たらぬ★。
    #   ⇒ 抜け道は拡張子でなく ★牙の走らせ方★ の側に在った (engine は .sh の harness から
    #     実 TS を走らせる形で監視下へ入った = 牙 1 件として現に数えられておる)。
    print(f"[木の点呼] PASS: 牙を持つ木はすべて監視下 (免除 {n_waived} 本は可視・"
          f"★牙なし未監視 {n_fangless} 本は牙が生えれば赤へ変わる — "
          f"★但し牙の勘定は sh/bash/py/bats に限る = ★.ts を足しても vitest の it( は "
          f"D1/D2/D3 のどれにも当たらず候補 0 件のままである (cmd_1376 実測)★ = "
          f"TS/JS の木は 牙を .sh 側から走らせるか 検知規則を足すまで数えられぬ★)")
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


def _invoke(args: list[str], today: str | None = None) -> tuple[int, str]:
    env = dict(os.environ)
    # ★試験は必ず日付を固定して撃つ★ = 期限つき免除の検分を暦に依らせると、
    #   ある日から試験が黙る/鳴る形になり、本 gate が塞ごうとしておる型そのものになる。
    if today is not None:
        env["GATE_TODAY"] = today
    else:
        env.pop("GATE_TODAY", None)
    r = subprocess.run([sys.executable, str(Path(__file__).resolve())] + args,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    return r.returncode, r.stdout


def _write_census_reg(path: Path, waivers: list) -> None:
    import yaml
    path.write_text(yaml.safe_dump({"mutations": [], "tree_census_waivers": waivers},
                                   allow_unicode=True))


def _write_projects(path: Path, paths: list[str]) -> None:
    import yaml
    path.write_text(yaml.safe_dump(
        {"projects": [{"id": f"p{i}", "path": p} for i, p in enumerate(paths)]},
        allow_unicode=True))


def selftest() -> int:
    ok = ng = 0
    # ★検分せなんだ事を名乗る器 (cmd_1382 差し戻し後の実害から)★ — 下の T50 の注を見よ。
    #   ★空にせず必ず summary へ刷る = 黙った検分を緑の中へ埋めぬ★。
    na: list[str] = []

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
        #   ★--repo-root を必ず与える★ (付帯5 を足した折の実測 2026-07-27 03:0x):
        #   既定の REPO_ROOT を使うと ★本 file が置かれた木が git repo か否か★ で
        #   結果が割れた (写しの木で T9b が exit 2 = ★試験が盤面に依っておった★)。
        #   ★試験は盤面から独立でなければならぬ★ ゆえ、清浄な fixture repo を固定して撃つ。
        t9repo = _mk_git_repo(T / "t9", {"README.md": "x\n"})
        subprocess.run(["git", "-C", str(t9repo), "-c", "user.email=g@x",
                        "-c", "user.name=gate", "commit", "-q", "-m", "init"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rc, out = _invoke(["--sanity", "--registry", str(T / "t3reg.yaml"),
                           "--repo-root", str(t9repo)])
        expect("T9 sanityも0件=UNDETERMINED", 2, rc)
        rc, out = _invoke(["--sanity", "--registry", str(T / "t1reg.yaml"),
                           "--repo-root", str(t9repo)])
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

        # ── ★期限つき免除 (cmd_1374)★ = 免除は【いつ返すか】が決まって初めて免除 ──
        # 素材は共通: 対照 + 未登録の変異test 1本を、免除の書き方だけ変えて撃つ。
        def _waiver_repo(tag: str):
            return _mk_git_repo(T / tag, {ctl: _COV_CONTROL_BODY,
                                          "tests/rogue_mutation.bats": _COV_ROGUE_BATS})

        # T27: 期限が未来 → 免除は効く (PASS) が ★期限つきと明示される★
        repo = _waiver_repo("t27")
        reg = T / "t27reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats", "reason": "所有者の手番ゆえ待つ",
                             "until": "2026-08-31"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)],
                          today="2026-07-26")
        expect("T27 期限内の免除=PASS", 0, rc, "[WAIVED〜2026-08-31]", out)

        # T28: ★期限切れ → 免除が【自分で返る】= FAIL★
        #      これが本層の芯である。★黙って延びる道が無い★ことの実証。
        repo = _waiver_repo("t28")
        reg = T / "t28reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats", "reason": "所有者の手番ゆえ待つ",
                             "until": "2026-08-31"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)],
                          today="2026-09-01")
        expect("T28 ★期限切れ免除=FAIL (借金が返る)★", 1, rc, "[WAIVER-EXPIRED]", out)
        expect("T28b 期限切れの名指し", 1, rc, "tests/rogue_mutation.bats", out)

        # T29: 期限無し → 赤にはせぬが ★無期限と名指しで数える★ (黙って永久にせぬ)
        repo = _waiver_repo("t29")
        reg = T / "t29reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats", "reason": "期限を書いておらぬ免除"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)],
                          today="2026-07-26")
        expect("T29 無期限免除=PASSだが名指しで可視", 0, rc, "★無期限★", out)
        expect("T29b PASS 行が無期限を数える", 0, rc, "うち★無期限 1 件★", out)

        # T30: 読めぬ期限 → UNDETERMINED (★読めぬ期限は期限でない★)
        repo = _waiver_repo("t30")
        reg = T / "t30reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats", "reason": "r", "until": "来月中"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)],
                          today="2026-07-26")
        expect("T30 読めぬ期限=UNDETERMINED", 2, rc, "読めぬ期限は期限でない", out)

        # ── ★木の点呼 (cmd_1374)★ = そもそも どの gate も見ておらぬ木を名指す ──
        fanged = _mk_git_repo(T / "c_fanged", {"tests/rogue_mutation.bats": _COV_ROGUE_BATS})
        plain = _mk_git_repo(T / "c_plain", {"README.md": "牙なし\n"})
        # ★決して監視されぬ牙なしの木★ = 「牙なし未監視」の数が本当に効いておるかを撃つ的。
        #   これを置かねば T33b は常に 0 を見ることになり ★変異させても落ちぬ試験★ になる
        #   ([[feedback_green_tests_that_prove_nothing]] 類型3 — 自分の試験へ当てたもの)。
        plain2 = _mk_git_repo(T / "c_plain2", {"README.md": "牙なし2\n"})
        creg = T / "creg.yaml"
        cproj = T / "cproj.yaml"
        _write_census_reg(creg, [])
        _write_projects(cproj, [str(fanged), str(plain), str(plain2)])

        # T31: ★見ておる木が 0 本 = UNDETERMINED★ (真空 PASS 禁)
        empty_watched = T / "watched_empty.txt"
        empty_watched.write_text("")
        rc, out = _invoke(["--tree-census", "--registry", str(creg), "--projects", str(cproj),
                           "--watched-file", str(empty_watched)])
        expect("T31 見ておる木0本=UNDETERMINED", 2, rc, "点呼の分母が立たぬ", out)

        # T32: ★牙を持つのに誰も見ておらぬ木 = FAIL + 名指し★ (本 cmd の実事故そのもの)
        watched_f = T / "watched.txt"
        watched_f.write_text(f"{plain}\n")
        rc, out = _invoke(["--tree-census", "--registry", str(creg), "--projects", str(cproj),
                           "--watched-file", str(watched_f)])
        expect("T32 ★未監視の牙持ち木=FAIL★", 1, rc, "[UNWATCHED]", out)
        expect("T32b 木の名指し", 1, rc, str(fanged), out)
        expect("T32c 牙の内訳も出す", 1, rc, "tests/rogue_mutation.bats", out)

        # T33: 監視下へ入れれば緑 (= 是正が効くことの対照)
        watched_f.write_text(f"{plain}\n{fanged}\n")
        rc, out = _invoke(["--tree-census", "--registry", str(creg), "--projects", str(cproj),
                           "--watched-file", str(watched_f)])
        expect("T33 監視下=PASS", 0, rc, "牙を持つ木はすべて監視下", out)
        expect("T33b 牙なし未監視も数える", 0, rc, "牙なし未監視 1", out)

        # T35: ★親が未監視なら赤くなる (cmd_1374 の実事故そのもの)★
        #      子 (submodule) だけを見ておる状態を組み、親が牙を持つ時に名指せるかを撃つ。
        #      ★初版はこれを取り逃がした★ = 親は分母にすら入らず常に緑を返した。
        #      ★登録簿 (projects.yaml) に親を載せずに撃つ★のが肝 =
        #      「登録が古い/抜けておっても構造だけで親へ届く」ことを示すため。
        parent = _mk_git_repo(T / "c_parent", {"tests/rogue_mutation.bats": _COV_ROGUE_BATS})
        child = parent / "sub"
        child.mkdir(parents=True, exist_ok=True)
        (child / "README.md").write_text("子 repo\n", encoding="utf-8")
        for cmd in (["git", "init", "-q"], ["git", "add", "-A"]):
            subprocess.run(cmd, cwd=child, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pproj = T / "pproj.yaml"
        _write_projects(pproj, [str(plain)])          # ★親を登録簿に載せぬ★
        pwatched = T / "pwatched.txt"
        pwatched.write_text(f"{child}\n")             # 子だけを見ておる
        preg = T / "pregistry.yaml"
        _write_census_reg(preg, [])
        rc, out = _invoke(["--tree-census", "--registry", str(preg), "--projects", str(pproj),
                           "--watched-file", str(pwatched)])
        expect("T35 ★子だけ監視=親の牙を名指す★", 1, rc, "[UNWATCHED]", out)
        expect("T35b 親の path を名指す", 1, rc, str(parent), out)

        # ── ★家老 規律(3)/(3b) を本 gate 自身へ当てた層 (2026-07-26)★ ──
        #    「道具の exit code でなく成果物の実数を数えよ」「代用品の申告を拾って止めよ」
        # T36: ★点呼できた木が 0 本 = UNDETERMINED★ (真空 PASS 禁)
        empty_proj = T / "emptyproj.yaml"
        _write_projects(empty_proj, [])
        ghost_watched = T / "ghost_watched.txt"
        ghost_watched.write_text(f"{T / 'no_such_repo'}\n")
        rc, out = _invoke(["--tree-census", "--registry", str(creg), "--projects", str(empty_proj),
                           "--watched-file", str(ghost_watched)])
        expect("T36 gate が撃った先が非repo=UNDETERMINED", 2, rc, "git repo でない", out)

        # T37: ★GATE_TODAY が読めぬ時、黙って本日へ倒れぬ★ (代用品の申告を拾う)
        repo = _waiver_repo("t37")
        reg = T / "t37reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl])],
                   waivers=[{"path": "tests/rogue_mutation.bats", "reason": "r",
                             "until": "2026-08-31"}])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)],
                          today="きのう")
        expect("T37 読めぬGATE_TODAY=黙って倒れぬ", 1, rc, "黙って本日へ倒れることはせぬ", out)

        # T34: 点呼の免除も期限切れで返る (登録検知の免除と同じ掟)
        _write_census_reg(creg, [{"path": str(fanged), "reason": "別 cmd で扱う",
                                  "until": "2026-08-31"}])
        watched_f.write_text(f"{plain}\n")
        rc, out = _invoke(["--tree-census", "--registry", str(creg), "--projects", str(cproj),
                           "--watched-file", str(watched_f)], today="2026-07-26")
        expect("T34 点呼の期限内免除=PASS", 0, rc, "免除 1 本は可視", out)
        rc, out = _invoke(["--tree-census", "--registry", str(creg), "--projects", str(cproj),
                           "--watched-file", str(watched_f)], today="2026-09-01")
        expect("T34b ★点呼の免除も期限切れで返る★", 1, rc, "[免除期限切れ]", out)

        # ── ★T38〜T43: 着弾の一意性 (cmd_1382・規律(8))★ ──────────────────────
        #   ★空振り検知 (byte 一致) では原理的に捕えられぬ層★ = 撃ってはおるが場所が違う形。
        #   ゆえに ★負例 (捕えてはならぬ形) も同数据える★ = 常に鳴る門は必ず外されるゆえ。
        def _anchor_repo(tag: str, body: str, guard: str) -> Path:
            r = T / f"anchor_{tag}"
            r.mkdir(parents=True)
            (r / "tool.sh").write_text(body, encoding="utf-8")
            # ★負例が意味を持つには test が現に赤くなる必要が在る★ = 変異で消える綴りを見張る。
            # (初版は MARKER_LINE を見ており変異後も緑 → 負例が「変異後も緑=FAIL」で落ちた。
            #  ★門でなく fixture が誤っておった★ ゆえ fixture を直した)
            (r / "check.sh").write_text(f"#!/bin/bash\ngrep -q {guard} tool.sh\n", encoding="utf-8")
            return r

        def _anchor_run(tag: str, body: str, mutate: str, extra: dict | None = None,
                        guard: str = "'guard() {'"):
            r = _anchor_repo(tag, body, guard)
            e = {"id": f"MUT-ANCHOR-{tag}", "desc": "d", "paths": ["tool.sh", "check.sh"],
                 "mutate": mutate, "test": "bash check.sh", "expect": "nonzero"}
            e.update(extra or {})
            reg = T / f"anchor_{tag}.yaml"
            _write_reg(reg, [e])
            return _invoke(["--registry", str(reg), "--repo-root", str(r)])

        # 同じ綴りが2箇所に在る victim (五号が現に踏んだ形 = 旧い同名が先に居る)
        TWO = "#!/bin/bash\n# MARKER_LINE\nguard() { echo old; }\nx=1\nguard() { echo new; }\n"
        ONE = "#!/bin/bash\n# MARKER_LINE\nguard() { echo only; }\nx=1\n"

        # T38: ★巻き込み型★ = sed に count 指定が無く 2 箇所を撃つ → UNDETERMINED + 名指し
        rc, out = _anchor_run("multi", TWO, "sed -i 's/guard/guard_X/' tool.sh\n")
        expect("T38 ★巻き込み型 (2箇所発火) = UNDETERMINED★", 2, rc, "箇所で発火", out)

        # T39: ★移動型★ = replace(old,new,1) で候補が2つ → 第2射が別の行を撃つ
        MOVE = ("python3 - <<'PY2'\np='tool.sh'\ns=open(p,encoding='utf-8').read()\n"
                "open(p,'w',encoding='utf-8').write(s.replace('guard() {','guardX() {',1))\nPY2\n")
        rc, out = _anchor_run("move", TWO, MOVE)
        expect("T39 ★移動型 (別候補が残る) = UNDETERMINED★", 2, rc, "撃たなんだ候補", out)

        # T40 (負例): anchor が一意なら同じ mutate でも通る = ★常に鳴る門ではない★
        rc, out = _anchor_run("uniq", ONE, MOVE)
        expect("T40 一意な anchor は通る (負例)", 0, rc, "PASS", out)

        # T41: ★申告すれば全置換は許す★ = 禁じておるのは【黙って】全置換すること
        rc, out = _anchor_run("declared", TWO, "sed -i 's/guard/guard_X/' tool.sh\n",
                              {"anchor_sites": 2})
        expect("T41 anchor_sites 申告つき全置換は通る", 0, rc, "PASS", out)

        # T42: ★申告が実測より少なければ鳴る★ (申告が飾りにならぬ形)
        rc, out = _anchor_run("underdeclared", TWO, "sed -i 's/guard/guard_X/g' tool.sh\n",
                              {"anchor_sites": 1})
        expect("T42 ★過小申告は鳴る★", 2, rc, "申告は 1 箇所", out)

        # T43 (負例): ★字下げ直し = 1 箇所の編集が n 発火に見える偽陽性を出さぬ★
        #   (実測で踏んだ形: ★backend 台帳★ cmd_1369 の B2a/B2b = block は 1 箇所しか無いのに
        #    行ごとの字下げ挿入で 5 発火に見えた。literal 数え上げで裏を取って偽陽性と判じた。
        #    ★ID を綴らぬのは、他 repo の台帳の ID を此処へ書くと幽霊 ID として鳴るゆえ★)
        BLOCK = "#!/bin/bash\n# MARKER_LINE\nif A:\n  p\n  q\n  r\n"
        REINDENT = ("python3 - <<'PY2'\np='tool.sh'\ns=open(p,encoding='utf-8').read()\n"
                    "open(p,'w',encoding='utf-8').write(s.replace('if A:\\n  p\\n  q\\n  r',"
                    "'def f():\\n    if A:\\n      p\\n      q\\n      r',1))\nPY2\n")
        rc, out = _anchor_run("reindent", BLOCK, REINDENT, guard="'^if A:'")
        expect("T43 字下げ直しを多発火と誤らぬ (負例)", 0, rc, "PASS", out)

        # T44: schema — anchor_sites が整数でなければ sanity が止める (黙って既定へ倒さぬ)
        bad = T / "anchor_badschema.yaml"
        _write_reg(bad, [{"id": "MUT-ANCHOR-BAD", "desc": "d", "paths": ["tool.sh"],
                          "mutate": "true", "test": "true", "anchor_sites": "いち"}])
        rc, out = _invoke(["--sanity", "--registry", str(bad)])
        expect("T44 anchor_sites 非整数=sanity が止める", 2, rc, "anchor_sites", out)

        # ── ★T45〜T49: cmd_1382 差し戻し3件 (三側すべて塞ぐ)★ ────────────────
        # T45: ★過大申告も鳴る★ (足軽二号の名指し)。旧版は fired > declared しか見ておらず
        #      ★anchor_sites: 99 と書けば門は黙った★ (是正前 実測 rc=0 PASS)。
        rc, out = _anchor_run("overdeclared", TWO, "sed -i 's/guard/guard_X/' tool.sh\n",
                              {"anchor_sites": 99})
        expect("T45 ★過大申告は鳴る★", 2, rc, "過大申告", out)

        # T46: ★自食い型★ (軍師一号の名指し)。旧版は第1射の【結果】へ当て直しておったゆえ
        #      置換後の綴りが元を含む形では第2射が第1候補へ戻るだけで
        #      ★第2候補が現に残っておるのに rc=0 PASS★ であった (是正前 六号 実測)。
        SELFFEED = ("python3 - <<'PY2'\np='tool.sh'\ns=open(p,encoding='utf-8').read()\n"
                    "open(p,'w',encoding='utf-8').write(s.replace('guard','guardX',1))\nPY2\n")
        rc, out = _anchor_run("selffeed", TWO, SELFFEED, guard="'guard() { echo old'")
        expect("T46 ★自食い型でも残り候補を捕える★", 2, rc, "撃たなんだ候補", out)

        # T47 (負例): ★残り候補が無ければ通る★ = 候補尽きの証。
        #   T46 の門が ★常に鳴る門★ にならぬことの対照。
        rc, out = _anchor_run("exhausted", ONE, MOVE)
        expect("T47 残り候補なし (候補尽き) は通る (負例)", 0, rc, "PASS", out)

        # T47b (負例・最重要): ★申告つきの全置換は、自食いの綴りでも通る★。
        #   初版の是正はこれを赤くしておった (T41 が落ちた) = ★正しい entry を殺す門★。
        #   「戻ったか」でなく「撃たれておらぬ候補が在るか」を問う形へ改めた事の対照である。
        rc, out = _anchor_run("selffeed_declared", TWO, "sed -i 's/guard/guard_X/' tool.sh\n",
                              {"anchor_sites": 2})
        expect("T47b ★申告つき全置換は自食いの綴りでも通る (負例)★", 0, rc, "PASS", out)

        # T48: ★物差しB (行の塊)★ = difflib の key が site ごとに割れて
        #   ★綴りとしては 1 箇所にしか見えぬのに現に 2 行へ着弾しておる★ 形を捕える。
        #   (六号 実測: 総当り 1,254,499 組中 1 件 — 稀だが現に在る。是正前は fired=1 で PASS)
        SKEW = "#!/bin/bash\naa0aa\nfiller\na00aa\n"
        rc, out = _anchor_run("skew", SKEW, "sed -i 's/0/1/g' tool.sh\n", guard="'aa0aa'")
        expect("T48 ★綴りで割れても行の塊が数える★", 2, rc, "行の塊", out)

        # T49: ★空白のみの変更は「測れなんだ」と名乗る★ (黙って一意の顔をさせぬ)
        rc, out = _anchor_run("wsonly", ONE, "sed -i 's/^x=1$/x=1   /' tool.sh\n")
        expect("T49 空白のみ=着弾を測れなんだ", 2, rc, "測れなんだ", out)

        # ── ★T51〜T53: 配線前の全数計数が捕えた「己の門の偽陽性」3 型 (負例)★ ──────
        #   ★いずれも実在の台帳 entry で現に鳴っておった★ = 出荷しておれば
        #   ★他人の正しい牙を 3 本 赤にしておった★。★門を建てる前に数えたゆえ捕まえた★。
        NEG_GUARD = "'^x=1$' tool.sh && ! grep -q MUT_MARK"

        # T51 (負例): ★追記型★ (printf >>) — 伏せる行が無いゆえ検分は当てはまらぬ。
        #   実例 = backend MUT-1350-M2 (五号)。初版は「候補が残っておる」と誤って鳴らした。
        rc, out = _anchor_run("append", ONE, "printf '\\nMUT_MARK\\n' >> tool.sh\n",
                              guard=NEG_GUARD)
        expect("T51 ★追記型は鳴らぬ (負例)★", 0, rc, "PASS", out)

        # T52 (負例): ★挿入型★ (sed 's/x/&\\n…/') — 同上 (difflib では i1==i2)。
        #   実例 = backend MUT-1350-M4 (五号)。
        rc, out = _anchor_run("insert", ONE, "sed -i 's/^x=1$/&\\nMUT_MARK/' tool.sh\n",
                              guard=NEG_GUARD)
        expect("T52 ★挿入型は鳴らぬ (負例)★", 0, rc, "PASS", out)

        # T53 (負例): ★行の移動は 1 箇所と数える★ — 消える塊と現れる塊に割れるが 1 つの編集。
        #   実例 = backend MUT-1350-M1 (五号) = 2 つの sed で行を移す変異。
        MOVE_BODY = "#!/bin/bash\nAAA\nBBB\nCCC\nx=1\n"
        MOVE_MUT = ("sed -i '/^BBB$/d' tool.sh\n"
                    "sed -i 's/^CCC$/CCC\\nBBB/' tool.sh\n")
        rc, out = _anchor_run("linemove", MOVE_BODY, MOVE_MUT,
                              guard="'^BBB$' tool.sh && [ \"$(sed -n 3p tool.sh)\" = BBB ] #")
        expect("T53 ★行の移動は 1 箇所 (負例)★", 0, rc, "PASS", out)

        # ── ★T54: (d)【file には当たったが interpreter に届かぬ】= 五号 cmd_1384★ ──────
        #   ★.pyc は (source の mtime【秒】, size) だけで有効性を判ずる★ゆえ、
        #   ★同 size の変異を同じ mtime のまま書けば、古い .pyc が有効と判ぜられ
        #     【変異前の code が走る】= 変異は当たったのに test は緑★。
        #   ★束縛入替 (列の順を入れ替える等) は size 差が 0 byte ゆえ最も当たり易い★
        #   (実例 = backend MUT-1384-M10/M11)。
        #   ★本 case は .pyc を paths へ名指しで持ち込み、mutate が mtime を戻す★ =
        #   ★purge_pycache を外せば変異後も緑 = runner は FAIL を返す★ ⇒
        #   ★之が処置を縛る負例である (処置が現に効いておることの証明)★。
        pyroot = T / "pycrepo"
        (pyroot / "pkg").mkdir(parents=True)
        (pyroot / "pkg" / "__init__.py").write_text("", encoding="utf-8")
        (pyroot / "pkg" / "mod.py").write_text(
            "def pair():\n    return (\n        1,\n        2,\n    )\n", encoding="utf-8")
        (pyroot / "check.sh").write_text(
            f'"{sys.executable}" -c '
            "'import pkg.mod as m; assert m.pair()==(1,2), \"NG PAIR\"'\n", encoding="utf-8")
        # ★古い .pyc を repo 側に作る★ (五号が実地で踏んだ盤面を再現する)
        subprocess.run([sys.executable, "-c", "import pkg.mod"], cwd=pyroot,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        pycs = sorted((pyroot / "pkg" / "__pycache__").glob("mod.*.pyc"))
        if not pycs:
            na.append("T54 (.pyc が作られぬ環境ゆえ検分せず — PYTHONDONTWRITEBYTECODE か)")
        else:
            rel_pyc = str(pycs[0].relative_to(pyroot))
            PYC_MUT = ("python3 - <<'PY2'\n"
                       "import os\n"
                       "p = 'pkg/mod.py'\n"
                       "st = os.stat(p)\n"
                       "s = open(p, encoding='utf-8').read()\n"
                       "old = '        1,\\n        2,\\n'\n"
                       "new = '        2,\\n        1,\\n'\n"
                       "assert s.count(old) == 1\n"
                       "assert len(old) == len(new)\n"
                       "open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))\n"
                       "os.utime(p, (st.st_atime, st.st_mtime))\n"
                       "PY2\n")
            e54 = {"id": "MUT-PYC-STALE", "desc": "d",
                   "paths": ["pkg/__init__.py", "pkg/mod.py", rel_pyc, "check.sh"],
                   "mutate": PYC_MUT, "test": "bash check.sh", "expect": "nonzero",
                   "red_needle": "NG PAIR"}
            reg54 = T / "pyc.yaml"
            _write_reg(reg54, [e54])
            rc, out = _invoke(["--registry", str(reg54), "--repo-root", str(pyroot)])
            expect("T54 ★古い .pyc を持ち込んでも変異は届く (処置が効いておる)★",
                   0, rc, "PASS", out)

        # ── ★T55: 本 gate が読んだ盤面を名乗る (事例15・軍師一号の名指し)★ ──────
        #   ★毎朝の緑は【作業ツリーが壊せば落ちる】ことしか言うておらぬ★ =
        #   ★HEAD について何も言うておらぬのに、読む者は HEAD の話と読む (規律(6) の型)★。
        #   ⇒ ★食い違う其の時に名指す形にした★ = 常に鳴る門にせぬため。
        board_repo = _mk_git_repo(T / "board", {
            "tool.sh": "#!/bin/bash\n# MARKER_LINE\nexit 0\n",
            "check.sh": "#!/bin/bash\nbash tool.sh\n",
        })
        subprocess.run(["git", "-C", str(board_repo), "-c", "user.email=gate@local",
                        "-c", "user.name=gate", "commit", "-q", "-m", "init"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        reg55 = T / "board.yaml"
        _write_reg(reg55, [_entry("MUT-BOARD-1", "sed -i 's/^exit 0$/exit 1/' tool.sh\n")])

        # T55a: 作業ツリー = HEAD ⇒ ★HEAD についても同じ事を言うておる★ と積極的に名乗る
        rc, out = _invoke(["--registry", str(reg55), "--repo-root", str(board_repo)])
        expect("T55a ★盤面を名乗る (作業ツリー = HEAD)★", 0, rc, "作業ツリー = HEAD", out)

        # T55b: worktree だけ動かす ⇒ ★此の緑は HEAD について何も言うておらぬ★ と告げる
        (board_repo / "tool.sh").write_text(
            "#!/bin/bash\n# MARKER_LINE\n# worktree だけの一行\nexit 0\n", encoding="utf-8")
        rc, out = _invoke(["--registry", str(reg55), "--repo-root", str(board_repo)])
        expect("T55b ★食い違う其の時に名指す★", 0, rc, "HEAD については何も言うておらぬ", out)

        # ── 付帯5: ★負の主張に刃が在るか★ (段1/段2・軍師一号の設計 §4) ──
        #   ★門を据える者が己の門を検めぬなら、本稿の族をまた踏む★ ゆえ
        #   設計が挙げた NA-1〜NA-4 を、下の各試験が捕える (対応を行末に記す)。
        #   ★登録の前に一度 偽にして赤を見た★ = 本 commit の message に実測を刻む。
        NEG_BANG = ('@test "T-FIX-001: does not emit the banner" {\n'
                    '  ! grep -q banner out.txt\n}\n')
        NEG_OK = ('@test "T-FIX-002: does not emit the banner" {\n'
                  '  if grep -q banner out.txt; then return 1; fi\n}\n')
        neg_reg_bare = T / "negreg.yaml"
        _write_reg(neg_reg_bare, [_entry("MUT-NEG-1", "true")])
        neg_reg_named = T / "negreg2.yaml"
        _write_reg(neg_reg_named, [dict(_entry("MUT-NEG-2", "true"),
                                        red_needle="not ok 1 T-FIX-002")])

        # T56 [NA-1/NA-3]: 段1 = 刃を持たぬ `!` を ★FAIL(1)★ で名指す (UNDETERMINED へ倒さぬ)
        r56 = _mk_git_repo(T / "neg56", {"tests/a.bats": NEG_BANG})
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r56)])
        expect("T56 段1 `!` を FAIL で名指す", 1, rc, "刃を持たぬ負の主張", out)

        # T57 (負例): 倒した後の形 (if …; then return 1) を 段1 は ★通す★ = 過剰でない
        r57 = _mk_git_repo(T / "neg57", {"tests/a.bats": NEG_OK})
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r57)])
        expect("T57 段1 正しい形は通す", 2, rc, "[段1] OK", out)

        # T58 [NA-2]: 段2 = 台帳が名指しておらぬ負の主張を ★UNDETERMINED(2)★ で数える
        expect("T58 段2 未登録を数える", 2, rc, "誰も証しておらぬ 1 本", out)
        expect("T58b 段2 は FAIL にせぬ (全軍の commit を塞がぬ)", 2, rc, "分母", out)

        # T59 [NA-2]: red_needle が試験 ID を名指しておれば ★緑★ (逆引きが現に効いておる証)
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_named),
                           "--repo-root", str(r57)])
        expect("T59 段2 名指しあり=緑", 0, rc, "台帳が刃を証しておるのは 1 本", out)

        # T60 [NA-4]: ★段2 の走査母集団は追跡下に限らぬ★ = git ls-files へ狭めれば
        #   分母が 0 へ落ち、★「未登録 0 件」という偽の 0★ が出る (設計 §4 が最も高くつくと
        #   名指した形)。★NEG_OK を使う★= `!` を持たぬゆえ段1 は緑 ⇒ ★此の試験は段2 だけを縛る★。
        #   ★初版は NEG_BANG を使うており、段1 (五号の門) の性質しか縛っておらなんだ★ =
        #   ★母集団を追跡下へ狭める変異を当てても緑であった (2026-07-27 03:1x 実測)★ =
        #   ★己の牙が己の層を一文字も縛っておらぬ★を、登録前の実射が捕えた。
        r60 = _mk_git_repo(T / "neg60", {"README.md": "x\n"})
        (r60 / "tests").mkdir(parents=True, exist_ok=True)
        (r60 / "tests" / "untracked.bats").write_text(NEG_OK, encoding="utf-8")
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r60)])
        expect("T60 ★段2 は未追跡の .bats も数える★", 2, rc, "untracked.bats", out)

        # T60b: ★段1 も未追跡を見る★ (五号の門の性質を、繋いだ我らの側からも縛る)
        (r60 / "tests" / "untracked_bang.bats").write_text(NEG_BANG, encoding="utf-8")
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r60)])
        expect("T60b ★段1 も未追跡の .bats を名指す★", 1, rc, "untracked_bang.bats", out)

        # T61: .bats が 0 file = ★測れておらぬ★ (分母 0 を緑にせぬ・真空 PASS 禁)
        r61 = _mk_git_repo(T / "neg61", {"README.md": "x\n"})
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r61)])
        expect("T61 分母0=測れておらぬ", 2, rc, "測れておらぬ", out)

        # T62: vendored (bats-assert/support) は走査せぬ = 第三者の規律へ手を出さぬ
        r62 = _mk_git_repo(T / "neg62",
                           {"tests/test_helper/bats-assert/x.bats": NEG_BANG})
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r62)])
        expect("T62 vendored は走査せぬ", 2, rc, "測れておらぬ", out)

        # T63: pre-commit (--sanity) は ★触った .bats の分だけ★ 見る (常に鳴る門にせぬ)
        #   _mk_git_repo は add まで撃つゆえ、index には全 file が載っておる = 触った扱い
        rc, out = _invoke(["--sanity", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r57)])
        expect("T63 sanity 触った .bats を見る", 2, rc, "此の commit が触る .bats 1 file", out)

        # T64: 触った .bats が 1 file も無ければ ★【対象なし】と名乗って通す★
        #   (★緑ではなく対象なしである★ を文言で言わせる = 黙った緑を作らぬ)
        subprocess.run(["git", "-C", str(r57), "-c", "user.email=g@x",
                        "-c", "user.name=gate", "commit", "-q", "-m", "init"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rc, out = _invoke(["--sanity", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r57)])
        expect("T64 sanity 触っておらぬ=対象なしで通す", 0, rc, "1 file も触っておらぬ", out)

        # T50: ★gate の実出力の語が docs に在ること★ (cmd_1382 差し戻し・軍師二号)
        #   ★書いた場所と読まれる場所を揃える★ = 赤を見た者が docs を grep して辿り着けるか。
        #   ★語が食い違えば此処が赤くなる★ ゆえ、次に出力を整理する者が黙って道を切れぬ。
        #   ★此処に境が要る (2026-07-26 21:5x 実測の自傷)★:
        #   本 T50 は【repo 全体の不変条件】であって、変異が動かす類の物ではない。
        #   然れど台帳の牙は `paths:` に挙げた file だけを写した scratch 木で baseline を
        #   撃つゆえ (copy_paths)、★docs 木がそこに存在せぬ★。
        #   初版は其れを「語が5つ欠けておる」と読んで赤くし、★--selftest を baseline に
        #   持つ牙 10 件が丸ごと UNDETERMINED へ落ちた★ (実測: MUT-1352-003/005/006/007・
        #   MUT-1370-001/002・MUT-1374-001/002・MUT-1382-001/002)。
        #   = ★己の docs 検分が、他人の牙 10 本を黙って計測不能にしておった★。
        #   ⇒ ★境 = docs 木その物が無いか (scratch 木) / 在って file だけ無いか (真の退行)★。
        #     前者は検分の主題が此の木に無いゆえ判ぜず、★名乗る★ (summary へ必ず刷る)。
        #     後者は docs を消した/移した退行ゆえ ★従来どおり赤★ = 道は切れておらぬ。
        doc = REPO_ROOT / "docs" / "content" / "ops" / "cmd_1352_silent_pitfall_gates.md"
        if not (REPO_ROOT / "docs").is_dir():
            na.append("T50 (docs 木を持たぬ木ゆえ検分せず — repo では検分される)")
        else:
            doc_txt = doc.read_text(encoding="utf-8") if doc.exists() else ""
            # ★語を足す時は docs も同時に足せ★ = 此の tuple が【道が通っておるか】の見張りである
            #   (cmd_1382 = pycache の処置 / 事例15 = 盤面の名乗り の語を 2026-07-27 に追加)
            missing = [w for w in ("同一の綴り置換", "過大申告", "撃たなんだ候補",
                                   "着弾を測れなんだ", "行の塊",
                                   "HEAD については何も言うておらぬ",
                                   "interpreter に届かぬ",
                                   # 付帯5 (負の主張の刃・2026-07-27)
                                   "誰も証しておらぬ", "対象なし")
                       if w not in doc_txt]
            expect(f"T50 ★gate の実出力の語が docs に在る★ (欠けておる語: {missing})",
                   0, len(missing))

    print("----")
    # ★検分せなんだ物は、緑の行にも赤の行にも必ず名を出す★ = 黙って消える道を作らぬ。
    na_note = f" / ★検分せず {len(na)} 件★: {'; '.join(na)}" if na else ""
    if ng == 0:
        print(f"[gate-2 selftest] {ok}/{ok} ALL PASS{na_note}")
        return 0
    print(f"[gate-2 selftest] FAIL: ok={ok} ng={ng}{na_note}")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    ap.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    ap.add_argument("--sanity", action="store_true")
    ap.add_argument("--negative-assertions", action="store_true",
                    help="付帯5: 負の主張に刃が在るかの段1/段2 を単独で撃つ (未登録を全数 印字)")
    ap.add_argument("--coverage", action="store_true",
                    help="cmd_1352b: 変異testらしき file が台帳に登録されておるかの検知層")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--tree-census", action="store_true",
                    help="cmd_1374: 牙を持つのに どの gate も見ておらぬ repo を名指す")
    ap.add_argument("--watched-file", type=Path, default=None,
                    help="gate が実際に撃った repo-root の一覧 (--tree-census 用)")
    ap.add_argument("--attempted-file", type=Path, default=None,
                    help="cmd_1374b: gate が★撃とうとした★ repo-root の一覧。watched に居らぬ物は"
                         " ★撃てておらぬ★ として UNDETERMINED で名指す (黙って点呼から消させぬ)")
    ap.add_argument("--projects", type=Path, default=REPO_ROOT / "config" / "projects.yaml",
                    help="木の登録簿 (点呼の分母)")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.tree_census:
        return tree_census(a.registry, a.watched_file, a.projects, a.attempted_file)
    if a.negative_assertions:
        rc, lines = negative_assertion_audit(a.registry, a.repo_root, verbose=True)
        for ln in lines:
            print(ln)
        return rc
    if a.sanity:
        return sanity(a.registry, a.repo_root)
    if a.coverage:
        return coverage(a.registry, a.repo_root)
    return run_all(a.registry, a.repo_root)


if __name__ == "__main__":
    sys.exit(main())
