#!/usr/bin/env bats

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

setup() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/slim_yaml.XXXXXX")"
    export SHOGUN_QUEUE_DIR="$TEST_TMPDIR/queue"
    export TEST_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -x "$TEST_PYTHON" ] || TEST_PYTHON="python3"
    mkdir -p "$SHOGUN_QUEUE_DIR"/{tasks,reports,inbox}
    # 冷却期間 (cmd_1467) は既定 2 時間だが、下の試験の大半は「終端の帳面が片付くか」を
    # 見る物なので、ここでは 0 にして冷却を効かせない。試験が作る帳面は必ず出来たてで、
    # 冷却を効かせたままだと全部 見送られ、何を見ている試験なのかが変わってしまう。
    # 冷却そのものの試験は、末尾で1本ずつ値を立てて撃つ。
    export SHOGUN_TASK_SLIM_COOLDOWN_SECONDS=0
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

write_yaml() {
    local file="$1" value="$2"
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$value" > "$file"
}

run_slim() {
    "$TEST_PYTHON" "$PROJECT_ROOT/scripts/slim_yaml.py" "$@"
}

run_slim_wrapper() {
    bash "$PROJECT_ROOT/scripts/slim_yaml.sh" "$@"
}

yaml_value() {
    local file="$1" expr="$2"
    "$TEST_PYTHON" - "$file" "$expr" <<'PY'
import sys
import yaml

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

value = data
for key in expr.split("."):
    if isinstance(value, dict):
        value = value.get(key)
    else:
        value = None
        break
print("" if value is None else value)
PY
}

@test "dry-run does not mutate commands tasks reports inbox migration or create archive dir" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_done\n  status: done\n- id: cmd_pending\n  status: pending\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_done.yaml" $'parent_cmd: cmd_done\nstatus: done\n'
    touch -d "2 days ago" "$SHOGUN_QUEUE_DIR/reports/ashigaru1_cmd_done.yaml"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" $'messages:\n- id: m1\n  read: true\n- id: m2\n  read: false\n'
    mkdir -p "$SHOGUN_QUEUE_DIR/reports/archive"
    write_yaml "$SHOGUN_QUEUE_DIR/reports/archive/old.yaml" "status: done"

    before="$(find "$SHOGUN_QUEUE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"

    run run_slim karo --dry-run
    assert_success
    assert_output --partial "[DRY-RUN] would archive"

    after="$(find "$SHOGUN_QUEUE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"
    [ "$before" = "$after" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive" ]
    [ -f "$SHOGUN_QUEUE_DIR/reports/archive/old.yaml" ]
}

@test "wrapper dry-run does not create queue lock file" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_done\n  status: done\n'

    run run_slim_wrapper karo --dry-run
    assert_success

    [ ! -e "$SHOGUN_QUEUE_DIR/.slim_yaml.lock" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert data["queue"][0]["id"] == "cmd_done"
PY
}

# ★cmd_1463★ 台帳の語彙は instructions/common/task_flow.md:58-78 の 8 値である。
# 此の試験は 2026-07-28 まで paused を終端・blocked を非終端として釘付けにしておった
# (どちらも 8 値に無い綴りである) = 試験が誤りを固定する側に回っておった形。
@test "archives the four terminal ledger statuses and keeps the four non-terminal ones" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_done\n  status: done\n  evidence: closed\n- id: cmd_superseded\n  status: superseded\n  evidence: closed\n- id: cmd_cancelled\n  status: cancelled\n  evidence: closed\n- id: cmd_archived\n  status: archived\n  evidence: closed\n- id: cmd_pending\n  status: pending\n- id: cmd_in_progress\n  status: in_progress\n- id: cmd_deferred\n  status: deferred\n- id: cmd_dispatched\n  status: dispatched\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["queue"]]
assert ids == ["cmd_pending", "cmd_in_progress", "cmd_deferred", "cmd_dispatched"], ids
PY
    "$TEST_PYTHON" - "$(find "$SHOGUN_QUEUE_DIR/archive" -name 'shogun_to_karo_*.yaml')" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = sorted(item["id"] for item in data["queue"])
assert ids == ["cmd_archived", "cmd_cancelled", "cmd_done", "cmd_superseded"], ids
PY
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive" -name 'shogun_to_karo_*.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

