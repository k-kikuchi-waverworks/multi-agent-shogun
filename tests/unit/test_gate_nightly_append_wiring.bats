#!/usr/bin/env bats
# test_gate_nightly_append_wiring.bats — ★gate-4 を【朝の門】へ配線した其の線を機械が縛る★ (cmd_1409)
#
# ★何ゆえ此の試験が在るか★:
#   呑まれ (台帳へ書いたのに mutations: へ入らず別 key の値として黙って呑まれる) を捕える最良の点は
#   commit の瞬間 (pre-commit の gate-4) である。★而して SHOGUN_GATE_SKIP=1 で通した commit は
#   誰も捕えぬ★ = 背戸が開いておる ⇒ 家老 09:55 の裁(2) で ★毎朝の門へも配線した★。
#
#   ★配線には二つの危うさが在り、其の両方を此処で縛る★:
#     (甲)★既定で門を落としてしまう★= 配線した其の朝から鳴れば「毎朝鳴って誰も消せぬ札」になる
#          (cmd_1388 の族) ⇒ ★既定は【名乗るのみ】= 門へ 1bit も入れぬ★事を負例で縛る。
#     (乙)★報告のみゆえ誰も読まぬ★= 門を落とさぬなら log に沈む ⇒ ★呑まれの朝は家老への
#          警報本文へ載る★事を縛る (rc は動かさぬが、人には届く)。
#
# ★作法★:
#   (a)★梯子を書き写さぬ★= 配線の実体は gate_nightly.sh から ★現物を抜いて eval する★。
#   (b)★canary を先に撃つ★= 抜き出しが空・越境でないことを T-NA-000 が名指す。
#   (c)★道具は stub に差し替える★= 縛るのは【配線】であって道具の中身ではない
#      (道具そのものは gate-4 自身の牙 6 本と test_gate_registry_append*.bats が縛る)。
#   (d)★bare `!` を使わぬ★ (bats の `!` は set -e から免除ゆえ刃を持たぬ・cmd_1401)。
#
# 契約:
#   T-NA-000: ★canary★= run_reporter と gate-4 block が現物から抜ける (抜けねば以下は無意味)
#   T-NA-001: ★既定は門へ 1bit も入れぬ★= 呑まれ (rc=1) でも append_gate=0・而して名乗る
#   T-NA-002: ★昇格の口が現に効く★= GATE_APPEND_STRICT=1 なら append_gate=1 (門へ入る)
#   T-NA-003: ★測れなんだ (rc=2) は警報へ載せぬ★= 環境の揺れで毎朝鳴る札を作らぬ
#   T-NA-004: ★呑まれ 0 の朝も母数を刷る★= 0/0 と 0/6 を分ける (五号 09:54 の急報の門における顔)
#   T-NA-005: ★道具の側へ STRICT が現に届く★= 届かねば呑まれが rc=2 に化け、警報から落ちる
#   T-NA-006: ★門の判定が append_gate を見ておる★= 生の rc を見れば報告のみが門を落とす
#   T-NA-007: ★警報の条件は生の rc=1 を見ておる★= gate だけ見れば呑まれの朝が黙って沈む
#   T-NA-008: ★実物の道具で母数が現に出る★ (stub でなく本物・本 repo の 6 冊)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_nightly.sh"
    [ -f "$GATE" ] || return 1
}

# ★現物から抜く★ — 書き写さぬ。抜けねば空が返り T-NA-000 が赤で名指す。
extract_reporter() { sed -n '/^run_reporter() {/,/^}$/p' "$GATE"; }
extract_block()    { sed -n '/^APPEND_STRICT=/,/^fi$/p' "$GATE"; }
extract_exits()    { sed -n '/^if \[ "$rc1" -eq 1 \]/,/^exit 0$/p' "$GATE"; }

