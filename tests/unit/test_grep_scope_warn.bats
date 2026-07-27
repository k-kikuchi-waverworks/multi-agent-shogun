#!/usr/bin/env bats
# test_grep_scope_warn.bats — cmd_1399: ★再帰 grep の 0 が二義である形を塞ぐ門★
#
# ■ 守っている物
#   この shell の `grep` は `ugrep --ignore-files` 包み (bash function) ゆえ .gitignore を尊ぶ。
#   本 repo の .gitignore は白名簿型 (7 行目が `*`) ゆえ、queue/ plans/ logs/ の動的 file は
#   ほとんどが未追跡であり、★再帰 grep から丸ごと消える★。
#   ★而して 0 は「該当なし」と同じ顔で返る★ = 探せておらぬ 0 と、本当に無い 0 が区別できぬ。
#
#   実測 (2026-07-27):
#     追跡下 385 本 / 未追跡・雑音を除いて 3402 本 (= 見えておらぬ側が 8.8 倍)
#     綴り subtask_karo_morning_sheet … 再帰 grep 0 file・git ls-files 0 file・全数 8 file
#
# ■ 撃ち方 (両方向 + 負の対照)
#   T-GSW-002/006 = 守りを外すと【名指しが消える】     (偽陰性の側)
#   T-GSW-003/008 = 守りを壊すと【無い物を在ると言う】 (偽陽性の側 = 負の対照)
#   T-GSW-004/007 = 全数を見る呼び方 (`command grep`) では黙る。壊すと騒ぐ
#
# ■ 変異登録案 (台帳 config/mutation_registry.yaml の書き手は六号ゆえ、登録は報告経由)
#   MUT-1399-G1: blind_files が空を返す        → T-GSW-006 赤 (未追跡側を見ぬ形へ戻す)
#   MUT-1399-G2: 検索器の判定を素通しにする    → T-GSW-007 赤 (全数を見る呼び方まで騒ぐ形)
#   MUT-1399-G3: 当たりの有無を見ずに在ると言う → T-GSW-008 赤 (0 件の名乗りが嘘になる形)

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export GUARD="$PROJECT_ROOT/scripts/grep_scope_warn.py"
    [ -f "$GUARD" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/gsw.XXXXXX")"
    export FIXTURE="$TEST_TMPDIR/repo"
    mkdir -p "$FIXTURE"
    (
        cd "$FIXTURE"
        git init -q .
        git config user.email t@t.invalid
        git config user.name t
        # 白名簿型 = 本 repo と同じ形。tracked.md だけを通す
        printf '*\n!*/\n!.gitignore\n!tracked.md\n' > .gitignore
        printf 'canary_present_here\n' > tracked.md
        mkdir -p plans queue
        printf 'canary_only_in_untracked\n' > plans/untracked_a.md
        printf 'nothing interesting\n' > queue/untracked_b.md
        git add .gitignore tracked.md
    ) >/dev/null 2>&1
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

_py() {
    if [ -x "$PROJECT_ROOT/.venv/bin/python3" ]; then "$PROJECT_ROOT/.venv/bin/python3" "$@";
    else python3 "$@"; fi
}

# stdin JSON を組んで門へ流す。$1=command $2=打たれた command の出力 $3=門の実体
_fire() {
    local cmd="$1" out="$2" guard="${3:-$GUARD}"
    _py - "$cmd" "$out" <<'PY' | _py "$guard" 2>&1
import json, os, sys
print(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": "Bash",
    "cwd": os.environ["FIXTURE"],
    "tool_input": {"command": sys.argv[1]},
    "tool_response": {"stdout": sys.argv[2], "stderr": ""},
}))
PY
}

# 門の写しを作り、sed で一箇所だけ壊す。$1=sed 式 → 壊した写しの path を返す
_mutate() {
    local expr="$1" dst="$TEST_TMPDIR/mutant.py"
    sed "$expr" "$GUARD" > "$dst"
    if cmp -s "$GUARD" "$dst"; then
        echo "MUTATION-DID-NOT-APPLY" >&2
        return 1
    fi
    echo "$dst"
}

# ---------------------------------------------------------------------------
# T-GSW-001: 門が己の判定を己で検める (口を開く形・開かぬ形の両側)
# ---------------------------------------------------------------------------
@test "T-GSW-001: selftest passes both directions of the detector" {
    run _py "$GUARD" --selftest
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "SELFTEST PASS"
}

# ---------------------------------------------------------------------------
# T-GSW-002: ★本題★ 追跡下 0 件でも、未追跡側に在れば file 名で名指す
# ---------------------------------------------------------------------------
@test "T-GSW-002: names the untracked file that a recursive grep silently missed" {
    run _fire "grep -rn 'canary_only_in_untracked' ." ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
    echo "$output" | grep -q "未追跡側に 1 本"
}

# ---------------------------------------------------------------------------
# T-GSW-003: ★負の対照★ 本当に無い時は「0 件」と名乗り、file 名を一つも出さぬ
# ---------------------------------------------------------------------------
@test "T-GSW-003: negative control — says zero, and names no file, when truly absent" {
    run _fire "grep -rn 'no_such_string_anywhere_1399' ." ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "0 件"
    if echo "$output" | grep -q "untracked_a.md"; then return 1; fi
    if echo "$output" | grep -q "当たった"; then return 1; fi
}

