#!/usr/bin/env bats
# cmd_1435 — 正本と生成物のずれを見る門（2026-07-28 足軽四号）
#
# 起きたこと: 2026-07-27 に CLAUDE.md が 10:40 と 17:36 の2度 変わったが、
#   そこから作られる AGENTS.md / .github/copilot-instructions.md /
#   agents/default/system.md / instructions/generated/*.md は1度も追いつかなかった。
#   気づけたのは、たまたま未 commit として git に見えていたからである。
#
# ここで固めること:
#   陽性 … 正本を変えて生成物を古いままにすると、門が赤くなり commit が止まる
#   陰性 … 作り直せば緑になる／正本にも生成物にも触れぬ commit では黙る
#   牙   … 門そのものを潰す変異を当てた時、この試験が現に赤くなる
#
# 撃ち方: 本 repo は一切 触らない。毎回 使い捨ての小さな git repo を建て、
#   そこへ本物の scripts/build_instructions.sh と scripts/gate_generated_sync.sh を
#   写して撃つ。本 repo への commit も stage も1つも起こさない。

setup_file() {
    REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export REPO

    # 本 repo が試験の前後で動いておらぬことを見る指紋
    REPO_STATUS_BEFORE="$(cd "$REPO" && git status --porcelain | md5sum)"
    export REPO_STATUS_BEFORE

    TPL="$BATS_FILE_TMPDIR/tpl"
    export TPL
    mkdir -p "$TPL/scripts" "$TPL/config" "$TPL/instructions"

    cp "$REPO/CLAUDE.md" "$TPL/CLAUDE.md"
    cp "$REPO/instructions/shogun.md" "$REPO/instructions/karo.md" \
       "$REPO/instructions/ashigaru.md" "$REPO/instructions/gunshi.md" "$TPL/instructions/"
    cp -r "$REPO/instructions/roles" "$REPO/instructions/common" \
          "$REPO/instructions/cli_specific" "$TPL/instructions/"
    cp "$REPO/config/opencode-permissions.yaml" "$TPL/config/"
    cp "$REPO/scripts/build_instructions.sh" "$REPO/scripts/gate_generated_sync.sh" "$TPL/scripts/"

    # 本 repo と同じく、意図して git から外してある2つを外す
    printf '%s\n' 'agents/default/agent.yaml' '.opencode/agents/*-runtime.md' > "$TPL/.gitignore"

    cd "$TPL" || return 1
    git init -q .
    git config user.email "test@example.invalid"
    git config user.name "cmd_1435 test"

    # commit を止めるかを見るため、本番と同じ形の shim を置く
    cat > "$TPL/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
REPO="$(git rev-parse --show-toplevel)"
exec bash "$REPO/scripts/gate_generated_sync.sh"
HOOK
    chmod +x "$TPL/.git/hooks/pre-commit"

    bash scripts/build_instructions.sh >/dev/null 2>&1 || return 1
    git add -A
    git -c core.hooksPath=/dev/null commit -qm "base" || return 1
}

setup() {
    WORK="$BATS_TEST_TMPDIR/repo"
    cp -a "$TPL" "$WORK"
    cd "$WORK" || return 1
    GATE="$WORK/scripts/gate_generated_sync.sh"
}

teardown_file() {
    local after
    after="$(cd "$REPO" && git status --porcelain | md5sum)"
    if [ "$REPO_STATUS_BEFORE" != "$after" ]; then
        echo "★本 repo の状態が試験で動いた★" >&2
        return 1
    fi
}

# 門が「ずれている」と名指した現物だけを抜く。
# ★末尾の「直し方」の行にも生成物の path が並ぶため、出力全体への文字列一致では
#   名指しと処方を取り違える（この試験を書いた当人が現に1度 踏んだ）。★
named_files() {
    printf '%s\n' "$output" | sed -n 's/^     //p'
}

# 正本を1行 変えて、生成物は古いままにする（2026-07-27 に起きかけた形そのもの）
stale_by_touching_source() {
    printf '\n<!-- cmd_1435 試験用の1行 -->\n' >> CLAUDE.md
    git add CLAUDE.md
}

