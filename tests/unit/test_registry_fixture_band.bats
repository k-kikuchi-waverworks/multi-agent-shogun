#!/usr/bin/env bats
# test_registry_fixture_band.bats — cmd_1387: 見本用の予約帯 MUT-9999-*
#
# 何を守るか (2 つで 1 組):
#   (1) 幽霊 ID 検分は予約帯を数えない。除いた件数は必ず表示する。
#   (2) 予約帯の id は台帳へ登録できない (schema が拒む)。
#
# なぜ 2 つで 1 組か:
#   (1) だけ置くと「登録されているのに検分から見えない本物」を作れてしまう。
#   つまり偽の変異テストを 1 本増やす代わりに、本物が黙って落ちる穴が開く。
#   向きが逆なだけで病は同じなので、片方だけでは守りにならない。
#
# 背景の実測 (2026-07-27):
#   幽霊 64 件のうち 15 件が selftest の見本 id だった
#   (gate_registry_append.py 10 / gate_verdict_drift.py 2 / 検分の bats 2 / 本 gate の註 1)。
#   これを登録して消せば、実体のない変異テストが 15 本増える。
#   数を減らすために中身を悪くしない、という掟に従い綴りで分けた。
#
# 注: 本 file 自身は予約帯の id を literal で書かない (書けば自分が見本の数を増やす)。
#     動的に組む — selftest T21 が同じ理由で使っている手である。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPLAY_PY="${REPLAY_PY_OVERRIDE:-$PROJECT_ROOT/scripts/gate_mutation_replay.py}"
    [ -f "$REPLAY_PY" ] || return 1
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/fixband.XXXXXX")"
    export FIXTURE_ID="MUT-$(printf '9999')-SAMPLE"
    # 帯の外の見本。★literal で書かぬ★ = 書けば本 file 自身が幽霊を 1 件 増やす。
    # 帯の内側 (上の行) と同じ理由だが、こちらは 18:2x まで literal のままであった (六号の落ち)。
    export REAL_ID="MUT-1387-$(printf 'REALSAMPLE')"
    # 検分される側の小さな repo (git 追跡下でなければ scan の対象にならない)
    export FIX_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$FIX_REPO/tests" "$FIX_REPO/scripts"
    printf 'FLAG = 0\n' > "$FIX_REPO/scripts/tool.py"
    # 陽性対照。coverage は「検出規則が現に何かを拾えるか」を先に確かめる造りで、
    # 拾えなければ真空 PASS を禁じて UNDETERMINED を返す。
    # 対照が無いと本 test は「予約帯が効いた」ではなく「何も見ていない」で緑になる。
    printf '# fake runner (陽性対照): --selftest 変異試験\n' \
        > "$FIX_REPO/scripts/gate_mutation_replay.py"
    cat > "$FIX_REPO/tests/note.py" <<EOF
# 見本として引く: ${FIXTURE_ID}
EOF
    (cd "$FIX_REPO" && git init -q && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm init) >/dev/null 2>&1
    cat > "$TEST_TMPDIR/reg.yaml" <<'YAML'
mutations:
  - id: MUT-COV-CTL
    desc: 対照
    paths: [scripts/tool.py]
    mutate: |
      sed -i 's/FLAG = 0/FLAG = 1/' scripts/tool.py
    test: |
      grep -q 'FLAG = 0' scripts/tool.py
coverage_waivers: []
YAML
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# T-FB-001: 予約帯の id は幽霊に数えない。ただし除いた件数は必ず表示する。
#   黙って除けば「数を静かに減らす」形になり、それは禁じられている。
# ---------------------------------------------------------------------------
@test "T-FB-001: fixture-band ids are excluded from the ghost count, and the exclusion is announced" {
    run python3 "$REPLAY_PY" --coverage --registry "$TEST_TMPDIR/reg.yaml" --repo-root "$FIX_REPO"
    # 幽霊として名指されていない
    local ghosts
    ghosts="$(echo "$output" | grep 'GHOST-ID' || true)"
    if echo "$ghosts" | grep -q "$FIXTURE_ID"; then
        echo "予約帯の id が幽霊として名指された: $ghosts" >&2
        return 1
    fi
    # 除いた件数を名乗っている
    echo "$output" | grep -q "見本用 MUT-9999-\* を 1 件 除いた"
}

# ---------------------------------------------------------------------------
# T-FB-002: 予約帯でない未登録 id は今までどおり幽霊として名指される。
#   除外が広すぎないことを反対側から縛る (本物を黙って見逃す形を防ぐ)。
# ---------------------------------------------------------------------------
@test "T-FB-002: a normal unregistered id is still reported as a ghost (the exclusion is not too wide)" {
    cat > "$FIX_REPO/tests/note.py" <<EOF
# 実射で確認済: ${REAL_ID}
EOF
    (cd "$FIX_REPO" && git add -A && git -c user.email=t@t -c user.name=t commit -qm x) >/dev/null 2>&1
    run python3 "$REPLAY_PY" --coverage --registry "$TEST_TMPDIR/reg.yaml" --repo-root "$FIX_REPO"
    echo "$output" | grep -q "GHOST-ID"
    echo "$output" | grep -q "$REAL_ID"
}

# ---------------------------------------------------------------------------
# T-FB-004: 英字つきの cmd 番号の見本も帯に入る。
#   実在例 ref:MUT-1369E-001 のような形を見本で再現する試験があるため。
#   帯の要は「9999 という実在しない cmd 番号」であって、英字の有無ではない。
# ---------------------------------------------------------------------------
@test "T-FB-004: the band also covers letter-suffixed cmd numbers (9999E), which fixtures need" {
    local letter_id
    letter_id="MUT-$(printf '9999')E-001"
    cat > "$FIX_REPO/tests/note.py" <<EOF
# 見本として引く: ${letter_id}
EOF
    (cd "$FIX_REPO" && git add -A && git -c user.email=t@t -c user.name=t commit -qm y) >/dev/null 2>&1
    run python3 "$REPLAY_PY" --coverage --registry "$TEST_TMPDIR/reg.yaml" --repo-root "$FIX_REPO"
    local ghosts
    ghosts="$(echo "$output" | grep 'GHOST-ID' || true)"
    if echo "$ghosts" | grep -q "$letter_id"; then
        echo "英字つきの見本 id が幽霊として名指された: $ghosts" >&2
        return 1
    fi
    echo "$output" | grep -q "見本用 MUT-9999-\* を 1 件 除いた"
}

# ---------------------------------------------------------------------------
# T-FB-003: 逆向きの守り。予約帯の id を台帳へ登録しようとしたら schema が拒む。
#   これが無いと「登録されているのに検分から見えない本物」が作れてしまう。
# ---------------------------------------------------------------------------
@test "T-FB-003: registering a real entry inside the fixture band is rejected by the schema" {
    run python3 - "$REPLAY_PY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("r", sys.argv[1])
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
base = {"desc": "x", "paths": ["a"], "mutate": "x", "test": "x"}
bad = r.validate_entry(dict(base, id="MUT-" + "9999-REAL"))
ok = r.validate_entry(dict(base, id="MUT-1387-" + "OKSAMPLE"))
print("BAD=", bad)
print("OK=", ok)
assert bad and "予約帯" in bad, f"予約帯の id が通ってしまう: {bad!r}"
assert ok is None, f"普通の id が拒まれる: {ok!r}"
print("BOTH_DIRECTIONS_OK")
PY
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "BOTH_DIRECTIONS_OK"
}
