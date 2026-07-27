#!/usr/bin/env bats
# test_cmd1363_shell_expansion.bats — 「道具へ渡す前に shell が食う」穴 (cmd_1363)
#
# ★判ずる基準は【中身の突合】である — exit code を信じてはならぬ★
#   本件の型は ★送信は成功したまま (exit 0 / [OK]) 中身だけ変わる★ ゆえ、
#   「撃てたか」でなく「原文どおり届いたか」で検める (足軽五号の具申 2026-07-26)。
#
# 実害3件 (同日・別人・同型):
#   足軽五号 = 本文の `docker rm -f vllm-8002` が実行され報告から消えた
#   足軽四号 = 中身が5箇所 黙って欠けた ([OK] は返っておった)
#   家老     = ntfy.sh で同型 (送信そのものが失敗) / inbox 本文の backtick を意図せず実行
#
# 構成:
#   G-xxx = 関所 (scripts/shell_expansion_guard.py) が食われる形を止めるか
#   D-xxx = 塞いだ後、3つの口を含む本文が ★原文どおり★ 届くか (byte一致)
#   V-xxx = 道具の内側で本文が変質した時、★黙って配らぬ★ か
#   N-xxx = ntfy.sh が送信失敗を黙って飲まぬか

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export GUARD="$PROJECT_ROOT/scripts/shell_expansion_guard.py"
    export IW="$PROJECT_ROOT/scripts/inbox_write.sh"
    export NTFY="$PROJECT_ROOT/scripts/ntfy.sh"
    [ -f "$GUARD" ] || return 1
    [ -f "$IW" ] || return 1
}

setup() {
    TESTDIR="$(mktemp -d)"
    mkdir -p "$TESTDIR/scripts" "$TESTDIR/queue/inbox"
    # ★2026-07-27 cmd_1381 段5(a) 足軽四号★ = ★本試験は【本番の logs/ntfy_send.log】へ書き込んでおった★。
    #   N-001/N-002 が偽 curl で ntfy.sh を走らせるゆえ、走るたび "title=テスト" の行が
    #   ★本番の記録へ 2 行 積まれる★ (実測: 2026-07-27 01:20〜01:21 に 4 行 積まれておるのを発見)。
    #   ★本物の矢は一度も飛んでおらぬ (偽 curl ゆえ) が、記録は現に汚れておった★ =
    #   ★段5(b) の判定子は此の log を読む★ ⇒ 試験の 500 が本番の「失敗」として数えられ、
    #   ★3 度走らせれば閾 (3件/3h) に達して偽の赤が出る★。
    #   ⇒ 段5(a) で開けた NTFY_LOG_FILE の口へ逃がす (本番の記録を試験で汚さぬ)。
    export NTFY_LOG_FILE="$TESTDIR/ntfy_send.log"
    cp "$IW" "$TESTDIR/scripts/"
    export TESTDIR
}

teardown() {
    [ -n "${TESTDIR:-}" ] && rm -rf "$TESTDIR"
}

# 届いた本文を取り出す (最新1件)
_recv() {
    python3 -c '
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
print(d["messages"][-1]["content"], end="")
' "$TESTDIR/queue/inbox/karo.yaml"
}

_verdict() {
    python3 "$GUARD" --command "$1" >/dev/null 2>&1
    local rc=$?
    [ $rc -eq 2 ] && echo DENY || echo ALLOW
}

# ─────────────── G: 関所が「食われる形」を止めるか ───────────────

@test "G-001: (A) backtick が地の文に在る → DENY (五号・家老が実際に踏んだ形)" {
    run _verdict 'bash scripts/inbox_write.sh karo "五号は `docker rm -f vllm-8002` を撃った" task_assigned karo'
    [ "$output" = "DENY" ]
}

@test "G-002: (B) \$(...) が地の文に在る → DENY" {
    run _verdict 'bash scripts/inbox_write.sh karo "port は $(echo 9100) である" report ashigaru1'
    [ "$output" = "DENY" ]
}

@test "G-003: (C) 未定義 \$VAR が地の文に在る → DENY (★最も危うい=静かに空へ★)" {
    run _verdict 'bash scripts/inbox_write.sh karo "hash は $COMMIT_SHA じゃ" task_assigned karo'
    [ "$output" = "DENY" ]
}

