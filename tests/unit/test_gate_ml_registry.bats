#!/usr/bin/env bats
# test_gate_ml_registry.bats — ★ml の台帳延長と、其の【免除】の射程を機械が縛る★ (cmd_1408)
#
# ★何ゆえ此の試験が在るか★:
#   木の点呼が 2026-07-27 06:30 に4本目の未監視木 (aituber-project-ml) を名指した。
#   台帳を shogun 側へ置き runner を --repo-root で跨がせて門の下へ入れた (web と同じ流儀)。
#   ★而して ml の登録検知 (coverage) は現に rc=2 で鳴る★ (六号 09:11 実測) =
#   ★runner の内側の二つの物差しが本 repo で互いに素★ゆえであり ml の側の欠けではない。
#   ⇒ ★理由と until を名指した免除★ を当てた。★免除は【緑にする】ではない★=
#     札は UNDETERMINED のまま残し、門だけ落とさぬ。
#
#   ★免除は【放っておけば広がる】★= 「ml coverage は当分 黙らせる」へ黙って育つ道が在る。
#   ゆえに ★免除の射程そのものへ牙を立てる★ = 別の理由・FAIL・期限切れでは免除が効かぬ事を機械が縛る。
#
# ★作法 (本夜〜本朝の規律を当てる)★:
#   (a)★梯子を書き写さぬ★= 判定の実体は gate_nightly.sh から ★現物を抜いて eval する★。
#   (b)★canary を先に撃つ★= 抜き出しが空・越境でないことを T-ML-000 が名指す。
#   (c)★負の主張は一度 偽にして赤を見よ★= 免除が効かぬ盤面を三通り 現に撃つ。
#   (d)★bare `!` を使わぬ★ (bats の `!` は set -e から免除ゆえ刃を持たぬ・cmd_1401)。
#
# ★★2026-07-27 10:0x (cmd_1409) = 免除は【返済した】★★
#   三号が runner の二つの物差しを揃え (【走らせる物】と【同伴】を別けて数える形へ)、
#   ★六号が己の手で撃って rc=0 を確かめた (10:04:23 実測)★ ⇒ 免除の block を gate から外した。
#   ⇒ ★免除の射程を縛っておった T-ML-001〜006 と其の牙 MUT-1408-ML1〜ML5 を同時に外した★
#     = ★守る対象が消えた検を残せば「anchor が無い」で毎朝鳴る = 免除より悪い札になる★。
#   ★免除は【期限で切れた】のでなく【要らなくなって消えた】★= 之が免除の正しい畢り方である。
#
# 契約 (今 在る三本):
#   T-ML-000: ★canary★= 配線 block と ml 台帳が現物から抜ける (抜けねば以下は無意味)
#             + ★免除の綴りが黙って戻っておらぬ事★ (ML_COV_WAIVER_SIG が在れば赤)
#   T-ML-007: ★ml 台帳の実体★= parse でき・牙 1 件・paths に p7 と p5 の両方・再検分日を持つ
#   T-ML-008: ★配線が消えれば赤★= gate_nightly が ml 台帳を呼び、撃った木を watched へ記す
#
# 牙 (台帳に登録済・単独書き手=六号):
#   MUT-1408-ML6: watched "$ML_ROOT" を消す               → T-ML-008 赤 (撃っておるのに点呼から消える)
#   MUT-1408-ML7: ml 台帳の paths から p5 を落とす        → T-ML-007 赤 (import 赤と変異赤を見分けられぬ)
#   MUT-1408-ML8: 抜き出しの始端 ML_ROOT= を改名          → T-ML-000 赤 (canary が死ねば以下が無意味)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_nightly.sh"
    export ML_REG_FILE="$PROJECT_ROOT/config/mutation_registry.ml.yaml"
    [ -f "$GATE" ] || return 1
}

# ★現物から抜く★ — 書き写さぬ。抜けねば空が返り T-ML-000 が赤で名指す。
fn_verdict()   { grep -m1 '^verdict() {' "$GATE"; }


@test "T-ML-000: canary — 配線 block と ml 台帳が現物から抜ける (抜けねば以下は無意味)" {
    # ★免除 (cmd_1408) は cmd_1409 で返済済★= 免除の射程を縛っておった T-ML-001〜006 は
    #   ★守る対象が消えたゆえ外した★ (残せば「anchor が無い」で毎朝鳴る = 免除より悪い札)。
    #   ★残すのは【配線そのもの】を縛る二本★ = 免除の有無に依らず要る。
    run bash -c "sed -n '/^ML_ROOT=/,/^fi\$/p' '$GATE'"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    printf '%s' "$output" | grep -qF 'mutation_registry.ml.yaml'
    # ★越境の証★= block の外の綴りが混ざっておらぬか
    if printf '%s' "$output" | grep -qF 'hook_rc'; then return 1; fi
    [ -f "$ML_REG_FILE" ]
    # ★免除が現に消えておる事も縛る★= 綴りが戻れば赤 (黙って復活する道を塞ぐ)
    if grep -qF 'ML_COV_WAIVER_SIG' "$GATE"; then return 1; fi
}

@test "T-ML-007: ml 台帳の実体 — 牙 1 件・paths に p7 と p5・再検分日を持つ" {
    run python3 -c "
import sys, yaml
d = yaml.safe_load(open('$ML_REG_FILE', encoding='utf-8'))
m = d['mutations']
assert len(m) == 1, len(m)
e = m[0]
p = e['paths']
assert any('p7_rvc_both_lungs' in x for x in p), p
# ★p5 は p7 が import する★ = 之が無ければ replay は import エラーで赤くなり
#   「壊せば落ちる」を測れぬ (本朝 未判定 10 件が嵌った当の穴)
assert any('p5_body_stats' in x for x in p), p
assert e['expect'] == 'nonzero', e['expect']
assert e['red_needle'], 'red_needle 無し = 別の理由の赤を変異の赤と読む'
assert str(e['review_by']) == '2026-08-10', e['review_by']
assert d['coverage_positive_control'], '陽性対照の差し替えが無い (runner は ml に居らぬ)'
print('ok')
"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'ok'
}

@test "T-ML-008: 配線が消えれば赤 — gate が ml 台帳を呼び、撃った木を watched へ記す" {
    grep -qF 'config/mutation_registry.ml.yaml' "$GATE"
    # ★宣言でなく実績★= watched は成功の枝の中でのみ書かれる (点呼の分母はここから来る)
    grep -qF 'watched "$ML_ROOT"' "$GATE"
    grep -qF 'attempted "$ML_ROOT"' "$GATE"
    # ★見えぬ朝を緑にせぬ★= else 枝が UNDETERMINED を返す
    # ★終端の錨は【現に在る綴り】でなければならぬ★ (cmd_1409 で実測して直した)=
    #   免除を外した折、終端を ML_COV_WAIVER_UNTIL= のままにしておったゆえ ★範囲が file 末尾まで
    #   伸び (263 行)、其れでも 2 を返して緑であった★ = ★偶々 緑★ = 本朝ずっと狩ってきた形。
    #   ⇒ 終端を ml_cov_gate= へ移した (ML block の直後・現に在る綴り) = 範囲は 21 行。
    run bash -c "sed -n '/^ML_ROOT=/,/^ml_cov_gate=/p' '$GATE' | grep -c 'rc1[12]=2'"
    [ "$output" = "2" ]
}