# 呑まれ検知の道具を stub へ差し替えて配線だけを撃つ。$1 = stub が返す rc
run_block() {
    local rc="$1"; shift
    local dir="$BATS_TEST_TMPDIR/board_$rc"
    mkdir -p "$dir/scripts"
    cat > "$dir/scripts/gate_registry_append.py" <<STUB
import os, sys
open(os.path.join(os.path.dirname(__file__), "strict_seen.txt"), "w").write(
    os.environ.get("REGISTRY_APPEND_STRICT", "unset"))
print("[gate-4] ★母数★ 走査 台帳 6 冊 (読めた 6 冊) / 登録 117 件 / 呑まれ ${rc} 件")
sys.exit(${rc})
STUB
    {
        echo 'set -u'
        extract_reporter
        printf 'SCRIPT_DIR=%q\n' "$dir"
        extract_block
        echo 'echo "APPEND_RC=$append_rc APPEND_GATE=$append_gate"'
    } > "$dir/harness.sh"
    env "$@" bash "$dir/harness.sh"
}

# ★門の【終いの二行】を現物から抜いて現に走らせる★ — 数えるのでなく撃つ。
#   引数 = 上書きしたい変数 (例 append_rc=1 append_gate=0)。★他の札は悉く 0 (=PASS) に据える★
#   ゆえ、落ちれば其れは ★呑まれの札だけが落とした★ことになる。
run_exits() {
    local dir="$BATS_TEST_TMPDIR/exits_$$_${BATS_TEST_NUMBER:-0}"
    mkdir -p "$dir"
    extract_exits > "$dir/exits.sh"
    [ -s "$dir/exits.sh" ] || return 1
    {
        # 抜いた二行が名指す札を悉く 0 (PASS) で埋める = 分母を先に据える
        grep -o '\$[a-z][a-z0-9_]*' "$dir/exits.sh" | sort -u | sed 's/^\$/export /; s/$/=0/'
        for kv in "$@"; do echo "export $kv"; done
        cat "$dir/exits.sh"
    } > "$dir/harness.sh"
    bash "$dir/harness.sh"
}

@test "T-NA-000: canary — run_reporter と gate-4 block が現物から抜ける (抜けねば以下は無意味)" {
    run extract_reporter
    [ -n "$output" ]
    printf '%s' "$output" | grep -qF '★UNDETERMINED★ 道具が居らぬ'
    run extract_block
    [ -n "$output" ]
    printf '%s' "$output" | grep -qF 'gate_registry_append.py'
    printf '%s' "$output" | grep -qF 'GATE_APPEND_STRICT'
    # ★越境の証★= block の外の綴りが混ざっておらぬか (verdict() は block の直後に在る)
    if printf '%s' "$output" | grep -qF 'verdict()'; then return 1; fi
    # ★終いの二行も抜けねば T-NA-006 が無意味になる★= 抜き出しの生存を此処で名乗る
    run extract_exits
    [ -n "$output" ]
    printf '%s' "$output" | grep -qF 'exit 1; fi'
    printf '%s' "$output" | grep -qF 'exit 2; fi'
}

@test "T-NA-001: 既定は門へ 1bit も入れぬ — 呑まれ (rc=1) でも gate=0・而して名乗る" {
    run run_block 1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'APPEND_RC=1 APPEND_GATE=0'
    # ★報告のみでも【黙らぬ】★= 門を落とさぬ事を其の場で名乗る
    printf '%s' "$output" | grep -qF '門の rc へは入れておらぬ'
}

@test "T-NA-002: 昇格の口が現に効く — GATE_APPEND_STRICT=1 なら門へ入る" {
    run run_block 1 GATE_APPEND_STRICT=1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'APPEND_RC=1 APPEND_GATE=1'
}

@test "T-NA-003: 測れなんだ (rc=2) は門にも警報にも入れぬ — 毎朝鳴る札を作らぬ" {
    run run_block 2
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'APPEND_RC=2 APPEND_GATE=0'
    printf '%s' "$output" | grep -qF '測れなんだ'
    # ★呑まれ (rc=1) の名乗りと取り違えておらぬ★
    if printf '%s' "$output" | grep -qF '★台帳に【呑まれ】在り'; then return 1; fi
}

@test "T-NA-004: 呑まれ 0 の朝も母数を刷る — 0/0 と 0/6 を分ける" {
    run run_block 0
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'APPEND_RC=0 APPEND_GATE=0'
    printf '%s' "$output" | grep -qF '★母数★'
    printf '%s' "$output" | grep -qF '走査 台帳 6 冊 (読めた 6 冊)'
}

