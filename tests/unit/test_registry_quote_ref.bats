#!/usr/bin/env bats
# test_registry_quote_ref.bats — cmd_1387: 引用の印 ref: (家老 18:10 の裁2)
#
# 何を守るか (3 つで 1 組):
#   (1) ref: を前置した id は「他の木の実例の引用」ゆえ幽霊に数えない。
#   (2) 引用の件数は必ず表示する。0 件でも表示する。
#   (3) ref: の無い同じ id は今までどおり幽霊として名指される。
#
# なぜ 3 つで 1 組か:
#   (1) だけなら「鳴ったら ref: を付ければ黙る」逃げ道になる。
#   (2) が無ければ引用が黙って消え、書き方を間違えた申告まで一緒に消える。
#   (3) が無ければ除外が広すぎても誰も気付けない。向きが逆なだけで病は同じである。
#
# 背景の実測 (2026-07-27 18:16):
#   幽霊 59 件のうち A (他の木の台帳に実在する id への言及) が 24 件あり、
#   その 13 件は「なぜこの造りにしたか」を語る註が他の木の変異テストを実例に挙げた物だった。
#   登録すれば実体のない変異テストが増える。註から消せば経緯の記録が痩せる。
#   ゆえに書き方で分けた (家老 18:10 の裁2)。
#
# なぜ前置きか: バッククォートで囲む形は採らない。「囲めば通る」は engine 側で踏んだ穴と
#   同じ族である。ref: は前置きゆえ grep で確実に拾え、人が読んでも引用と分かる。
#
# 注: 本 file 自身は検分される側の id を literal で書かない (書けば自分が数を増やす)。
#     動的に組む — T-FB 系と同じ手である。

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export REPLAY_PY="${REPLAY_PY_OVERRIDE:-$PROJECT_ROOT/scripts/gate_mutation_replay.py}"
    [ -f "$REPLAY_PY" ] || return 1
    python3 -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/quoteref.XXXXXX")"
    # 綴りを動的に組む。literal で書けば本 file 自身が幽霊を 1 件 増やす
    # (見本の id は台帳に載らぬゆえ)。T-FB 系と同じ手である。
    export SAMPLE_ID="MUT-1387-$(printf 'QUOTESAMPLE')"
    export QUOTE_MARK="ref:"
    # 検分される側の小さな repo (git 追跡下でなければ scan の対象にならない)
    export FIX_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$FIX_REPO/tests" "$FIX_REPO/scripts"
    printf 'FLAG = 0\n' > "$FIX_REPO/scripts/tool.py"
    # 陽性対照。coverage は検出規則が現に何かを拾えるかを先に確かめる造りで、
    # 拾えなければ真空 PASS を禁じて UNDETERMINED を返す。
    # 対照が無いと本 test は「引用が効いた」ではなく「何も見ていない」で緑になる。
    printf '# fake runner (陽性対照): --selftest 変異試験\n' \
        > "$FIX_REPO/scripts/gate_mutation_replay.py"
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

# 検分される側の註を 1 行だけ置き直して commit する
_put_note() {
    cat > "$FIX_REPO/tests/note.py" <<EOF
# $1
EOF
    (cd "$FIX_REPO" && git init -q 2>/dev/null; git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm x) >/dev/null 2>&1
    return 0
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ---------------------------------------------------------------------------
# T-QR-001: ref: 付きは引用ゆえ幽霊に数えない。ただし引用の件数は必ず表示する。
# ---------------------------------------------------------------------------
@test "T-QR-001: a ref:-prefixed id counts as a quote, not a ghost, and the count is announced" {
    _put_note "実例 = backend の ${QUOTE_MARK}${SAMPLE_ID} = 他の木の変異テストゆえ"
    run python3 "$REPLAY_PY" --coverage --registry "$TEST_TMPDIR/reg.yaml" --repo-root "$FIX_REPO"
    local ghosts
    ghosts="$(echo "$output" | grep 'GHOST-ID' || true)"
    if echo "$ghosts" | grep -q "$SAMPLE_ID"; then
        echo "引用が幽霊として名指された: $ghosts" >&2
        return 1
    fi
    # 黙って捨てていない = 件数を名乗っている
    echo "$output" | grep -q "付きの言及を 1 件 別に数えた"
}

# ---------------------------------------------------------------------------
# T-QR-002: ★負例★ ref: の無い同じ id は今までどおり幽霊として名指される。
#   これが無いと「鳴ったら ref: を付ければ黙る」逃げ道を作ったことになる。
# ---------------------------------------------------------------------------
@test "T-QR-002: the same id without ref: is still reported as a ghost (no escape hatch)" {
    _put_note "実射で確認済: ${SAMPLE_ID}"
    run python3 "$REPLAY_PY" --coverage --registry "$TEST_TMPDIR/reg.yaml" --repo-root "$FIX_REPO"
    echo "$output" | grep -q "GHOST-ID"
    echo "$output" | grep -q "$SAMPLE_ID"
    # 引用は 0 件のはず (ref: が無いゆえ)
    echo "$output" | grep -q "付きの言及を 0 件 別に数えた"
}

# ---------------------------------------------------------------------------
# T-QR-003: 引用が 1 件も無い日でも件数を表示する。
#   0 を表示しなければ「引用が無かった」と「引用を数えていない」を読む者が分けられない。
# ---------------------------------------------------------------------------
@test "T-QR-003: the quote count is announced even when it is zero" {
    _put_note "註のみ (id は書かない)"
    run python3 "$REPLAY_PY" --coverage --registry "$TEST_TMPDIR/reg.yaml" --repo-root "$FIX_REPO"
    echo "$output" | grep -q "付きの言及を 0 件 別に数えた"
}