# ── 陰性（緑になるべき側） ──────────────────────────────────────────

@test "N1 対照: 手を入れぬ盤面では緑になる（この土台が赤ければ以降の赤は読めぬ）" {
    run bash "$GATE" --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
    [[ "$output" == *"すべて正本と一致"* ]]
}

@test "N2 正本を変えて作り直せば緑になる" {
    printf '\n<!-- cmd_1435 試験用の1行 -->\n' >> CLAUDE.md
    bash scripts/build_instructions.sh >/dev/null 2>&1
    git add -A
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "N3 正本にも生成物にも触れぬ commit では黙る（鳴り過ぎぬこと）" {
    mkdir -p docs/content/ops
    printf 'よそ事\n' > docs/content/ops/cmd_1435_unrelated.md
    git add docs/content/ops/cmd_1435_unrelated.md
    run bash "$GATE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "N4 検分は本 repo の作業ツリーを汚さない（撃つ前と後で git status が同じ）" {
    local before after
    before="$(cd "$REPO" && git status --porcelain | md5sum)"
    run bash "$REPO/scripts/gate_generated_sync.sh" --all
    [ "$status" -eq 0 ]
    after="$(cd "$REPO" && git status --porcelain | md5sum)"
    [ "$before" = "$after" ]
}

# ── 陽性（赤になるべき側。赤の理由まで名指させる） ──────────────────

@test "P1 正本を変えて生成物を古いままにすると赤になり、ずれた物を名指す" {
    stale_by_touching_source
    run bash "$GATE"
    [ "$status" -eq 1 ]
    # 赤の理由を確かめる: rc が 1 なだけでは足りぬ。ずれた現物を名指しているか。
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"中身がずれている"* ]]
    [[ "$output" == *"build_instructions.sh"* ]]   # 直し方が出ている

    local named; named="$(named_files)"
    [[ "$named" == *"AGENTS.md"* ]]
    [[ "$named" == *".github/copilot-instructions.md"* ]]
    [[ "$named" == *"agents/default/system.md"* ]]
    # 波及先を取り違えていないか: CLAUDE.md はこの3本にしか流れ込まない。
    # instructions/generated/*.md は instructions/roles ほかの部品から作られるため動かない。
    [[ "$named" != *"instructions/generated/"* ]]
    [ "$(printf '%s\n' "$named" | grep -c .)" -eq 3 ]
}

@test "P6 部品 (instructions/common) を触った時も検知し、波及先が CLAUDE.md とは違うことを示す" {
    printf '\n<!-- cmd_1435 試験用の1行 -->\n' >> instructions/common/protocol.md
    git add instructions/common/protocol.md
    run bash "$GATE"
    [ "$status" -eq 1 ]

    local named; named="$(named_files)"
    [[ "$named" == *"instructions/generated/"* ]]
    [[ "$named" == *".opencode/agents/"* ]]
    # 逆に CLAUDE.md 由来の3本は動かない（波及先が違うことを数で示す）
    [[ "$named" != *"AGENTS.md"* ]]
    [ "$(printf '%s\n' "$named" | grep -c .)" -eq 38 ]   # generated 28 + opencode 10
}

@test "P2 実際に commit が止まる（門の返り値でなく git の振る舞いで見る）" {
    local before after
    before="$(git rev-list --count HEAD)"
    stale_by_touching_source
    run git commit -m "正本だけ直して生成物を忘れた commit"
    [ "$status" -ne 0 ]
    after="$(git rev-list --count HEAD)"
    [ "$before" = "$after" ]              # commit は1つも増えていない
    [[ "$output" == *"追いついておらぬ"* ]]
}

@test "P3 生成物だけを手で書き換えた形も赤になる" {
    printf '\n手で足した1行\n' >> AGENTS.md
    git add AGENTS.md
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"AGENTS.md"* ]]
}

