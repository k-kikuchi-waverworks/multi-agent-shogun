#!/usr/bin/env bats
# test_gate_census_wiring.bats — ★三本の口に【呼ぶ者】を与えた其の配線を、機械が縛る★
#
# ★cmd 番号は未だ持たぬ★= 本任は家老の 04:33 の便で下されたが cmd が起票されておらぬ。
#   ★己で番号を選ばぬ★ (採番は cmd_id_alloc.sh の払い出しのみ・手動採番は禁 = 2026-07-25 に
#   1日 6 件 衝突した実害の根絶策)。★cmd_1406 は【番人が控えと固着を区別できぬ】の別件ゆえ使わぬ★。
#   ⇒ 変異 id は衝突せぬ綴り (MUT-CENSUSWIRE-*) で置き、★払い出し後に家老が付け替える★。
#
# ★なぜ此の試験が在るか (2026-07-27 04:27 軍師二号の実測)★:
#   本夜 建てた七つの口は ★実体 7/7 在れど配線は 4/7★ であった。呼ぶ者が居らなんだのは
#     ・registry_census.py    (台帳の点呼)
#     ・fang_domain_census.py (牙の域の点呼)
#     ・gate_verdict_drift.py (牙の遷移)
#   ★之は cmd_1359 (stall_watchdog が3ヶ月 呼ばれなんだ) と同じ族★=★番人は書いただけでは番をせぬ★。
#   ⇒ gate_nightly.sh へ呼び口を据えた。★而して「据えた」だけでは、明日 消えても音がせぬ★=
#   ★ゆえに配線そのものへ牙を立てる★。
#
# ★此の試験の作法 (本夜の教訓を全て当てる)★:
#   (a)★梯子を書き写さぬ★= 判定の実体は ★gate_nightly.sh から現物を抜いて eval する★=
#      ★実装が動けば此の試験も動く★ (cmd_1404 二束目「梯子を書き写しておった二本」の轍を踏まぬ)。
#   (b)★canary を先に撃つ★= 抜き出しが空でないことを T0 で確かめる =
#      ★関数が renamed されたら【0 行を eval して全部緑】でなく、T0 が赤で名指す★。
#   (c)★負の主張は一度 偽にして赤を見よ★ (02:12 全軍規律) = T2/T3 は ★道具を現に壊して★撃つ。
#   (d)★bare `!` を使わぬ★= bats の `!` は set -e から免除ゆえ刃を持たぬ (cmd_1401・repo 94 箇所)。
#      判定は必ず `if <cmd>; then return 1; fi` の形で書く。
#
# 契約 (gate_nightly.sh の census 配線):
#   T0: ★canary★= run_reporter / srt / 配線 block が現物から抜ける (抜けねば以下は全て無意味)
#   T1: 既定は ★呼ばぬ★ = GATE_CENSUS_WIRING 未設定 → CENSUS_WIRING=0 / 同 STRICT も 0
#   T2: ★道具が居らぬ★ → rc=2 (UNDETERMINED) + 「道具が居らぬ」と名乗る (★黙って飛ばさぬ★)
#   T3: ★札を出さぬ (落ちた・綴りが変わった)★ → rc=2 + 「1行も出さなんだ」と名乗る
#       ★rc だけを見る形では緑になる盤面 (rc=0 で札を出さぬ道具) で撃つ★
#   T4: 札つき rc=0 → rc=0・出力は素通し
#   T5: 札つき rc=1 → ★rc=1 が保たれる★ (FAIL を UNDETERMINED や PASS へ丸めぬ)
#   T6: ★門へ入れるのは WIRING=1 かつ STRICT=1 の時のみ★= 他の三通りは 0 (報告のみ)
#   T7: ★呼ばぬ朝も黙らぬ★= WIRING=0 で配線 block を撃つと「呼んでおらぬ」と毎朝 1 行 名乗る
#
# 変異登録案 (牙 台帳の単独書き手=六号・登録は家老の号令後):
#   MUT-CENSUSWIRE-W1: run_reporter の「道具が居らぬ」枝を `return 0` へ倒す          → T2 赤
#   MUT-CENSUSWIRE-W2: 札の照合 (grep -qF "$banner") を消す                           → T3 赤
#   MUT-CENSUSWIRE-W3: srt() を `echo "$1"` へ倒す (既定で門へ入れる)                 → T6 赤
#   MUT-CENSUSWIRE-W4: else 枝の「呼んでおらぬ」1 行を消す (黙って呼ばぬ)             → T7 赤
#   MUT-CENSUSWIRE-W5: CENSUS_WIRING の既定を 1 へ倒す                                → T1 赤

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GATE="$PROJECT_ROOT/scripts/gate_nightly.sh"
    [ -f "$GATE" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/censuswire.XXXXXX")"
}

teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ★現物から抜く★ — 書き写さぬ。抜けねば空が返り、T0 が之を赤で名指す。
extract_block() { sed -n "$1" "$GATE"; }

fn_run_reporter() { extract_block '/^run_reporter() {/,/^}/p'; }
# ★srt は一行形★= `/^}/` の範囲で抜くと ★閉じ括弧が同じ行に在るゆえ次の関数の `}` まで走る★
#   (2026-07-27 05:2x 実測 = 22 行 抜けて後続の代入と verdict()/fold_lines() まで eval しておった。
#    ★己の計器が黙って範囲を広げた★= 本夜 何度も出た族の、抜き出し側の顔である)。
#   ⇒ ★一行形は其の一行だけを取る★。T0 が ★行数と越境★の両方を縛る。
fn_srt()          { grep -m1 '^srt() {' "$GATE"; }
defaults_block()  { extract_block '/^CENSUS_WIRING=/,/^regcensus_rc=/p'; }
wiring_block()    { extract_block '/^if \[ "\$CENSUS_WIRING" = "1" \]; then/,/^fi$/p'; }

# ★札を出す偽の道具★ (rc を引数で決める) — 現物の python script は撃たぬ (此処で測るのは配線ゆえ)。
make_tool() { # $1=path $2=banner $3=rc
    printf '#!/usr/bin/env python3\nimport sys\nprint(%s)\nsys.exit(%s)\n' "\"$2 実測\"" "$3" > "$1"
    chmod +x "$1"
}

@test "T0: canary — run_reporter/srt/配線block が現物から抜ける (抜けねば以下は無意味)" {
    # ★下限だけでなく上限も縛る★= ★抜き出しが越境しておらぬ★ことまで見る。
    #   越境は「足りぬ」でなく「余る」形の誤りゆえ、行数の下限では捕まらぬ。
    run fn_run_reporter
    [ "$status" -eq 0 ]
    if [ "$(printf '%s\n' "$output" | wc -l)" -lt 5 ]; then return 1; fi
    if [ "$(printf '%s\n' "$output" | wc -l)" -gt 30 ]; then return 1; fi
    printf '%s' "$output" | grep -qF 'UNDETERMINED'
    # ★越境の証 = 関数の外に在る綴りが混ざっておらぬか★
    if printf '%s' "$output" | grep -qF 'inbox_write'; then return 1; fi

    run fn_srt
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    printf '%s' "$output" | grep -qF 'CENSUS_STRICT'
    # ★一行形の越境を名指す★= 此の綴りは srt の【後】に在るゆえ、混ざれば範囲が走っておる
    if printf '%s' "$output" | grep -qF 'regcensus_gate'; then return 1; fi

    run wiring_block
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'registry_census.py'
    printf '%s' "$output" | grep -qF 'fang_domain_census.py'
    printf '%s' "$output" | grep -qF 'gate_verdict_drift.py'

    run defaults_block
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'GATE_CENSUS_WIRING'
}

@test "T1: 既定は呼ばぬ・門へも入れぬ (env 未設定 → WIRING=0 / STRICT=0)" {
    # ★現物の既定行を其のまま eval する★= 既定を書き替えれば此処が落ちる。
    run bash -c "set -u; unset GATE_CENSUS_WIRING GATE_CENSUS_STRICT; \
                 eval \"\$(sed -n '/^CENSUS_WIRING=/,/^regcensus_rc=/p' '$GATE')\"; \
                 echo \"W=\$CENSUS_WIRING S=\$CENSUS_STRICT R=\$regcensus_rc:\$fangdom_rc:\$drift_rc\""
    [ "$status" -eq 0 ]
    [ "$output" = "W=0 S=0 R=0:0:0" ]

    # ★立てれば現に立つ★ (既定 0 が「flag が死んでおる」ではないことを示す = 多重支持の緑を避ける)
    run bash -c "set -u; export GATE_CENSUS_WIRING=1 GATE_CENSUS_STRICT=1; \
                 eval \"\$(sed -n '/^CENSUS_WIRING=/,/^regcensus_rc=/p' '$GATE')\"; \
                 echo \"W=\$CENSUS_WIRING S=\$CENSUS_STRICT\""
    [ "$output" = "W=1 S=1" ]
}

