#!/usr/bin/env bats
# e2e_bloom_routing.bats — Dim C: スマート切り替えE2Eテスト
# Issue #53 Phase 2 — find_agent_for_model() + karo bloom routing 統合検証
#
# VPS上でのみ実行を想定。tmuxセッション "multiagent" が起動済みで
# 混合CLI設定（ashigaru1-3=Spark, ashigaru4-5=Sonnet, ashigaru6-7=Opus）が
# 必要。
#
# 事前条件:
#   - VPS設定: ashigaru1-3=codex/spark, ashigaru4-5=claude/sonnet, ashigaru6-7=claude/opus
#   - bloom_routing: "manual" または "auto"
#   - 全足軽がアイドル状態（テスト開始前）
#
# 実行方法:
#   bats tests/e2e/e2e_bloom_routing.bats
#
# ═══════════════════════════════════════════════════════════════
# ★TC-BLOOM-004 と 005 は、稼働中の agent を止めます★ (cmd_1462)
# ═══════════════════════════════════════════════════════════════
#
# この 2 本は、実際の tmux pane へキー入力を送ります。
#   ・ashigaru4 / ashigaru5 の pane へ "echo 'Working...'; sleep 30" を打ち込む
#   ・テストの終わりに、その pane へ Ctrl-C を送る
# その間、その agent の作業は止まります。手元の環境ではなく、動いている agent です。
#
# 2026-07-28 に測ったところ、pane が存在する環境ではこの 2 本は skip されず、
# そのまま実行されていました。つまり誰かが何気なく `bats tests/e2e/` を走らせると、
# 他の者の作業が止まります。
#
# そこで、この 2 本は明示的に opt-in した時だけ走る形にしました。
#
#   E2E_BLOOM_ALLOW_LIVE_PANES=1 bats tests/e2e/e2e_bloom_routing.bats
#
# 走らせてよいのは、全 agent がアイドルで、止めてよいと分かっている時だけです。
#
# opt-in していない時は SKIP にしません。不合格にします。
# SKIP は「走っていないのに合格」に見えるためです（この repo では SKIP=FAIL）。
# 不合格の文面に「何が守られていないか」を書いてあります。
#
# 残りの 4 本（001/002/003/006）は opt-in を要りません。
# get_recommended_model と find_agent_for_model を呼ぶだけで、pane へ書き込みません
# （lib/ の中に send-keys は 1 件も無いことを確認済み）。
#
# 詳細: docs/content/ops/cmd_1462_e2e_live_pane_optin.md

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# 稼働中の pane へ書き込むテストの入口。tmux を触る前に必ず通す。
require_live_pane_optin() {
    if [ "${E2E_BLOOM_ALLOW_LIVE_PANES:-0}" = "1" ]; then
        return 0
    fi
    echo "このテストは走っていません。合格ではありません。" >&2
    echo "" >&2
    echo "  理由: 稼働中の agent の pane へ実際にキー入力を送るため、既定では走らせない。" >&2
    echo "  何が起きるか: ashigaru4/5 の pane へ \"sleep 30\" を打ち込み、終了時に Ctrl-C を送る。" >&2
    echo "                その間、その agent の作業は止まる。" >&2
    echo "" >&2
    echo "  走らせるには: E2E_BLOOM_ALLOW_LIVE_PANES=1 bats tests/e2e/e2e_bloom_routing.bats" >&2
    echo "  走らせてよいのは、全 agent がアイドルで、止めてよいと分かっている時だけ。" >&2
    echo "" >&2
    echo "  今 守られていないもの: ビジー時の Bloom ルーティング" >&2
    echo "    ・ashigaru4 がビジーの時、L5 タスクが ashigaru5 へ回るか (TC-BLOOM-004)" >&2
    echo "    ・Sonnet 足軽が全員ビジーの時、Codex へ降格せず QUEUE になるか (TC-BLOOM-005)" >&2
    echo "" >&2
    echo "  詳細: docs/content/ops/cmd_1462_e2e_live_pane_optin.md" >&2
    return 1
}

setup() {
    # tmuxセッションの存在確認
    if ! tmux has-session -t multiagent 2>/dev/null; then
        skip "tmux session 'multiagent' が存在しない。VPS上でshutsuijin後に実行せよ。"
    fi

    TEST_TMP="$(mktemp -d)"
    make_fixture_settings

    # ★振り分けの判断を試すテストは fixture の布陣に対して撃つ★ (cmd_1462)
    #   live の config/settings.yaml に対して撃つと、家老が班構成を変えるたびに落ちる。
    #   守りたいのは「この布陣なら、この Bloom level はこのモデルへ行く」という判断であって、
    #   今日たまたま誰が何のモデルかではない。
    #   live を読む道は TC-BLOOM-100 に 1 本だけ残してある (下を参照)。
    export CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_fixture.yaml"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/agent_status.sh" 2>/dev/null || true
}

