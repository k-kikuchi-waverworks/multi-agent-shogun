#!/usr/bin/env bats
# test_stop_hook.bats — stop_hook_inbox.sh unit tests
#
# Calls the REAL production script with env var overrides:
#   __STOP_HOOK_SCRIPT_DIR → points to test temp directory
#   __STOP_HOOK_AGENT_ID   → mocks tmux agent detection
#
# テスト構成:
#   T-HOOK-001: stop_hook_active=true → exit 0
#   T-HOOK-002: agent不明 → exit 0
#   T-HOOK-003: agent_id=shogun → exit 0
#   T-HOOK-004: 完了メッセージ → inbox_writeが呼ばれる (report_completed)
#   T-HOOK-005: エラーメッセージ → inbox_writeが呼ばれる (error_report)
#   T-HOOK-006: 中立メッセージ → inbox_write呼ばれない
#   T-HOOK-007: last_assistant_message空 → inbox_write呼ばれない
#   T-HOOK-008: inbox未読あり → block JSON出力
#   T-HOOK-009: inbox未読なし + 完了メッセージ → exit 0 + 通知あり
#   T-HOOK-010: inbox未読あり + 完了メッセージ → block + 通知あり

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/scripts/stop_hook_inbox.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"

    # Mock inbox_write.sh — logs arguments to file
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: run the REAL hook script with test overrides
run_hook() {
    local json="$1"
    local agent_id="${2:-ashigaru1}"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="$agent_id" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

# Helper: run with no agent ID set
run_hook_no_agent() {
    local json="$1"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

@test "T-HOOK-001: stop_hook_active=true skips all processing" {
    run_hook '{"stop_hook_active": true, "last_assistant_message": "任務完了"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-002: unknown agent (empty agent_id) exits 0" {
    run_hook_no_agent '{"stop_hook_active": false}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-003: shogun agent always exits 0" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了"}' "shogun"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-004: completion message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了でござる。report YAML更新済み。"}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
    grep -q "ashigaru1" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-005: error message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "ファイルが見つからない。エラーで中断する。"}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "error_report" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-006: neutral message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "待機する。次の指示を待つ。"}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-007: empty last_assistant_message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

# ───────────────────────────────────────────────────────────
# T-HOOK-011 (cmd_1468): fixture の形が、実際に書く側の形と同じであること
# ───────────────────────────────────────────────────────────
# T-HOOK-008/010 は 2026-07-28 08:43 時点で赤だった。原因は hook ではなく fixture である。
# fixture は `  - id:` (list を2字 下げる形) で書いており、key が4字 下がっていた。
# 一方 stop_hook_inbox.sh は `^  read: false` = ★2字ちょうど★ で数える。
# 実際に書く側 (inbox_write.sh) は PyYAML の
#   yaml.dump(default_flow_style=False, indent=2)
# を使い、★list を下げない★ ゆえ key は2字である。
# つまり fixture だけが現物と違う形をしており、
#   T-HOOK-008/010 = 未読があるのに0件と数えて赤
#   T-HOOK-009     = 既読だから緑ではなく、★そもそも一件も数えていないから緑★
# になっていた。009 の緑は「検めて通った」ではなく「見る物が無かった」側である (規 条5)。
#
# 本テストは、書く側と同じ dump 設定で1件 吐かせ、hook が使う数え方が
# ★現に当たる★ ことを撃つ。書く側の serialize 契約が変われば、ここが先に落ちる。
@test "T-HOOK-011: fixture shape matches what the real writer emits (unread grep hits)" {
    local generated="$TEST_TMP/generated_inbox.yaml"
    python3 - "$generated" <<'PY'
import sys, yaml
data = {"messages": [{
    "id": "msg_001", "from": "karo", "timestamp": "2026-07-28T08:43:00",
    "type": "task_assigned", "content": "新タスクだ", "read": False,
}]}
with open(sys.argv[1], "w") as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
PY

    # 陽性: hook と同じ数え方で1件 当たる
    [ "$(grep -cE '^  read: false' "$generated")" -eq 1 ]

    # 陰性: 旧 fixture の形 (key が4字) では当たらない = 数え方は形に敏感である
    cat > "$TEST_TMP/old_shape.yaml" << 'YAML'
messages:
  - id: msg_001
    read: false
YAML
    [ "$(grep -cE '^  read: false' "$TEST_TMP/old_shape.yaml")" -eq 0 ]
}

@test "T-HOOK-008: unread inbox messages produce block JSON" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
- id: msg_001
  from: karo
  type: task_assigned
  content: "新タスクだ"
  read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
}

@test "T-HOOK-009: no unread + completion message exits 0 with notification" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
- id: msg_001
  from: karo
  type: task_assigned
  content: "古いメッセージ"
  read: true
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "タスク完了した。report YAML updated。"}'
    [ "$status" -eq 0 ]
    # cmd_1401: 旧 `[ -z "$output" ] || ! echo … | grep -q` は ★行途中の否定も set -e 免除★
    # ゆえ当たっても緑であった (2026-07-27 実測)。★出力が在って且つ block を含む★時のみ落とす形へ。
    if [ -n "$output" ] && echo "$output" | grep -q '"block"'; then return 1; fi
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-010: unread inbox + completion message blocks AND notifies" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
- id: msg_001
  from: karo
  type: task_assigned
  content: "次のタスク"
  read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "任務完了でござる。"}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}
