#!/usr/bin/env bats
# test_agent_registry_deprecated.bats — cmd_1418
#
# 何を守る試験か:
#   settings.yaml に deprecated: true と書かれた定義を拾う口
#   (lib/agent_registry.sh の agent_registry_deprecated_agents)。
#
#   なぜ要るか: gunshi_a / gunshi_b は cmd_645 で廃止され、定義だけが残っている。
#   pane は元より無いので、実体を見る口はこの2件を「不在」と判定する。
#   それは判定として正しいが、点呼が毎回2件の赤を出すことになる。
#   毎朝 鳴る警報は外される。かといって一覧から黙って除くと
#   「居たものが消えた」と後から読む者が誤る。
#   ゆえに除かずに「廃止済」と別の札を付け、件数を必ず出す形にした。
#
#   この試験が守るのは「札が settings.yaml を現に読んでいること」である。
#   名前を code に直書きしていたら、下の T-ARD-002 が落ちる。
#
# 試験 ID:
#   T-ARD-001  deprecated: true の定義だけを拾う (他は拾わない)
#   T-ARD-002  拾う根拠は名前ではなく flag である (直書き殺し)
#   T-ARD-003  変異: flag を消すと拾わなくなる (＝ flag を現に読んでいる証拠)
#   T-ARD-004  deprecated: false / 記述なしは拾わない
#   T-ARD-005  agent_registry_is_deprecated の可否判定
#   T-ARD-006  cli 節の外にある deprecated は拾わない
#   T-ARD-007  現物の settings.yaml では gunshi_a / gunshi_b の2件

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export LIB="$PROJECT_ROOT/lib/agent_registry.sh"
    [ -f "$LIB" ] || return 1
}

setup() {
    FIXTURE="$BATS_TEST_TMPDIR/settings.yaml"
}

# _write_fixture <deprecated 行 (old2 用)>
# old1 は常に deprecated: true、old2 の行だけ引数で差し替える。
_write_fixture() {
    cat > "$FIXTURE" <<EOF
version: 1
cli:
  default: claude
  agents:
    karo:
      type: claude
    ashigaru1:
      type: claude
    old1:
      type: claude
      deprecated: true  # 廃止済み
    old2:
      type: claude
      ${1:-deprecated: true}
other:
  deprecated: true
EOF
}

_deprecated() {
    bash -c "source '$LIB'; agent_registry_deprecated_agents '$FIXTURE'"
}

# --- T-ARD-001 ---

@test "T-ARD-001: deprecated: true の定義だけを拾う" {
    _write_fixture
    run _deprecated
    [ "$status" -eq 0 ]
    [ "$output" = "old1
old2" ]
}

# --- T-ARD-002: 直書き殺し ---
#   現物の廃止済みは gunshi_a / gunshi_b である。
#   もし code がその名前を直書きしていたら、名前の違う見本では 0 件になる。
#   ここで2件 拾えることが「名前ではなく flag を読んでいる」証拠になる。

@test "T-ARD-002: 拾う根拠は名前ではなく flag である" {
    _write_fixture
    run _deprecated
    [ "$status" -eq 0 ]
    [[ "$output" != *"gunshi_a"* ]]
    [ "$(echo "$output" | grep -c .)" -eq 2 ]
}

# --- T-ARD-003: 変異 ---
#   flag を消して、拾われなくなることを見る。
#   これが落ちなければ、上の T-ARD-001 は何も証明していない。

@test "T-ARD-003: 変異 — deprecated 行を消すと old2 は拾われない" {
    # まず変異前を控える (この対照が無いと差が読めない)
    _write_fixture
    local before
    before=$(_deprecated)
    [ "$before" = "old1
old2" ]

    # 変異: old2 の deprecated 行を別の欄へ差し替える
    _write_fixture "model: claude-opus-5"
    run _deprecated
    [ "$status" -eq 0 ]
    [ "$output" = "old1" ]

    # 変異が現に効いた (＝ 変異前と後で答えが変わった)
    [ "$before" != "$output" ]
}

@test "T-ARD-004: deprecated: false は拾わない" {
    _write_fixture "deprecated: false"
    run _deprecated
    [ "$output" = "old1" ]
}

@test "T-ARD-004b: deprecated: truely のような別語は拾わない" {
    _write_fixture "deprecated: truely"
    run _deprecated
    [ "$output" = "old1" ]
}

# --- T-ARD-005: 可否判定 ---

@test "T-ARD-005: agent_registry_is_deprecated の可否" {
    _write_fixture
    run bash -c "source '$LIB'; agent_registry_is_deprecated old1 '$FIXTURE'"
    [ "$status" -eq 0 ]
    run bash -c "source '$LIB'; agent_registry_is_deprecated karo '$FIXTURE'"
    [ "$status" -ne 0 ]
    run bash -c "source '$LIB'; agent_registry_is_deprecated nosuchagent '$FIXTURE'"
    [ "$status" -ne 0 ]
}

# --- T-ARD-006: 節の外は見ない ---
#   見本の末尾に cli 節の外の deprecated: true を置いてある。
#   これを拾うと、無関係な設定で点呼の母数が動く。

@test "T-ARD-006: cli 節の外の deprecated は拾わない" {
    _write_fixture
    run _deprecated
    [[ "$output" != *"other"* ]]
}

@test "T-ARD-006b: settings が無い時は 0 件で rc=0 (落ちない)" {
    run bash -c "source '$LIB'; agent_registry_deprecated_agents '$BATS_TEST_TMPDIR/nosuchfile.yaml'"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# --- T-ARD-007: 現物 ---

@test "T-ARD-007: 現物の settings.yaml では gunshi_a / gunshi_b の2件" {
    run bash -c "source '$LIB'; agent_registry_deprecated_agents '$PROJECT_ROOT/config/settings.yaml'"
    [ "$status" -eq 0 ]
    [ "$output" = "gunshi_a
gunshi_b" ]
}