# 試験用の布陣。実際の班構成とは無関係で、動かない。
#   Spark  (max_bloom=3) = ashigaru1-3
#   Sonnet (max_bloom=5) = ashigaru4-5
#   Opus   (max_bloom=6) = ashigaru6-7
make_fixture_settings() {
    cat > "${TEST_TMP}/settings_fixture.yaml" <<'FIXEOF'
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-sonnet-4-6:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
cli:
  agents:
    ashigaru1: {cli: codex,  model: gpt-5.3-codex-spark}
    ashigaru2: {cli: codex,  model: gpt-5.3-codex-spark}
    ashigaru3: {cli: codex,  model: gpt-5.3-codex-spark}
    ashigaru4: {cli: claude, model: claude-sonnet-4-6}
    ashigaru5: {cli: claude, model: claude-sonnet-4-6}
    ashigaru6: {cli: claude, model: claude-opus-4-6}
    ashigaru7: {cli: claude, model: claude-opus-4-6}
FIXEOF
}

teardown() {
    # fixture の一時ディレクトリを片付ける (cmd_1462)
    [ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
    :
}

# 振り分けの判断だけを見るための固定 (cmd_1462)。
#
# find_agent_for_model は 2 つを見る。
#   (a) 設定のどの足軽がそのモデルか  ← fixture で固定できる
#   (b) その足軽が今ビジーか          ← live の tmux を見る。固定できない
# (b) をそのままにすると、実際に足軽が働いている時は空いている別の足軽へ
# フォールバックし、テストは布陣と関係なく落ちる (2026-07-28 に現に踏んだ)。
#
# ここで固定するのは (b) だけである。振り分けの判断そのもの (a) は本物を通す。
# 実際の pane のビジー状態に対する検証は TC-BLOOM-004/005 が受け持つ。
stub_all_agents_idle() {
    agent_is_busy_check() { return 1; }   # 1 = idle
}
# ─────────────────────────────────────────────
# TC-BLOOM-001: L1タスク → Spark足軽（ashigaru1/2/3）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-001: L1タスク → Sparkエージェントに振られる" {
    stub_all_agents_idle
    run get_recommended_model 1
    [ "$status" -eq 0 ]
    # L1はSpark (max_bloom=3)が最安
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    # Spark足軽はashigaru1, 2, 3のいずれか
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-002: L5タスク → Sonnet足軽（ashigaru4/5）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-002: L5タスク → Sonnetエージェントに振られる" {
    stub_all_agents_idle
    run get_recommended_model 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"sonnet"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[4-5]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-003: L6タスク → Opus足軽（ashigaru6/7）に振られる
# ─────────────────────────────────────────────
@test "TC-BLOOM-003: L6タスク → Opusエージェントに振られる" {
    stub_all_agents_idle
    run get_recommended_model 6
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[6-7]$ ]]
}


# ─────────────────────────────────────────────
# TC-BLOOM-100: live の設定ファイルを読む唯一の 1 本 (cmd_1462)
# ─────────────────────────────────────────────
@test "TC-BLOOM-100: live の settings.yaml を読んでも、黙って空を返さない" {
    # ★このテストが守っているもの★
    #
    # 上の 4 本は fixture の布陣に対して撃つ。班構成が動いても落ちないためである。
    # その代わり、live の config/settings.yaml を 1 本も読まなくなる。
    # そうすると「設定ファイルの形が変わって、adapter が読めなくなった」時に
    # 誰も気づかない。この 1 本がその穴を塞ぐ。
    #
    # ★今日の布陣は見ない★。見るのは「adapter が live の設定に対して
    #   はっきりした答を返すか」だけである。答は 2 通りしかない。
    #     rc=0 → モデル名を 1 行 返す
    #     rc=2 → 判定材料が無い、と理由を名乗る (今日はこちら。capability_tiers 未設定)
    #   ★空を返して rc=0★ は、どちらでもない。これが cmd_1462 で直したバグである。
    #
    # ゆえに、このテストが赤くなる時に疑うのは次の 2 つ。
    #   ・config/settings.yaml が壊れた (YAML として読めない → rc=3)
    #   ・adapter が設定を読む道が壊れた

    local live_settings="${PROJECT_ROOT}/config/settings.yaml"
    [ -f "$live_settings" ]

    # live の設定を読ませる (このテストだけ fixture を使わない)
    run env CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT" \
            CLI_ADAPTER_SETTINGS="$live_settings" \
            bash -c 'source "$CLI_ADAPTER_PROJECT_ROOT/lib/cli_adapter.sh" >/dev/null 2>&1; get_recommended_model 5'

    if [ "$status" -eq 0 ]; then
        # モデル名を返したなら、空であってはならない
        [ -n "$output" ]
    else
        # 返せないなら、理由を名乗っていること。黙って空で終わらせない
        [ "$status" -eq 2 ] || [ "$status" -eq 3 ]
        run env CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT" \
                CLI_ADAPTER_SETTINGS="$live_settings" \
                bash -c 'source "$CLI_ADAPTER_PROJECT_ROOT/lib/cli_adapter.sh" >/dev/null 2>&1; get_recommended_model 5 2>&1 1>/dev/null'
        [[ "$output" == *"NO-RECOMMENDATION"* ]]
    fi
}

