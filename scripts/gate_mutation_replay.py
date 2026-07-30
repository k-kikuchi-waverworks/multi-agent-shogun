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

★挿入点の掟 (cmd_1409 — 「登録した」と「登録されておる」は同じ物ではない)★:
  ★entry は【mutations: list の末尾】へ挿せ = coverage_waivers: が在る冊では其の直前である★。
  ★file の末尾へ継ぐな★ — 五号 08:15 実測: shogun 台帳の末尾へ継いだ entry は mutations: の
  下に入らず ★最後の top-level key の値として黙って呑まれた★ (parse は通り・道具も何も申さず・
  ★mutations の総数も動かぬ★)。★「正しく壊れた」ゆえ書いた当人にも見えぬ★。
  ★冊の形で結果が変わる (六号 09:34 実測)★= mutations: が末尾の冊 (web/ml/engine) では通り、
  末尾でない冊 (shogun/backend/app) では呑まれる ⇒ ★人の記憶に置いてはならぬ★。
  ⇒ ★★挿した直後に機械へ数えさせよ★★:
       python3 scripts/gate_registry_append.py --count config/mutation_registry.yaml
     (pre-commit の gate-4 が同じ検分を自動で撃つ。呑まれは ★翌朝の replay にも見えぬ★ =
      台帳に載っておらぬ牙は撃たれもせぬゆえ、commit の其の瞬間に名指す以外に口が無い)

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
                                                        # ★F を書く者は今 居ない★ (書いていた
                                                        #   gate_nightly.sh は cmd_1479 で撤去)
                                                        #   ⇒ 空/不在なら UNDETERMINED を返す
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


