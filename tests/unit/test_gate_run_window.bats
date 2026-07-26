#!/usr/bin/env bats
# test_gate_run_window.bats — ★門に【己の走行の刻】と【盤面が動いた事】を名乗らせた其の配線を縛る★
#
# ★出所 (cmd_1408・2026-07-27 08:20 六号が己の走行で踏んだ)★:
#   六号は台帳 93 件の全数 replay を 07:50 に始め、08:31 に畢えた。
#   ★其の最中 (08:10:59) に三号の commit 4076bdf が着き、台帳 paths の中身が入れ替わった★。
#   ⇒ ★先に測った entry は旧盤面・後は新盤面を見ておった★のに、
#     ★門の出力からは【境】が一片も割れなんだ★ (entry ごとの刻が無く、盤面の名乗りは一行目に一度だけ)。
#
# ★★之は「一度 真であった名乗りが、いつまで真かを名乗っておらぬ」形である★★=
#   事例15 (45e1a28・六号が 01:39 に建てた口) は ★盤面の【別】★ は名乗るが
#   ★盤面が【動いた事】★ は名乗らぬ。★己の建てた口の射程の穴ゆえ、己で塞ぐ★ (家老 08:21 裁定)。
#
# ★★exit code は動かしておらぬ★★= ★盤面が動く度に門が赤くなれば【常に鳴る門】になり、必ず外される★
#   (cmd_1388 の族)。★退くのは【一行目の名乗り】だけで足る★ = 家老 08:39 が最も重く見た点。
#
# ★刻を【行末】へ置いた理由 (行頭でない)★= ★此の出力には読み手が二人 居る★:
#   (1) scripts/gate_verdict_drift.py VERDICT_RE = `^\s+(?:ok\s+|★NG★\s*|未定\s+)…`
#   (2) scripts/gate_nightly.sh:300 の `grep -vE '^\s*ok\s'` (PASS 行を除く口)
#   ⇒ ★行頭へ置けば二人とも黙って盲になる★= ★★形を変える時は【読む者】を先に数える★★。
#   T-WIN-004/005 が其の契約を縛る (= 将来 行頭へ移す者が居れば、其の場で赤くなる)。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_mutation_replay.py"
    export DRIFT="$PROJECT_ROOT/scripts/gate_verdict_drift.py"
    [ -f "$GATE" ] || return 1
    [ -f "$DRIFT" ] || return 1
}

setup() {
    TESTDIR="$(mktemp -d)"
    export TESTDIR
    mkdir -p "$TESTDIR/scripts" "$TESTDIR/config"
    cp "$GATE" "$TESTDIR/scripts/"
    # ★小盤面の的★= 変異が当たれば赤くなるだけの最小の口 (門の振舞いを測るのが目的ゆえ)
    printf 'VALUE = 1\nif __name__ == "__main__":\n    import sys\n    sys.exit(0 if VALUE == 1 else 1)\n' \
        > "$TESTDIR/scripts/target.py"
    cat > "$TESTDIR/config/mutation_registry.yaml" <<'YEOF'
mutations:
  - id: MUT-WINTEST-001
    desc: 門の振舞いを測る為の的 (本 repo の牙ではない)
    suspected_by: ashigaru6
    paths: [scripts/target.py]
    anchor_sites: 1
    mutate: |
      sed -i 's/^VALUE = 1$/VALUE = 2/' scripts/target.py
    test: |
      python3 scripts/target.py
    expect: nonzero
    timeout: 60
coverage_waivers: []
tree_census_waivers: []
YEOF
}

teardown() {
    [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

_run_gate() {
    cd "$TESTDIR"
    python3 scripts/gate_mutation_replay.py \
        --registry config/mutation_registry.yaml --repo-root . 2>&1
}

# ═══════════ T-WIN-00x: 刻と窓を門が己で名乗るか ═══════════

@test "T-WIN-001: ★entry ごとの刻が【行末】に出る★ (境を後から機械で割る鍵)" {
    run _run_gate
    [[ "$output" == *"MUT-WINTEST-001"* ]]
    # ★刻の綴りまで縛る★= 「何か出ておる」でなく「時刻の形で出ておる」
    echo "$output" | grep -qE 'MUT-WINTEST-001:.*\[刻 [0-9]{2}:[0-9]{2}:[0-9]{2}\]$'
}

@test "T-WIN-002: ★★盤面が走行中に動けば門が己で名乗る★★" {
    cd "$TESTDIR"
    # ★他者の commit が着いた体★= 門を呼ぶ前後で digest を採らせ、間で中身を入れ替える
    run python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("R", "scripts/gate_mutation_replay.py")
R = importlib.util.module_from_spec(spec); spec.loader.exec_module(R)
entries, err = R.load_registry(pathlib.Path("config/mutation_registry.yaml"))
assert not err, err
repo = pathlib.Path(".")
_d0, per0 = R.paths_digest(repo, entries)
t = pathlib.Path("scripts/target.py"); t.write_text(t.read_text() + "# 他者の commit が着いた\n")
_d1, per1 = R.paths_digest(repo, entries)
print(R.window_declaration(per0, per1, "07:50:00", "08:31:00"))
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"走行中に盤面が動いた"* ]]
    [[ "$output" == *"scripts/target.py"* ]]
    # ★★動いた事だけでなく【一行目の名乗りが何処まで真か】を退く所まで言うておるか★★
    [[ "$output" == *"【走行の始まり】についてのみ真"* ]]
    [[ "$output" == *"【窓】を見た"* ]]
}

@test "T-WIN-003: ★負例 = 盤面が動かねば【名乗らぬ】★ (常に鳴る門を作らぬ)" {
    # ★之が無ければ「名乗る門」は「毎朝 名乗る門」になり、読まれなくなって外される★
    #   (cmd_1388 の族・家老 08:39 が最も重く見た点)。
    run _run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"[窓]"* ]]
    [[ "$output" == *"動いておらぬ"* ]]
    # ★★偽にして赤★★= 動いておらぬ走行で「動いた」と言うたら落ちる
    [[ "$output" != *"走行中に盤面が動いた"* ]]
}

# ═══════════ T-WIN-00x: 出力の【形】の契約 (読む者が二人 居る) ═══════════

@test "T-WIN-004: ★契約★ 刻を足した entry 行を gate_verdict_drift が今も読める" {
    # ★刻を【行頭】へ移せば此処が落ちる★= VERDICT_RE は `^\s+` の次に mark を要求するゆえ。
    cd "$TESTDIR"
    cp "$DRIFT" scripts/
    run _run_gate
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > gate_out.txt
    run python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("D", "scripts/gate_verdict_drift.py")
D = importlib.util.module_from_spec(spec); spec.loader.exec_module(D)
got = D.parse_verdicts(pathlib.Path("gate_out.txt").read_text(encoding="utf-8"))
assert got.get("MUT-WINTEST-001") == "PASS", f"読めなんだ: {got}"
print("READABLE")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"READABLE"* ]]
}

@test "T-WIN-005: ★契約★ gate_nightly の PASS 除外 (^\\s*ok\\s) が今も効く" {
    # ★刻を行頭へ移せば PASS 行が家老への警報本文へ漏れ出す★= 毎朝 全 PASS が警報に混ざる。
    run _run_gate
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -E 'MUT-WINTEST-001' | grep -qE '^\s*ok\s'
    # ★除外した後に当該 PASS 行が残っておらぬこと★
    leaked="$(printf '%s\n' "$output" | grep -E 'MUT-WINTEST-001' | grep -vE '^\s*ok\s' | wc -l)"
    [ "$leaked" -eq 0 ]
}