# ---------------------------------------------------------------------------
# T-GSW-004: 全数を見る呼び方 (`command grep`) では黙る = 盲点が無い所で騒がぬ
# ---------------------------------------------------------------------------
@test "T-GSW-004: stays silent for command grep (which already sees everything)" {
    run _fire "command grep -rn 'canary_only_in_untracked' ." ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-005: 非再帰 grep でも黙る
# ---------------------------------------------------------------------------
@test "T-GSW-005: stays silent for a non-recursive grep" {
    run _fire "grep 'canary_only_in_untracked' tracked.md" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-006: 変異A = 未追跡側を見ぬ形へ戻すと、T-GSW-002 の名指しが消える
#   ★之が赤にならぬなら、T-GSW-002 は守りでなく飾りである★
# ---------------------------------------------------------------------------
@test "T-GSW-006: mutation A (blind set emptied) kills the naming in T-GSW-002" {
    local mutant
    mutant="$(_mutate 's|^    allp = \[p for p in out.stdout.split("\\0") if p\]|    allp = []|')"
    run _fire "grep -rn 'canary_only_in_untracked' ." "" "$mutant"
    if echo "$output" | grep -q "plans/untracked_a.md"; then return 1; fi
}

# ---------------------------------------------------------------------------
# T-GSW-007: 変異B = 検索器の判定を素通しにすると、command grep でも騒ぎ出す
# ---------------------------------------------------------------------------
@test "T-GSW-007: mutation B (detector disabled) makes it shout at command grep" {
    local mutant
    mutant="$(_mutate 's|^    if prog != os.path.basename(prog) or prog not in IGNORE_AWARE:|    if False:|')"
    run _fire "command grep -rn 'canary_only_in_untracked' ." "" "$mutant"
    echo "$output" | grep -q "grep_scope"
}

# ---------------------------------------------------------------------------
# T-GSW-008: 変異C = 当たりの有無を見ずに在ると言うと、負の対照 (T-GSW-003) が崩れる
# ---------------------------------------------------------------------------
@test "T-GSW-008: mutation C (always claims hits) breaks the negative control" {
    local mutant
    mutant="$(_mutate 's|^    if hits:$|    if True:|')"
    run _fire "grep -rn 'no_such_string_anywhere_1399' ." "" "$mutant"
    echo "$output" | grep -q "当たった"
}

# ---------------------------------------------------------------------------
# T-GSW-012: ★根が下位 dir なら黙る★
#   ugrep --ignore-files が読むのは【根から下で出会った .gitignore】だけである。
#   ゆえに `grep -rn PAT ./plans` は最上位の白名簿を読まず、★元より全数を見ておる★。
#   実測 (本 repo・2026-07-27): 根=. で 0 本 / 根=./queue で 6 本 (全数 6 本と一致)。
#   ⇒ 此処で騒げば狼少年になり、★本物の赤まで無視される★。
# ---------------------------------------------------------------------------
@test "T-GSW-012: stays silent when the search root carries no .gitignore" {
    run _fire "grep -rn 'canary_only_in_untracked' ./plans" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-013: 変異D = 根の判定を外すと、盲でない検索にまで騒ぎ出す
# ---------------------------------------------------------------------------
@test "T-GSW-013: mutation D (root check disabled) makes it shout at a non-blind root" {
    # ★.gitignore の有無を見ずに「どの dir も盲」と読ませる★
    #   (`if not blind: return None` の一行だけを潰す形では試験にならぬ =
    #    後段の絞り込みも blind を使うゆえ、結局 静かなままになる。実測して此方へ替えた)
    local mutant
    mutant="$(_mutate 's|if os.path.isdir(base) and os.path.isfile(os.path.join(base, ".gitignore")):|if os.path.isdir(base):|')"
    run _fire "grep -rn 'canary_only_in_untracked' ./plans" "" "$mutant"
    echo "$output" | grep -q "untracked_a.md"
}

# ---------------------------------------------------------------------------
# T-GSW-009: 門は決して 0 か 2 以外を返さぬ = ★落とす道具ではない★
#   (PostToolUse の 2 は「言葉を返す」であって、走り終えた command の rc は変えぬ)
# ---------------------------------------------------------------------------
@test "T-GSW-009: exit status is only ever 0 or 2 — never a failure code" {
    for c in "grep -rn 'canary_only_in_untracked' ." \
             "grep -rn 'no_such_string_anywhere_1399' ." \
             "command grep -rn 'x' ." \
             "grep 'x' tracked.md" \
             "echo hello" \
             "grep -rf /nonexistent/list ."; do
        run _fire "$c" ""
        if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then
            echo "command=$c status=$status" >&2
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# T-GSW-010: 母数を数える口が【数え方ごと】出す
#   ★git ls-files 単体を母数にしてはならぬ★ = 再帰 grep と同じ物を落とすゆえ
# ---------------------------------------------------------------------------
@test "T-GSW-010: --census prints the population together with how it was counted" {
    cd "$FIXTURE"
    run _py "$GUARD" --census
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "git ls-files --others --ignored --exclude-standard"
    echo "$output" | grep -q "母数にならぬ"
}

# ---------------------------------------------------------------------------
# T-GSW-011: 壊れた JSON でも素通しする (fail-OPEN) が、★黙らぬ★
# ---------------------------------------------------------------------------
@test "T-GSW-011: fails open but loud on malformed payload" {
    run bash -c "printf 'not json' | '$([ -x "$PROJECT_ROOT/.venv/bin/python3" ] && echo "$PROJECT_ROOT/.venv/bin/python3" || echo python3)' '$GUARD' 2>&1"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "grep_scope"
}
