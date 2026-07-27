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
# 契約:
#   T-ML-000: ★canary★= 免除 block / mlcov() / 台帳 file が現物から抜ける (抜けねば以下は無意味)
#   T-ML-001: ★此の理由 (対照以外 0 件) の UNDETERMINED のみ免除★ → 門は落とさぬ・札は UNDETERMINED のまま
#   T-ML-002: ★別の理由の UNDETERMINED は免除せぬ★ (台帳が見えぬ 等) → 門を落とす
#   T-ML-003: ★FAIL (rc=1) は免除せぬ★ = 免除の綴りを含んでおっても落とす
#   T-ML-004: ★期限切れは自動で失効★ = until を過ぎた朝から門を落とし、其の旨を名乗る
#   T-ML-005: ★免除を PASS と刷らぬ★ = mlcov() は UNDETERMINED の札に「免除」を添えて返す
#   T-ML-006: ★門の三箇所が現に ml_cov_gate を見ておる★ (rc12 直読みへ巻き戻れば赤)
#   T-ML-007: ★ml 台帳の実体★= parse でき・牙 1 件・paths に p7 と p5 の両方・再検分日を持つ
#   T-ML-008: ★配線が消えれば赤★= gate_nightly が ml 台帳を呼び、撃った木を watched へ記す
#
# 変異登録案 (台帳の単独書き手=六号・登録は家老の号令後):
#   MUT-1408-ML1: 免除の条件から rc12 -eq 2 を外す        → T-ML-003 赤 (FAIL まで免除する)
#   MUT-1408-ML2: 免除の signature 照合を消す             → T-ML-002 赤 (別の理由まで免除する)
#   MUT-1408-ML3: until の比較を外し常に免除              → T-ML-004 赤 (黙って延びる)
#   MUT-1408-ML4: mlcov() を verdict へ倒す               → T-ML-005 赤 (免除が緑に化ける)
#   MUT-1408-ML5: 門の条件を rc12 直読みへ戻す            → T-ML-006 赤 (免除が効かず毎朝鳴る)
#   MUT-1408-ML6: watched "$ML_ROOT" を消す               → T-ML-008 赤 (撃っておるのに点呼から消える)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_nightly.sh"
    export ML_REG_FILE="$PROJECT_ROOT/config/mutation_registry.ml.yaml"
    [ -f "$GATE" ] || return 1
}

# ★現物から抜く★ — 書き写さぬ。抜けねば空が返り T-ML-000 が赤で名指す。
waiver_block() { sed -n '/^ML_COV_WAIVER_UNTIL=/,/^fi$/p' "$GATE"; }
fn_mlcov()     { sed -n '/^mlcov() {/,/^}/p' "$GATE"; }
fn_verdict()   { grep -m1 '^verdict() {' "$GATE"; }

# 免除が効く盤面の out12 (★現物の signature を現物から採る★ = 綴りを書き写さぬ)
sig() { grep -m1 '^ML_COV_WAIVER_SIG=' "$GATE" | sed "s/^ML_COV_WAIVER_SIG='//; s/'$//"; }

# $1=rc12 $2=out12 $3=until(任意) → "gate:waived" を刷る
run_waiver() {
    local until_arg=""
    [ -n "${3:-}" ] && until_arg="export GATE_ML_COV_WAIVER_UNTIL='$3';"
    bash -c "set -u; $until_arg rc12=$1; out12='$2'; \
             eval \"\$(sed -n '/^ML_COV_WAIVER_UNTIL=/,/^fi\$/p' '$GATE')\"; \
             printf '%s:%s\n' \"\$ml_cov_gate\" \"\$ml_cov_waived\"; printf '%s\n' \"\$out12\""
}

@test "T-ML-000: canary — 免除block/mlcov/台帳 が現物から抜ける (抜けねば以下は無意味)" {
    run waiver_block
    [ "$status" -eq 0 ]
    if [ "$(printf '%s\n' "$output" | wc -l)" -lt 8 ]; then return 1; fi
    if [ "$(printf '%s\n' "$output" | wc -l)" -gt 30 ]; then return 1; fi
    printf '%s' "$output" | grep -qF 'ml_cov_gate'
    printf '%s' "$output" | grep -qF 'ML_COV_WAIVER_SIG'
    # ★越境の証★= 免除 block の外に在る綴りが混ざっておらぬか
    if printf '%s' "$output" | grep -qF 'hook_rc'; then return 1; fi

    run fn_mlcov
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'ml_cov_waived'

    run sig
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    [ -f "$ML_REG_FILE" ]
}

