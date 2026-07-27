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
# ■ 変異の登録 (台帳 config/mutation_registry.yaml・登録済み commit e808caa・書き手は六号)
#   MUT-1399-G1: blind_files が空を返す         → ^T-GSW-002 赤 (未追跡側の名指しが消える)
#   MUT-1399-G2: 検索器の判定を素通しにする     → ^T-GSW-004 赤 (command grep にまで騒ぐ)
#   MUT-1399-G3: 当たりの有無を見ずに在ると言う → ^T-GSW-003 赤 (負の対照が崩れる)
#   MUT-1399-G4: 根の .gitignore 判定を外す     → ^T-GSW-012 赤 (盲でない根にまで騒ぐ)
#
#   ★当初 拙者は 006/007/008/013 を宛てた。六号が実測で正した (23:11)。★
#   006/007/008/013 は【自分の中で sed を撃って写しを壊す】形の試験である。
#   ゆえに台帳の変異を先に当てると、sed の当てる先が既に書き換わっており当たらぬ。
#   cmp が同一と読み MUTATION-DID-NOT-APPLY で落ちる = ★赤にはなるが、赤の理由が
#   「働きが壊れた」ではなく「己の sed が当たらぬ」になる★。
#   之を台帳へ載せれば、牙が守るのは働きでなく sed の綴りになってしまう。
#   移した先 (002/004/003/012) は働きを直に検める側であり、六号が 4 本とも
#   赤の理由が働きであることを実測している。
#   ★filter には ^ の錨が要る★ = 素の "T-GSW-002" は T-GSW-006 の題にも当たり 2 本 走る。
#
# ■ 変異試験は【2 回 撃つ】形にしてある (23:3x・六号の名指しを実測で追認して直した)
#   変異体に「黙ること／名指さぬこと」だけを言わせる形は、★門が丸ごと壊れて何も吐かぬ時にも満たされる★。
#   実測: run_hook を即 return 0 に潰した門で全 22 本を撃つと、002 は赤・★006/020/021/022 は緑のまま★。
#   ゆえに 006/020/021/022 は ① 原本を撃って鳴ることを確かめ → ② 変異体を撃って黙ることを確かめる、の順にした。
#   ①が無ければ、之らは単独では何も証しておらぬ (台帳の replay は 1 本だけを走らせるゆえ、単独で立つ要が在る)。

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
    # ① 先に原本を撃ち、★名指すこと★を確かめる (= 陽性の対照)
    #    之が無いと「門が何も吐かぬ」時にも ② が満たされ、006 は緑のまま通る。
    run _fire "grep -rn 'canary_only_in_untracked' ." ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
    # ② 変異体を撃ち、名指しが消えることを確かめる
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

# ═══════════════════════════════════════════════════════════════════════════
# 23:2x 追加 — 軍師一号の検分 (8 通り) が名指した 3 つの穴。家老 23:20 が三件とも裁可
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# T-GSW-014: ★rg PAT . が鳴る★ — 今 最も普通に打たれる形が盲のまま黙っていた
# ---------------------------------------------------------------------------
@test "T-GSW-014: rg with an explicit path is still recursive — it must speak" {
    run _fire "rg 'canary_only_in_untracked' ." ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
}

# ---------------------------------------------------------------------------
# T-GSW-015: ugrep の同型も鳴る (家老の条件③)
# ---------------------------------------------------------------------------
@test "T-GSW-015: ugrep with an explicit path speaks too" {
    run _fire "ugrep 'canary_only_in_untracked' ." ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
}

# ---------------------------------------------------------------------------
# T-GSW-016: ★両方向★ 正しく全数を見る呼びでは、rg でも黙る
#   ※之が無ければ T-GSW-014 は「常に鳴る門」でも緑になる
# ---------------------------------------------------------------------------
@test "T-GSW-016: rg rooted at a subdir that carries no .gitignore stays silent" {
    run _fire "rg 'canary_only_in_untracked' ./plans" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-017: ★git grep が鳴る★ + 責めでなく報せの一行を添える
#   git grep は追跡下しか見ぬ = 家老を欺いたのと同じ病を持つ道具である
# ---------------------------------------------------------------------------
@test "T-GSW-017: git grep is tracked-only — it must speak, and say why" {
    run _fire "git grep -n 'canary_only_in_untracked'" ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
    echo "$output" | grep -q "git grep は元より追跡下のみを見る道具である"
}

# ---------------------------------------------------------------------------
# T-GSW-018: ★負の対照★ git の他の副命令 (git log) では黙る
# ---------------------------------------------------------------------------
@test "T-GSW-018: other git subcommands stay silent" {
    run _fire "git log --oneline" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-019: ★引用符が閉じておらぬ command で、門が黙らぬ★
#   段が 0 個で rc=0 は「何も検めておらぬ」が「異常なし」の顔で返る形である
# ---------------------------------------------------------------------------
@test "T-GSW-019: an unparseable command is named, not silently passed" {
    run _fire 'grep -rn "unbalanced .' ""
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "一つも検めておらぬ"
}

# ---------------------------------------------------------------------------
# T-GSW-020: 変異E = rg の再帰判定に `and not roots` を戻すと T-GSW-014 が黙る
# ---------------------------------------------------------------------------
@test "T-GSW-020: mutation E (rg path guard restored) silences T-GSW-014" {
    run _fire "rg 'canary_only_in_untracked' ." ""      # ① 原本は鳴る
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
    local mutant
    mutant="$(_mutate 's|^    if not recursive and prog in ("rg", "ugrep"):|    if not recursive and prog in ("rg", "ugrep") and not roots:|')"
    run _fire "rg 'canary_only_in_untracked' ." "" "$mutant"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-021: 変異F = git grep の読み取りを外すと T-GSW-017 が黙る
# ---------------------------------------------------------------------------
@test "T-GSW-021: mutation F (git grep detection removed) silences T-GSW-017" {
    run _fire "git grep -n 'canary_only_in_untracked'" ""   # ① 原本は鳴る
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "plans/untracked_a.md"
    local mutant
    mutant="$(_mutate 's|^    if tokens\[0\] == "git" and len(tokens) > 1 and tokens\[1\] == "grep":|    if False:|')"
    run _fire "git grep -n 'canary_only_in_untracked'" "" "$mutant"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# T-GSW-022: 変異G = lex 失敗を空 list へ戻すと T-GSW-019 が黙る
#   ★「読めなんだ」が「異常なし」の顔になる形の再現★
# ---------------------------------------------------------------------------
@test "T-GSW-022: mutation G (lex failure returns empty) makes the gate silent again" {
    run _fire 'grep -rn "unbalanced .' ""                # ① 原本は鳴る
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "一つも検めておらぬ"
    local mutant
    mutant="$(_mutate 's|^        return None$|        return []|')"
    run _fire 'grep -rn "unbalanced .' "" "$mutant"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