@test "G-004: (D) 引用符なし heredoc → DENY (勧めた逃げ道が新しい口にならぬこと)" {
    run _verdict "bash scripts/inbox_write.sh karo --body-stdin t f <<EOF
本文に \`x\` が在る
EOF"
    [ "$output" = "DENY" ]
}

@test "G-005: ntfy.sh の本文 backtick → DENY (家老が同日踏んだ同型)" {
    run _verdict 'bash scripts/ntfy.sh "✅ 完了" "本文に `code` が在る"'
    [ "$output" = "DENY" ]
}

@test "G-010: single quote は素通し (★本来の正しい書き方★)" {
    run _verdict "bash scripts/inbox_write.sh karo '五号は \`docker rm -f x\` を撃った' t f"
    [ "$output" = "ALLOW" ]
}

@test "G-011: <<'EOF' (引用符つき heredoc) は素通し" {
    run _verdict "bash scripts/inbox_write.sh karo --body-stdin t f <<'EOF'
本文に \`x\` が在る
EOF"
    [ "$output" = "ALLOW" ]
}

@test "G-012: 意図した \"\$msg\" 単体は素通し (既存の実呼出を殺さぬ)" {
    run _verdict 'bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo "$msg" error gate_nightly'
    [ "$output" = "ALLOW" ]
}

@test "G-013: 関所の外 (対象外の道具) は検めぬ — 越権に赤くせぬ" {
    run _verdict 'git commit -m "fix: `backtick` in message"'
    [ "$output" = "ALLOW" ]
}

@test "G-020: PreToolUse hook 契約 — stdin JSON を食わせると rc=2 で止まる" {
    run bash -c 'printf "%s" "$1" | python3 "$2"' _ \
        '{"tool_name":"Bash","tool_input":{"command":"bash scripts/inbox_write.sh karo \"a `id` b\" t f"}}' \
        "$GUARD"
    [ "$status" -eq 2 ]
    [[ "$output" == *"関所"* ]]
}

@test "G-021: 関所が認めた逃げ道を道具が本当に受け取る (contract 突合)" {
    run python3 "$GUARD" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"逃げ道"* ]]
}

# ─────────── D: 塞いだ後、3つの口を含む本文が原文どおり届くか ───────────
# ★これが家老の要件④ = 「故意に3つの口を含む文を送って原文どおり届くことを実測せよ」★

@test "D-001: --body-stdin + <<'EOF' で3つの口すべてが byte 一致で届く" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh karo --body-stdin task_assigned shogun <<'EOF'
(A) 五号は `docker rm -f vllm-8002` を撃った
(B) sha=$(git rev-parse HEAD) を照合せよ
(C) path=$IW_UNDEFINED_VAR_XYZ/models を見よ
EOF
    run _recv
    [[ "$output" == *'`docker rm -f vllm-8002`'* ]]
    [[ "$output" == *'$(git rev-parse HEAD)'* ]]
    [[ "$output" == *'$IW_UNDEFINED_VAR_XYZ/models'* ]]
}

@test "D-002: --content-file (関所が案内する綴り) で byte 一致" {
    cd "$TESTDIR"
    printf '%s' 'port=`echo 9100` sha=$(id) path=$UNDEF/x' > body.txt
    bash scripts/inbox_write.sh karo --content-file body.txt task_assigned shogun
    run _recv
    [ "$output" = 'port=`echo 9100` sha=$(id) path=$UNDEF/x' ]
}

@test "D-003: --body-file=PATH (= つき) で byte 一致" {
    cd "$TESTDIR"
    printf '%s' 'a=`x` b=$(y) c=$Z' > body.txt
    bash scripts/inbox_write.sh karo --body-file=body.txt task_assigned shogun
    run _recv
    [ "$output" = 'a=`x` b=$(y) c=$Z' ]
}

@test "D-004: 従来の positional 呼出は壊れておらぬ (後方互換)" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh karo '普通の日本語本文' report ashigaru1
    run _recv
    [ "$output" = '普通の日本語本文' ]
}

# ─────── V: 道具の内側で本文が変質した時、黙って配らぬか ───────
# U+0085 (NEL) は YAML round-trip で ★空白へ黙って変わる★ (cmd_1363 実測)。
# 旧 verify は id の実在しか見ておらず、この変質を緑で通しておった。

@test "V-001: ★本文が変質して届く形 (U+0085) を検知し、配達せず非0で落ちる★" {
    cd "$TESTDIR"
    python3 -c 'open("body.txt","w",encoding="utf-8").write("NEL\u0085あり")'
    run bash scripts/inbox_write.sh karo --content-file body.txt report ashigaru1
    [ "$status" -ne 0 ]
    [[ "$output" == *"変質"* ]]
}

@test "V-002: 変質検知時は ★壊れた entry を残さぬ★ (書込前へ戻す)" {
    cd "$TESTDIR"
    bash scripts/inbox_write.sh karo '健全な先客' report ashigaru1
    python3 -c 'open("body.txt","w",encoding="utf-8").write("NEL\u0085あり")'
    bash scripts/inbox_write.sh karo --content-file body.txt report ashigaru1 || true
    # 先客は残り、壊れた本文は1件も積まれておらぬこと
    run python3 -c '
import yaml
d=yaml.safe_load(open("queue/inbox/karo.yaml"))
ms=d["messages"]
print(len(ms), "NEL" in "".join(m["content"] for m in ms))
'
    [ "$output" = "1 False" ]
}

# ─────────── N: ntfy.sh が送信失敗を黙って飲まぬか ───────────
# 本物の ntfy.sh を走らせ、transport (curl) だけ差し替えて HTTP status を与える。

@test "N-001: HTTP 500 → ★非0で落ちる (旧版は常に exit 0 で黙っておった)★" {
    mkdir -p "$TESTDIR/bin"
    printf '#!/bin/sh\necho 500\n' > "$TESTDIR/bin/curl"
    chmod +x "$TESTDIR/bin/curl"
    # cmd_1419 その5: bats の中では既定で送信を止める（殿の端末を鳴らさぬため）。
    #   本 test は偽 curl で 500 を作り、curl を呼ぶ経路そのものを試すゆえ明示で逃げ道を開ける。
    run env NTFY_DRY_RUN=0 PATH="$TESTDIR/bin:$PATH" bash "$NTFY" "テスト" "本文"
    [ "$status" -ne 0 ]
    [[ "$output" == *"HTTP=500"* ]]
}

@test "N-002: HTTP 200 → 0 で通る (正常系を殺しておらぬ)" {
    mkdir -p "$TESTDIR/bin"
    printf '#!/bin/sh\necho 200\n' > "$TESTDIR/bin/curl"
    chmod +x "$TESTDIR/bin/curl"
    run env NTFY_DRY_RUN=0 PATH="$TESTDIR/bin:$PATH" bash "$NTFY" "テスト" "本文"
    [ "$status" -eq 0 ]
}
