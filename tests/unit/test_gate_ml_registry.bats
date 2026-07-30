#!/usr/bin/env bats
# test_gate_ml_registry.bats — ml の台帳 (config/mutation_registry.ml.yaml) の中身を機械が縛る (cmd_1408)
#
# なぜこの試験が在るか:
#   ml (F: の Windows 正本) へは 1 file も置かない方針ゆえ、ml 向けの変異テスト台帳は
#   shogun 側に置いてある。台帳の中身が黙って崩れると、変異の赤と import の赤が
#   見分けられなくなる (2026-07-27 に未判定 10 件がこの穴に嵌った)。
#
# 2026-07-30 (cmd_1479 段② レーンA 第2束) に 2 本 外した:
#   T-ML-000 (canary) と T-ML-008 (配線が消えれば赤) は、どちらも
#   scripts/gate_nightly.sh から現物を抜いて検めていた。その gate を撤去したので、
#   守る対象が消えた。牙 MUT-1408-ML6 / ML8 も同じ commit で外してある。
#   残した T-ML-007 は台帳そのものを見ており、gate_nightly に依らない。
#
# 契約 (今 在る一本):
#   T-ML-007: ml 台帳の実体 = parse でき・牙 1 件・paths に p7 と p5 の両方・再検分日を持つ
#
# 牙 (台帳に登録済):
#   MUT-1408-ML7: ml 台帳の paths から p5 を落とす → T-ML-007 赤 (import 赤と変異赤を見分けられぬ)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export ML_REG_FILE="$PROJECT_ROOT/config/mutation_registry.ml.yaml"
    [ -f "$ML_REG_FILE" ] || return 1
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