@test "T-NA-005: 道具の側へ STRICT が現に届く (届かねば呑まれが rc=2 へ化ける)" {
    run run_block 1
    [ "$status" -eq 0 ]
    run cat "$BATS_TEST_TMPDIR/board_1/scripts/strict_seen.txt"
    [ "$output" = "1" ]
}

@test "T-NA-006: 門の判定は append_gate を見ておる (生の rc を見れば報告のみが門を落とす)" {
    # ★初版は grep で「append_rc が exit の行に居らぬ」を数えておった★= ★牙が当たらなんだ★
    #   (10:22 実測: exit 1 の条件を append_gate → append_rc へ差し替えても緑のまま) ⇒
    #   ★★数えるのを止め、終いの二行を現物から抜いて【現に走らせる】形へ改めた★★。
    # 呑まれ在り (append_rc=1) ・報告のみ (append_gate=0) の朝 = ★門は落ちてはならぬ★
    run run_exits append_rc=1 append_gate=0
    [ "$status" -eq 0 ]
    # 同じ朝で昇格しておれば (append_gate=1) = ★門は落ちねばならぬ★
    run run_exits append_rc=1 append_gate=1
    [ "$status" -eq 1 ]
    # 測れなんだ が門へ入る形 (append_gate=2) = ★UNDETERMINED ゆえ exit 2★
    run run_exits append_rc=2 append_gate=2
    [ "$status" -eq 2 ]
}

@test "T-NA-007: 警報の条件は生の rc=1 を見ておる (gate だけ見れば呑まれの朝が沈む)" {
    run bash -c "sed -n '/^if \\[ \"\$rc1\" -ne 0 \\]/p' '$GATE' | grep -c 'append_rc\" -eq 1'"
    [ "$output" = "1" ]
    # ★警報本文へ【何が呑まれたか】が載る★= rc だけでは名指しにならぬ
    grep -qF 'appendnote=' "$GATE"
    grep -qF '${appendnote}' "$GATE"
}

@test "T-NA-009: 母数が同じ冊を二度 数えぬ (綴り違いの同一 file を実体で一意にする)" {
    # ★環境の偶々に依らせぬ★= 冊の一覧を返す口へ ★綴り違いの同じ冊★ を直に食わせて縛る。
    #   (本 repo では註の --registry を拾うて現に二度 数えており 7 冊 265 件と刷っておった・10:31 実測)
    run python3 - <<PY
import importlib.util, sys, pathlib
root = pathlib.Path("$PROJECT_ROOT")
sys.path.insert(0, str(root / "scripts"))
import registry_census as C
spec = importlib.util.spec_from_file_location("gra", root / "scripts" / "gate_registry_append.py")
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
same = root / "config" / "mutation_registry.ml.yaml"
C.read_gate_pairs = lambda _p: ([("config/mutation_registry.ml.yaml", "."), (str(same), ".")], None)
books, err = M.known_books()
assert err is None, err
assert len(books) == 1, [str(b) for b in books]
print("ok 一意")
PY
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'ok 一意'
    # ★実物の走行でも重なりが無い事★ (上の縛りが現場で効いておるかの裏取り)
    run bash -c "cd '$PROJECT_ROOT' && python3 scripts/gate_registry_append.py --all | sed -n 's/^  ok \\(.*\\): 登録.*/\\1/p' | python3 -c \"
import sys, pathlib
ps = [pathlib.Path(l.strip()).resolve() for l in sys.stdin if l.strip()]
print('dup' if len(ps) != len(set(ps)) else 'uniq', len(ps))\""
    printf '%s' "$output" | grep -q '^uniq '
}

@test "T-NA-008: 実物の道具で母数が現に出る (stub でなく本物・本 repo)" {
    run bash -c "cd '$PROJECT_ROOT' && python3 scripts/gate_registry_append.py --all"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '[gate-4] ★母数★'
    printf '%s' "$output" | grep -qE '走査 台帳 [0-9]+ 冊 \(読めた [0-9]+ 冊\)'
}