# ★陽性と陰性を対で撃つ★= 8 値どおりに書いた entry は名指されず、8 値に無い綴りは名指される。
# 陰性側の綴りは実台帳に現に居る 1 件 (cmd_1463 の実測) を写した物である。
@test "canonical ledger statuses are not reported as non-canonical but an unknown spelling still is" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_pending\n  status: pending\n- id: cmd_in_progress\n  status: in_progress\n- id: cmd_deferred\n  status: deferred\n- id: cmd_dispatched\n  status: dispatched\n- id: cmd_done\n  status: done\n- id: cmd_superseded\n  status: superseded\n- id: cmd_cancelled\n  status: cancelled\n- id: cmd_archived\n  status: archived\n'

    run run_slim karo --dry-run
    assert_success
    refute_output --partial "non-canonical command status"

    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_bogus\n  status: superseded_by_17_30_correction\n'
    run run_slim karo --dry-run
    assert_success
    assert_output --partial "non-canonical command status: cmd_bogus:superseded_by_17_30_correction"
}

# このテストが守るのは家老の状態そのものである。台帳の8値をそのまま task file へ当てると
# status: archived の task file (karo.yaml 等) が終端と読まれ、ファイルごと archive へ移って
# idle の置き札に化ける。task file の語彙は別で、archived は「退いた持ち場の記録」= 非終端である
# (正本 = instructions/common/task_flow.md の「タスクファイルの終端 / 非終端」の表)。
@test "task file with status archived is left alone and not named" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/karo.yaml" $'worker_id: karo\ntask_id: subtask_karo\nstatus: archived\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/gunshi_a.yaml" $'task_id: subtask_legacy_gunshi\nstatus: archived\n'

    run run_slim karo
    assert_success
    refute_output --partial "karo.yaml has non-canonical status"
    refute_output --partial "gunshi_a.yaml has non-canonical status"

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/karo.yaml" "status")" = "archived" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/karo.yaml" "task_id")" = "subtask_karo" ]
    [ -f "$SHOGUN_QUEUE_DIR/tasks/gunshi_a.yaml" ]
    [ ! -d "$SHOGUN_QUEUE_DIR/archive/tasks" ]
}

# task file の終端は done と failed の二つである (task_flow.md:112-118)。
@test "failed task file is terminal and canonical task is reset to idle" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru3.yaml" $'worker_id: ashigaru3\ntask_id: subtask_failed\nstatus: failed\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru3.yaml" "status")" = "idle" ]
    [ "$(find "$SHOGUN_QUEUE_DIR/archive/tasks" -name 'ashigaru3_*.yaml' | wc -l)" -eq 1 ]
}

# task file の blocked は「まだ始めるな」= 非終端。台帳の語彙には元より無い綴りである。
@test "blocked task file is kept as active and not reported as non-canonical" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru4.yaml" $'worker_id: ashigaru4\ntask_id: subtask_blocked\nstatus: blocked\n'

    run run_slim karo
    assert_success
    refute_output --partial "ashigaru4.yaml has non-canonical status"

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru4.yaml" "status")" = "blocked" ]
}

@test "supports current top-level task status and resets canonical task to top-level idle" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_done\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/subtask_done.yaml" $'task_id: subtask_done\nstatus: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "worker_id")" = "ashigaru1" ]
    [ ! -f "$SHOGUN_QUEUE_DIR/tasks/subtask_done.yaml" ]
    [ -f "$SHOGUN_QUEUE_DIR/archive/tasks/subtask_done.yaml" ]
}

@test "supports legacy task.status and preserves legacy idle shape" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" $'task:\n  task_id: subtask_legacy\n  status: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "task.status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "status")" = "" ]
}

# ── cmd_1467: 待機ファイルを空にしない ──
# 2026-07-28 08:09:28 に、ちょうど done だった足軽2名のタスク YAML が中身2行だけに
# なった。done は「もう要らない」ではなく「次の指示を待っている」状態である。
# 下の6本は「誰が」「何を終えて」「全文はどこにあり」「いつ時点の写しか」が
# 待機ファイルに残ることを確かめる。

@test "cmd_1467: top-level stub keeps identity and points at the archive" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_1462_bloom\nparent_cmd: cmd_1462\nstatus: done\n'

    run run_slim karo
    assert_success

    local stub="$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml"
    [ "$(yaml_value "$stub" "status")" = "idle" ]
    [ "$(yaml_value "$stub" "last_task_id")" = "subtask_1462_bloom" ]
    [ "$(yaml_value "$stub" "last_parent_cmd")" = "cmd_1462" ]
    [ -n "$(yaml_value "$stub" "archived_from")" ]
    [ -n "$(yaml_value "$stub" "archived_at")" ]
}