@test "T2: 道具が居らぬ → rc=2 で【撃てなんだ】と名乗る (黙って飛ばさぬ)" {
    run bash -c "set -u; eval \"\$(sed -n '/^run_reporter() {/,/^}/p' '$GATE')\"; \
                 run_reporter '試し' '[試し]' '$TEST_TMPDIR/居らぬ道具.py'"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | grep -qF '道具が居らぬ'
    printf '%s' "$output" | grep -qF 'UNDETERMINED'
}

@test "T3: 札を1行も出さぬ道具 → rc=2 (★rc=0 で黙る道具を緑と読まぬ★)" {
    # ★之が「偽にして赤を見る」の当の盤面★= rc は 0 ゆえ rc だけ見る形では緑になる。
    printf '#!/usr/bin/env python3\nprint("何か別の綴り")\n' > "$TEST_TMPDIR/黙る.py"
    chmod +x "$TEST_TMPDIR/黙る.py"
    run bash -c "set -u; eval \"\$(sed -n '/^run_reporter() {/,/^}/p' '$GATE')\"; \
                 run_reporter '試し' '[台帳の点呼]' '$TEST_TMPDIR/黙る.py'"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | grep -qF '1行も出さなんだ'
    # ★生の末尾を添えておる★= 読む者が「何が出たか」を辿れる形
    printf '%s' "$output" | grep -qF '何か別の綴り'
}

@test "T4: 札つき rc=0 → rc=0・出力は素通し" {
    make_tool "$TEST_TMPDIR/緑.py" '[台帳の点呼]' 0
    run bash -c "set -u; eval \"\$(sed -n '/^run_reporter() {/,/^}/p' '$GATE')\"; \
                 run_reporter '試し' '[台帳の点呼]' '$TEST_TMPDIR/緑.py'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '[台帳の点呼] 実測'
    if printf '%s' "$output" | grep -qF 'UNDETERMINED'; then return 1; fi
}

@test "T5: 札つき rc=1 → rc=1 が保たれる (FAIL を丸めぬ)" {
    make_tool "$TEST_TMPDIR/赤.py" '[牙の域の点呼]' 1
    run bash -c "set -u; eval \"\$(sed -n '/^run_reporter() {/,/^}/p' '$GATE')\"; \
                 run_reporter '試し' '[牙の域の点呼]' '$TEST_TMPDIR/赤.py'"
    [ "$status" -eq 1 ]
    printf '%s' "$output" | grep -qF '[牙の域の点呼] 実測'
}

@test "T6: 門へ入れるのは WIRING=1 かつ STRICT=1 の時のみ (他の三通りは報告のみ)" {
    for pair in "0 0" "0 1" "1 0" "1 1"; do
        set -- $pair
        run bash -c "set -u; CENSUS_WIRING=$1; CENSUS_STRICT=$2; \
                     eval \"\$(grep -m1 '^srt() {' '$GATE')\"; srt 2"
        [ "$status" -eq 0 ]
        if [ "$1" = "1" ] && [ "$2" = "1" ]; then
            [ "$output" = "2" ]   # ★此の一通りだけ rc が門へ抜ける★
        else
            [ "$output" = "0" ]   # ★報告のみ = 門へ 1bit も入れぬ★
        fi
    done
}

@test "T7: 呼ばぬ朝も黙らぬ (WIRING=0 で【呼んでおらぬ】と1行 名乗る)" {
    run bash -c "set -u; CENSUS_WIRING=0; SCRIPT_DIR='$PROJECT_ROOT'; \
                 out2=; out4=; out6b=; out7=; out9=; regcensus_rc=0; fangdom_rc=0; drift_rc=0; \
                 eval \"\$(sed -n '/^run_reporter() {/,/^}/p' '$GATE')\"; \
                 eval \"\$(sed -n '/^if \[ \"\\\$CENSUS_WIRING\" = \"1\" \]; then/,/^fi\$/p' '$GATE')\""
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF '呼んでおらぬ'
    printf '%s' "$output" | grep -qF 'GATE_CENSUS_WIRING=1'
    # ★呼ばぬ朝に三本を撃っておらぬ事も示す★ (現物の点呼の札が出ておらぬ)
    if printf '%s' "$output" | grep -qF '採取時刻'; then return 1; fi
}