@test "P4 生成物を commit 対象から外すと『作り直しでは出来るが対象に無い』で赤になる" {
    git rm --cached -q instructions/generated/codex-karo.md
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"commit 対象に無い"* ]]
    [[ "$output" == *"codex-karo.md"* ]]
}

@test "P5 作られなくなった生成物は『作り直しでは出来なかった』で赤になる" {
    # cursor 4本を作る行を落とす = 追跡されておるのに作られぬ物が出る
    sed -i '/^build_instruction_file "cursor"/d' scripts/build_instructions.sh
    git add scripts/build_instructions.sh
    run bash "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"作り直しでは出来なかった"* ]]
    [[ "$output" == *"cursor-shogun.md"* ]]
}

# ── 判じられぬ側（緑に混ぜぬこと） ──────────────────────────────────

@test "U1 作り直す道具が commit 対象から消えたら『判じられぬ』を名乗り、緑と言わない" {
    git rm --cached -q scripts/build_instructions.sh
    run bash "$GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"判じられぬ"* ]]
    [[ "$output" != *"PASS"* ]]
}

# ── 牙（門を潰したらこの試験が赤くなるか） ──────────────────────────
#
# 昨夜 三号が「黙る／名指さぬ」だけを主張する試験は門が壊れても緑になると掴んでいる。
# ゆえに変異ごとに、まず対照（変異なしで赤が出る）を撃ってから変異を当てる。
# そうしないと、赤の理由が「門が壊れた」のか「撃ち方が悪い」のか分かれない。

assert_mutation_kills_the_gate() {
    local label="$1"
    run bash "$GATE"
    if [ "$status" -eq 1 ]; then
        echo "変異「$label」を当てても門が赤のまま = この試験に牙が無い" >&2
        return 1
    fi
}

@test "M1 門の頭で即 return する変異を当てると、P1 の赤が消える" {
    stale_by_touching_source
    run bash "$GATE"
    [ "$status" -eq 1 ]                                   # 対照: 変異なしでは赤
    sed -i 's/^set -uo pipefail$/set -uo pipefail\nexit 0/' "$GATE"
    assert_mutation_kills_the_gate "頭で即 exit 0"
}

@test "M2 比べる所を常に真にする変異を当てると、P1 の赤が消える" {
    stale_by_touching_source
    run bash "$GATE"
    [ "$status" -eq 1 ]                                   # 対照
    sed -i 's|if ! cmp -s "\$SB_IDX/\$p" "\$SB/\$p"; then|if false; then|' "$GATE"
    assert_mutation_kills_the_gate "比較を常に真"
}

@test "M3 発火の条件を潰す変異を当てると、P1 の赤が消える" {
    stale_by_touching_source
    run bash "$GATE"
    [ "$status" -eq 1 ]                                   # 対照
    sed -i 's|^        \[ "\$p" = "\$e" \] && return 0$|        :|' "$GATE"
    sed -i 's|^        case "\$p" in "\$e"/\*) return 0 ;; esac$|        :|' "$GATE"
    assert_mutation_kills_the_gate "in_scope が常に外れ"
}

@test "M4 赤の返り値を 0 にすげ替える変異を当てると、P1 の赤が消える" {
    stale_by_touching_source
    run bash "$GATE"
    [ "$status" -eq 1 ]                                   # 対照
    sed -i 's|^FAIL=1$|FAIL=0|' "$GATE"
    assert_mutation_kills_the_gate "FAIL=0"
}

@test "M5 母数を数える所を空にする変異を当てると、赤が消え『判じられぬ』へ落ちる" {
    stale_by_touching_source
    run bash "$GATE"
    [ "$status" -eq 1 ]                                   # 対照
    sed -i 's|^git ls-files -- "\${OUTPUT_ROOTS\[@\]}" > "\$tracked_list"$|: > "$tracked_list"|' "$GATE"
    assert_mutation_kills_the_gate "母数を空に"
    # ★0件を緑と読ませぬこと★ = 母数が消えた時に PASS と名乗らぬか
    run bash "$GATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"1本も無い"* ]]
}