@test "cmd_1467: legacy task.status stub keeps identity inside the task mapping" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" $'task:\n  task_id: subtask_legacy\n  parent_cmd: cmd_1467\n  status: done\n'

    run run_slim karo
    assert_success

    local stub="$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml"
    [ "$(yaml_value "$stub" "task.status")" = "idle" ]
    [ "$(yaml_value "$stub" "task.last_task_id")" = "subtask_legacy" ]
    [ "$(yaml_value "$stub" "task.last_parent_cmd")" = "cmd_1467" ]
    [ -n "$(yaml_value "$stub" "task.archived_from")" ]
    # 旧形の置き札は top-level を持たぬまま = 形そのものは変えておらぬ
    [ "$(yaml_value "$stub" "status")" = "" ]
}

# 文字列が合っているだけでは足りない (cmd_1440 の教訓)。
# 参照先のファイルが実際に存在するかまで確かめる。このリポジトリには、名前だけ
# 合っていて実体の無い参照が5か月 誰にも気づかれず残っていた例がある。
@test "cmd_1467: archived_from names a file that really exists" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru5.yaml" $'worker_id: ashigaru5\ntask_id: subtask_ptr\nstatus: done\n'

    run run_slim karo
    assert_success

    local pointer
    pointer="$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru5.yaml" "archived_from")"
    [ -n "$pointer" ]
    [ -f "$SHOGUN_QUEUE_DIR/archive/tasks/$pointer" ]
    # 控えの中身が、消える前の帳面そのものであること
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/archive/tasks/$pointer" "task_id")" = "subtask_ptr" ]
}

# アーカイブのファイル名の日時と、待機ファイルに書く日時が、同じ1つの出所から
# 出ていること。別々に now() を呼ぶと、境目の1秒で二つが食い違う。
@test "cmd_1467: archived_at agrees with the timestamp in the archive filename" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru6.yaml" $'worker_id: ashigaru6\ntask_id: subtask_stamp\nstatus: done\n'

    run run_slim karo
    assert_success

    local pointer stamp expected
    pointer="$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru6.yaml" "archived_from")"
    # ashigaru6_20260728080928.yaml → 20260728080928
    stamp="${pointer##*_}"; stamp="${stamp%.yaml}"
    expected="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:8:2}:${stamp:10:2}:${stamp:12:2}"
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru6.yaml" "archived_at")" = "$expected" ]
}

# 無い物を空文字で埋めると「在るが空」と「元より無い」が同じ顔になる。
@test "cmd_1467: a task file without task_id gains no empty last_task_id" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru3.yaml" $'worker_id: ashigaru3\nstatus: done\n'

    run run_slim karo
    assert_success

    run "$TEST_PYTHON" -c "
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as fh:
    data = yaml.safe_load(fh) or {}
print('last_task_id' in data, 'last_parent_cmd' in data, 'archived_from' in data)
" "$SHOGUN_QUEUE_DIR/tasks/ashigaru3.yaml"
    assert_success
    assert_output "False False True"
}

# 後方互換の約束 = 待機ファイルは task_id を設定しない。
# 監視スクリプト (stall_watchdog_scan.py) と idle_revive_scan.py は task_id を読む。
# 待機ファイルが task_id を持つと「status は idle なのにタスクが載っている」
# ファイルに見えてしまう。そのため別の名前 last_task_id で残している。
# このテストが、名前を task_id へ戻す変更を止める役目を持つ。
@test "cmd_1467: the stub does not set task_id so existing readers still see no task" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_compat\nparent_cmd: cmd_1467\nstatus: done\n'
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" $'task:\n  task_id: subtask_compat2\n  status: done\n'

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "task_id")" = "" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "parent_cmd")" = "" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru2.yaml" "task.task_id")" = "" ]

    # 番人が現に読んで「assigned は 0 本」と答えること (置き札を任と読まぬ証)
    run "$TEST_PYTHON" "$PROJECT_ROOT/scripts/stall_watchdog_scan.py" --dry-run \
        --queue-root "$SHOGUN_QUEUE_DIR" --no-qc-scan --no-qc-ledger-scan
    assert_success
    assert_output --partial "assigned=0"
}

@test "archives read inbox messages and preserves unread messages" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" $'messages:\n- id: read-msg\n  read: true\n- id: unread-msg\n  read: false\n'

    run run_slim karo
    assert_success

    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/inbox/karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["messages"]]