def hunk_sites(a_root: Path, b_root: Path) -> list:
    """★行の塊が【どの file から来たか】を返す★ (cmd_1387・2026-07-27)。

    ★何故 要るか★= 物差しB (行の塊) で鳴った時、読む者へ手掛かりが 1 つも出ておらなんだ。
      内訳 (anchor_firings の detail) は ★同一の (old→new) が 2 回以上出た時にしか埋まらぬ★ =
      物差しA が 1 で物差しB が 2 の盤面では ★常に空である★。
      ⇒ ★鳴っても持ち主が動けぬ★ = 本日ずっと狩ってきた「名乗らぬ計器」そのものである。

    ★実害 (2026-07-27 18:40)★= 六号が五号の牙を「2 箇所で発火」と報せたが、
      内訳が空ゆえ ★どの file の塊かを渡せなんだ★。
      五号は静かな盤面で 3 回 撃ち直して 3 回とも PASS を見るしか無く、
      ★持ち主が己の牙を疑う以外に道が無かった★ (五号 18:57 の言)。
      ★file 名さえ出ておれば、其の場で「変異が書かぬ file の塊である」と判った★。

    返す物 = [{"file": 相対路, "count": 塊の数, "sample": 変わった綴りの頭}] を塊の多い順に。
    ★数え方は _diff_shape と同一でなければならぬ★ (別の数を出せば計器が二つに割れる)。
    """
    import difflib
    af, bf = _tree_text_files(a_root), _tree_text_files(b_root)
    out = []
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
            if "".join(old.split()) == "".join(new.split()):
                continue
            pieces.append(("".join(old.split()), "".join(new.split())))
        dels = [i for i, (o, n) in enumerate(pieces) if o and not n]
        adds = [i for i, (o, n) in enumerate(pieces) if n and not o]
        used, moved = set(), 0
        for d in dels:
            for a in adds:
                if a not in used and pieces[d][0] == pieces[a][1]:
                    used.add(a)
                    moved += 1
                    break
        n = len(pieces) - moved
        if n <= 0:
            continue
        sample = next((o or nw for o, nw in pieces if (o or nw)), "")
        out.append({"file": rel, "count": n, "sample": sample[:60]})
    return sorted(out, key=lambda d: -d["count"])


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
        #   実例 = backend ref:MUT-1350-M1 (五号) = 2 つの sed で ★行を移す★ 変異ゆえ
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
        # ★物差しB で鳴った時の手掛かり (cmd_1387)★= 上の内訳 (綴りの内訳) は
        #   ★同一の (old→new) が 2 回以上出た時にしか埋まらぬ★ ゆえ、物差しB が鳴らした盤面では
        #   ★常に空である★ = ★鳴っても持ち主が動けぬ★ (2026-07-27 18:40 に現に起きた)。
        #   ⇒ ★塊が【どの file から来たか】を必ず添える★ = 持ち主が「己の変異が書かぬ file の
        #     塊である」を其の場で判ぜられる (五号が 3 回 撃ち直す羽目になった当の穴)。
        hs = "; ".join(f"{x['file']}×{x['count']}"
                       + (f"「{x['sample']}」" if x["sample"] else "")
                       for x in hunk_sites(pristine, mut)[:4])
        return (f"★同一の綴り置換が {fired} 箇所で発火 (申告は {declared} 箇所)★ = 狙い+余所を"
                f"巻き込んでおる。赤が出ても【どの箇所の赤か】を名指しできぬ。"
                f" 数えた物差し = {which} ({spell_note} / 行の塊 {by_hunks})."
                + (f" 内訳: {d}." if d else "")
                + (f" 塊の出所: {hs}." if hs else "")
                + f" 処方 = anchor を一意な綴りへ絞る (前後の行を含める) か、全置換が意図なら"
                f" 台帳へ anchor_sites: {fired} と書け (黙って全置換するのを禁じておる)")

    if fired == 0:
        # 空白のみの変更 = 着弾を測る術が無い。★黙って通さぬ★ (未検分は緑ではない)。
        return ("★着弾を測れなんだ (変わったのは空白のみ)★ = 一意とは言えぬ。"
                " 処方 = 空白でなく【意味の在る綴り】を変える mutate にせよ")

    if declared > fired:
        # ★過大申告 = 申告が飾りになる道★ (cmd_1382 差し戻し (ii)・足軽二号の名指し)。
        # 旧版は fired > declared しか見ておらず、anchor_sites: 99 と書けば門は黙った。
        # ★此処にも塊の出所を添える (cmd_1387)★= 「2 と申告したが実測 1」と言われた者が
        #   次に問うのは ★其の 1 は何処の 1 か★ である (六号が 19:03 に己で踏んで判った)。
        hs = "; ".join(f"{x['file']}×{x['count']}" for x in hunk_sites(pristine, mut)[:4])
        return (f"★anchor_sites の申告 {declared} 箇所に対し、実測は {fired} 箇所★ = 過大申告。"
                f" ({spell_note} / 行の塊 {by_hunks}"
                + (f" / 塊の出所 {hs}" if hs else "") + ")"
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
        #   実例 (配線前の全数計数で捕えた偽陽性) = backend ref:MUT-1350-M1 (移動) /
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
        #   実例 = backend ref:MUT-1350-M2 (追記型) / M4 (挿入型) = 五号。
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
# ような略記の申告は拾えぬ (完全形で書く規律とセットで効く)。
#
# ★★cmd_1408 (2026-07-27) = 「幽霊 63 件」の一語を三語へ割る + 物差しを是正した★★
#   ① ★物差しの是正★: 旧 REGISTRY_ID_RE (下に DISCARDED として残す) は
#      ★足軽三号が cmd_1386 (scripts/ledger_id_census.py — ★此の file は cmd_1479 第4束で
#      撤去済。現物は git show 88aa167:scripts/ledger_id_census.py★) で
#      【壊れておると証して捨てた綴り】その物★が、門の中で生き残っておった形である。破れ方は二つ:
#        (a) ★枝を 1 つしか読まぬ★ = 「MUT-<cmd>-R3-M1〜M5」が全て「MUT-<cmd>-R3」へ潰れる
#        (b) ★先読みが無い★ = 「XMUT-<cmd>-001」の綴りの途中から id を拾う
#      ★(a) は偽陰性を作る★: 台帳に「MUT-<cmd>-R3」が在れば、実在せぬ「…-R3-M9」の申告を
#      門は「MUT-<cmd>-R3」と読んで【幽霊でない】と黙る。★2026-07-27 07:57 実測では現物 0 件★
#      = 之は説明であって実測ではない ⇒ ★selftest T71 が fixture で現に落ちることを示す★。
#      ⇒ census と同じ綴りへ揃えた。★是正の結果 幽霊は 63 → 64 件へ【増えた】★
#      (07:57 実測・shogun 木) = ★数を良くする動きではない★ことを数で示せる形。
#   ② ★出所の別を名乗らせる★: 幽霊を A / C / C? の三語へ割る。
#        A  = ★別台帳 (backend/app/web/engine 等) に実在★ = 申告は真・記録が他木に在るだけ
#        C  = ★何処の台帳にも無い (真に未登録)★ = 所有者の借財
#        C? = ★別台帳の一部が読めなんだ★ ⇒ ★「真に未登録」とは言わぬ★ (fail-closed)
#      ★verdict は動かさぬ★ = A も従来どおり FAIL の中に数える。★門を静かにする為に数を
#      消す形は禁★ (家老下命 cmd_1408) = 分けて名乗るだけである。
#   ③ ★旧物差しとの読みの差を毎朝 数える★ = [RULER-SHADOW]。是正が黙って巻き戻された時や、
#      新しい綴りの形が現れた時に、★門が己の物差しについて口を利く★形にしておく。
# ─────────────────────────────────────────────────────────────────────────────
# 物差し。★元は census (scripts/ledger_id_census.py) の `ID_RE` と同一に揃えてあった★が、
#   ★census は cmd_1479 第4束で撤去した (殿が承認された掃除)★ = 呼び手が 1 本も無かったため。
#   ⇒ ★今この綴りを持つのは此の 1 行だけである。突き合わせる相手は repo に無い。★
#   ★撤去の前に機械で比べた★= census の ID_RE と下の綴りは ★文字まで同一★であった。
#     ゆえに「揃えてあった状態のまま、片方だけが残った」形である (綴りは変えていない)。
#   ★2 つ持てばずれる、という元の危うさは消えた。代わりに別の危うさが立つ★ =
#     ★此処を誰かが緩めても、突き合わせて気づく相手が居ない。★
#   現物 (撤去した側) を読みたい時 = git show 88aa167:scripts/ledger_id_census.py
#     (★f887dae 以前ならどの版でもよい。撤去は第4束の commit である★)
REGISTRY_ID_RE = re.compile(r"(?<![A-Za-z0-9])MUT-[0-9]+[A-Za-z]*(?:-[A-Za-z0-9]+)+")
# ★捨てた綴り★ = 今も影を数える為だけに残す (これで判定してはならぬ)
REGISTRY_ID_RE_DISCARDED = re.compile(r"MUT-\d{3,4}-[A-Za-z0-9]+")

# ─────────────────────────────────────────────────────────────────────────────
# 見本用の予約帯 MUT-9999-* (cmd_1387・2026-07-27 家老 17:31 の裁(乙))
#
# 何が起きていたか: 変異テストの道具は、自分の selftest の中で「台帳の見本」を作る。
#   その見本 id (MUT-9999-SWALLOW など) を、幽霊 ID 検分が本物の id と同じに数えていた。
#   実測 = 幽霊 64 件のうち 14 件が見本 id (gate_registry_append.py 10 / gate_verdict_drift.py 2 /
#   test_gate_registry_append_wiring.bats 2)。
# なぜ登録で消してはいけないか: 見本を台帳へ登録すれば、実体のない変異テストが 1 本増える。
#   つまり「幽霊を消すために偽物を作る」形になる。数を減らすために中身を悪くしてはならない。
# 対処: 綴りで分ける。9999 は実在しない cmd 番号なので、本物と衝突しない。
#   検分は予約帯を除いて数え、除いた件数を必ず表示する (黙って減らさない)。
#   逆向きの守りも同時に置く = 予約帯の id を台帳へ登録しようとしたら schema エラーにする
#   (これが無いと「偽の変異テスト 1 本」を防ぐ代わりに「本物が黙って検分から落ちる」穴が開く)。
# 英字つきの cmd 番号 (実在例 = 1369E) を見本で再現する試験があるので、帯にも英字を許す。
# 帯の要は「9999 という実在しない cmd 番号」であって、英字の有無ではない。
FIXTURE_ID_BAND_RE = re.compile(r"^MUT-9999[A-Za-z]*-")

# ─────────────────────────────────────────────────────────────────────────────
# 引用の印 ref: (cmd_1387・2026-07-27 家老 18:10 の裁2)
#
# 何が起きていたか: 註の中で他の木の変異テストを実例として挙げると
#   (例: 「実例 = backend の ref:MUT-1350-M1 = 2 つの sed で行を移す変異ゆえ」)、
#   幽霊 ID 検分がそれを「この木の申告」として数えていた。実測 = 幽霊 A 22 件のうち 11 件。
# なぜ登録でも削除でも駄目か:
#   登録すれば実体のない変異テストが 11 本増える。註から消せば「なぜこの造りにしたか」の
#   経緯が痩せる。どちらも「数を減らすために中身を悪くする」形である。
# 対処: 書き方で分ける。他の木の実例を引く時は id の前に ref: を付ける。
#   検分は素の id を「申告」、ref: 付きを「引用」として ★別に数え、件数を必ず名乗る★
#   (黙って捨てれば、書き方を間違えた申告まで一緒に消える)。
# なぜ前置きか: バッククォートで囲む形は採らない。「囲めば通る」は engine 側で踏んだ穴と
#   同じ族である。ref: は前置きゆえ grep で確実に拾え、人が読んでも引用と分かる。
QUOTE_PREFIX = "ref:"

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
    """台帳が名指しする tracked file のうち【test 本体】を返す。

    返り = ({走らせる物 relpath: [entry id]}, {同伴 relpath: [entry id]}, error)

    ★綴りを一切見ぬ★ = paths / test / mutate の中の path らしき文字列を拾い、
    追跡下・COVERAGE_EXTS・test 本体の印を持つものだけを残す。

    ★★二つに分けて返す = 【走らせる物】と【同伴】★★ (cmd_1408・三号 2026-07-27)
      ・走らせる物 = test / mutate に現れる = ★赤くなる側の本体★ (entry が之を走らせて赤を見る)
      ・同伴       = ★paths にしか現れぬ物★ = 本体が import する依存等、
        ★replay が写す為だけに並んでおる物★ (ml の cmd1349_p5_body_stats.py が現物)。
    ★何ゆえ別けるか★= ★視野計の分母は「規則が見付ける【べき】変異試験」でなければならぬ★。
      同伴を分母へ入れると、★台帳が走らせてもおらぬ file を「規則の盲」として数える★ =
      ★★問いの違う二つの計器を同じ問いだと思う形★★ (家老 22:35 通達①)。
      ★実測 (2026-07-27 09:32)★= 6 冊の盲 17 件は ★悉く【走らせる物】★であり、
      ★同伴は ml の 1 件のみ★ ⇒ ★分母を絞っても盲は 1 件も失われぬ★
      (失うのは「台帳が走らせておらぬ同伴を盲と呼んでおった」誤りだけである)。
    ★★同伴も返す (捨てぬ)★★= 呼び手が ★役を名乗らせた上で画面へ出す★ ゆえ =
      ★黙って落とせば「見えておらぬ物が減った」と読まれる = 数を良くする動きになる★。
    """
    tracked, err = ls_files(repo)
    if err:
        return None, None, err
    tset = set(tracked)
    out: dict[str, list[str]] = {}
    comp: dict[str, list[str]] = {}
    seen_run: set[str] = set()
    for e in entries:
        eid = str(e.get("id", "?"))
        run_blob = " ".join([str(e.get("test", "")), str(e.get("mutate", ""))])
        blob = " ".join([run_blob] + [str(p) for p in (e.get("paths") or [])])
        run_rels = {m.group(0).lstrip("./") for m in _PATHLIKE_RE.finditer(run_blob)}
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
                return None, None, f"読めぬ追跡 file: {rel} ({ex}) — 黙って飛ばさぬ (沈黙禁)"
            if rel in run_rels:
                seen_run.add(rel)
            tgt = out if rel in seen_run else comp
            tgt.setdefault(rel, [])
            if eid not in tgt[rel]:
                tgt[rel].append(eid)
    # ★一つの木で【走らせる物】と【同伴】の両方に立つ file は、走らせる物を正とする★
    #   (別の entry が現に走らせておるなら、其れは規則が見付ける【べき】物ゆえ)
    for rel in list(comp):
        if rel in out:
            for eid in comp.pop(rel):
                if eid not in out[rel]:
                    out[rel].append(eid)
    return out, comp, None


_BUNDLE_RUNNERS = {"pytest", "py.test", "bats", "unittest", "nose2"}


def bundle_style_tests(entries, repo: Path) -> list[tuple[str, str]]:
    """entry の test が【束】(ディレクトリ・ワイルドカード) を走らせておるかを数える。

    何を見張るか (cmd_1408・六号が己の借財として名乗った穴):
      同伴かどうかの判別は「entry の test/mutate に path がそのまま現れるか」で決めている
      (registry_named_test_bodies)。ゆえに誰かが test を束で書けば
      (例: `pytest tests/unit/`)、その test 本体は paths にしか現れず【同伴】と読まれ、
      視野計の分母から静かに落ちる。落ちても画面には何も出ぬ。

    今 6冊にこの形は 1 件も無い (2026-07-27 09:32 実測)。
    「今 無い」は「起こらぬ」ではないゆえ、機械の側へ移す。

    探し方: test の各行を空白で割り、runner (pytest/bats 等) より後ろの引数のうち
      ・ワイルドカードを含む
      ・末尾が / である
      ・repo の中で現にディレクトリである
    のいずれかに当たるものを束と読む。runner の後ろに限るのは、
    引用符の中の綴りや `mkdir -p .venv/bin` の類を束と誤読せぬためである。

    返り = [(entry id, 当たった綴り)] (該当なしなら空)。判定 (exit code) には使わぬ。
    """
    found: list[tuple[str, str]] = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        eid = str(e.get("id", "?"))
        hit = None
        for line in str(e.get("test", "")).splitlines():
            after_runner = False
            prev = ""
            for tok_raw in line.split():
                tok = tok_raw.strip("\"'`,();")
                prev_was_flag = prev.startswith("-") and "=" not in prev
                prev = tok
                if not tok:
                    continue
                if Path(tok).name in _BUNDLE_RUNNERS:
                    after_runner = True
                    continue
                if not after_runner or tok.startswith("-"):
                    continue
                # 旗の値 (--filter T-SW-00[12] 等) は path ではない = 束と読まぬ
                if prev_was_flag:
                    continue
                # ★path らしく見えぬ綴りは束と読まぬ★ = 2026-07-27 23:0x に現に踏んだ偽陽性。
                #   bats の --filter に渡す `T-SW-00[12]` を「glob ゆえ束」と読んでおった。
                if "/" not in tok and not (repo / tok).is_dir():
                    continue
                if any(ch in tok for ch in "*?["):
                    hit = tok
                    break
                if tok.endswith("/") or (repo / tok).is_dir():
                    hit = tok
                    break
            if hit:
                break
        if hit:
            found.append((eid, hit))
    return found


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
    # cmd_1387: 見本用の予約帯を本物として登録させない。
    #   予約帯は幽霊 ID 検分から除かれる = ここを通せば「登録されているのに検分から見えない」
    #   本物が生まれる。除外と登録禁止は必ず対で置く。
    if FIXTURE_ID_BAND_RE.match(str(e["id"])):
        return (f"id が見本用の予約帯にある: {e['id']} — MUT-9999-* は selftest の見本専用で、"
                f"幽霊 ID 検分から除かれる。本物の変異テストには使えない (cmd_1387)")
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


def copy_paths_snapshot(repo: Path, paths: list[str], dsts: list[Path]) -> str | None:
    """★同じ瞬間の写しを配る★ (cmd_1387・2026-07-27 に実物で捕えた)。

    何を塞ぐか = ★変異が起こしておらぬ差を、着弾として数える道★。
      旧い形は pristine / base / mut を ★別々に写しておった★ =
      写しと写しの【間】に他人が同じ木へ書けば、其の差が変異の産物と見分けが付かぬ。
      本 runner は着弾数を「変異の前後の木の差」で数えるゆえ、他人の 1 行が
      ★着弾 +1★ として数えられ、牙が「2 箇所で発火」と誤って名指される。

    実測 (2026-07-27 18:5x・六号が sandbox で決定的に再現):
      paths に dir を持つ entry (例 tests/) の写しの間に他人が tests/ の中の 1 行を書いたら、
      行の塊 = 2 と出て「同一の綴り置換が 2 箇所で発火」と鳴った。
      変異自身は 1 file しか書いておらず、其の file の中では綴りは 1 箇所である。
      ★静かな盤面では再現せぬ★ゆえ、鳴らされた持ち主が撃ち直しても PASS しか見えぬ。

    ★之は本日ずっと狩ってきた族の一員である★ =
      「共有 file の世で、二つの瞬間に測った物を突き合わせるな」(軍師一号 13:48 の条②の系)。

    処方 = ★1 度だけ写し、其の写しを複製する★ = 配る木は悉く【同じ瞬間】の物になる。
      写している最中に他人が書く形は猶 残る (それは写しが 1 度でも起こる) が、
      ★其の時も配る木は互いに一致する★ = 変異の産物と見分けが付く。
    """
    if not dsts:
        return "写す先が 0 件"
    first = dsts[0]
    first.mkdir(parents=True, exist_ok=True)
    err = copy_paths(repo, paths, first)
    if err:
        return err
    purge_pycache(first)
    for d in dsts[1:]:
        try:
            shutil.copytree(first, d)
        except OSError as exc:
            return f"写しを複製できぬ: {d} ({exc})"
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
    # ★1 度だけ写し、其の写しを複製する★ = 三つの木が悉く【同じ瞬間】の物になる。
    #   別々に写せば、写しの間に他人が書いた 1 行が【着弾 +1】として数えられる (cmd_1387)。
    #   .pyc の掃除は copy_paths_snapshot が写しの側で済ませる (複製ゆえ三つとも同じ)。
    err = copy_paths_snapshot(repo, e["paths"], [pristine, base, mut])
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


def _clock() -> str:
    """★走行の刻 (境を後から機械で割る鍵)★ — cmd_1408・六号"""
    import datetime
    return datetime.datetime.now().strftime("%H:%M:%S")


def paths_digest(repo: Path, entries) -> tuple[str, dict]:
    """★台帳 paths の【中身】を畳んだ digest を返す (cmd_1408・六号)★

    ★何を塞ぐか★= ★門は走行の始めに一度だけ盤面を名乗り、其の名乗りを走行の終わりまで
    有効であるかの如く残しておった★。★93 件の走行は 40 分を要する★ゆえ、
    ★其の間に他者の commit が paths の中身を入れ替えれば、一行目の名乗りは黙って偽になる★。
    ★2026-07-27 の実例★= 六号の走行 (07:50 開始) の最中に三号の 4076bdf (08:10:59) が着き、
      ★先に測った entry は旧盤面・後は新盤面★を見ておった。★出力からは境が割れなんだ★。
    ⇒ ★之は「一度 真であった名乗りが、いつまで真かを名乗っておらぬ」形★である。

    ★mtime でなく中身の digest を採る理由★= ★mtime は touch でも動き、内容が同じでも食い違う★=
      ★偽の警報を出す門は外される★ゆえ、★中身が現に変わった時だけ鳴る★形にした。
    """
    import hashlib
    rels = sorted({str(x) for e in entries if isinstance(e, dict)
                   for x in (e.get("paths") or [])})
    per: dict[str, str] = {}
    h = hashlib.sha256()
    for rel in rels:
        t = repo / rel
        try:
            if t.is_dir():
                # ★dir も copy_paths が写す対象ゆえ数える★ (写す物と数える物を割らぬ)
                hh = hashlib.sha256()
                for f in sorted(t.rglob("*")):
                    if f.is_file() and "__pycache__" not in f.parts:
                        hh.update(str(f.relative_to(t)).encode())
                        hh.update(f.read_bytes())
                d = hh.hexdigest()
            elif t.is_file():
                d = hashlib.sha256(t.read_bytes()).hexdigest()
            else:
                d = "<実体なし>"
        except OSError as e:
            # ★読めなんだ事を黙って飛ばさぬ★= 読めぬ事自体を digest の一部にする
            d = f"<読めぬ:{type(e).__name__}>"
        per[rel] = d
        h.update(rel.encode("utf-8"))
        h.update(d.encode("utf-8"))
    return h.hexdigest(), per


def window_declaration(before: dict, after: dict, started: str, ended: str) -> str:
    """★走行が【瞬間】を見たのか【窓】を見たのかを、門が己で名乗る (cmd_1408・六号)★

    ★exit code は動かさぬ★= ★盤面が動く度に門が赤くなれば【常に鳴る門】になり、必ず外される★
      (本夜ずっと退けてきた形)。★退くのは【一行目の名乗り】だけで足る★。
    """
    moved = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
    if not moved:
        return ("  [窓] 走行の始め ({s}) と終わり ({e}) で台帳 paths の中身は ★動いておらぬ★ = "
                "★此の走行は【瞬間】を見た★ = 一行目の盤面の名乗りは走行の全体について真である"
                ).format(s=started, e=ended)
    names = ", ".join(moved[:6]) + (" ほか" if len(moved) > 6 else "")
    return ("  [窓] ★★走行中に盤面が動いた ({n} file)★★ ({s} → {e}) = {names}\n"
            "       ⇒ ★★一行目の盤面の名乗りは【走行の始まり】についてのみ真である★★ = "
            "★此の走行は【瞬間】でなく【窓】を見た★\n"
            "       ⇒ ★各 entry を、其れを測った時の盤面へ当てた★ = "
            "★境は各行 末尾の [刻] で割れる★ (動いた commit の刻と突き合わせよ)"
            ).format(n=len(moved), s=started, e=ended, names=names)


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
    # ★cmd_1408 (丙)★= 走行の入口で盤面を焼く (出口で採り直し、動いておれば門が己で名乗る)
    _started = _clock()
    _digest0, _per0 = paths_digest(repo, entries)
    n_pass = n_fail = n_undet = 0
    for e in entries:
        eid = e.get("id", "?") if isinstance(e, dict) else "?"
        with tempfile.TemporaryDirectory(prefix="mutreplay_") as w:
            verdict, why = evaluate_entry(e, repo, Path(w))
        mark = {PASS: "ok  ", FAIL: "★NG★", UNDET: "未定 "}[verdict]
        who = e.get("suspected_by") if isinstance(e, dict) else None
        tag = f" [疑い:{who}]" if who else ""
        # ★刻は【行末】へ置く★= ★行頭へ置けば、此の出力を機械で読む者が黙って盲になる★。
        #   ★2026-07-30 cmd_1479 (88aa167) 現在、機械で読む者は 1 人も居らぬ★ =
        #   下に挙げた二人は どちらも撤去した:
        #     gate_verdict_drift.py の `VERDICT_RE` = `^\s+(?:ok\s+|★NG★\s*|未定\s+)…` (撤去)
        #     gate_nightly.sh の `grep -vE '^\s*ok\s'` (PASS 行を除く口・撤去)
        #   ⇒ ★形の枷が緩んだ、と読むな★= 読む者が居らぬのは今の盤面の性質でしかなく、
        #     次に誰かが機械で読み始めた時、行頭へ刻を移してあれば同じ盲が生える。
        #   ★行番号で指さぬ★ = 行が動いた瞬間に別の物を指すゆえ (CLAUDE.md 条F)。
        #   ⇒ ★形を変える時は【読む者】を先に数える★ (2026-07-27 六号が実測して確かめた)
        print(f"  {mark} {verdict:12s} {eid}:{tag} {why} [刻 {_clock()}]")
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
    # ★cmd_1408 (丙)★= 出口で盤面を採り直す (動いておれば名乗る・exit code は動かさぬ)
    _digest1, _per1 = paths_digest(repo, entries)
    print(window_declaration(_per0, _per1, _started, _clock()))
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
    """tracked COVERAGE_EXTS file 中の台帳 ID 完全形言及を返す。

    返り = ([(rel, line_no, id)], [(rel, line_no, id)], [(rel, line_no, 旧読み, 新読み or None)], error)
      第1 = ★申告★ = 素の id 言及 (幽霊検分の対象)
      第2 = ★引用★ (cmd_1387) = ref: を前置した id = 他の木の実例を挙げておるだけの物。
            ★幽霊に数えぬが、黙って捨てもせぬ★ = 件数は coverage が必ず名乗る。
      第3 = ★物差しの影★ (cmd_1408) = 同じ位置を ★捨てた綴り★ と ★今の綴り★ が別々に読む所。
            ★判定には一切使わぬ★ = 数えて名乗る為だけの器 (是正が黙って巻き戻る/新しい綴りの
            形が現れる、の二つを門が己の口で言える形にしておく)。
    幽霊 ID 検分 (四号 M9 型) の材料。読めぬ追跡 file は沈黙せず error (coverage scan と同じ掟)。
    """
    tracked, err = ls_files(repo)
    if err:
        return None, None, None, err
    refs: list[tuple[str, int, str]] = []
    quotes: list[tuple[str, int, str]] = []
    shadows: list[tuple[str, int, str, str | None]] = []
    for rel in tracked:
        if Path(rel).suffix not in COVERAGE_EXTS:
            continue
        p = repo / rel
        if not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            return None, None, None, f"読めぬ追跡 file: {rel} ({e}) — 黙って飛ばさぬ (沈黙禁)"
        for i, line in enumerate(text.splitlines(), 1):
            now = {m.start(): m.group(0) for m in REGISTRY_ID_RE.finditer(line)}
            for st, mid in sorted(now.items()):
                # cmd_1387: ref: を前置した物は【他の木の実例の引用】= 此の木の申告ではない
                if line[max(0, st - len(QUOTE_PREFIX)):st] == QUOTE_PREFIX:
                    quotes.append((rel, i, mid))
                else:
                    refs.append((rel, i, mid))
            for m in REGISTRY_ID_RE_DISCARDED.finditer(line):
                if now.get(m.start()) != m.group(0):
                    shadows.append((rel, i, m.group(0), now.get(m.start())))
    return refs, quotes, shadows, None


def peer_registry_paths(own: Path) -> list[tuple[str, Path]]:
    """★幽霊 ID の出所照合先★ = 他木の台帳 (cmd_1408)。

    既定は gate_nightly.sh と ★同じ path・同じ env★ で解いていた (二つ持てば必ずずれるゆえ)。
    ★2026-07-30 cmd_1479 (88aa167) で gate_nightly.sh を撤去したので、揃える相手は消えた★
    = 下の cands が この path 群の唯一の持ち主になった。
    ★併せて名乗る★= 冊の一覧を持つ所は、今 repo 内に ★2 つ在って食い違っている★:
      ・此処 (5 冊 = shogun / backend / app / web / engine)
      ・gate_registry_append.py の _fallback_books (3 冊 = shogun / web / ml)
    ★どちらを正本にするかは決まっていない★ (決めるのは殿。起票して裁を待つ)。
    ⇒ ★片方だけ見て「冊は N 冊」と名乗るな。★
    ★己の台帳は除く★ (解決後の path で照合) — 己を「別台帳」と呼ばぬ。
    """
    home = Path.home()
    backend = Path(os.environ.get("GATE_BACKEND_ROOT") or (home / "aituber-project" / "backend"))
    app = Path(os.environ.get("GATE_APP_ROOT") or (home / "aituber-project"))
    engine = Path(os.environ.get("GATE_ENGINE_ROOT")
                  or "/mnt/c/Users/k-kikuchi/development/ai-automate-engine")
    cands = [
        ("shogun", DEFAULT_REGISTRY),
        ("backend", backend / "config" / "mutation_registry.yaml"),
        ("app", app / "config" / "mutation_registry.yaml"),
        ("web", REPO_ROOT / "config" / "mutation_registry.web.yaml"),
        ("engine", engine / "config" / "mutation_registry.yaml"),
    ]

    def _r(p: Path) -> Path:
        try:
            return p.resolve()
        except OSError:
            return p

    ownr = _r(own)
    return [(n, p) for n, p in cands if _r(p) != ownr]


def load_peer_ids(peers: list[tuple[str, Path]]):
    """(id → [台帳名], 読めた台帳の名札, 読めなんだ [(名, 理由)]) を返す。

    ★読めぬ台帳を 0 件へ倒さぬ★ = 読めなんだ台帳が 1 つでも在れば、呼び手は
    「何処にも無い (真に未登録)」と断ずる資格を失う (下の C? へ倒れる)。
    """
    ids: dict[str, list[str]] = {}
    read: list[str] = []
    unread: list[tuple[str, str]] = []
    for name, p in peers:
        doc, err, present = resolve_registry_doc(p)
        if not present:
            unread.append((name, f"{p} が無い"))
            continue
        if err or not isinstance(doc, dict) or not isinstance(doc.get("mutations"), list):
            unread.append((name, f"{p}: {err or '台帳に mutations: リストが無い'}"))
            continue
        n = 0
        for e in doc["mutations"]:
            if isinstance(e, dict) and e.get("id"):
                ids.setdefault(str(e["id"]), []).append(name)
                n += 1
        read.append(f"{name}({n})")
    return ids, read, unread


def coverage(registry: Path, repo: Path, peers: list[Path] | None = None) -> int:
    """gate-2 付帯 (cmd_1352b): 変異testらしき file が台帳に登録されておるかの検知層。

    peers = 幽霊 ID の出所照合先 (別台帳)。None なら既定 (peer_registry_paths) を解く。

    FAIL は「block」でなく「家老へ警告」を意味していた (gate_nightly が既存の家老 inbox
    警告経路へ相乗りしていた)。
    ★2026-07-30 cmd_1479 (88aa167) で gate_nightly.sh を撤去したので、此の FAIL を
    家老へ運ぶ者は今 居ない★ = ★撃った本人の画面に出るだけである★。
    ⇒ 手で撃った時は、FAIL を自分で読んで自分で運べ (誰も後から拾わぬ)。
    免除は coverage_waivers (同じ台帳 file 内・理由必須) のみ =
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
    refs, quotes, shadows, rerr = scan_registry_id_refs(repo)
    if rerr:
        print(f"[gate-2 coverage] UNDETERMINED: {rerr}")
        return 2
    known = {str(e.get("id")) for e in entries}
    # cmd_1387: 見本用の予約帯 (MUT-9999-*) を除く。除いた件数は必ず表示する。
    fixture_refs = [(rel, ln, mid) for rel, ln, mid in refs if FIXTURE_ID_BAND_RE.match(mid)]
    ghosts = [(rel, ln, mid) for rel, ln, mid in refs
              if mid not in known and not FIXTURE_ID_BAND_RE.match(mid)]
    fixture_files = sorted({rel for rel, _, _ in fixture_refs})
    print(f"  [予約帯] 見本用 MUT-9999-* を {len(fixture_refs)} 件 除いた"
          f" (file {len(fixture_files)} 本: {', '.join(fixture_files) if fixture_files else 'なし'})"
          f" — selftest の見本ゆえ台帳には載らぬ。登録しようとすれば schema が拒む (cmd_1387)")
    # cmd_1387: ref: を前置した引用 (他の木の実例) を別に数える。0 件でも必ず名乗る。
    quote_files = sorted({rel for rel, _, _ in quotes})
    print(f"  [引用] ref: 付きの言及を {len(quotes)} 件 別に数えた"
          f" (file {len(quote_files)} 本: {', '.join(quote_files) if quote_files else 'なし'})"
          f" — 他の木の実例を挙げておるだけゆえ此の木の申告に数えぬ (cmd_1387)")
    # ── ★出所の別 (cmd_1408)★ = 「幽霊 N 件」の一語を A / C / C? の三語へ割る ──
    #   ★verdict は動かさぬ★ = A も C も従来どおり FAIL の中に数える (門を静かにする為に
    #   数を消す形は禁 — 家老下命)。★割るのは【誰の手番か】を画面から読ませる為である★:
    #     A  = 別台帳に実在 = ★申告は真・記録が他木に在るだけ★ (処方は「登録」ではない)
    #     C  = 何処の台帳にも無い = ★所有者の借財★
    #     C? = 別台帳の一部が読めなんだ = ★「真に未登録」と断ずる資格が無い★
    peer_list = peer_registry_paths(registry) if peers is None else [(p.name, p) for p in peers]
    peer_ids, peer_read, peer_unread = load_peer_ids(peer_list)
    print(f"  [照合] 幽霊の出所照合先 = 別台帳 {len(peer_read)} 件"
          f" [{'/'.join(peer_read) if peer_read else 'なし'}]"
          f" — ★読めなんだ台帳 {len(peer_unread)} 件★"
          + (f" ({'; '.join(f'{n}: {why}' for n, why in peer_unread)})" if peer_unread else ""))
    n_a = n_c = n_unk = 0
    for rel, ln, mid in ghosts:
        if mid in peer_ids:
            n_a += 1
            print(f"  ★NG★ [GHOST-ID/A]   {rel}:{ln} が {mid} を名指す。本 repo の台帳には無いが"
                  f" ★別台帳 {'/'.join(peer_ids[mid])} に実在★ = 申告は真・記録が他木に在る"
                  " (処方は【登録】ではなく、木を跨ぐ引用と判る書き方か、其の木の gate で見ること)")
        elif peer_unread:
            n_unk += 1
            print(f"  ★NG★ [GHOST-ID/C?]  {rel}:{ln} が {mid} を名指すが本 repo の台帳に無い。"
                  f" ★別台帳 {len(peer_unread)} 件が読めなんだゆえ【真に未登録】とは言わぬ★"
                  " (判別不能 = 照合先を直してから断ぜよ)")
        else:
            n_c += 1
            print(f"  ★NG★ [GHOST-ID/C]   {rel}:{ln} が {mid} を名指すが"
                  " ★本 repo にも別台帳にも実在せぬ (真に未登録)★"
                  " (docstring 申告と台帳の食い違い = 四号 M9 型。登録するか申告を消せ)")
    # ── ★物差しの影 (cmd_1408)★ = 捨てた綴りと今の綴りが別々に読む所を数える ──
    #   ★判定には使わぬ★。是正が黙って巻き戻る/新しい綴りの形が現れる を門が己で言う為の器。
    for rel, ln, old, new in shadows[:10]:
        print(f"  注   [RULER-SHADOW] {rel}:{ln} ★捨てた綴りなら「{old}」と読む所を、"
              f"今の物差しは「{new if new else '(id と読まぬ)'}」と読む★")
    if shadows:
        print(f"  注   [RULER-SHADOW] 計 {len(shadows)} 件"
              + (f" (上は先頭 10 件のみ)" if len(shadows) > 10 else "")
              + " — ★二つの綴りが現に別々に読んでおる = 是正 (cmd_1408) が効いておる★"
                " (0 件になった時の意味は二つ = 木から其の形の綴りが消えたか、"
                "★物差しが巻き戻ったか★ — 見分けは selftest T71/T72 が持つ)")

    # ── ★視野計★ (付帯4・cmd_1370): 検知規則の recall を台帳で測り、盲を数字で言わせる ──
    named, companions, nerr = registry_named_test_bodies(entries, repo)
    if nerr:
        print(f"[gate-2 coverage] UNDETERMINED: {nerr}")
        return 2
    blind = {rel: ids for rel, ids in named.items() if rel not in cands}
    for rel in sorted(blind):
        print(f"  注   [RULE-BLIND]    {rel}: 台帳 {'/'.join(blind[rel])} が名指す変異試験だが"
              " ★検知規則 D1/D2/D3 には見えておらぬ★ (台帳が在るゆえ守られてはおる。"
              "同じ形の【未登録】は検知できぬ = 検知規則の視野の外)")
    # ★★同伴は【消さぬ】= 名を出したまま、役を名乗らせる★★ (cmd_1408・三号)
    #   ★黙って分母から落とせば「見えておらぬ物が減った」と読まれる = 数を良くする動きになる★。
    for rel in sorted(c for c in companions if c not in cands):
        print(f"  注   [RULE-BLIND/同伴] {rel}: 台帳 {'/'.join(companions[rel])} が"
              " paths にのみ挙げる物 = ★台帳は之を走らせてはおらぬ★ (本体が import する依存等)"
              " ⇒ ★規則に見えておらぬが【視野の分母には入れぬ】★"
              " (走らせてもおらぬ物を『規則の盲』と数えれば、規則の死を誤って疑う)")
    # ── 束で走らせる entry を数える (cmd_1408・六号の借財) ────────────────────
    #   同伴の判別は「test に path がそのまま現れるか」で決めておる。束で書けば
    #   test 本体が同伴と読まれ、視野計の分母から静かに落ちる。
    #   母数は 0 でも必ず刷る = 「0 件」と「そもそも数えておらぬ」を分ける。
    #   判定 (exit code) は動かさぬ = 名乗るに留める。昇格は家老/殿の号令。
    bundles = bundle_style_tests(entries, repo)
    print(f"  [束] 台帳 {len(entries)} 件を走査 / ★test を束 (ディレクトリ・ワイルドカード) で"
          f"走らせる entry = {len(bundles)} 件★"
          " — 探し方 = test の runner (pytest/bats 等) より後ろの引数が dir か glob か")
    for eid, tok in bundles:
        rels = sorted(r for r, ids in companions.items() if eid in ids)
        print(f"  注   [束/同伴] {eid}: test が ★{tok}★ を束で走らせる"
              " ⇒ paths の test 本体が test に現れず【同伴】と読まれ、"
              "★視野計の分母から静かに落ちうる★"
              f" (この entry の同伴 = {', '.join(rels) if rels else 'なし'})"
              " — 処方は test に本体の path を名指しで書くこと")
    n_named, n_seen = len(named), len(named) - len(blind)
    # ★物差しの長さを先に言う★: 対照は必ず当たる fixture ゆえ分母から除く。
    #   除いた残りが 0 件なら【recall を測れておらぬ】= 「全部見えておる」ではない
    #   (分母0と全員健全を区別する — cmd_1364 の流儀を検知器自身へ当てたもの)
    # ★★併せて【同伴】は named に入っておらぬ (cmd_1408・三号)★★ =
    #   ★台帳が走らせておらぬ file を「規則が見落とした」と数えるのは筋が違う★。
    #   ★之を入れておった為、ml (非対照が同伴 1 件のみ) で
    #    「検出規則が死んでおる疑い」へ誤って escalate しておった★ = 規則は現に生きておる。
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
              f" / ID申告 {len(refs)} 件 (別に引用 {len(quotes)} 件) 中 ★幽霊 {len(ghosts)} 件"
              f" (A 別台帳に実在 {n_a} / C 真に未登録 {n_c} / C? 判別不能 {n_unk})★"
              f" (視野: {vision})")
        print("  処方: 「赤を一度確認した」変異を config/mutation_registry.yaml へ登録せよ")
        print("        (登録の書式は本 file 冒頭 docstring)。登録すべきでない正当な理由が在るなら")
        print("        coverage_waivers へ【理由つきで】免除を書け (黙って外す道は無い)。")
        print("        幽霊 ID は台帳へ登録するか docstring の申告を消せ (申告≠実在を残すな)。")
        print("        ★但し出所で手番が違う★= C=所有者が登録 / A=他木の台帳に在る引用ゆえ"
              "登録では消えぬ / C?=先に照合先を直せ (★数を減らす為に消すな★ — cmd_1408)。")
        return 1
    # ★PASS の文言に視野を刻む★ = 「候補すべて登録済」を【全部検査した】と読ませぬための限定
    #   (cmd_1364 の「検査した と 全部検査した を混同させぬ」を、検知器自身へ当てたもの)
    # ★「登録済」と「免除」を混ぜて言わぬ★ = 全件が免除の木で「すべて登録済」と出すのは
    #   画面の嘘である (cmd_1353b D-1 で直したのと同じ型 — 見出しが実態と食い違う)。
    n_reg = len(cands) - n_waived
    print(f"[gate-2 coverage] PASS: ★規則に見えた★候補 {len(cands)} 件 ="
          f" ★登録 {n_reg} 件 / 免除 {n_waived} 件 (うち★無期限 {n_open_ended} 件★)★"
          f" — 免除は可視・期限切れ 0 件・ID申告 {len(refs)} 件 (別に引用 {len(quotes)} 件) に幽霊なし"
          f" (照合先 = 別台帳 {len(peer_read)} 件・読めなんだ {len(peer_unread)} 件)"
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
# ★己の路を己で名乗る★ (cmd_1407) = ID の綴りの規則が此処に在ることを出力から辿れる形。
NEG_GATE_SELF = "scripts/gate_mutation_replay.py"


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


# ─────────────────────────────────────────────────────────────────────────────
# ★ID として読めなかった試験名を名乗る (cmd_1407)★
#
# ★何を塞ぐか★= 段2 は台帳の red_needle を ★試験 ID★ で逆引きする。而して ID の綴りの
#   規則 (BATS_TEST_ID_RE) は ★どこにも書かれておらぬ★ = 頭に置く・大文字と数字のみ・
#   ハイフンを1つ以上含む。ゆえに「T0」「A1」「(B-N3) …」「日本語で始まる名」は
#   ★ID が1つも取れぬ★。書き手は「台帳へ登録した」と思うたまま、其の試験は
#   ★誰も証しておらぬ側★ に残り続ける。
# ★六号 05:5x の名乗りを一点 訂正して受ける★= 「台帳に何を書いても永久に落ちる」ではない。
#   段2 は ID が無ければ ★名の全文★ でも照合する (下の witnessed 判定の第二項)。
#   ゆえに逃げ道は在る = ★@test の名を一字も違えず red_needle へ書く★。
#   ★然れど其の逃げ道も、規則と同じく どこにも書かれておらぬ★ = ゆえに門が名乗る。
# ★落とさぬ★= 数と現物を刷るのみ。rc は一切 動かさぬ (家老 22:24 の枷)。
# ★行頭を動かさぬ★= 既存の行の綴りと位置はそのまま。★末尾へ足すだけ★ である
#   (本 file の自試験 T63/T64 が段2 の出力の綴りを掴んでおるゆえ = 読み手を先に数えた)。
# ─────────────────────────────────────────────────────────────────────────────
def idless_test_lines(tests: list[dict], repo: Path, needles: str,
                      verbose: bool = False) -> list[str]:
    """ID が取れなかった試験名を名指す行を返す (空 list = 全部 ID が取れた)。"""
    idless = [t for t in tests if not t.get("id")]
    if not idless:
        return []
    by_name = [t for t in idless if t.get("name") and t["name"] in needles]
    lines = [
        f"  ── ★ID として読めなかった試験名 = {len(idless)} 本★ "
        f"(分母 {len(tests)} 本中・うち ★名の全文★ で台帳が証しておるのは {len(by_name)} 本)",
        f"     規則 (どこにも書かれておらぬゆえ門が名乗る) = {NEG_GATE_SELF}: "
        f"BATS_TEST_ID_RE = {BATS_TEST_ID_RE.pattern}",
        "       = ★名の【頭】に置く・大文字と数字のみ・ハイフンを1つ以上含む★ (例 T-QRM-001)",
        "       ⇒ 「T0」「A1」「(B-N3) …」「日本語で始まる名」は ID が1つも取れぬ",
        "     ★落としておらぬ★ = 之は「壊れておる」ではなく ★台帳が ID では名指せぬ★ の報せである",
        "     処方は二つ: (a) 名の頭を T-XXX-001 の形にする  "
        "(b) red_needle へ ★@test の名を一字も違えず★ 書く (段2 は名の全文でも照合する)",
    ]
    shown = idless if verbose else idless[:5]
    for t in shown:
        try:
            rel = Path(t["file"]).relative_to(repo)
        except ValueError:
            rel = Path(t["file"])
        lines.append(f"       {rel}:{t['line']}: {str(t['name'])[:70]}")
    if len(idless) > len(shown):
        lines.append(f"       … 他 {len(idless) - len(shown)} 本 "
                     "(全数は --negative-assertions --verbose)")
    return lines


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
      全数 (未登録の負の主張。★数は日々 動くゆえ此処へ焼かぬ★ =
      知りたければ `--negative-assertions` を撃て) を毎 commit 鳴らせば
      ★全 agent の commit が毎回 ⚠ を出す★ =
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
    idless = idless_test_lines(tests, repo, needles, verbose=verbose)
    if not unwitnessed:
        return 0, [f"[段2] OK: {head}", f"  {scope}"] + idless
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
    # ★rc は動かさぬ★= ID が読めぬことは「壊れておる」ではない。末尾へ足すのみ (cmd_1407)。
    lines += idless
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
#     その file を本層が読む形であった。★gate の呼び出し行を消せば、その木は記録されぬ★ゆえ
#     「配線を消したのに watched のまま」という食い違いが ★構造的に起こり得ぬ★。
#     (cmd_1359 の「番人は書いただけでは番をせぬ」を、点呼自身へ当てたもの)
#
#   ■ ★★2026-07-30 cmd_1479 (88aa167) 以後 = 本層を撃つ者も、養う者も 居ない★★
#     --watched-file へ書いていたのは gate_nightly.sh だけで、それを撤去した。
#     ★--tree-census を実運用で撃つ呼び手も repo 内に 0 本★ =
#       残っている呼びは ①本 file の --selftest の中 (T-CEN-* が擬似盤面で撃つ) ②手で撃つ口 のみ。
#       ⇒ ★selftest が緑でも「点呼が現に走っている」ではない★ (擬似盤面での緑である)。
#     ⇒ 今 手で撃てば、watched が空ゆえ ★「どの gate も見ておらぬ木」が全数に近く出る★。
#       ★之を「盤面が壊れた」と読むな★= 養う者が消えただけである。
#     ⇒ 直す形 (毎朝の門を建て直すか、点呼ごと退役させるか) は決まっていない。
#       ★門を建てるのは起票して殿の裁を待つ仕事である★ (CLAUDE.md 自己修正の禁)。
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
    # ★穴★: watched は各 gate の【成功の枝の中】でしか記録されぬ (gate_nightly ★88aa167 で撤去済★ の
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
        print("  処方: その木へ台帳を置き coverage を撃つ (毎朝の門 gate_nightly.sh は cmd_1479 で")
        print("        撤去したので、★今 その木を自動で見る者は居ない★ = 手で撃つか、監視を建て直すか) か、")
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


def _cov_entry(eid: str, paths: list[str], companion_only: bool = False):
    """coverage 検分用の entry。

    ★test が path を名指す★= ★実物の台帳が悉くそう書かれておる★ (2026-07-27 実測 =
      6 冊の台帳が名指す test 本体 60 件は ★1 件も欠けず test/mutate に現れる★)。
    ★companion_only=True★ = ★paths にしか現れぬ【同伴】★ を作る =
      ★ml の cmd1349_p5_body_stats.py と同じ形★ (本体が import する依存)。
    """
    named = "" if companion_only else " " + " ".join(paths)
    return {"id": eid, "desc": eid, "paths": paths,
            "mutate": "true", "test": "true" + named}


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

    def check(name: str, cond: bool, note: str = ""):
        """真偽で縛る口 (cmd_1387)。rc でなく【出力の中身】を見る試験に使う。"""
        nonlocal ok, ng
        if cond:
            print(f"  ok {name}")
            ok += 1
        else:
            print(f"  NG {name}: {note}")
            ng += 1

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
        #      cmd_1387: 9999 は見本用の予約帯になったので 9998 へ移した。
        #        9999 のままだと予約帯として除かれ、この試験が「幽霊を出せない」形で緑になる
        #        (= 検査が何も見ていないのに通る形。実際にこの試験は赤で教えてくれた)。
        ghost_id = "MUT-" + "9998-999"
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

        # ── ★T73 (cmd_1408・三号 2026-07-27)★ = ★【同伴】を規則の盲と数えるな★ ────────
        #   ★実事故★= ml を門の下へ入れた朝、登録検知が rc=2 で
        #   「検出規則が死んでおる疑い」を出した。★然るに規則は現に生きておった★ =
        #   非対照の唯一の要素が ★cmd1349_p5_body_stats.py = p7 が import する同伴★ であり、
        #   ★台帳は之を走らせてはおらぬ★ (test は p7 の --selfcheck を撃つ)。
        #   ⇒ ★走らせてもおらぬ file を「規則が見落とした」と数えて規則の死を疑うておった★。
        #   ★T25 との対★= T25 は【走らせる物】が見えぬ時に鳴る (規則の死の疑いは正しい)。
        #   本試験は【同伴】しか無い時に ★鳴らぬ★ ことを縛る = 誤検知の側から物差しを固める。
        repo = _mk_git_repo(T / "t73", {ctl: _COV_CONTROL_BODY,
                                        "tests/silent_body.py": _COV_SILENT_PY})
        reg = T / "t73reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-COMPANION", ["tests/silent_body.py"],
                                    companion_only=True)])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T73 ★同伴のみ=規則の死を疑わぬ★ (誤 escalate せぬ)", 0, rc,
               "視野は測れておらぬ", out)
        expect("T73b ★同伴は消さず役を名乗る★ (黙って分母から落とさぬ)", 0, rc,
               "[RULE-BLIND/同伴]", out)

        # ── T74 (cmd_1408・六号) = 束で走らせる entry を門が己で名乗る ────────────
        #   塞ぐ穴: 同伴の判別は「test に path がそのまま現れるか」で決めておる。
        #   束 (pytest tests/unit/ 等) で書けば test 本体は同伴と読まれ、
        #   視野計の分母から静かに落ちる。落ちた事は画面に何も出ぬ。
        #   両方向で縛る = 束を名乗ること (T74a) と、名指しの時に黙ること (T74b)。
        #   ★T74b が無ければ「常に鳴る門」を作れてしまう★ (cmd_1388 の族)。
        repo = _mk_git_repo(T / "t74", {ctl: _COV_CONTROL_BODY,
                                        "tests/silent_body.py": _COV_SILENT_PY})
        reg = T / "t74reg.yaml"
        bundle_entry = {"id": "MUT-COV-BUNDLE", "desc": "束で走らせる形",
                        "paths": ["tests/silent_body.py"],
                        "mutate": "true", "test": "pytest tests/"}
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]), bundle_entry])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T74a ★束で走らせる entry を名乗る★", 0, rc, "[束/同伴] MUT-COV-BUNDLE", out)
        expect("T74a2 ★母数を刷る (0 件と未走査を分ける)★", 0, rc,
               "台帳 2 件を走査", out)

        # T74b (負例): test が本体を名指しておれば ★束とは読まぬ★ = 黙る
        repo = _mk_git_repo(T / "t74b", {ctl: _COV_CONTROL_BODY,
                                         "tests/silent_body.py": _COV_SILENT_PY})
        reg = T / "t74breg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-NAMED", ["tests/silent_body.py"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        # rc=2 はこの fixture の性質 (silent な本体は検知規則に見えぬ = T25 と同じ)。
        # ここで縛るのは rc ではなく ★束と読まぬこと★ である。
        # T74c (負例・現に踏んだ偽陽性から): bats の --filter に渡す綴りを束と読まぬ。
        #   実物 = MUT-1387-SW1 の `bats --filter T-SW-00[12] <本体>`。
        #   [ を glob と読んで「束」と名乗っておった (2026-07-27 23:0x 実測)。
        repo74c = _mk_git_repo(T / "t74c", {ctl: _COV_CONTROL_BODY,
                                            "tests/silent_body.py": _COV_SILENT_PY})
        reg74c = T / "t74creg.yaml"
        _write_reg(reg74c, [_cov_entry("MUT-COV-CTL", [ctl]),
                            {"id": "MUT-COV-FILTER", "desc": "filter は path でない",
                             "paths": ["tests/silent_body.py"], "mutate": "true",
                             "test": "bats --filter T-SW-00[12] tests/silent_body.py"}])
        rc74c, out74c = _invoke(["--coverage", "--registry", str(reg74c),
                                 "--repo-root", str(repo74c)])
        check("T74c ★旗の値 (filter) を束と読まぬ★ (現に踏んだ偽陽性)",
              "[束/同伴]" not in out74c and "走らせる entry = 0 件" in out74c,
              f"rc={rc74c} / [束/同伴] が出た: {'[束/同伴]' in out74c}")

        check("T74b ★名指しは束と読まぬ (常に鳴る門にせぬ)★",
              "[束/同伴]" not in out and "走らせる entry = 0 件" in out,
              f"rc={rc} / [束/同伴] が出た: {'[束/同伴]' in out}"
              f" / 母数行: {'走らせる entry = 0 件' in out}")

        # T22: 実在 ID の言及は幽霊扱いせぬ (誤検知抑止の負例)
        repo = _mk_git_repo(T / "t22", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# 実射で確認済: {real_id}\n"})
        reg = T / "t22reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry(real_id, ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo)])
        expect("T22 実在ID言及=幽霊扱いせぬ", 0, rc, "幽霊なし", out)

        # ── ★cmd_1408 selftests★: 幽霊の【出所を割る】+ ★捨てた綴りの偽陰性を fixture で落とす★
        #   ID は T21 と同じ理由で ★必ず動的に組む★ (literal を書けば本 file 自身が幽霊言及になる)
        peer_only = "MUT-" + "8801-001"   # ★別台帳にのみ在る★ id
        nowhere = "MUT-" + "8802-001"     # ★何処の台帳にも無い★ id
        peer_reg = T / "t70peer.yaml"
        _write_reg(peer_reg, [_cov_entry(peer_only, ["other_tree/test.bats"])])
        t70_files = {ctl: _COV_CONTROL_BODY,
                     "tests/rogue_mutation.bats":
                         _COV_ROGUE_BATS + f"# 実射で確認済: {peer_only} と {nowhere}\n"}
        reg = T / "t70reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-ROGUE", ["tests/rogue_mutation.bats"])])

        # T70: ★A (別台帳に実在) と C (真に未登録) を分けて名乗る★ = 「幽霊」の一語を割る
        repo = _mk_git_repo(T / "t70", t70_files)
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(peer_reg)])
        expect("T70 出所A=別台帳に実在と名乗る", 1, rc, "[GHOST-ID/A]", out)
        expect("T70b 出所C=真に未登録と名乗る", 1, rc, "[GHOST-ID/C]", out)
        expect("T70c 締めの数で A と C を分ける", 1, rc, "A 別台帳に実在 1 / C 真に未登録 1", out)
        # ★verdict は動かさぬ★ = A が在っても FAIL のまま (門を静かにする為に数を消さぬ)
        expect("T70d 出所を割っても verdict は動かさぬ (A も FAIL の中)", 1, rc,
               "幽霊 2 件", out)

        # T70e: ★照合先が読めなんだ時に【真に未登録】と断ぜぬ (fail-closed)★
        #   = 「読めぬ」を「無い」へ倒せば ★C の数が水増しされ、他人へ在らぬ借財を負わせる★
        repo = _mk_git_repo(T / "t70e", t70_files)
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(T / "no_such_peer.yaml")])
        expect("T70e 読めぬ台帳=判別不能 (C?) と名乗る", 1, rc, "[GHOST-ID/C?]", out)
        expect("T70f 読めぬ間は【真に未登録】と言わぬ", 0, 1 if "実在せぬ (真に未登録)" in out else 0)

        # T71: ★捨てた綴り (旧 REGISTRY_ID_RE) の偽陰性を fixture で現に落とす★
        #   台帳に「…-R3」が在る木で、実在せぬ「…-R3-M9」を「確認済」と申告した盤面。
        #   ★捨てた綴りは枝を 1 つしか読まぬゆえ「…-R3」と読み【幽霊でない】と黙る★
        #   ⇒ ★物差しが巻き戻れば本 test は rc0 へ落ちて赤くなる★ = 是正そのものの牙。
        base = "MUT-" + "8803-R3"
        branch = base + "-M9"
        repo = _mk_git_repo(T / "t71", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# 実射で確認済: {branch}\n"})
        reg = T / "t71reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry(base, ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(peer_reg)])
        expect("T71 枝つき幽霊を名指す (捨てた綴りなら黙る形)", 1, rc, branch, out)

        expect("T71b 影の計器が読みの差を数える", 1, rc, "[RULER-SHADOW]", out)

        # ── cmd_1387: 見本用の予約帯 MUT-9999-* (家老 17:31 の裁(乙)) ──
        # T75: 予約帯の id は幽霊に数えない。除いた件数は必ず表示する。
        #   数を黙って減らす形は禁じられている (cmd_1408 の掟)。
        fixture_id = "MUT-" + "9999-SAMPLE"
        repo = _mk_git_repo(T / "t75", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# selftest の見本: {fixture_id}\n"})
        reg = T / "t75reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-ROGUE", ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(peer_reg)])
        ghost_lines = "\n".join(l for l in out.splitlines() if "GHOST-ID" in l)
        check("T75 予約帯の id を幽霊に数えない", fixture_id not in ghost_lines,
              f"予約帯の id が幽霊として名指された: {ghost_lines[:300]}")
        check("T75b 除いた件数を名乗る", "見本用 MUT-9999-* を 1 件 除いた" in out,
              f"除外の件数が出ておらぬ: {out[:400]}")

        # T76: 逆向きの守り = 予約帯の id を台帳へ登録したら schema が拒む。
        #   これが無いと「偽の変異テストを 1 本増やす」代わりに
        #   「本物が黙って幽霊検分から落ちる」穴が開く (向きが逆の同じ病)。
        why = validate_entry({"id": "MUT-" + "9999-REAL", "desc": "x", "paths": ["a"],
                              "mutate": "x", "test": "x"})
        check("T76 予約帯を本物として登録できない", bool(why) and "予約帯" in (why or ""),
              f"予約帯の id が schema を通ってしまう: {why!r}")
        why_ok = validate_entry({"id": "MUT-" + "1387-OK", "desc": "x", "paths": ["a"],
                                 "mutate": "x", "test": "x"})
        check("T76b 予約帯でない id は従来どおり通る", why_ok is None, f"→ {why_ok!r}")

        # ── cmd_1387: 引用の印 ref: (家老 18:10 の裁2) ────────────────────────────
        #   註が他の木の実例を挙げておるだけの物を「此の木の申告」と数えぬ。
        #   ★三つで 1 組にする★ = ①引用は幽霊に数えぬ ②件数を必ず名乗る
        #   ③★ref: の無い同じ id は従来どおり鳴る★ (③が無ければ「全部を引用にすれば黙る」
        #   逃げ道を作った事になり、向きが逆の同じ病になる)。
        quoted_id = "MUT-" + "8805-001"
        peer_reg_q = T / "t77peer.yaml"
        _write_reg(peer_reg_q, [_cov_entry(quoted_id, ["other_tree/test.bats"])])
        repo = _mk_git_repo(T / "t77", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# 実例 = 別の木の ref:{quoted_id}\n"})
        reg = T / "t77reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-ROGUE", ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(peer_reg_q)])
        expect("T77 ref: 付きは引用ゆえ幽霊に数えぬ", 0, rc, "幽霊なし", out)
        check("T77b 引用の件数を必ず名乗る (黙って捨てぬ)",
              "[引用] ref: 付きの言及を 1 件 別に数えた" in out,
              f"引用の件数が出ておらぬ: {out[:400]}")
        # T77c ★負例★: 同じ id を ref: 無しで書けば従来どおり幽霊 (A) として鳴る
        repo = _mk_git_repo(T / "t77c", {ctl: _COV_CONTROL_BODY,
                                         "tests/rogue_mutation.bats":
                                             _COV_ROGUE_BATS + f"# 実射で確認済: {quoted_id}\n"})
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(peer_reg_q)])
        expect("T77c ★負例★ ref: 無しは従来どおり幽霊として鳴る", 1, rc, "[GHOST-ID/A]", out)
        check("T77d 引用 0 件でも件数を名乗る",
              "[引用] ref: 付きの言及を 0 件 別に数えた" in out,
              f"引用 0 件の名乗りが無い: {out[:400]}")

        # T72: ★綴りの途中を拾わぬ★ = 捨てた綴りの二つ目の破れ (先読みが無い) の負例。
        #   ★捨てた綴りなら鳴り、今の物差しなら鳴らぬ★ = 誤検知の側からも物差しを縛る。
        stray = "MUT-" + "8804-001"
        repo = _mk_git_repo(T / "t72", {ctl: _COV_CONTROL_BODY,
                                        "tests/rogue_mutation.bats":
                                            _COV_ROGUE_BATS + f"# 綴りの途中: X{stray} は id にあらず\n"})
        reg = T / "t72reg.yaml"
        _write_reg(reg, [_cov_entry("MUT-COV-CTL", [ctl]),
                         _cov_entry("MUT-COV-ROGUE", ["tests/rogue_mutation.bats"])])
        rc, out = _invoke(["--coverage", "--registry", str(reg), "--repo-root", str(repo),
                           "--peer-registry", str(peer_reg)])
        expect("T72 綴りの途中は id と読まぬ=幽霊なし", 0, rc, "幽霊なし", out)

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
        #   実例 = backend ref:MUT-1350-M2 (五号)。初版は「候補が残っておる」と誤って鳴らした。
        rc, out = _anchor_run("append", ONE, "printf '\\nMUT_MARK\\n' >> tool.sh\n",
                              guard=NEG_GUARD)
        expect("T51 ★追記型は鳴らぬ (負例)★", 0, rc, "PASS", out)

        # T52 (負例): ★挿入型★ (sed 's/x/&\\n…/') — 同上 (difflib では i1==i2)。
        #   実例 = backend ref:MUT-1350-M4 (五号)。
        rc, out = _anchor_run("insert", ONE, "sed -i 's/^x=1$/&\\nMUT_MARK/' tool.sh\n",
                              guard=NEG_GUARD)
        expect("T52 ★挿入型は鳴らぬ (負例)★", 0, rc, "PASS", out)

        # T53 (負例): ★行の移動は 1 箇所と数える★ — 消える塊と現れる塊に割れるが 1 つの編集。
        #   実例 = backend ref:MUT-1350-M1 (五号) = 2 つの sed で行を移す変異。
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
        #   (実例 = backend ref:MUT-1384-M10/M11)。
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

        # ─────────────────────────────────────────────────────────────────
        # T67: ★門が【己が要求する鍵の綴り】を名乗る★ (cmd_1407・六号 05:5x の実測より)
        #   機序 = 段2 の逆引きは BATS_TEST_ID_RE (頭・大文字数字・ハイフン必須) に依る。
        #   ゆえに「T0」形の名では ID が1つも取れず、書き手は台帳へ登録した積もりで
        #   ★誰も証しておらぬ側★ に残り続ける。★而して其の規則はどこにも書かれておらぬ★。
        #   ⇒ 門に名乗らせる。★落とさぬ★ = rc を一切 動かさぬ (T67c が其れを縛る)。
        # ─────────────────────────────────────────────────────────────────
        NEG_NOID = ('@test "T0 does not emit the banner" {\n'
                    '  if grep -q banner out.txt; then return 1; fi\n}\n')
        r67 = _mk_git_repo(T / "neg67", {"tests/a.bats": NEG_NOID})
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r67)])
        expect("T67a ★ID が読めぬ試験名を数えて名指す★", 2, rc,
               "ID として読めなかった試験名 = 1 本", out)
        expect("T67a2 ★規則そのものを出力に出す★ (docs に頼らぬ)", 2, rc,
               "ハイフンを1つ以上含む", out)

        # T67b (負の対照): ID が取れる名ばかりなら ★一言も申さぬ★ = 常に鳴る門にせぬ
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_bare),
                           "--repo-root", str(r57)])
        check("T67b ★ID が取れる名では黙る★",
              "ID として読めなかった試験名" not in out,
              "ID が取れる名ばかりの木で名指しが出た = 常に鳴る門になっておる")

        # T67c: ★逃げ道が現に効く★ = 台帳へ ★名の全文★ を書けば証は立つ。
        #   六号の「台帳に何を書いても永久に落ちる」を一点 訂正する試験である。
        #   ★併せて rc=0 を縛る★= 名指しを足しても ★判定は動いておらぬ★ の証。
        neg_reg_byname = T / "negreg3.yaml"
        _write_reg(neg_reg_byname, [dict(_entry("MUT-NEG-3", "true"),
                                         red_needle="not ok 1 T0 does not emit the banner")])
        rc, out = _invoke(["--negative-assertions", "--registry", str(neg_reg_byname),
                           "--repo-root", str(r67)])
        expect("T67c ★名の全文で台帳が証せば緑★ (rc は名指しに動かされぬ)", 0, rc,
               "台帳が刃を証しておるのは 1 本", out)
        check("T67c2 ★緑でも名指しは消えぬ★ (ID で名指せぬ事実は残る)",
              "名の全文★ で台帳が証しておるのは 1 本" in out,
              "緑の時に名指しが落ちておる = 書き手は綴りの穴に気付けぬ")

        # ─────────────────────────────────────────────────────────────────
        # T65: ★写しは【同じ瞬間】の物でなければならぬ★ (cmd_1387・2026-07-27)
        #   機序 = pristine / base / mut を別々に写すと、写しと写しの【間】に
        #   他人が同じ木へ書いた 1 行が ★変異の産物と見分けが付かぬ★ =
        #   物差しB (行の塊) が之を +1 と数え、1 箇所しか撃たぬ牙を
        #   「2 箇所で発火 = 過小申告」と誤って名指す。
        #   ★静かな盤面では再現せぬ★ゆえ、鳴らされた持ち主が撃ち直しても PASS しか見えぬ
        #   (足軽五号が現に 3 回 撃ち直して 3 回とも PASS を見た = 18:48 の便)。
        #   ⇒ 処方 = ★1 度だけ写し、其の写しを複製する★ = 配る木は悉く同じ瞬間の物になる。
        #
        #   ★此処を両側から縛る (家老 18:44 の条件)★:
        #     (a) 他人の 1 行を着弾と数えぬ  (b) ★現に 2 箇所を撃つ変異は猶 2 と数える★
        #   片側だけでは「絞りすぎて見落とす」へ倒れたのが判らぬ。
        r65 = T / "snap65" / "repo"
        (r65 / "src").mkdir(parents=True)
        (r65 / "src" / "a.py").write_text("x = 'anchor here'\ny = 2\n", encoding="utf-8")
        (r65 / "src" / "b.py").write_text("# bystander\n", encoding="utf-8")

        # ★写しの【最中】に他人が書く盤面を作る★ = copy_paths を包んで、
        #   1 回 写るたびに repo へ 1 行 足す。別々に写す形なら之を掴んでしまう。
        _orig_copy = globals()["copy_paths"]
        _calls: list[Path] = []

        def _spy_copy(repo_, paths_, dst_):
            err_ = _orig_copy(repo_, paths_, dst_)
            _calls.append(dst_)
            (r65 / "src" / "b.py").write_text(
                "# bystander\n" + "# 他人の 1 行\n" * len(_calls), encoding="utf-8")
            return err_

        globals()["copy_paths"] = _spy_copy
        try:
            d65 = T / "snap65" / "out"
            p65, b65, m65 = d65 / "pristine", d65 / "base", d65 / "mut"
            err65 = copy_paths_snapshot(r65, ["src"], [p65, b65, m65])
        finally:
            globals()["copy_paths"] = _orig_copy

        check("T65a 写しは 1 度だけ (三つ配っても repo は 1 度しか読まぬ)",
              err65 is None and len(_calls) == 1,
              f"err={err65} 写した回数={len(_calls)} (期待 1)")
        dig_p, dig_b, dig_m = tree_digest(p65), tree_digest(b65), tree_digest(m65)
        check("T65b 三つの木は互いに一致する (同じ瞬間の物)",
              dig_p == dig_b == dig_m,
              f"pristine={len(dig_p)} base={len(dig_b)} mut={len(dig_m)} 件で食い違う")

        # (a) 変異は a.py の 1 箇所だけを書く ⇒ 他人が b.py へ書いた行を数えてはならぬ
        _f65 = m65 / "src" / "a.py"
        _f65.write_text(_f65.read_text(encoding="utf-8")
                        .replace("anchor here", "ANCHOR HERE"), encoding="utf-8")
        _a65, _ = anchor_firings(p65, m65)
        _b65 = changed_line_hunks(p65, m65)
        check("T65c ★他人の 1 行を着弾と数えぬ (1 箇所の変異は 1)★",
              max(_a65, _b65) == 1, f"物差しA={_a65} 物差しB={_b65} (期待 採用=1)")

        # (b) ★逆向き★ = 現に 2 箇所を撃つ変異は猶 2 と数える (絞りすぎて見落とさぬ)
        r65b = T / "snap65b" / "repo"
        (r65b / "src").mkdir(parents=True)
        (r65b / "src" / "a.py").write_text(
            "x = 'anchor here'\ny = 'anchor here'\n", encoding="utf-8")
        d65b = T / "snap65b" / "out"
        p65b, m65b = d65b / "pristine", d65b / "mut"
        check("T65d 写しの下拵え", copy_paths_snapshot(r65b, ["src"], [p65b, m65b]) is None)
        _f65b = m65b / "src" / "a.py"
        _f65b.write_text(_f65b.read_text(encoding="utf-8")
                         .replace("anchor here", "ANCHOR HERE"), encoding="utf-8")
        _a65b, _ = anchor_firings(p65b, m65b)
        _b65b = changed_line_hunks(p65b, m65b)
        check("T65e ★現に 2 箇所を撃つ変異は猶 2 と数える (見落としへ倒れておらぬ)★",
              max(_a65b, _b65b) == 2, f"物差しA={_a65b} 物差しB={_b65b} (期待 採用=2)")

        # ─────────────────────────────────────────────────────────────────
        # T66: ★物差しB で鳴った時、塊が【どの file から来たか】を名乗る★ (cmd_1387)
        #   機序 = 綴りの内訳 (anchor_firings の detail) は ★同一の (old→new) が 2 回以上
        #   出た時にしか埋まらぬ★ ゆえ、物差しA=1・物差しB=2 の盤面では ★常に空★ であった。
        #   ⇒ ★鳴っても持ち主が動けぬ★ = 2026-07-27 18:40 に現に起きた
        #     (六号が五号へ内訳を渡せず、五号は静かな盤面で 3 回 撃ち直すしか無かった)。
        #   ★両側から縛る★:
        #     (a) 物差しB が鳴らした時 = ★file 名が出る★
        #     (b) 綴りが鳴らした時 = ★従来の内訳 (old→new×n) が消えておらぬ★
        #   片側だけでは「片方を足して片方を落とした」が判らぬ。

        # (a) 離れた 2 file を 1 箇所ずつ書き換える = 綴りは 1・行の塊は 2
        r66 = _mk_playground(T / "hunk66")
        (r66 / "alpha.txt").write_text("aaa\nbbb\n", encoding="utf-8")
        (r66 / "beta.txt").write_text("ccc\nddd\n", encoding="utf-8")
        reg66 = T / "hunk66reg.yaml"
        _write_reg(reg66, [dict(_entry(
            "MUT-T66",
            "sed -i 's/bbb/BBB/' alpha.txt && sed -i 's/ddd/DDD/' beta.txt",
            test="bash check.sh"), paths=["tool.sh", "check.sh", "alpha.txt", "beta.txt"])])
        rc, out = _invoke(["--registry", str(reg66), "--repo-root", str(r66)])
        expect("T66a ★塊の出所に file 名が出る (alpha)★", 2, rc, "alpha.txt", out)
        check("T66b ★もう一方の file も出る (beta)★", "beta.txt" in out,
              f"出力に beta.txt が無い: {out[-400:]}")
        check("T66c ★塊の出所という語で名乗る★", "塊の出所" in out,
              f"出力に「塊の出所」が無い: {out[-400:]}")

        # (b) ★退行の検め★= 同一の綴りが 2 箇所で発火する盤面では従来の内訳が今も出る
        r66b = _mk_playground(T / "hunk66b")
        (r66b / "dup.txt").write_text("zzz\nqqq\nzzz\n", encoding="utf-8")
        reg66b = T / "hunk66breg.yaml"
        _write_reg(reg66b, [dict(_entry(
            "MUT-T66B", "sed -i 's/zzz/ZZZ/g' dup.txt", test="bash check.sh"),
            paths=["tool.sh", "check.sh", "dup.txt"])])
        rc, out = _invoke(["--registry", str(reg66b), "--repo-root", str(r66b)])
        expect("T66d ★綴りの内訳は消えておらぬ (退行なし)★", 2, rc, "内訳:", out)
        check("T66e ★綴りの内訳が old→new×n の形で出る★", "×2" in out,
              f"出力に「×2」が無い: {out[-400:]}")

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
                                   "誰も証しておらぬ", "対象なし",
                                   # 付帯3 幽霊の出所割り + 物差し是正 (cmd_1408・2026-07-27)
                                   "別台帳に実在", "真に未登録", "判別不能", "捨てた綴り",
                                   # 物差しB で鳴った時の手掛かり (cmd_1387・2026-07-27)
                                   "塊の出所",
                                   # 束で走らせる test の見張り (cmd_1408・2026-07-27)
                                   "を束で走らせる")
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
    ap.add_argument("--peer-registry", type=Path, action="append", default=None,
                    help="cmd_1408: 幽霊 ID の出所照合先 (別台帳) を明示する。★与えねば"
                         " peer_registry_paths の既定 5 冊を解く★ (揃える相手だった"
                         " gate_nightly.sh は cmd_1479 で撤去済)。読めぬ台帳が在れば幽霊は"
                         " 【真に未登録】でなく【判別不能】と名乗る (fail-closed)")
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
        return coverage(a.registry, a.repo_root, a.peer_registry)
    return run_all(a.registry, a.repo_root)


if __name__ == "__main__":
    sys.exit(main())
