#!/usr/bin/env bats
# test_gate_registry_append_wiring.bats — ★gate-4 (台帳の呑まれ) の配線そのものへ牙を立てる★ (cmd_1409)
#
# ★何ゆえ配線へ牙が要るか★:
#   ★呑まれ (entry を書いたのに mutations: の下に居らぬ) は【翌朝の replay にも見えぬ】★ =
#   台帳に載っておらぬ牙は撃たれもせぬゆえ、★commit の其の瞬間に名指す以外に捕える口が無い★。
#   ⇒ ★gate_precommit.sh から gate-4 の呼び出しが消えた其の日、我らは【何の音も聞かぬ】★
#     = cmd_1359 (stall_watchdog が3ヶ月 呼ばれなんだ) / 04:27 軍師二号「実体 7/7・配線 4/7」と同じ族。
#   ⇒ ★「据えた」でなく「効いておる」を機械に言わせる★。
#
# ★此の試験の作法★:
#   (a) ★文字を照合せぬ = 振舞いで縛る★ — 呼び先を stub へ差し替え、★rc と出力が現に伝わるか★を見る
#       (grep で「呼び出し行が在るか」を見る形は、行が在って rc を捨てておっても緑になる)。
#   (b) ★canary を先に撃つ★ (T-RA-000) — 素の盤面で PASS が出ねば、以下の赤は全て無意味。
#   (c) ★負の主張を偽にして赤を見る★ — gate-4 だけを鳴らせた盤面で、門が現に鳴るか。
#   (d) ★bare `!` を使わぬ★ (cmd_1401) — 判定は `if <cmd>; then return 1; fi` の形で書く。
#
# 契約:
#   T-RA-000: canary = 四つの stub 全て rc=0 なら門は PASS を返し、★gate-4 を名乗る★
#   T-RA-001: gate-4 が rc=2 → 門は 0 で通すが ★UNDETERMINED を刷り、gate-4 の出力を素通しする★
#   T-RA-002: gate-4 が rc=1 → 門は ★exit 1 (commit を止める)★ + gate-4 の出力を刷る
#   T-RA-003: ★gate-4 の呼び出しが在っても rc を拾わねば赤★ (T-RA-001/002 が之を縛る)
#             = 本 file では独立 test を置かず、上二つが同じ穴を塞ぐ旨をここへ記す
#
# 変異登録 (config/mutation_registry.yaml):
#   MUT-1409-G5: gate_precommit.sh の gate-4 呼び出し行を消す → T-RA-001 赤

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_precommit.sh"
    [ -f "$GATE" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/gate4wire.XXXXXX")"
    mkdir -p "$TEST_TMPDIR/scripts"
    # ★門の現物を写す (書き写さぬ = 実装が動けば此の試験も動く)★
    cp "$GATE" "$TEST_TMPDIR/scripts/gate_precommit.sh"
    # ★呼び先は全て stub★ — 本試験の問いは「rc と出力が門へ伝わるか」ただ一つ
    stub scripts/gate_artifact_capture.sh 0 "[stub gate-1]"
    stub scripts/gate_mutation_replay.py  0 "[stub gate-2]"
    stub scripts/gate_anchor_touched.py   0 "[stub gate-3]"
    stub scripts/gate_registry_append.py  0 "[stub gate-4] 呑まれ 0"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# stub <relpath> <rc> <出力>
#   ★.py は門が python3 で呼ぶゆえ python で書く★ — bash の stub を置くと
#   ★SyntaxError で rc=1 になり、【別の理由の赤】が「配線が効いておる」に見える★
#   (現に 09:41 の初走で T-RA-002/004 が此の偽の理由で緑になった。T-RA-000 の canary が之を捕えた)。
stub() {
    local rel="$1" rc="$2" msg="$3"
    if [[ "$rel" == *.py ]]; then
        printf '#!/usr/bin/env python3\nimport sys\nprint("""%s""")\nsys.exit(%s)\n' "$msg" "$rc" > "$TEST_TMPDIR/$rel"
    else
        printf '#!/usr/bin/env bash\necho "%s"\nexit %s\n' "$msg" "$rc" > "$TEST_TMPDIR/$rel"
    fi
    chmod +x "$TEST_TMPDIR/$rel"
}

run_gate() { run bash "$TEST_TMPDIR/scripts/gate_precommit.sh"; }

@test "T-RA-000 canary: 素の盤面で門は PASS を返し gate-4 を名乗る" {
    run_gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"gate-4"* ]]
}

@test "T-RA-001 gate-4 が rc=2 → 門は UNDETERMINED を刷り出力を素通しする" {
    stub scripts/gate_registry_append.py 2 "★呑まれ★ MUT-9999-X は mutations: の下に居らぬ"
    run_gate
    [ "$status" -eq 0 ]                      # ★既定は commit を止めぬ★
    [[ "$output" == *"UNDETERMINED"* ]]
    [[ "$output" == *"MUT-9999-X"* ]]        # ★rc だけ拾うて本文を捨てる形を許さぬ★
}

@test "T-RA-002 gate-4 が rc=1 → 門は exit 1 で commit を止め、出力を刷る" {
    stub scripts/gate_registry_append.py 1 "★FAIL★ 台帳へ書いたのに登録されておらぬ"
    run_gate
    [ "$status" -eq 1 ]
    [[ "$output" == *"登録されておらぬ"* ]]
}

@test "T-RA-004 gate-4 の道具が居らぬ時も黙らぬ (rc≠0 が門へ伝わる)" {
    rm -f "$TEST_TMPDIR/scripts/gate_registry_append.py"
    run_gate
    if [ "$status" -eq 0 ] && [[ "$output" != *"UNDETERMINED"* ]]; then
        echo "道具が消えたのに門が黙って緑を返した: $output"
        return 1
    fi
}