assert ids == ["unread-msg"], ids
PY
    archive_count="$(find "$SHOGUN_QUEUE_DIR/archive" -name 'inbox_karo_*.yaml' | wc -l)"
    [ "$archive_count" -eq 1 ]
}

@test "inbox with null messages value is treated as empty and does not fail" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/inbox/gunshi_a.yaml" "messages:"

    run run_slim karo
    assert_success

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/inbox/gunshi_a.yaml" "messages")" = "" ]
    archive_count="$(find "$SHOGUN_QUEUE_DIR" -name 'inbox_gunshi_a_*.yaml' 2>/dev/null | wc -l)"
    [ "$archive_count" -eq 0 ]
}

@test "ntfy inbox old pending entries are inventoried but not deleted" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" $'inbox:\n- id: pending-old\n  status: pending\n  timestamp: "2000-01-01T00:00:00+09:00"\n- id: processed-old\n  status: processed\n  timestamp: "2000-01-01T00:00:00+09:00"\n'

    run run_slim karo --dry-run
    assert_success
    assert_output --partial "old ntfy pending/non-terminal entries kept"
    assert_output --partial "old ntfy terminal entries available for explicit cleanup"

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" "inbox.0.id")" = "" ]
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/ntfy_inbox.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["inbox"]]
assert ids == ["pending-old", "processed-old"], ids
PY
}

# cmd_1463 裁(1): 剪定の条件 = 正本 instructions/karo.md の「剪定 gate」の項
# 「終端 status かつ evidence 欄に close 根拠があること」を満たすエントリのみ剪定可。
# これが無いと、家老が slim を撃った瞬間に evidence の空な45件 (2026-07-28 08:0x 実測) が
# 黙って archive へ移る。
@test "terminal command without evidence is kept and named while one with evidence is archived" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_with_evidence\n  status: done\n  evidence: "B1 done (a975a27)"\n- id: cmd_no_evidence\n  status: superseded\n- id: cmd_empty_evidence\n  status: archived\n  evidence: ""\n- id: cmd_active\n  status: in_progress\n'

    run run_slim karo
    assert_success
    assert_output --partial "terminal but evidence is empty: 2 kept"
    assert_output --partial "cmd_no_evidence"
    assert_output --partial "cmd_empty_evidence"

    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["queue"]]
assert ids == ["cmd_no_evidence", "cmd_empty_evidence", "cmd_active"], ids
PY
    "$TEST_PYTHON" - "$(find "$SHOGUN_QUEUE_DIR/archive" -name 'shogun_to_karo_*.yaml')" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
ids = [item["id"] for item in data["queue"]]
assert ids == ["cmd_with_evidence"], ids
PY
}

# 空白だけの evidence を「有り」と読むと、条件は書式だけを見る抜け道になる。
@test "evidence made of whitespace only counts as empty" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_blank\n  status: done\n  evidence: "   "\n'

    run run_slim karo
    assert_success
    assert_output --partial "terminal but evidence is empty: 1 kept"
    "$TEST_PYTHON" - "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert [i["id"] for i in data["queue"]] == ["cmd_blank"]
PY
}

# 非終端のエントリは evidence が無くても名指されない (条件は終端にだけ掛かる)。
@test "non-terminal command without evidence is not named by the evidence check" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" $'queue:\n- id: cmd_x\n  status: in_progress\n- id: cmd_y\n  status: deferred\n'

    run run_slim karo
    assert_success
    refute_output --partial "terminal but evidence is empty"
}

# ── cmd_1467: 仕事を終えた直後の帳面を消さない (冷却期間) ──
# 2026-07-28 08:09:28 に掃除を撃った時、その瞬間 status: done だった足軽2名の帳面が
# 中身2行まで削られた。done は「もう要らない」ではなく「次の指示を待っている」状態である。
# 控え94本を測ると、6回に1回 (17.0%) は足軽が5分以内に書いた帳面を消していた。
# 下の6本は「出来たての終端は見送る・古い終端は現に片付く」を対で撃つ。
# 片方だけでは、見送りが効いたのか そもそも何も見ていないのかが分けられない。