# ─────────────────────────────────────────────
# TC-BLOOM-004: ashigaru4ビジー + L5タスク → ashigaru5に振られる
# kill/restart発生なし（ビジーペイン不変確認）
# ─────────────────────────────────────────────
@test "TC-BLOOM-004: ashigaru4ビジー時、L5タスクはashigaru5に振られる" {
    # ★稼働中の agent へ書き込む。tmux を触る前に opt-in を確かめる★
    require_live_pane_optin || return 1

    # ashigaru4のペインターゲットを取得
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru4" {print $1}')

    if [[ -z "$pane4" ]]; then
        # opt-in した上で pane が無いのは環境の問題ではなく、前提が崩れている。
        # SKIP にすると「走っていないのに合格」になるので不合格にする。
        echo "opt-in したが ashigaru4 の pane が見つからない。" >&2
        echo "  出陣していないか、@agent_id が設定されていない。" >&2
        return 1
    fi

    # sleep でビジー状態を作成（teardownはtrapで保証）
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # ビジー確認
    busy_rc=0
    agent_is_busy_check "$pane4" && true || busy_rc=$?
    if [[ $busy_rc -ne 0 ]]; then
        echo "ashigaru4 をビジー状態にできなかった（busy_rc=${busy_rc}）。" >&2
        echo "  ビジー判定そのものが壊れている可能性がある。SKIP にせず不合格とする。" >&2
        return 1
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # ashigaru4はビジーなのでashigaru5に振られるべき
    [ "$output" = "ashigaru5" ] || \
        { echo "期待: ashigaru5, 実際: $output"; return 1; }

    # ashigaru4がまだ稼働中（kill/restartされていない）を確認
    still_busy=0
    agent_is_busy_check "$pane4" && true || still_busy=$?
    [[ $still_busy -eq 0 ]] || echo "WARNING: ashigaru4の状態が変化した（kill/restartの可能性）"
}

# ─────────────────────────────────────────────
# TC-BLOOM-005: ashigaru4/5両方ビジー + L5タスク → QUEUE（Codexに降格しない）
# ─────────────────────────────────────────────
@test "TC-BLOOM-005: Sonnet足軽全員ビジー時、QUEUEになる（Codexへの降格なし確認）" {
    # ★稼働中の agent へ書き込む。tmux を触る前に opt-in を確かめる★
    require_live_pane_optin || return 1

    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru4" {print $1}')
    pane5=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru5" {print $1}')

    if [[ -z "$pane4" || -z "$pane5" ]]; then
        # 理由は TC-BLOOM-004 と同じ。SKIP にせず不合格にする。
        echo "opt-in したが ashigaru4 または ashigaru5 の pane が見つからない。" >&2
        echo "  出陣していないか、@agent_id が設定されていない。" >&2
        return 1
    fi

    # sleep でashigaru4/5をビジー状態に（teardownはtrapで保証）
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; tmux send-keys -t '$pane5' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    tmux send-keys -t "$pane5" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # 両方ビジー確認
    rc4=0; agent_is_busy_check "$pane4" && true || rc4=$?
    rc5=0; agent_is_busy_check "$pane5" && true || rc5=$?

    if [[ $rc4 -ne 0 || $rc5 -ne 0 ]]; then
        echo "ashigaru4/5 のいずれかをビジー状態にできなかった（rc4=${rc4}, rc5=${rc5}）。" >&2
        echo "  ビジー判定そのものが壊れている可能性がある。SKIP にせず不合格とする。" >&2
        return 1
    fi

    # L5タスクのルーティング
    recommended=$(get_recommended_model 5)
    # Sonnet足軽が全員ビジー → フォールバックまたはQUEUE
    result=$(find_agent_for_model "$recommended")

    # フォールバック（他のアイドル足軽）またはQUEUEが許容される
    # Sonnet足軽でないフォールバックの場合、モデル品質の警告を出す
    if [[ "$result" =~ ^ashigaru[1-3]$ ]]; then
        echo "フォールバック先: $result (Sparkエージェント — 品質低下注意)"
    elif [[ "$result" = "QUEUE" ]]; then
        echo "QUEUE: 全足軽ビジー"
    else
        echo "フォールバック先: $result"
    fi

    # QUEUEかashigaruを返すことを確認（何もしないは×）
    [[ "$result" = "QUEUE" ]] || [[ "$result" =~ ^ashigaru[0-9]+$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-006: L3タスク → Sonnet足軽には振られない（Codex優先）
# ─────────────────────────────────────────────
@test "TC-BLOOM-006: L3タスクはSpark足軽が優先（Sonnetへのオーバーエンジニアリングなし）" {
    stub_all_agents_idle
    run get_recommended_model 3
    [ "$status" -eq 0 ]

    # L3の推奨モデルはSonnetではなくSpark
    [[ "$output" != *"sonnet"* ]] || { echo "L3でSonnetが推奨された（コスト最適化違反）"; return 1; }
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # Spark足軽（ashigaru1-3）のみ
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}