@test "T-ML-001: 此の理由の UNDETERMINED のみ免除 → 門は落とさぬが札は UNDETERMINED のまま" {
    run run_waiver 2 "[gate-2 ml coverage] UNDETERMINED: ★$(sig) 以外を 1 件も見えておらぬ★"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '0:1'      # gate=0 (門は落とさぬ) / waived=1
    printf '%s' "$output" | grep -qF '免除'
    printf '%s' "$output" | grep -qF 'until'
    # ★緑と刷っておらぬ★= 元の UNDETERMINED の名乗りが消えておらぬこと
    printf '%s' "$output" | grep -qF 'UNDETERMINED'
}

@test "T-ML-002: 別の理由の UNDETERMINED は免除せぬ (★免除は【当分黙らせる】ではない★)" {
    run run_waiver 2 "[gate-2 ml coverage] UNDETERMINED: ml 台帳が見えぬ = path 違いの疑い"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '2:0'      # gate=2 (門を落とす) / waived=0
    if printf '%s' "$output" | grep -qF '免除 (cmd_1408)'; then return 1; fi
}

@test "T-ML-003: FAIL は免除せぬ (免除の綴りを含んでおっても落とす)" {
    run run_waiver 1 "[gate-2 ml coverage] FAIL: 台帳に無い変異test 1 件 ($(sig) の綴りも此処に在る)"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '1:0'      # gate=1 (FAIL のまま門を落とす) / waived=0
}

@test "T-ML-004: 期限切れは自動で失効し、其の旨を名乗る (★黙って延びる道は無い★)" {
    run run_waiver 2 "[gate-2 ml coverage] UNDETERMINED: ★$(sig) 以外を 1 件も見えておらぬ★" "2026-07-01"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '2:0'      # gate=2 = 門を落とす
    printf '%s' "$output" | grep -qF '期限が切れた'
}

@test "T-ML-005: 免除を PASS と刷らぬ (mlcov は UNDETERMINED の札に免除を添える)" {
    run bash -c "set -u; rc12=2; ml_cov_waived=1; ML_COV_WAIVER_UNTIL=2026-08-10; \
                 eval \"\$(grep -m1 '^verdict() {' '$GATE')\"; \
                 eval \"\$(sed -n '/^mlcov() {/,/^}/p' '$GATE')\"; mlcov"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'UNDETERMINED'
    printf '%s' "$output" | grep -qF '免除'
    if printf '%s' "$output" | grep -qF 'PASS'; then return 1; fi

    # ★免除しておらぬ時は素の札★ (免除の文言が常時 付くのでないこと = 常に鳴る/常に註がつく門を作らぬ)
    run bash -c "set -u; rc12=2; ml_cov_waived=0; ML_COV_WAIVER_UNTIL=2026-08-10; \
                 eval \"\$(grep -m1 '^verdict() {' '$GATE')\"; \
                 eval \"\$(sed -n '/^mlcov() {/,/^}/p' '$GATE')\"; mlcov"
    [ "$output" = "UNDETERMINED" ]
}

@test "T-ML-006: 門の三箇所が現に ml_cov_gate を見ておる (rc12 直読みへ巻き戻れば赤)" {
    # ★警告の枝★ / ★exit 1★ / ★exit 2★ の三箇所
    [ "$(grep -c 'ml_cov_gate" -ne 0' "$GATE")" -eq 2 ]
    [ "$(grep -c 'ml_cov_gate" -eq 1' "$GATE")" -eq 1 ]
    # ★門の条件行が rc12 を直に読んでおらぬ★ (読んでおれば免除が効かず毎朝鳴る)
    if grep -E '^(if|.*\|\|) .*rc12" -(ne|eq) ' "$GATE" | grep -qF 'hook_rc'; then return 1; fi
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
    run bash -c "sed -n '/^ML_ROOT=/,/^ML_COV_WAIVER_UNTIL=/p' '$GATE' | grep -c 'rc1[12]=2'"
    [ "$output" = "2" ]
}