@test "cmd_1467: 出来たての done は見送られ、中身が残る" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_fresh\nparent_cmd: cmd_1467\nstatus: done\ndescription: |\n  終えた直後。次の指示を待っている。\n'

    SHOGUN_TASK_SLIM_COOLDOWN_SECONDS=7200 run run_slim karo
    assert_success

    # 指示文が現に残っていること (置き札に化けていない)
    run cat "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml"
    assert_output --partial "次の指示を待っている"
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "task_id")" = "subtask_fresh" ]
    # 控えへも移っていないこと
    [ -z "$(ls -A "$SHOGUN_QUEUE_DIR/archive/tasks" 2>/dev/null)" ]
}

@test "cmd_1467: 見送った物を名乗る (黙って見送らない)" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_named\nstatus: done\n'

    SHOGUN_TASK_SLIM_COOLDOWN_SECONDS=7200 run run_slim karo
    assert_success
    assert_output --partial "ashigaru1.yaml を見送る"
    assert_output --partial "合わせて 1 本 見送った"
}

# ★陰性側★ 冷却を越えた帳面は現に片付くこと。
# これが無いと「常に見送る」だけの実装でも上の試験は緑になる。
@test "cmd_1467: 冷却を越えた done は現に片付く" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" $'worker_id: ashigaru1\ntask_id: subtask_old\nstatus: done\ndescription: |\n  古い終端。\n'
    touch -d "3 hours ago" "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml"

    SHOGUN_TASK_SLIM_COOLDOWN_SECONDS=7200 run run_slim karo
    assert_success
    refute_output --partial "見送る"

    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "status")" = "idle" ]
    [ "$(yaml_value "$SHOGUN_QUEUE_DIR/tasks/ashigaru1.yaml" "last_task_id")" = "subtask_old" ]
}

# canonical でない名前の帳面は「ファイルごと消える」道を通る。
# そちらにも同じ見送りが掛かること。
@test "cmd_1467: canonical でない帳面も、出来たてなら見送られる" {
    write_yaml "$SHOGUN_QUEUE_DIR/shogun_to_karo.yaml" "queue: []"
    write_yaml "$SHOGUN_QUEUE_DIR/tasks/gunshi_a.yaml" $'task_id: subtask_noncanon\nstatus: done\n'

    SHOGUN_TASK_SLIM_COOLDOWN_SECONDS=7200 run run_slim karo
    assert_success
    assert_output --partial "gunshi_a.yaml を見送る"
    [ -f "$SHOGUN_QUEUE_DIR/tasks/gunshi_a.yaml" ]
}

# ★刻が読めない時は見送る側へ倒す★ = 消してよいと言い切れない物を消さない。
@test "cmd_1467: 最終書込の刻が読めない帳面は見送る" {
    run "$TEST_PYTHON" - "$PROJECT_ROOT/scripts/slim_yaml.py" <<'PY'
import sys, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("sy", sys.argv[1])
sy = importlib.util.module_from_spec(spec); spec.loader.exec_module(sy)
# 在りもしない path を渡す = stat が落ちる
reason = sy.task_slim_hold_reason(Path("/nonexistent/dir/never.yaml"), 7200)
print("HOLD" if reason else "SLIM")
print(reason or "")
PY
    assert_success
    assert_output --partial "HOLD"
    assert_output --partial "刻が読めない"
}

@test "cmd_1467: 冷却の指定が数として読めない時は既定へ倒す (0 にしない)" {
    run "$TEST_PYTHON" - "$PROJECT_ROOT/scripts/slim_yaml.py" <<'PY'
import sys, os, importlib.util
os.environ["SHOGUN_TASK_SLIM_COOLDOWN_SECONDS"] = "ちょっと"
spec = importlib.util.spec_from_file_location("sy", sys.argv[1])
sy = importlib.util.module_from_spec(spec); spec.loader.exec_module(sy)
got = sy.get_task_slim_cooldown_seconds()
# ★2つの値を並べて刷るな★= どちらが出ても通る形になる。
# 初版は got と既定を両方 刷って「7200 が在るか」を見ており、got が 0 でも
# 既定の 7200 が刷られるので緑のままだった (変異 MC5 が生き残って露見した)。
print("SAME" if got == sy.TASK_SLIM_COOLDOWN_SECONDS else f"DIFF got={got}")
PY
    assert_success
    # 読めない値で 0 (= 冷却なし) へ落ちると、守りが黙って消える。
    # assert_line で行を名指す (assert_output の全文一致だと、下の警告の1行で落ちる)。
    assert_line "SAME"
    # 黙って既定へ倒すのではなく、読めなかったことを名乗ること
    assert_output --partial "数として読めない"
}
